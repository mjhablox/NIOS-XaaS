# DDIaaS DHCP Endpoint — Operations Runbook

**Scope:** Day-2 operations for DDIaaS DHCP endpoints running on Kea (2.2 / 2.6) with
CloudNativePG (CNPG) Postgres backend on AWS EKS.

**Audience:** On-call engineers, SREs, and developers debugging customer endpoint
issues on `stage` / `prod`.

**Last updated:** 2026-04-28

---

## 0. Conventions

| Variable | Example | Where it comes from |
|---|---|---|
| `ENDPOINT_ID` | `zxftpxzvcsagz5leigsjooew55gl4gfw` | CSP API → `endpoints[].id` |
| `NS` | `ddiaas-dhcp-endpoint` | Endpoint namespace on EKS |
| `CLUSTER` | `cnpg-${ENDPOINT_ID}` | CNPG cluster name |
| `CSP_URL` | `stage.csp.infoblox.com` / `csp.infoblox.com` | Per environment |
| `CSP_API_TOKEN` | (secret) | Per environment / per user |
| `FFO_NAME` | `adc-ddiaas-dhcp-account-override-kea-2.6` | FeatureFlagOverride for Kea 2.6 |
| `FFO_NS` | `atlas-app-def-system` | FFO namespace |

Set up your shell session:

```bash
export ENDPOINT_ID=<id>
export NS=ddiaas-dhcp-endpoint
export CLUSTER="cnpg-${ENDPOINT_ID}"
```

---

## 1. Common diagnostic entry points

### 1.1 Quick health check

```bash
# Pods
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID" -o wide

# CNPG cluster
kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{"phase: "}{.status.phase}{"\nprimary: "}{.status.currentPrimary}{"\nready: "}{.status.readyInstances}{"/"}{.spec.instances}{"\n"}'

# Endpoint state from CSP
curl -sH "Authorization: Token $CSP_API_TOKEN" \
  "https://$CSP_URL/api/universalinfra/v1/endpoints/$ENDPOINT_ID" | jq .result.state
```

### 1.2 Full diagnostic dump

```bash
cd Automation/NIOS-XaaS
./debug_endpoint.sh "$ENDPOINT_ID"
```

`debug_endpoint.sh` runs 12 sections covering: FeatureFlagOverride, App/Version
CRs, pods, Kea config (5b), DB schema migration (5c), CNPG cluster + pending pod
diagnosis (5d), CNPG secrets, container statuses, app version labels, and
endpoint-manager state machine.

### 1.3 End-to-end DHCP test

```bash
cd Automation/NIOS-XaaS
./run.sh                 # creates endpoint, runs Kea 2.2 → 2.6 upgrade, dras lease
```

---

## 2. Deployment scenarios

### 2.1 Create a new DHCP endpoint (greenfield)

**Pre-flight**

- AWS account / EKS cluster healthy, Karpenter nodepool `private` available in
  ≥3 AZs (us-east-1a/b/c).
- CSP token has `universalinfra:write`, `ddi:write`.
- Namespace `ddiaas-dhcp-endpoint` exists.

**Steps**

1. `cd Automation/NIOS-XaaS && source .venv/bin/activate`
2. Set env: `CSP_URL`, `CSP_API_TOKEN`.
3. `python3 create_endpoint.py --no-cleanup`
4. Watch creation: `kubectl get pods -n $NS -l ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID -w`
5. Wait until endpoint state `Available` (CSP `endpoints/$ENDPOINT_ID`).
6. Verify lease: pre-upgrade `dras` step should report `lease received`.

**Rollback:** `python3 create_endpoint.py --cleanup --endpoint-id $ENDPOINT_ID`
or via CSP UI: delete IPsec tunnel → range → subnet → IP space → endpoint → US.

---

### 2.2 Upgrade Kea 2.2 → 2.6 on an existing endpoint

**Pre-flight**

- Endpoint healthy, DHCP serving leases.
- CNPG cluster healthy `3/3`, no Pending pods.
- PVCs spread across **at least 2 distinct AZs** (see §3.2 pre-flight check).
- Branch `deployment-configurations/fix-kea-2.6-deployment` deployed (or merged).

**Steps**

1. Apply / patch FFO to enable Kea 2.6 for this account:
   ```bash
   kubectl edit featureflagoverride -n "$FFO_NS" "$FFO_NAME"
   # add the account_id under spec.accounts
   ```
2. Watch the endpoint reconcile (`endpoint-manager` → `endpoint-config-manager`
   → new `dhcp-kea4` pods appear with image tag `kea-2.6.x`).
3. Wait for old pods (`kea-2.2.x`) to terminate.
4. Verify:
   ```bash
   ./debug_endpoint.sh "$ENDPOINT_ID"   # sections 5b, 5c, 5d, 9
   ```
   Expect: `kea-dhcp4.conf` contains `Subnet4`, dhcp-host log shows
   `schema is up-to-date`, CNPG cluster `Cluster in healthy state`.
5. Run `dras` lease test (post-upgrade in `create_endpoint.py` Step 12, or
   manual `dras` from the customer side).

**Rollback (DB-backup based):** see branch
`ddiaas.dhcp.resolver.endpoint/feature/rollback-to-kea-2.2-using-db-backup`.

---

### 2.3 Rollback Kea 2.6 → 2.2

1. Snapshot CNPG DB **before** rollback:
   ```bash
   kubectl cnpg backup "$CLUSTER" -n "$NS" --backup-name pre-rollback-$(date +%s)
   ```
2. Remove the account from the FFO (revert §2.2 step 1).
3. The schema rollback path lives in
   `ddi.dhcp.host.db` migration `down` scripts. Use the rollback procedure
   documented in `ddiaas.dhcp.resolver.endpoint/feature/rollback-to-kea-2.2-using-db-backup`.
4. Verify with `./debug_endpoint.sh "$ENDPOINT_ID"`.

---

### 2.4 Delete an endpoint

```bash
# Via CSP API (preferred — also tears down IPsec + IP space if --cascade)
curl -sX DELETE -H "Authorization: Token $CSP_API_TOKEN" \
  "https://$CSP_URL/api/universalinfra/v1/endpoints/$ENDPOINT_ID"
```

If stuck, force-clean K8s resources (only after confirming with the customer):

```bash
kubectl delete cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" --wait=false
kubectl delete pvc -n "$NS" -l "cnpg.io/cluster=$CLUSTER"
kubectl delete deploy,sts,svc,cm,secret -n "$NS" \
  -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID"
```

---

## 3. Incident playbooks

### 3.1 DHCP not responding after Kea 2.6 upgrade

**Symptoms**
- `dras` returns `No replies received`.
- `kea-dhcp4` pods Running but `kea-dhcp4.conf` has **no `Subnet4`** section.
- IPAM `dhcp/host/<id>` shows `current_version: ""`, `associated_server: null`.
- `dhcp-host` container log:
  ```
  failed to query for 'lease4' table:
  failed to connect to host=cnpg-<id>-rw...:5432: connection refused
  ```

**Diagnosis**
```bash
./debug_endpoint.sh "$ENDPOINT_ID"
# Inspect sections 5b (kea config), 5c (schema migration), 5d (CNPG)
```

**Most common cause:** CNPG primary unreachable → see §3.2.

**Other causes:**
- Schema migration failed (5c reports `FAILURE`) → see §3.3.
- App-def-controller didn't roll out new image → check
  `kubectl describe appdefinition` for the endpoint.

---

### 3.2 CNPG instance stuck `Pending` (PVC zone vs topology-spread deadlock)

**Symptoms**
- One CNPG pod (e.g. `cnpg-<id>-1`) `Pending` indefinitely.
- `cluster.status.phase: "Primary instance is being restarted without a switchover"`.
- `kubectl describe pod` event:
  `FailedScheduling: ... volume node affinity conflict ... didn't match pod topology spread constraints`.

**Root cause**
PVC bound (via `WaitForFirstConsumer`) in AZ X. Topology-spread
`maxSkew: 2, whenUnsatisfiable: DoNotSchedule` requires the pod to be in AZ Y
because the other replicas already filled X. Unsatisfiable — neither
scheduler nor Karpenter can place the pod.

**Pre-flight check (do BEFORE any rolling restart / upgrade)**
```bash
kubectl get pvc -n "$NS" -l "cnpg.io/cluster=$CLUSTER" \
  -o json | jq -r '.items[] | "\(.metadata.name)\t\(.spec.volumeName)"' \
  | while read pvc pv; do
      zone=$(kubectl get pv "$pv" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[].matchExpressions[?(@.key=="topology.kubernetes.io/zone")].values[0]}')
      echo "$pvc -> $zone"
    done
# Expect PVCs spread across ≥2 AZs. If all 3 land in the same AZ,
# tolerate maxSkew with care or recreate one PVC before upgrading.
```

**Recovery**

```bash
cd Automation/NIOS-XaaS
./recover_cnpg_pending.sh "$ENDPOINT_ID"        # dry-run first with --dry-run
```

Manual equivalent:
```bash
# (Optional safety) if the pending pod is currentPrimary, promote a healthy replica:
kubectl cnpg promote "$CLUSTER" "<healthy-replica>" -n "$NS"

# Delete pending pod + its PVC(s); CNPG operator recreates them in a satisfiable AZ
kubectl delete pod -n "$NS" "<pending-pod>" --wait=false
kubectl delete pvc -n "$NS" "<pending-pvc>"
```

**Verify**
```bash
kubectl get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER" -o wide
kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{.status.phase}{"\n"}'
# Expect: Cluster in healthy state, 3/3
```

**Long-term prevention** (chart changes for `deployment-configurations/fix-kea-2.6-deployment`):
- Set `topologySpreadConstraints[].whenUnsatisfiable: ScheduleAnyway`, OR use
  `maxSkew: 1` with `minDomains: 3`.
- Set CNPG `spec.primaryUpdateMethod: switchover` (default `restart` is unsafe
  when the primary's replacement pod can't be scheduled).
- Add a chart pre-flight that fails the upgrade if PVC zone-skew > 1.

---

### 3.3 DB schema migration failure

**Symptoms**
- Section 5c of `debug_endpoint.sh` reports `FAILURE`.
- `dhcp-host` log: `kea-admin upgrade ... FAILED`, `schema mismatch`, etc.
- `dhcp-host` container in `CrashLoopBackOff`.

**Diagnosis**
```bash
kubectl logs -n "$NS" <pod> -c dhcp-host --tail=2000 \
  | grep -Ei 'migration|schema|kea-admin'
```

**Recovery**
1. Take a manual CNPG backup (see §2.3 step 1).
2. Fix the broken migration (usually a forward-only ALTER that failed). Coordinate
   with `ddi.dhcp.host.db` repo owners.
3. Patch the chart with the corrected migration, redeploy the endpoint config.
4. Re-run `./debug_endpoint.sh` and verify 5c reports `SUCCESS` /
   `schema is up-to-date`.

---

### 3.4 IPsec tunnel down

**Symptoms**
- `dras` cannot reach the endpoint at all (timeout, not "no reply").
- `kubectl get strongswanconfig -n $NS` shows `phase: Failed`.
- Endpoint state in CSP: `IPsecDown` or similar.

**Diagnosis**
```bash
kubectl logs -n "$NS" -l app=strongswan --tail=500
kubectl describe strongswanconfig -n "$NS" <name>
```

**Recovery**
1. Verify customer-side tunnel identity & PSK match (CSP UI → endpoint → IPsec).
2. Restart strongswan pod: `kubectl rollout restart deploy -n "$NS" strongswan`.
3. If tunnel ID was rotated by the customer, recreate via
   `POST /api/universalinfra/v1/endpoints/{id}/ipsec`.

---

### 3.5 Endpoint stuck in `Pending` / `Provisioning`

**Diagnosis**
```bash
kubectl logs -n ddiaas-endpoint-manager deploy/endpoint-manager --tail=500 \
  | grep "$ENDPOINT_ID"
kubectl logs -n ddiaas-endpoint-manager deploy/endpoint-config-manager --tail=500 \
  | grep "$ENDPOINT_ID"
```

**Common causes**
- App-def-controller can't reconcile (FFO mismatch, image not found).
- Quota / capacity exhaustion in the target nodepool — check Karpenter:
  ```bash
  kubectl get nodeclaim -A | grep private
  ```
- IAM / image pull secret missing in the target namespace.

---

### 3.6 Pod stuck `ImagePullBackOff` after Kea image update

```bash
kubectl describe pod -n "$NS" <pod> | tail -30
# Confirm the new image tag exists in the registry
```

If the tag was a typo, fix in `deployment-configurations` and roll forward.
If registry creds expired, refresh the imagePullSecret in `$NS`.

---

## 4. Quick reference: useful one-liners

```bash
# Watch pod state for an endpoint
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID" -w

# Tail dhcp-host logs across all kea pods
for p in $(kubectl get pod -n "$NS" -l ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID -o name); do
  echo "=== $p ==="
  kubectl logs -n "$NS" "$p" -c dhcp-host --tail=100
done

# Dump kea-dhcp4.conf from a running pod
kubectl exec -n "$NS" <pod> -c kea-dhcp4 -- \
  cat /home/keadist/v4.5/etc/kea/kea-dhcp4.conf | jq .

# CNPG cluster summary
kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" -o yaml \
  | yq '.status | {phase, currentPrimary, targetPrimary, readyInstances, instancesStatus}'

# PVC → AZ mapping
kubectl get pvc -n "$NS" -l "cnpg.io/cluster=$CLUSTER" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.volumeName}{"\n"}{end}'
```

---

## 5. Escalation

| Area | Owner |
|---|---|
| `deployment-configurations`, chart | DDIaaS Platform |
| `ddi.dhcp.host.db`, schema migrations | DHCP team |
| `ddi.dhcp.host.server`, dhcp-host container | DHCP team |
| `ddiaas.endpoint.manager`, endpoint state machine | DDIaaS Platform |
| `atlas-app-definition-controller`, FFO/AppDef rollout | Atlas team |
| CNPG / Postgres operator | DBRE / Cloud Infra |
| Karpenter / EKS / IAM | Cloud Infra |

---

## 6. Tools / scripts in this repo

| Script | Purpose |
|---|---|
| [Automation/NIOS-XaaS/run.sh](Automation/NIOS-XaaS/run.sh) | E2E test: create endpoint + Kea 2.2→2.6 upgrade + DHCP lease |
| [Automation/NIOS-XaaS/create_endpoint.py](Automation/NIOS-XaaS/create_endpoint.py) | 12-step endpoint provisioning + upgrade test |
| [Automation/NIOS-XaaS/debug_endpoint.sh](Automation/NIOS-XaaS/debug_endpoint.sh) | 12-section diagnostic for an endpoint |
| [Automation/NIOS-XaaS/recover_cnpg_pending.sh](Automation/NIOS-XaaS/recover_cnpg_pending.sh) | Recover stuck CNPG Pending pod (PVC/topology deadlock) |

# DDIaaS DHCP Endpoint — Operations Runbook

**Scope:** Day-2 operations for DDIaaS DHCP endpoints running on Kea (2.2 / 2.6) with
CloudNativePG (CNPG) Postgres backend on AWS EKS.

**Audience:** On-call engineers, SREs, and developers debugging customer endpoint
issues on `stage` / `prod`.

**Last updated:** 2026-05-01

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

### 2.3 Rollback Kea 2.6 → 2.2 (DB-reset approach)

> **When to use:** The rolling update from 2.6 → 2.2 stalled — one zone got the
> new chart but the DB is still at schema v22. Kea 2.2 cannot start against a
> v22 schema, so pods are `CrashLoopBackOff` or stuck in health-check failures.
> Lease data will be re-synced from cloud after startup; this approach does
> **not** preserve local lease state.

**Pre-flight**

| Check | Command |
|---|---|
| Identify which zones have Kea 2.2 vs 2.6 | `kubectl get pods -n $NS -l ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID -o wide` |
| Confirm CNPG cluster healthy (3/3) | `kubectl get cluster.postgresql.cnpg.io -n $NS $CLUSTER` |
| Note current DB schema version | See step 2 below |
| Know the target Kea 2.2 chart version | e.g. `v0.1.0-13-g2c6382a-j159-main` |

**Orchestration scripts:**
```
Automation/NIOS-XaaS/Rollback/
├── start_rollback.sh        # orchestrator — calls 01 → 02 → can_scale_up
├── 01_scale_down.sh          # scale all zones to 0 replicas
├── 02_fix_db.sh              # drop + reset DB (or restore from backup)
└── can_scale_up.sh           # FFO-aware sequential zone scale-up + summary
```

#### Step 1 — Remove account from FFO (trigger Kea 2.2 chart rollback)

Remove the account ID from the `FeatureFlagOverride` so that the
`endpoint-config-manager` reconciles both HelmReleases back to the Kea 2.2
chart version.

```bash
kubectl edit featureflagoverride -n "$FFO_NS" "$FFO_NAME"
# Remove the account_id from spec.accounts
```

> The FFO change propagates through `app-definition-controller` →
> `endpoint-config-manager` → updates both `HelmRelease` CRs. This takes
> 1-3 minutes per zone. Do **not** wait for pods — the DB schema mismatch
> will keep them unhealthy.

Alternatively, create a `deployment-configurations` PR that pins the
Kea 2.2 chart version directly (e.g. PR #125450 on branch `rollback-to-kea-2.2`).

#### Step 2 — Scale down all zones

Scale every deployment for the endpoint to 0 replicas so no Kea process is
running while the DB is modified.

```bash
cd Automation/NIOS-XaaS/Rollback
./01_scale_down.sh "$ENDPOINT_ID"
```

**What the script does:**
1. Discovers all deployments matching `dhcp-${ENDPOINT_ID}-*` in `ddiaas-dhcp-endpoint`.
2. Scales each deployment to 0 replicas.
3. Waits for all pods to terminate (`kubectl rollout status`).
4. Reports remaining pods (if any are still terminating).

**Verify:**
```bash
kubectl get pods -n "$NS" | grep "dhcp-${ENDPOINT_ID}"
# Expect: no pods
kubectl get deploy -n "$NS" | grep "dhcp-${ENDPOINT_ID}"
# Expect: 0/0 for all deployments
```

#### Step 3 — Reset the DB schema

Drop all tables from the `public` schema. When Kea 2.2 starts, `dhcp-host`
runs `kea-admin db-init` which creates the v13 DDL from scratch. Lease data
is then synced from cloud.

```bash
./02_fix_db.sh "$ENDPOINT_ID" reset
```

**What the script does:**
1. **Pre-flight:** confirms all deployments are at 0 replicas, CNPG secret exists,
   CNPG primary pod is reachable.
2. Creates a Kubernetes Job (`schema-rollback-${ENDPOINT_ID}`) using the CNPG
   postgres image.
3. The Job runs `DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;` —
   leaving the DB completely empty.
4. Reports success and reminds that Kea 2.2 will initialise the schema on startup.

> **Alternative — restore mode:** `./02_fix_db.sh "$ENDPOINT_ID" restore` uses the
> `ddi.dhcp.host.server` image to run `kea-admin db-init` inside the Job, then
> copies data from `backup_premigration` schema (if it exists from a previous
> 2.2 → 2.6 upgrade). Use this if you need to preserve pre-upgrade lease state.

**Verify:**
```bash
# Exec into CNPG primary and check
kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';"
# Expect: 0 tables (empty public schema)
```

#### Step 4 — Sequential zone scale-up with FFO checks

Scale zones back up one at a time, starting with the **last zone** (highest
letter, e.g. `1b` before `1a`). This is important because:

- The rolling update processes zones in reverse order (last zone first).
- The zone that was already updated to Kea 2.2 chart should come up first.
- Its `dhcp-host` container runs `kea-admin db-init` → creates schema v13.
- The second zone then starts against an already-initialised v13 DB.

```bash
./can_scale_up.sh "$ENDPOINT_ID" ddiaas-endpoint-manager "<kea-2.2-chart-version>"
```

Example:
```bash
./can_scale_up.sh "$ENDPOINT_ID" ddiaas-endpoint-manager v0.1.0-13-g2c6382a-j159-main
```

**What the script does for each zone (sequentially):**

1. **FFO check** — polls the zone's `HelmRelease` until:
   - `spec.chart.spec.version` matches the expected Kea 2.2 chart version.
   - `status.conditions[Ready]` is `True` (reconciliation complete).
   - Retries every 15-30s until both conditions are met.

2. **Kea 2.6 safety guard** — inspects:
   - The HelmRelease chart version for any `kea-2.6` / `upgrade-to-kea` substring.
   - The deployment's pod template container images for any `kea.*2.6` match.
   - **Aborts** if either check detects Kea 2.6.

3. **Scale up** — `kubectl scale deployment ... --replicas=1`

4. **Wait for pod healthy** — polls until the pod shows `9/9 Running`.

5. **Summary** (after all zones are up):
   - DB schema version (queries `schema_version` table on CNPG primary).
   - All container image versions per zone (all 9 containers).
   - Recent errors from `dhcp-kea4` and `dhcp-host` logs (filtered:
     excludes interface/dhcp6 noise).

#### Step 5 — Verify

```bash
# Quick health check
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID"
# Expect: 2 pods, both 9/9 Running

# DB schema
kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -t -A -c \
  "SELECT version || '.' || minor FROM schema_version ORDER BY version DESC, minor DESC LIMIT 1"
# Expect: 13.0

# HelmRelease chart versions
kubectl get helmrelease -n ddiaas-endpoint-manager | grep "dhcp-${ENDPOINT_ID}"
# Expect: both at the Kea 2.2 chart version, Ready=True

# Full diagnostic
./debug_endpoint.sh "$ENDPOINT_ID"
```

#### One-liner (automated)

To run all steps (2-4) in sequence:

```bash
cd Automation/NIOS-XaaS/Rollback
./start_rollback.sh
```

`start_rollback.sh` calls `01_scale_down.sh` → `02_fix_db.sh reset` →
`can_scale_up.sh` for each endpoint ID configured in the script.

> **Note:** The scripts require **bash ≥ 4** (uses `mapfile` and associative
> arrays). On macOS, the system bash is v3.2 — use `/opt/homebrew/bin/bash`
> (install via `brew install bash`). The scripts' shebangs are already set
> to `/opt/homebrew/bin/bash`.

#### Expected timeline

| Phase | Duration |
|---|---|
| FFO removal → HelmRelease reconciliation | 1-3 min |
| Scale down + pod termination | 1-2 min |
| DB reset Job | ~10 sec |
| First zone scale-up + healthy | 2-4 min |
| FFO propagation to second zone | 1-3 min |
| Second zone scale-up + healthy | 2-4 min |
| **Total** | **~8-15 min** |

#### Rollback of the rollback

If you need to go back to Kea 2.6 after this procedure:
1. Re-add the account to the FFO (§2.2 step 1).
2. The `endpoint-config-manager` will reconcile both HelmReleases to the
   Kea 2.6 chart. The `dhcp-host` container's `kea-admin db-upgrade` will
   migrate the schema from v13 → v22.
3. Verify with `./debug_endpoint.sh "$ENDPOINT_ID"`.

---

### 2.4 Rollback Kea 2.6 → 2.2 (DB-backup restore approach)

> **When to use:** Same stalled-rollback scenario as §2.3, but you want to
> preserve pre-upgrade lease data from the `backup_premigration` schema
> (created automatically during the 2.2 → 2.6 upgrade).

Follow §2.3 steps 1-2, then use **restore** mode instead of reset:

```bash
./02_fix_db.sh "$ENDPOINT_ID" restore
```

This uses the `ddi.dhcp.host.server` image to:
1. Drop the `public` schema.
2. Run `kea-admin db-init` → creates v13 DDL.
3. Copy data from `backup_premigration.*_bak` tables into `public.*`.

Then continue with §2.3 steps 4-5.

> The `backup_premigration` schema only exists if the endpoint previously
> went through a successful 2.2 → 2.6 upgrade. If it doesn't exist, the
> restore Job fails — fall back to the reset approach (§2.3).

---

### 2.5 Delete an endpoint

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
| [Automation/NIOS-XaaS/Rollback/start_rollback.sh](Automation/NIOS-XaaS/Rollback/start_rollback.sh) | Orchestrates full Kea 2.6 → 2.2 rollback (scale down → DB reset → scale up) |
| [Automation/NIOS-XaaS/Rollback/01_scale_down.sh](Automation/NIOS-XaaS/Rollback/01_scale_down.sh) | Scale all DHCP deployments for an endpoint to 0 replicas |
| [Automation/NIOS-XaaS/Rollback/02_fix_db.sh](Automation/NIOS-XaaS/Rollback/02_fix_db.sh) | Reset or restore DB schema (v22 → empty / v13) |
| [Automation/NIOS-XaaS/Rollback/can_scale_up.sh](Automation/NIOS-XaaS/Rollback/can_scale_up.sh) | FFO-aware sequential zone scale-up with safety checks + summary |

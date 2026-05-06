# DDIaaS DHCP Endpoint — Operations Runbook

**Scope:** Day-2 operations for DDIaaS DHCP endpoints running on Kea (2.2 / 2.6) with
CloudNativePG (CNPG) Postgres backend on AWS EKS.

**Audience:** On-call engineers, SREs, and developers debugging customer endpoint
issues on `stage` / `prod`.

**Last updated:** 2026-05-06

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
| Know the target Kea 2.2 chart version | `v0.1.0-13-g2c6382a-j159-main` |
| DC PR merged (rollback FFO) | Create a `deployment-configurations` PR that pins the per-endpoint FFO `ddiaasDhcpBase.chart.version` to `v0.1.0-13-g2c6382a-j159-main`. Must be merged **before** running `can_scale_up.sh`. |

> **Important:** The `ddiaasDhcpBase.chart.version` for Kea 2.2 rollback is
> **`v0.1.0-13-g2c6382a-j159-main`** across all rollback methods (`reset`,
> `restore`, and `newdb`). This is the hotfix-9 chart with rsyslog redirection.

**Orchestration scripts:**
```
Automation/NIOS-XaaS/Rollback/
├── start_rollback.sh        # orchestrator — calls 01 → 02 → can_scale_up
├── 01_scale_down.sh          # scale all zones to 0 replicas
├── 02_fix_db.sh              # drop + reset DB (or restore from backup)
└── can_scale_up.sh           # FFO-aware sequential zone scale-up + summary
```

#### Step 1 — Create the rollback FFO (deployment-configurations PR)

Add a per-endpoint `versionOverride` with **priority 510** (higher than the
Kea 2.6 FFO at 305/310) in:

```
deployment-configurations/envs/<env>/<cluster>/ddiaas-feature-flag-override-dhcp-values.yaml
```

```yaml
  - name: adc-ddiaas-dhcp-rollback-kea-2.6-to-2.2
    namespace: "atlas-app-def-system"
    labels:
      matchExpressions:
        endpoint_id:
          - "<ENDPOINT_ID>"
    app:
      name: "ddiaas-dhcp"
      version: "0.26.2-hf-9-0"
      priority: 510
```

This pins `ddiaasDhcpBase.chart.version` to `v0.1.0-13-g2c6382a-j159-main`.

Create a PR, get approval, and **merge**.

> **Important:** The DC PR must be merged **before** running `can_scale_up.sh`.
> The script polls the HelmRelease chart version — if the FFO hasn't propagated,
> it will wait indefinitely.

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

> **Prerequisite:** The `deployment-configurations` PR that creates the
> per-endpoint rollback FFO (pinning `ddiaasDhcpBase.chart.version` to
> `v0.1.0-13-g2c6382a-j159-main`) must be **merged** before running
> `can_scale_up.sh`. The script polls for HelmRelease chart version match —
> if the FFO hasn't propagated, it will wait indefinitely.

Scale zones back up one at a time, starting with the **last zone** (highest
letter, e.g. `1b` before `1a`). This is important because:

- The rolling update processes zones in reverse order (last zone first).
- The zone that was already updated to Kea 2.2 chart should come up first.
- Its `dhcp-host` container runs `kea-admin db-init` → creates schema v13.
- The second zone then starts against an already-initialised v13 DB.

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

---

### 2.4 Rollback Kea 2.6 → 2.2 (FFO + fresh CNPG DB — `newdb` approach)

> **When to use:** You need to roll back a **specific endpoint** from Kea 2.6
> to Kea 2.2 and:
> - The existing CNPG cluster has issues (corrupted, stuck, or PVC zone deadlock).
> - You don't need to preserve lease data (leases will re-sync from cloud).
> - The `backup_premigration` schema does not exist or is corrupted.
>
> This approach **deletes and recreates** the entire CNPG cluster from scratch,
> ensuring a clean Postgres instance. Kea 2.2's `dhcp-host` then initialises
> schema v13 on first startup.
>
> **Validated on:** 2026-05-06, endpoint `6yp5a7ff5p4evrowbgqpukbjrwf2xov5`
> in `ddi-qa-use1`.

**Pre-flight**

| Check | Command |
|---|---|
| Endpoint has Kea 2.6 running | `./debug_endpoint.sh "$ENDPOINT_ID"` — confirm kea image has `kea-2.6` or schema v22 |
| Know the target Kea 2.2 chart version | `v0.1.0-13-g2c6382a-j159-main` |

#### Step 1 — Create the rollback FFO (deployment-configurations PR)

Same as §2.5 Step 1 — add a per-endpoint `versionOverride` with **priority 510**
in:

```
deployment-configurations/envs/<env>/<cluster>/ddiaas-feature-flag-override-dhcp-values.yaml
```

```yaml
  - name: adc-ddiaas-dhcp-rollback-kea-2.6-to-2.2
    namespace: "atlas-app-def-system"
    labels:
      matchExpressions:
        endpoint_id:
          - "<ENDPOINT_ID>"
    app:
      name: "ddiaas-dhcp"
      version: "0.26.2-hf-9-0"
      priority: 510
```

This pins `ddiaasDhcpBase.chart.version` to `v0.1.0-13-g2c6382a-j159-main`.

Create a PR, get approval, and **merge**. Example: PR #126294.

> **Important:** The DC PR must be merged **before** running `can_scale_up.sh`.
> The script polls the HelmRelease chart version — if the FFO hasn't propagated,
> it will wait indefinitely.

#### Step 2 — Scale down all zones

```bash
cd Automation/NIOS-XaaS/Rollback
./01_scale_down.sh "$ENDPOINT_ID"
```

**Verify:**
```bash
kubectl get pods -n "$NS" | grep "dhcp-${ENDPOINT_ID}"
# Expect: no pods
```

#### Step 3 — Delete and recreate the CNPG cluster (newdb)

```bash
./02_fix_db.sh "$ENDPOINT_ID" newdb
```

**What the script does:**
1. Confirms all deployments are at 0 replicas.
2. Deletes the existing CNPG cluster (`kubectl delete cluster.postgresql.cnpg.io`).
3. Waits for all CNPG pods and PVCs to be fully cleaned up.
4. Recreates the CNPG cluster from the stored manifest (3 instances, PostgreSQL 17.5).
5. Waits for the new cluster to reach `Cluster in healthy state` with all
   instances ready (3/3).
6. Verifies the new CNPG secret and RW service are available.

The new DB is completely empty — no schemas, no tables. Kea 2.2's `dhcp-host`
will initialise schema v13 on first startup.

**Verify:**
```bash
# CNPG cluster healthy
kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER"
# Expect: phase=Cluster in healthy state, 3/3 instances

# Pods running
kubectl get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER"
# Expect: 3 pods, all 1/1 Running

# DB is empty
kubectl exec -n "$NS" "${CLUSTER}-1" -- \
  psql -U postgres -d dhcp_endpoint -c \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';"
# Expect: 0
```

#### Step 4 — Sequential zone scale-up with FFO checks

> **Prerequisite:** The DC PR (from Step 1) must be **merged** and the FFO
> propagated before running this step.

```bash
./can_scale_up.sh "$ENDPOINT_ID" ddiaas-endpoint-manager v0.1.0-13-g2c6382a-j159-main
```

The script:
1. Discovers zones from HelmReleases (sorted descending: last zone first).
2. **For each zone** (sequentially):
   - Waits for HelmRelease chart version to match `v0.1.0-13-g2c6382a-j159-main`.
   - Verifies no Kea 2.6 images in deployment spec.
   - Scales to 1 replica.
   - Waits for pod 9/9 Running.
3. Prints summary: DB schema, all container images, recent errors.

> **Note:** The first zone's `dhcp-host` container runs `kea-admin db-init` to
> create the v13 schema in the fresh DB. The second zone finds schema already
> initialised.

#### Step 5 — Verify

```bash
# Quick checks
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID"
# Expect: 2 pods, both 9/9 Running

# DB schema
kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -t -A -c \
  "SELECT version || '.' || minor FROM schema_version ORDER BY version DESC, minor DESC LIMIT 1"
# Expect: 13.0

# Kea image
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID" \
  -o jsonpath='{range .items[*]}{.spec.containers[?(@.name=="dhcp-kea4")].image}{"\n"}{end}'
# Expect: ci-2025-09-05T17-55Z-169-2fb6baf-feature-rsyslog-redirection (Kea 2.2)

# Full diagnostic
./debug_endpoint.sh "$ENDPOINT_ID"
```

#### Known observations

| Observation | Explanation |
|---|---|
| `dhcp-scm-client` readiness 503 for several minutes after scale-up | SCM subscribe stream may take time to establish after a fresh pod start. Cluster-wide — all DHCP pods on `ddi-qa-use1` show 8/9 until the SCM route stabilises. Resolves on its own (1-20 min). |
| `Restoring dhcpv4 leases is not needed because hagroups is empty` | Expected with fresh DB — no HA group configured yet. Leases will re-sync from cloud. |
| `LS_EXCEPTION_OCCURRED exception occurred: Failed to get reply: Server closed the connection` | Startup race in `dhcp-kea4` lease-sync hook. Resolves within seconds. |

#### Expected timeline

| Phase | Duration |
|---|---|
| DC PR merge + ArgoCD sync | 2-3 min |
| Scale down + pod termination | 1-2 min |
| CNPG delete + recreate + healthy | 3-5 min |
| FFO → HelmRelease propagation (zone 1) | 3-8 min |
| First zone scale-up + 9/9 ready | 2-20 min (SCM client delay) |
| Second zone scale-up + 9/9 ready | 1-3 min |
| **Total** | **~12-40 min** |

#### Rollback of the rollback (re-upgrade to Kea 2.6)

1. Remove the per-endpoint FFO override from `deployment-configurations`.
2. Re-add the account to the Kea 2.6 FFO (§2.2 step 1) if previously removed.
3. The `endpoint-config-manager` will reconcile both HelmReleases to the
   Kea 2.6 chart. The `dhcp-host` container's `kea-admin db-upgrade` will
   migrate the schema from v13 → v22.
4. Verify with `./debug_endpoint.sh "$ENDPOINT_ID"`.

---

### 2.5 Rollback Kea 2.6 → 2.2 (FFO + DB-backup restore approach) — RECOMMENDED

> **When to use:** You need to roll back a **specific endpoint** from Kea 2.6
> to Kea 2.2 while preserving lease data. This is the validated production
> approach. Unlike §2.3, it does **not** require removing the account from the
> Kea 2.6 FFO — instead, a higher-priority per-endpoint FFO overrides it.
>
> **Validated on:** 2026-05-04, endpoints `q7ts2sz3u735pwmcrqev4vdrfuvk6lpw`
> and `tlhftd4xwdcd5crmy5kj6mfx3tcedut6` in `ddi-qa-use1`.

**Pre-flight**

| Check | Command |
|---|---|
| Endpoint has Kea 2.6 running | `./debug_endpoint.sh "$ENDPOINT_ID"` — confirm kea image has `kea-2.6` or schema v22 |
| CNPG cluster healthy | `kubectl get cluster.postgresql.cnpg.io -n $NS $CLUSTER` |
| `backup_premigration` schema exists | `kubectl exec -n $NS $CNPG_RW_POD -- psql -U postgres -d dhcp_endpoint -c "SELECT schema_name FROM information_schema.schemata WHERE schema_name='backup_premigration';"` |
| Know the target Kea 2.2 chart version | `v0.1.0-13-g2c6382a-j159-main` |

#### Step 1 — Create the rollback FFO (deployment-configurations PR)

Add a per-endpoint `versionOverride` with **priority 510** (higher than the
Kea 2.6 FFO at 305/310) in:

```
deployment-configurations/envs/<env>/<cluster>/ddiaas-feature-flag-override-dhcp-values.yaml
```

```yaml
  - name: adc-ddiaas-dhcp-rollback-kea-2.6-to-2.2
    namespace: "atlas-app-def-system"
    labels:
      matchExpressions:
        endpoint_id:
          - "<ENDPOINT_ID>"
    app:
      name: "ddiaas-dhcp"
      version: "0.26.2-hf-9-0"
      priority: 510
```

> **Why priority 510?** The Kea 2.6 account-level FFO is at priority 305-310.
> A higher priority per-endpoint override wins, so only this endpoint rolls back
> while other endpoints on the same account stay on Kea 2.6.
>
> **Why `0.26.2-hf-9-0`?** This is the Kea 2.2 app version that maps to chart
> `v0.1.0-13-g2c6382a-j159-main` (the hotfix-9 release with rsyslog redirection).

Create a PR, get approval, and **merge**. Example: PR #125797.

#### Step 2 — Scale down all zones

Wait for deployments to be at 0 (endpoint may already be scaled down if Kea
was crashing). Otherwise:

```bash
cd Automation/NIOS-XaaS/Rollback
./01_scale_down.sh "$ENDPOINT_ID"
```

**Verify:**
```bash
kubectl get pods -n "$NS" | grep "dhcp-${ENDPOINT_ID}"
# Expect: no pods
```

#### Step 3 — Restore DB from backup_premigration

```bash
./02_fix_db.sh "$ENDPOINT_ID" restore
```

**What the script does:**
1. Confirms deployments are at 0, CNPG primary reachable.
2. Connects to CNPG primary via `kubectl exec` with `session_replication_role=replica`
   (bypasses FK constraints).
3. Drops the `public` schema.
4. Runs `kea-admin db-init` → creates clean Kea 2.2 schema (v13.0).
5. Restores data from `backup_premigration` tables (`lease4_bak`, `lease6_bak`,
   `hosts_bak`, etc.) into the corresponding `public` tables.
6. Reports row counts.

**Verify:**
```bash
kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -t -A -c \
  "SELECT version || '.' || minor FROM schema_version;"
# Expect: 13.0

kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -t -A -c \
  "SELECT count(*) FROM lease4 WHERE state=0;"
# Expect: pre-upgrade lease count (from backup)
```

> If `backup_premigration` doesn't exist, fall back to reset mode:
> `./02_fix_db.sh "$ENDPOINT_ID" reset` — this creates an empty v13 schema.
> Leases will be re-synced from cloud on startup.

#### Step 4 — Scale up with FFO verification

> **Prerequisite:** The `deployment-configurations` PR (from Step 1) must be
> **merged** before running `can_scale_up.sh`. The script polls for HelmRelease
> chart version match — if the FFO hasn't propagated, it will wait indefinitely.

```bash
./can_scale_up.sh "$ENDPOINT_ID" ddiaas-endpoint-manager v0.1.0-13-g2c6382a-j159-main
```

The script:
1. Discovers zones from HelmReleases (sorted descending: 1c before 1b).
2. **For each zone** (sequentially):
   - Waits for HelmRelease chart version to match (FFO propagation, ~3-8 min).
   - Verifies no Kea 2.6 images in deployment spec.
   - Scales to 1 replica.
   - Waits for pod 9/9 Running.
3. Prints summary: DB schema, all container images, recent errors.

> **Timing:** The FFO takes 3-8 minutes per zone to propagate after the PR is
> merged. The script polls automatically (30s interval). Total ~8-15 min.

#### Step 5 — Verify

```bash
# Quick checks
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID"
# Expect: 2 pods, both 9/9 Running

# DB schema
kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -t -A -c \
  "SELECT version || '.' || minor FROM schema_version;"
# Expect: 13.0

# Kea image
kubectl get pods -n "$NS" -l "ddiaas.infoblox.com/endpoint-id=$ENDPOINT_ID" \
  -o jsonpath='{range .items[*]}{.spec.containers[?(@.name=="dhcp-kea4")].image}{"\n"}{end}'
# Expect: ci-2025-09-05T17-55Z-169-2fb6baf-feature-rsyslog-redirection (Kea 2.2)

# Full diagnostic
./debug_endpoint.sh "$ENDPOINT_ID"

# Send DHCP leases and confirm no errors
# Then check:
kubectl exec -n "$NS" "$CNPG_RW_POD" -- \
  psql -U postgres -d dhcp_endpoint -t -A -c \
  "SELECT state, count(*) FROM lease4 GROUP BY state;"
```

#### Known benign errors after rollback

| Error | Source | Explanation |
|---|---|---|
| `Failed to send leases ... to Data Out: 404 (Not Found)` | dhcp-host / dhcp-data-out | ti-proxy cloud ingress returns 404 if the cloud-side lease receiver is not deployed for this test env (`grpc-ddiaas-env-2a.test.infoblox.com`). Non-blocking — local DHCP works fine. |
| `hagroups is empty` | dhcp-host | Cloud lease-sync HA group not configured for this endpoint. Non-blocking. |
| `unable to forward command to the dhcp4 service: No such file or directory` | dhcp-host (startup) | Startup race: dhcp-host tries to talk to kea4 before its Unix socket is ready. Resolves within seconds. |
| `sockets: status: failed` (interface ovs-system/svc-ep/haas-ovs down) | dhcp-host status-get | OVS/network interfaces not relevant for DHCP in the pod network. Info-level, not errors. |

#### Expected timeline

| Phase | Duration |
|---|---|
| PR merge + ArgoCD sync | 2-3 min |
| FFO → HelmRelease propagation (zone 1) | 3-5 min |
| Scale down (if not already at 0) | 1-2 min |
| DB restore from backup | ~30 sec |
| First zone scale-up + 9/9 ready | 2-4 min |
| FFO propagation to second zone | 2-5 min |
| Second zone scale-up + 9/9 ready | 2-4 min |
| **Total** | **~12-20 min** |

---

### 2.6 Delete an endpoint

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

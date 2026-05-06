#!/opt/homebrew/bin/bash
set -euo pipefail

# Step 2: Apply a Kubernetes Job to rollback DB schema
#
# Three modes:
#   reset   - Drop all tables from public schema → completely empty DB.
#             Kea 2.2 will run kea-admin db-init on startup, then lease sync from cloud fills data.
#   restore - Drop public schema, kea-admin db-init (v13 DDL) + restore data from backup_premigration.
#   newdb   - Delete and recreate the entire CNPG Cluster (same name → same service/secret).
#             Gives a completely fresh PostgreSQL instance with zero WAL/bloat.
#             Kea 2.2 will run kea-admin db-init on startup.
#
# Usage: ./02_fix_db.sh <endpoint_id> [reset|restore|newdb]
#   Default mode: restore

ENDPOINT_ID="${1:?Usage: $0 <endpoint_id> [reset|restore|newdb]}"
MODE="${2:-restore}"
if [[ "$MODE" != "reset" && "$MODE" != "restore" && "$MODE" != "newdb" ]]; then
  echo "Error: mode must be 'reset', 'restore', or 'newdb', got '${MODE}'"
  echo "Usage: $0 <endpoint_id> [reset|restore|newdb]"
  exit 1
fi
DHCP_NS="ddiaas-dhcp-endpoint"
HOST_CONTROLLER_IMAGE="harbor.services.sdp.infoblox.com/infobloxcto/ddi.dhcp.host.server:ci-2025-03-14T00-23Z-884-eee43bcb-develop"
CNPG_POSTGRES_IMAGE="ghcr.io/cloudnative-pg/postgresql:17.5-bookworm"
CNPG_CLUSTER="cnpg-${ENDPOINT_ID}"
CNPG_SECRET="${CNPG_CLUSTER}-app"
DB_NAME="dhcp_endpoint"

# reset mode uses the lightweight CNPG postgres image (only needs psql)
# restore mode uses the Kea 2.2 host-controller image (needs kea-admin)
if [[ "$MODE" == "reset" ]]; then
  JOB_IMAGE="$CNPG_POSTGRES_IMAGE"
else
  JOB_IMAGE="$HOST_CONTROLLER_IMAGE"
fi
JOB_NAME="schema-rollback-${ENDPOINT_ID}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

header() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()   { echo -e "  ${RED}✗${NC} $1"; }
info()   { echo -e "  $1"; }

echo -e "${BOLD}Rollback Step 2: Fix DB Schema (v22 → v13)${NC}"
echo -e "Endpoint: ${CYAN}${ENDPOINT_ID}${NC}"
echo -e "Mode:     ${CYAN}${MODE}${NC} $(if [[ "$MODE" == "reset" ]]; then echo '(empty v13 tables, no data restore)'; elif [[ "$MODE" == "newdb" ]]; then echo '(delete + recreate CNPG cluster, fresh DB)'; else echo '(v13 tables + restore data from backup)'; fi)"
echo -e "Cluster:  $(kubectl config current-context)"
echo -e "Time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ─────────────────────────────────────────────
header "1. Pre-flight checks"
# ─────────────────────────────────────────────

# Check all deployments for this endpoint are scaled to 0
DEPLOY_PREFIX="dhcp-${ENDPOINT_ID}-"
mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$DHCP_NS" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep "^${DEPLOY_PREFIX}" || true)

if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
  warn "No deployments found matching ${DEPLOY_PREFIX}*. Proceeding anyway."
else
  for DEP in "${DEPLOYMENTS[@]}"; do
    CURRENT_REPLICAS=$(kubectl get deployment "$DEP" -n "$DHCP_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_REPLICAS" != "0" ]]; then
      fail "Deployment ${DEP} has ${CURRENT_REPLICAS} replicas. ALL deployments must be 0 before fixing DB."
      info "  Run: ./01_scale_down.sh ${ENDPOINT_ID}"
      exit 1
    fi
    ok "Deployment ${DEP} scaled to 0"
  done
fi

# Check CNPG secret exists
if [[ "$MODE" != "newdb" ]]; then
  if ! kubectl get secret "$CNPG_SECRET" -n "$DHCP_NS" &>/dev/null; then
    fail "CNPG secret ${CNPG_SECRET} not found in ${DHCP_NS}"
    exit 1
  fi
  ok "CNPG secret found: ${CNPG_SECRET}"
fi

# Check CNPG cluster is running (not required for newdb — we delete it anyway)
if [[ "$MODE" != "newdb" ]]; then
  CNPG_RW_POD=$(kubectl get pods -n "$DHCP_NS" -l "cnpg.io/cluster=${CNPG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "$CNPG_RW_POD" ]]; then
    fail "No CNPG primary pod found for cluster ${CNPG_CLUSTER}"
    exit 1
  fi
  ok "CNPG primary pod: ${CNPG_RW_POD}"
fi

# Clean up previous job if exists
if kubectl get job "$JOB_NAME" -n "$DHCP_NS" &>/dev/null; then
  warn "Previous job ${JOB_NAME} exists. Deleting..."
  kubectl delete job "$JOB_NAME" -n "$DHCP_NS" --ignore-not-found
  sleep 2
fi

# ═══════════════════════════════════════════════
# NEWDB MODE: Delete and recreate the entire CNPG Cluster
# ═══════════════════════════════════════════════
if [[ "$MODE" == "newdb" ]]; then
  header "2. Deleting existing CNPG Cluster"

  if kubectl get cluster.postgresql.cnpg.io "$CNPG_CLUSTER" -n "$DHCP_NS" &>/dev/null; then
    info "Deleting CNPG Cluster: ${CNPG_CLUSTER}"
    kubectl delete cluster.postgresql.cnpg.io "$CNPG_CLUSTER" -n "$DHCP_NS" --wait=true --timeout=120s
    ok "CNPG Cluster deleted"
  else
    warn "CNPG Cluster ${CNPG_CLUSTER} not found. Will create fresh."
  fi

  # Wait for all CNPG pods to terminate
  info "Waiting for CNPG pods to terminate..."
  for i in $(seq 1 60); do
    POD_COUNT=$(kubectl get pods -n "$DHCP_NS" -l "cnpg.io/cluster=${CNPG_CLUSTER}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$POD_COUNT" == "0" ]]; then
      break
    fi
    sleep 2
  done
  if [[ "$POD_COUNT" != "0" ]]; then
    fail "CNPG pods did not terminate within 120s"
    exit 1
  fi
  ok "All CNPG pods terminated"

  # ─────────────────────────────────────────────
  header "3. Creating new CNPG Cluster"
  # ─────────────────────────────────────────────

  CNPG_OWNER="${ENDPOINT_ID}-user"

  # The Helm chart template (cnpg-db-cluster.yaml) does a lookup for the existing CNPG Cluster
  # and reads .metadata.labels.releaseName to determine ownership.
  # We must set this to the first-AZ HelmRelease name, otherwise the 2nd zone fails with nil pointer.
  HELM_NS="ddiaas-endpoint-manager"
  mapfile -t AZ_RELEASES < <(kubectl get helmreleases -n "$HELM_NS" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null \
    | grep "^dhcp-${ENDPOINT_ID}-" | sort)

  FIRST_AZ_RELEASE="${AZ_RELEASES[0]:-}"
  if [[ -z "$FIRST_AZ_RELEASE" ]]; then
    warn "Could not find HelmRelease for endpoint. Using fallback releaseName."
    FIRST_AZ_RELEASE="dhcp-${ENDPOINT_ID}-unknown"
  fi
  info "CNPG cluster owner (releaseName): ${FIRST_AZ_RELEASE}"

  # Derive AZ list from HelmRelease names (e.g. dhcp-<id>-us-east-1a → us-east-1a)
  AZ_LIST=()
  for REL in "${AZ_RELEASES[@]}"; do
    AZ="${REL#dhcp-${ENDPOINT_ID}-}"
    AZ_LIST+=("$AZ")
  done
  if [[ ${#AZ_LIST[@]} -eq 0 ]]; then
    warn "Could not determine AZ list. CNPG pods will schedule on any tolerated node."
  else
    info "Derived AZ list: ${AZ_LIST[*]}"
  fi
  FIRST_AZ="${AZ_LIST[0]:-}"

  # Build nodeAffinity YAML dynamically
  NODE_AFFINITY=""
  if [[ ${#AZ_LIST[@]} -gt 0 ]]; then
    AZ_VALUES=""
    for AZ in "${AZ_LIST[@]}"; do
      AZ_VALUES="${AZ_VALUES}
                  - ${AZ}"
    done
    NODE_AFFINITY="    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:${AZ_VALUES}
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: topology.kubernetes.io/zone
                operator: In
                values:
                  - ${FIRST_AZ}"
  fi

  cat <<EOF | kubectl apply -n "$DHCP_NS" -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${CNPG_CLUSTER}
  namespace: ${DHCP_NS}
  labels:
    releaseName: ${FIRST_AZ_RELEASE}
  annotations:
    linkerd.io/inject: disabled
    prometheus.io/port: "9187"
    prometheus.io/scrape: "true"
spec:
  imageName: ${CNPG_POSTGRES_IMAGE}
  instances: 3
  postgresql:
    parameters:
      shared_buffers: "256MB"
      max_slot_wal_keep_size: "1536MB"
      synchronous_commit: "remote_write"
    synchronous:
      dataDurability: required
      method: any
      number: 1
  affinity:
    podAntiAffinityType: required
${NODE_AFFINITY}
    tolerations:
      - effect: "NoSchedule"
        key: "infoblox.com/ddiaas"
        operator: "Exists"
  topologySpreadConstraints:
    - maxSkew: 2
      topologyKey: topology.kubernetes.io/zone
      whenUnsatisfiable: DoNotSchedule
      labelSelector:
        matchLabels:
          cnpg.io/cluster: ${CNPG_CLUSTER}
  bootstrap:
    initdb:
      database: ${DB_NAME}
      owner: ${CNPG_OWNER}
      dataChecksums: true
      localeCollate: 'C'
      localeCType: 'C'
  storage:
    pvcTemplate:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 2Gi
      storageClassName: gp3
      volumeMode: Filesystem
EOF

  ok "CNPG Cluster ${CNPG_CLUSTER} created"

  # ─────────────────────────────────────────────
  header "4. Waiting for CNPG Cluster to be ready"
  # ─────────────────────────────────────────────
  info "Waiting for primary pod to become Ready..."

  for i in $(seq 1 90); do
    PHASE=$(kubectl get cluster.postgresql.cnpg.io "$CNPG_CLUSTER" -n "$DHCP_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    READY_INSTANCES=$(kubectl get cluster.postgresql.cnpg.io "$CNPG_CLUSTER" -n "$DHCP_NS" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "0")
    if [[ "$PHASE" == "Cluster in healthy state" && "$READY_INSTANCES" -ge 1 ]]; then
      break
    fi
    if (( i % 10 == 0 )); then
      info "  Phase: ${PHASE:-pending}, Ready instances: ${READY_INSTANCES:-0} (${i}s elapsed)"
    fi
    sleep 2
  done

  if [[ "$PHASE" != "Cluster in healthy state" || "$READY_INSTANCES" -lt 1 ]]; then
    fail "CNPG Cluster did not become healthy within 180s (phase: ${PHASE}, ready: ${READY_INSTANCES})"
    info "  Debug: kubectl get cluster.postgresql.cnpg.io ${CNPG_CLUSTER} -n ${DHCP_NS} -o yaml"
    exit 1
  fi
  ok "CNPG Cluster healthy (${READY_INSTANCES} instances ready)"

  # Verify service is resolvable
  CNPG_RW_SVC="${CNPG_CLUSTER}-rw"
  if kubectl get svc "$CNPG_RW_SVC" -n "$DHCP_NS" &>/dev/null; then
    ok "Service ${CNPG_RW_SVC} exists"
  else
    fail "Service ${CNPG_RW_SVC} not found — pods won't be able to connect"
    exit 1
  fi

  # Verify secret was regenerated
  if kubectl get secret "$CNPG_SECRET" -n "$DHCP_NS" &>/dev/null; then
    ok "Secret ${CNPG_SECRET} regenerated"
  else
    fail "Secret ${CNPG_SECRET} not found — credentials unavailable for Kea pods"
    exit 1
  fi

  # Verify empty DB is accessible
  CNPG_RW_POD=$(kubectl get pods -n "$DHCP_NS" -l "cnpg.io/cluster=${CNPG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  TABLE_COUNT=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" 2>/dev/null | tr -d '[:space:]' || echo "0")

  echo ""
  echo -e "${GREEN}${BOLD}=== newdb COMPLETE ===${NC}"
  echo -e "  CNPG Cluster:   ${CYAN}${CNPG_CLUSTER}${NC}"
  echo -e "  Service:        ${CNPG_RW_SVC}.${DHCP_NS}.svc.cluster.local"
  echo -e "  Secret:         ${CNPG_SECRET}"
  echo -e "  Database:       ${DB_NAME} (${TABLE_COUNT} public tables — empty)"
  echo -e "  Kea 2.2 will run kea-admin db-init on startup → v13 schema"
  echo -e "  Then lease sync from cloud will populate data"
  echo ""
  echo -e "Next: Run ${CYAN}./can_scale_up.sh ${ENDPOINT_ID}${NC}"
  exit 0
fi

# ─────────────────────────────────────────────
header "2. Creating rollback Job"
# ─────────────────────────────────────────────

cat <<EOF | kubectl apply -n "$DHCP_NS" -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${DHCP_NS}
  labels:
    app: schema-rollback
    endpointID: "${ENDPOINT_ID}"
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: schema-rollback
          image: ${JOB_IMAGE}
          command:
            - sh
            - -ec
            - |
              echo "=== Schema Rollback Job ==="
              echo "Endpoint: ${ENDPOINT_ID}"
              echo "Mode: ${MODE}"
              echo "Host: \${DB_HOST}, Database: \${DB_DATABASE}, User: \${DB_USER}"
              export PGPASSWORD="\${DB_PASSWORD}"
              PSQL="psql -h \${DB_HOST} -U \${DB_USER} -d \${DB_DATABASE}"

              # --- Step 1: Check current schema version ---
              SCHEMA_VERSION=\$(\${PSQL} -t -A -c "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1" 2>/dev/null || echo "NONE")
              SCHEMA_VERSION=\$(echo "\${SCHEMA_VERSION}" | tr -d '[:space:]')
              echo "Current schema_version: \${SCHEMA_VERSION}"

              # --- Step 2: Drop public schema ---
              echo ""
              echo "--- Dropping public schema ---"
              \${PSQL} -c "DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public;"
              echo "Public schema dropped and recreated (empty)."

              if [ "${MODE}" = "reset" ]; then
                # ── RESET MODE: DB is now completely empty ──
                # Kea 2.2 will run kea-admin db-init on startup → creates v13 DDL
                # Then lease sync from cloud will populate the tables
                TABLE_COUNT=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')
                echo ""
                echo "=== Reset COMPLETE ==="
                echo "  Public schema is empty (\${TABLE_COUNT} tables)"
                echo "  Kea 2.2 will create v13 schema on startup via kea-admin db-init"
                echo "  Lease sync from cloud will populate data"
              else
                # ── RESTORE MODE: create v13 DDL + restore backup data ──

                # --- Step 3: Run kea-admin db-init to create v13 DDL ---
                KEA_ADMIN=\$(find /home/keadist -name kea-admin -type f 2>/dev/null | head -1)
                if [ -z "\${KEA_ADMIN}" ]; then
                  echo "ERROR: kea-admin not found in image"
                  exit 1
                fi
                echo ""
                echo "--- Running kea-admin db-init (found at: \${KEA_ADMIN}) ---"
                \${KEA_ADMIN} db-init pgsql \
                  --host "\${DB_HOST}" \
                  --port 5432 \
                  --user "\${DB_USER}" \
                  --password "\${DB_PASSWORD}" \
                  --name "\${DB_DATABASE}" \
                  --yes
                echo "kea-admin db-init completed."

                # --- Step 4: Verify schema_version is now 13 ---
                NEW_VERSION=\$(\${PSQL} -t -A -c "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1" 2>/dev/null || echo "NONE")
                NEW_VERSION=\$(echo "\${NEW_VERSION}" | tr -d '[:space:]')
                echo "Schema version after db-init: \${NEW_VERSION}"
                if [ "\${NEW_VERSION}" != "13" ]; then
                  echo "ERROR: Expected schema_version 13 after db-init, got \${NEW_VERSION}"
                  exit 1
                fi

                # --- Step 5: Signal that db-init is done (restore handled outside Job) ---
                BACKUP_EXISTS=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'backup_premigration'" 2>/dev/null || echo "0")
                BACKUP_EXISTS=\$(echo "\${BACKUP_EXISTS}" | tr -d '[:space:]')
                if [ "\${BACKUP_EXISTS}" = "0" ]; then
                  echo "ERROR: backup_premigration schema does not exist. Cannot restore without backup data."
                  exit 1
                fi
                BACKUP_TABLE_COUNT=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'backup_premigration' AND table_type = 'BASE TABLE'")
                echo "backup_premigration schema found with \${BACKUP_TABLE_COUNT} tables."
                echo ""
                echo "=== db-init COMPLETE. Restore will be done via superuser outside this Job. ==="
              fi
          env:
            - name: DB_HOST
              value: "${CNPG_CLUSTER}-rw"
            - name: DB_DATABASE
              value: "${DB_NAME}"
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: "${CNPG_SECRET}"
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: "${CNPG_SECRET}"
                  key: password
EOF

ok "Job ${JOB_NAME} created"

# ─────────────────────────────────────────────
header "3. Waiting for Job to complete"
# ─────────────────────────────────────────────
info "Streaming logs..."
echo ""

# Wait for pod to be created
for i in $(seq 1 30); do
  JOB_POD=$(kubectl get pods -n "$DHCP_NS" -l "job-name=${JOB_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$JOB_POD" ]]; then
    break
  fi
  sleep 2
done

if [[ -z "${JOB_POD:-}" ]]; then
  fail "Job pod did not start within 60s"
  exit 1
fi

# Wait for container to be running/terminated
kubectl wait --for=condition=Ready pod/"$JOB_POD" -n "$DHCP_NS" --timeout=120s 2>/dev/null || true

# Stream logs
kubectl logs -f "job/${JOB_NAME}" -n "$DHCP_NS" 2>/dev/null || true

echo ""

# Check job status
JOB_STATUS=$(kubectl get job "$JOB_NAME" -n "$DHCP_NS" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
if [[ "$JOB_STATUS" == "Complete" || "$JOB_STATUS" == "SuccessCriteriaMet" ]]; then
  ok "Job completed successfully"
elif [[ "$JOB_STATUS" == "Failed" ]]; then
  fail "Job FAILED. Check logs above for errors."
  info "  Debug: kubectl logs job/${JOB_NAME} -n ${DHCP_NS}"
  info "  Cleanup: kubectl delete job ${JOB_NAME} -n ${DHCP_NS}"
  exit 1
else
  warn "Job status: ${JOB_STATUS}. It may still be running."
  info "  Check: kubectl get job ${JOB_NAME} -n ${DHCP_NS}"
  info "  Logs:  kubectl logs -f job/${JOB_NAME} -n ${DHCP_NS}"
fi

# ─────────────────────────────────────────────
# Step 4 (restore mode only): Restore data from backup_premigration
# Uses kubectl exec into CNPG pod as postgres superuser (can set session_replication_role)
# ─────────────────────────────────────────────
if [[ "$MODE" == "restore" ]]; then
  header "4. Restoring data from backup_premigration (via superuser)"

  info "Building restore SQL..."

  # Get list of backup tables with data
  BACKUP_TABLES=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'backup_premigration' AND table_type = 'BASE TABLE' ORDER BY table_name")

  # Get all public tables for TRUNCATE
  ALL_PUBLIC_TABLES=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
    "SELECT string_agg('public.' || table_name, ', ') FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'")

  # Build SQL file locally
  RESTORE_FILE=$(mktemp)
  echo "SET session_replication_role = 'replica';" > "$RESTORE_FILE"
  echo "TRUNCATE ${ALL_PUBLIC_TABLES};" >> "$RESTORE_FILE"

  RESTORE_COUNT=0
  SKIP_COUNT=0
  for BAK_TABLE in $BACKUP_TABLES; do
    PUBLIC_TABLE=$(echo "$BAK_TABLE" | sed 's/_bak$//')
    # Check if public table exists
    EXISTS=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
      "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${PUBLIC_TABLE}'")
    EXISTS=$(echo "$EXISTS" | tr -d '[:space:]')
    if [[ "$EXISTS" == "1" ]]; then
      ROW_COUNT=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
        "SELECT COUNT(*) FROM backup_premigration.${BAK_TABLE}")
      ROW_COUNT=$(echo "$ROW_COUNT" | tr -d '[:space:]')
      if [[ "$ROW_COUNT" != "0" ]]; then
        echo "  Will restore: ${BAK_TABLE} -> public.${PUBLIC_TABLE} (${ROW_COUNT} rows)"
        echo "INSERT INTO public.${PUBLIC_TABLE} SELECT * FROM backup_premigration.${BAK_TABLE};" >> "$RESTORE_FILE"
        RESTORE_COUNT=$((RESTORE_COUNT + 1))
      else
        SKIP_COUNT=$((SKIP_COUNT + 1))
      fi
    else
      warn "public.${PUBLIC_TABLE} does not exist in v13 schema, skipping ${BAK_TABLE}"
      SKIP_COUNT=$((SKIP_COUNT + 1))
    fi
  done
  echo "SET session_replication_role = 'origin';" >> "$RESTORE_FILE"

  info "Restore SQL ready: ${RESTORE_COUNT} tables to restore, ${SKIP_COUNT} skipped"
  info "Executing restore via postgres superuser on ${CNPG_RW_POD}..."

  # Pipe the SQL into the CNPG pod
  kubectl exec -i -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" < "$RESTORE_FILE"
  RESTORE_RC=$?
  rm -f "$RESTORE_FILE"

  if [[ $RESTORE_RC -ne 0 ]]; then
    fail "Restore failed (exit code: ${RESTORE_RC})"
    exit 1
  fi

  # Final verification
  LEASE4_COUNT=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
    "SELECT COUNT(*) FROM public.lease4" 2>/dev/null || echo "N/A")
  LEASE4_COUNT=$(echo "$LEASE4_COUNT" | tr -d '[:space:]')
  SCHEMA_VER=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
    "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1")
  SCHEMA_VER=$(echo "$SCHEMA_VER" | tr -d '[:space:]')
  TABLE_COUNT=$(kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')

  echo ""
  echo -e "${GREEN}${BOLD}=== Restore COMPLETE ===${NC}"
  echo -e "  Schema version: ${CYAN}${SCHEMA_VER}${NC}"
  echo -e "  Public tables:  ${TABLE_COUNT}"
  echo -e "  lease4 rows:    ${CYAN}${LEASE4_COUNT}${NC}"
  echo -e "  backup_premigration: preserved (not dropped)"

  if [[ "$SCHEMA_VER" != "13" ]]; then
    fail "Expected schema version 13, got ${SCHEMA_VER}"
    exit 1
  fi
  ok "Schema v13 with backup data restored successfully"
else
  echo ""
  if [[ "$JOB_STATUS" == "Complete" ]]; then
    echo -e "${GREEN}${BOLD}Step 2 complete.${NC} DB is empty. Kea 2.2 will create v13 schema on startup, then lease sync from cloud."
  fi
fi
echo -e "Next: Deploy Kea 2.2 via DC PR, then run ${CYAN}./can_scale_up.sh ${ENDPOINT_ID}${NC}"

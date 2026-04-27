#!/usr/bin/env bash
set -euo pipefail

# Step 2: Apply a Kubernetes Job to rollback DB schema
#
# Two modes:
#   reset   - Drop all tables from public schema → completely empty DB.
#             Kea 2.2 will run kea-admin db-init on startup, then lease sync from cloud fills data.
#   restore - Drop public schema, kea-admin db-init (v13 DDL) + restore data from backup_premigration.
#
# Usage: ./02_fix_db.sh <endpoint_id> [reset|restore]
#   Default mode: restore

ENDPOINT_ID="${1:?Usage: $0 <endpoint_id> [reset|restore]}"
MODE="${2:-restore}"
if [[ "$MODE" != "reset" && "$MODE" != "restore" ]]; then
  echo "Error: mode must be 'reset' or 'restore', got '${MODE}'"
  echo "Usage: $0 <endpoint_id> [reset|restore]"
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
echo -e "Mode:     ${CYAN}${MODE}${NC} $(if [[ "$MODE" == "reset" ]]; then echo '(empty v13 tables, no data restore)'; else echo '(v13 tables + restore data from backup)'; fi)"
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
if ! kubectl get secret "$CNPG_SECRET" -n "$DHCP_NS" &>/dev/null; then
  fail "CNPG secret ${CNPG_SECRET} not found in ${DHCP_NS}"
  exit 1
fi
ok "CNPG secret found: ${CNPG_SECRET}"

# Check CNPG cluster is running
CNPG_RW_POD=$(kubectl get pods -n "$DHCP_NS" -l "cnpg.io/cluster=${CNPG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$CNPG_RW_POD" ]]; then
  fail "No CNPG primary pod found for cluster ${CNPG_CLUSTER}"
  exit 1
fi
ok "CNPG primary pod: ${CNPG_RW_POD}"

# Clean up previous job if exists
if kubectl get job "$JOB_NAME" -n "$DHCP_NS" &>/dev/null; then
  warn "Previous job ${JOB_NAME} exists. Deleting..."
  kubectl delete job "$JOB_NAME" -n "$DHCP_NS" --ignore-not-found
  sleep 2
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
          image: ${HOST_CONTROLLER_IMAGE}
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

                # --- Step 5: Restore data from backup_premigration ---
                BACKUP_EXISTS=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'backup_premigration'" 2>/dev/null || echo "0")
                BACKUP_EXISTS=\$(echo "\${BACKUP_EXISTS}" | tr -d '[:space:]')
                if [ "\${BACKUP_EXISTS}" = "0" ]; then
                  echo "ERROR: backup_premigration schema does not exist. Cannot restore without backup data."
                  exit 1
                fi
                BACKUP_TABLE_COUNT=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'backup_premigration' AND table_type = 'BASE TABLE'")
                echo "backup_premigration schema found with \${BACKUP_TABLE_COUNT} tables."

                echo ""
                echo "--- Restoring data from backup_premigration ---"
                BACKUP_TABLES=\$(\${PSQL} -t -A -c "SELECT table_name FROM information_schema.tables WHERE table_schema = 'backup_premigration' AND table_type = 'BASE TABLE' ORDER BY table_name")
                RESTORE_COUNT=0
                SKIP_COUNT=0
                for BAK_TABLE in \${BACKUP_TABLES}; do
                  PUBLIC_TABLE=\$(echo "\${BAK_TABLE}" | sed 's/_bak\$//')
                  EXISTS=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '\${PUBLIC_TABLE}'")
                  EXISTS=\$(echo "\${EXISTS}" | tr -d '[:space:]')
                  if [ "\${EXISTS}" = "1" ]; then
                    ROW_COUNT=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM backup_premigration.\${BAK_TABLE}")
                    ROW_COUNT=\$(echo "\${ROW_COUNT}" | tr -d '[:space:]')
                    if [ "\${ROW_COUNT}" != "0" ]; then
                      echo "  Restoring \${BAK_TABLE} -> public.\${PUBLIC_TABLE} (\${ROW_COUNT} rows)..."
                      \${PSQL} -c "INSERT INTO public.\${PUBLIC_TABLE} SELECT * FROM backup_premigration.\${BAK_TABLE}"
                      RESTORE_COUNT=\$((RESTORE_COUNT + 1))
                    else
                      echo "  Skipping \${BAK_TABLE} -> public.\${PUBLIC_TABLE} (0 rows)"
                      SKIP_COUNT=\$((SKIP_COUNT + 1))
                    fi
                  else
                    echo "  WARNING: public.\${PUBLIC_TABLE} does not exist in v13 schema, skipping \${BAK_TABLE}"
                    SKIP_COUNT=\$((SKIP_COUNT + 1))
                  fi
                done
                echo "Restored \${RESTORE_COUNT} tables, skipped \${SKIP_COUNT} tables."

                # --- Step 6: Final verification ---
                TABLE_COUNT=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')
                LEASE4_COUNT=\$(\${PSQL} -t -A -c "SELECT COUNT(*) FROM public.lease4" 2>/dev/null || echo "N/A")
                LEASE4_COUNT=\$(echo "\${LEASE4_COUNT}" | tr -d '[:space:]')
                echo ""
                echo "=== Restore COMPLETE ==="
                echo "  Schema version: \${NEW_VERSION}"
                echo "  Public tables: \${TABLE_COUNT}"
                echo "  lease4 rows: \${LEASE4_COUNT}"
                echo "  backup_premigration: preserved (not dropped)"
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
if [[ "$JOB_STATUS" == "Complete" ]]; then
  ok "Job completed successfully"
  echo ""
  if [[ "$MODE" == "reset" ]]; then
    echo -e "${GREEN}${BOLD}Step 2 complete.${NC} DB is empty. Kea 2.2 will create v13 schema on startup, then lease sync from cloud."
  else
    echo -e "${GREEN}${BOLD}Step 2 complete.${NC} DB is now at schema v13 with data restored from backup."
  fi
  echo -e "Next: Run ${CYAN}./03_verify_db.sh ${ENDPOINT_ID}${NC} to verify, then deploy Kea 2.2 via DC PR."
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

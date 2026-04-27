#!/usr/bin/env bash
set -euo pipefail

# Verify DB state for a DHCP endpoint
#
# Two modes:
#   kea22 - Verify schema v13 (Kea 2.2) — after rollback
#   kea26 - Verify schema v22 (Kea 2.6) — after upgrade
#
# Usage: ./03_verify_db.sh <endpoint_id> [kea22|kea26]
#   Default mode: kea22

ENDPOINT_ID="${1:?Usage: $0 <endpoint_id> [kea22|kea26]}"
MODE="${2:-kea22}"
if [[ "$MODE" != "kea22" && "$MODE" != "kea26" ]]; then
  echo "Error: mode must be 'kea22' or 'kea26', got '${MODE}'"
  echo "Usage: $0 <endpoint_id> [kea22|kea26]"
  exit 1
fi

if [[ "$MODE" == "kea22" ]]; then
  EXPECTED_VERSION="13"
  EXPECTED_TABLES=55
  EXPECTED_TABLES_MIN=50
  EXPECTED_INDEX=148
  EXPECTED_INDEX_MIN=140
  EXPECTED_TRIGGER=81
  EXPECTED_TRIGGER_MIN=75
  EXPECTED_FK=68
  EXPECTED_FK_MIN=60
  KEA_LABEL="Kea 2.2"
else
  EXPECTED_VERSION="22"
  EXPECTED_TABLES=60
  EXPECTED_TABLES_MIN=55
  EXPECTED_INDEX=160
  EXPECTED_INDEX_MIN=150
  EXPECTED_TRIGGER=81
  EXPECTED_TRIGGER_MIN=75
  EXPECTED_FK=72
  EXPECTED_FK_MIN=65
  KEA_LABEL="Kea 2.6"
fi
DHCP_NS="ddiaas-dhcp-endpoint"
CNPG_CLUSTER="cnpg-${ENDPOINT_ID}"
DB_NAME="dhcp_endpoint"

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

echo -e "${BOLD}Verify DB State (${KEA_LABEL})${NC}"
echo -e "Endpoint: ${CYAN}${ENDPOINT_ID}${NC}"
echo -e "Mode:     ${CYAN}${MODE}${NC} (expecting schema v${EXPECTED_VERSION})"
echo -e "Cluster:  $(kubectl config current-context)"
echo -e "Time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# Find CNPG primary pod
CNPG_RW_POD=$(kubectl get pods -n "$DHCP_NS" -l "cnpg.io/cluster=${CNPG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$CNPG_RW_POD" ]]; then
  fail "No CNPG primary pod found for cluster ${CNPG_CLUSTER}"
  exit 1
fi
ok "CNPG primary pod: ${CNPG_RW_POD}"

run_sql() {
  kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -t -A -c "$1" 2>/dev/null
}

run_sql_pretty() {
  kubectl exec -n "$DHCP_NS" "$CNPG_RW_POD" -- psql -U postgres -d "$DB_NAME" -c "$1" 2>/dev/null
}

PASS_COUNT=0
FAIL_COUNT=0

check_pass() { ok "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
check_fail() { fail "$1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ─────────────────────────────────────────────
header "1. Schema version"
# ─────────────────────────────────────────────
SCHEMA_VERSION=$(run_sql "SELECT version FROM schema_version ORDER BY version DESC LIMIT 1" | tr -d '[:space:]')
if [[ "$SCHEMA_VERSION" == "$EXPECTED_VERSION" ]]; then
  check_pass "schema_version = ${SCHEMA_VERSION} (expected: ${EXPECTED_VERSION})"
else
  check_fail "schema_version = ${SCHEMA_VERSION} (expected: ${EXPECTED_VERSION})"
fi

# ─────────────────────────────────────────────
header "2. Public schema table count"
# ─────────────────────────────────────────────
TABLE_COUNT=$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')
if [[ "$TABLE_COUNT" -ge "$EXPECTED_TABLES_MIN" ]]; then
  check_pass "Public schema has ${TABLE_COUNT} tables (expected: ${EXPECTED_TABLES})"
else
  check_fail "Public schema has ${TABLE_COUNT} tables (expected: ${EXPECTED_TABLES})"
fi

# ─────────────────────────────────────────────
header "3. Key tables exist"
# ─────────────────────────────────────────────
# Common tables for both versions
KEY_TABLES="lease4 lease6 lease4_stat lease6_stat schema_version hosts ipv6_reservations dhcp4_options dhcp6_options"

# Kea 2.6 (v22) has additional tables
if [[ "$MODE" == "kea26" ]]; then
  KEY_TABLES="$KEY_TABLES lease4_pool_stat lease6_pool_stat dhcp4_server dhcp6_server dhcp4_audit dhcp6_audit dhcp4_global_parameter dhcp6_global_parameter"
fi

for TABLE in $KEY_TABLES; do
  EXISTS=$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = '${TABLE}'" | tr -d '[:space:]')
  if [[ "$EXISTS" == "1" ]]; then
    check_pass "Table public.${TABLE} exists"
  else
    check_fail "Table public.${TABLE} MISSING"
  fi
done

# ─────────────────────────────────────────────
header "4. Data row counts (current vs pre-migration backup)"
# ─────────────────────────────────────────────
BACKUP_SCHEMA_EXISTS=$(run_sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'backup_premigration'" | tr -d '[:space:]')

for TABLE in lease4 lease6 hosts; do
  CURRENT_COUNT=$(run_sql "SELECT COUNT(*) FROM public.${TABLE}" 2>/dev/null | tr -d '[:space:]' || echo "N/A")
  if [[ "$BACKUP_SCHEMA_EXISTS" == "1" ]]; then
    BACKUP_COUNT=$(run_sql "SELECT COUNT(*) FROM backup_premigration.${TABLE}_bak" 2>/dev/null | tr -d '[:space:]' || echo "N/A")
    if [[ "$CURRENT_COUNT" != "N/A" && "$BACKUP_COUNT" != "N/A" && "$CURRENT_COUNT" -ge "$BACKUP_COUNT" ]]; then
      check_pass "public.${TABLE}: ${CURRENT_COUNT} rows (backup: ${BACKUP_COUNT})"
    elif [[ "$CURRENT_COUNT" != "N/A" && "$BACKUP_COUNT" != "N/A" ]]; then
      check_fail "public.${TABLE}: ${CURRENT_COUNT} rows < backup: ${BACKUP_COUNT} (data loss?)"
    else
      info "public.${TABLE}: ${CURRENT_COUNT} rows  |  backup: ${BACKUP_COUNT}"
    fi
  else
    info "public.${TABLE}: ${CURRENT_COUNT} rows  |  (no backup_premigration)"
  fi
done

# ─────────────────────────────────────────────
header "5. Indexes and constraints"
# ─────────────────────────────────────────────
INDEX_COUNT=$(run_sql "SELECT COUNT(*) FROM pg_indexes WHERE schemaname = 'public'" | tr -d '[:space:]')
TRIGGER_COUNT=$(run_sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = 'public'" | tr -d '[:space:]')
FK_COUNT=$(run_sql "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_schema = 'public' AND constraint_type = 'FOREIGN KEY'" | tr -d '[:space:]')

if [[ "$INDEX_COUNT" -ge "$EXPECTED_INDEX_MIN" ]]; then
  check_pass "Indexes: ${INDEX_COUNT} (expected: ${EXPECTED_INDEX})"
else
  check_fail "Indexes: ${INDEX_COUNT} (expected: ${EXPECTED_INDEX})"
fi

if [[ "$TRIGGER_COUNT" -ge "$EXPECTED_TRIGGER_MIN" ]]; then
  check_pass "Triggers: ${TRIGGER_COUNT} (expected: ${EXPECTED_TRIGGER})"
else
  check_fail "Triggers: ${TRIGGER_COUNT} (expected: ${EXPECTED_TRIGGER})"
fi

if [[ "$FK_COUNT" -ge "$EXPECTED_FK_MIN" ]]; then
  check_pass "Foreign keys: ${FK_COUNT} (expected: ${EXPECTED_FK})"
else
  check_fail "Foreign keys: ${FK_COUNT} (expected: ${EXPECTED_FK})"
fi

# ─────────────────────────────────────────────
header "6. backup_premigration preserved"
# ─────────────────────────────────────────────
BACKUP_EXISTS=$(run_sql "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'backup_premigration'" | tr -d '[:space:]')
if [[ "$BACKUP_EXISTS" == "1" ]]; then
  BACKUP_TABLES=$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'backup_premigration' AND table_type = 'BASE TABLE'" | tr -d '[:space:]')
  # backup_premigration should have 55 tables (snapshot of Kea 2.2 public schema)
  if [[ "$BACKUP_TABLES" -ge 50 ]]; then
    check_pass "backup_premigration: ${BACKUP_TABLES} tables (expected: 55, matches Kea 2.2 table count)"
  else
    check_fail "backup_premigration: ${BACKUP_TABLES} tables (expected: 55)"
  fi
else
  warn "backup_premigration schema not found (data was not backed up before migration)"
fi

# ─────────────────────────────────────────────
header "7. Deployment state"
# ─────────────────────────────────────────────
DEPLOY_PREFIX="dhcp-${ENDPOINT_ID}-"
mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$DHCP_NS" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep "^${DEPLOY_PREFIX}" || true)

if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
  warn "No deployments found matching ${DEPLOY_PREFIX}*"
else
  for DEP in "${DEPLOYMENTS[@]}"; do
    REPLICAS=$(kubectl get deployment "$DEP" -n "$DHCP_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
    if [[ "$REPLICAS" == "0" ]]; then
      ok "Deployment ${DEP} is scaled to 0"
    else
      info "Deployment ${DEP} has ${REPLICAS} replicas (running)"
    fi
  done
fi

# ─────────────────────────────────────────────
header "Summary"
# ─────────────────────────────────────────────
echo ""
if [[ "$FAIL_COUNT" == "0" ]]; then
  echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED (${PASS_COUNT}/${PASS_COUNT})${NC}"
  echo ""
  echo -e "  DB is at schema v${EXPECTED_VERSION}, verified for ${KEA_LABEL}."
else
  echo -e "  ${RED}${BOLD}${FAIL_COUNT} CHECKS FAILED${NC} out of $((PASS_COUNT + FAIL_COUNT))"
  echo ""
  echo -e "  ${BOLD}DB does not match expected state for ${KEA_LABEL}.${NC}"
fi

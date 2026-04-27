#!/bin/bash
#
# lease4_count.sh - Query DHCPv4 lease counts from the dhcp-leases DB
#
# Creates short-lived pods (auto-cleaned) to reach private RDS.
# With --xaas, performs a 3-DB cross-reference to classify leases as
# DDIaaS (XaaS) vs NIOS.
#
# Usage:
#   ./lease4_count.sh [OPTIONS]
#   --namespace <ns>            (default: ddi)
#   --secret <name>             (default: dhcp-leases-db-dsn)
#   --limit <n>                 (default: 30)
#   --context <kube-ctx>        Cloud cluster context (default: current)
#   --accounts-file <file>      Filter to account IDs found in file
#   --xaas                      Enable DDIaaS/XaaS vs NIOS-X classification
#   --ddiaas-context <kube-ctx> DDIaaS data-plane cluster context (default: ddi-stg-use1)
#   --ddiaas-ns <ns>            DDIaaS endpoint-manager namespace (default: ddiaas-endpoint-manager)

set -euo pipefail

NAMESPACE="ddi"
SECRET_NAME="dhcp-leases-db-dsn"
LIMIT=30
KUBE_CONTEXT=""
ACCOUNTS_FILE=""
XAAS_MODE=false
DDIAAS_CONTEXT="ddi-stg-use1"
DDIAAS_NS="ddiaas-endpoint-manager"
IMG="core-harbor-prod.sdp.infoblox.com/infobloxcto/postgres:15.14-alpine3.22"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
  --namespace <ns>            Cloud namespace (default: ddi)
  --secret <name>             DB secret (default: dhcp-leases-db-dsn)
  --limit <n>                 Max rows per section (default: 30)
  --context <kube-ctx>        Cloud cluster context (default: current)
  --accounts-file <file>      Filter to account IDs found in file
  --xaas                      Show DDIaaS/XaaS lease counts
  --ddiaas-context <kube-ctx> DDIaaS data-plane cluster (default: ddi-stg-use1)
  --ddiaas-ns <ns>            Endpoint manager namespace (default: ddiaas-endpoint-manager)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)       NAMESPACE="$2"; shift 2 ;;
        --secret)          SECRET_NAME="$2"; shift 2 ;;
        --limit)           LIMIT="$2"; shift 2 ;;
        --context)         KUBE_CONTEXT="$2"; shift 2 ;;
        --accounts-file)   ACCOUNTS_FILE="$2"; shift 2 ;;
        --xaas)            XAAS_MODE=true; shift ;;
        --ddiaas-context)  DDIAAS_CONTEXT="$2"; shift 2 ;;
        --ddiaas-ns)       DDIAAS_NS="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *)                 echo "Unknown: $1"; usage ;;
    esac
done

KC="kubectl"
[[ -n "$KUBE_CONTEXT" ]] && KC="kubectl --context=$KUBE_CONTEXT"

# Track all pods we create for cleanup
PODS_TO_CLEAN=()
cleanup() {
    for pod_info in "${PODS_TO_CLEAN[@]}"; do
        local ctx_flag="${pod_info%%|*}"
        local ns_pod="${pod_info#*|}"
        local ns="${ns_pod%%|*}"
        local pod="${ns_pod#*|}"
        kubectl $ctx_flag delete pod -n "$ns" "$pod" --ignore-not-found >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

register_pod() {
    local ctx_flag="$1" ns="$2" pod="$3"
    PODS_TO_CLEAN+=("${ctx_flag}|${ns}|${pod}")
}

run_pod_query() {
    local ctx_flag="$1" ns="$2" secret="$3" secret_key="$4" pod="$5" sql_b64="$6" psql_flags="${7:-}"
    register_pod "$ctx_flag" "$ns" "$pod"
    kubectl $ctx_flag run "$pod" -n "$ns" --restart=Never --image="$IMG" \
      --overrides="{
        \"spec\": {
          \"containers\": [{
            \"name\": \"psql\",
            \"image\": \"$IMG\",
            \"command\": [\"sh\",\"-c\",\"echo '$sql_b64' | base64 -d | psql $psql_flags \\\"\$DSN\\\"\"],
            \"env\": [{\"name\":\"DSN\",\"valueFrom\":{\"secretKeyRef\":{\"name\":\"$secret\",\"key\":\"$secret_key\"}}}]
          }]
        }
      }" >/dev/null 2>&1
    kubectl $ctx_flag wait --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s pod/"$pod" -n "$ns" >/dev/null 2>&1 || {
        echo "ERROR: pod $pod failed"
        kubectl $ctx_flag logs -n "$ns" "$pod" 2>&1 || true
        return 1
    }
    kubectl $ctx_flag logs -n "$ns" "$pod" 2>&1
}

LIMIT_INT=$(printf '%d' "$LIMIT" 2>/dev/null) || { echo "Error: --limit must be integer"; exit 1; }

ACCT_FILTER=""
if [[ -n "$ACCOUNTS_FILE" ]]; then
    [[ -f "$ACCOUNTS_FILE" ]] || { echo "Error: not found: $ACCOUNTS_FILE"; exit 1; }
    ACCT_LIST=$(grep -E '^[0-9]+$' "$ACCOUNTS_FILE" | awk '$1 >= 32' | sort -un | paste -sd, -)
    [[ -n "$ACCT_LIST" ]] || { echo "Error: no account IDs in $ACCOUNTS_FILE"; exit 1; }
    ACCT_FILTER="AND account_id IN ('$(echo "$ACCT_LIST" | sed "s/,/','/g")')"
    echo "==> Accounts: $(echo "$ACCT_LIST" | tr ',' '\n' | wc -l | tr -d ' ') from $ACCOUNTS_FILE"
fi

echo "==> Cluster: $($KC config current-context) | NS: $NAMESPACE | Limit: $LIMIT_INT"
$XAAS_MODE && echo "==> XaaS mode: DDIaaS context=$DDIAAS_CONTEXT ns=$DDIAAS_NS"

# ============================================================
# XaaS classification: 3-DB cross-reference
# ============================================================
XAAS_HOST_FILTER=""
if $XAAS_MODE; then
    echo "==> Step 1/3: Querying endpoint manager DB for DDIaaS DHCP ophids..."
    DDIAAS_CTX_FLAG=""
    [[ -n "$DDIAAS_CONTEXT" ]] && DDIAAS_CTX_FLAG="--context=$DDIAAS_CONTEXT"

    SQL_OPHID="SELECT e.ophid FROM endpoints e WHERE e.endpoint_id IN (SELECT DISTINCT endpoint_id FROM endpoint_service_az_mapping WHERE service_type = 'dhcp');"
    POD_EM="xaas-em-$$"
    OPHID_RAW=$(run_pod_query "$DDIAAS_CTX_FLAG" "$DDIAAS_NS" "ddiaas-endpoint-manager-db-dsn" "uri_dsn.txt" "$POD_EM" "$(echo "$SQL_OPHID" | base64)" "-t -A")
    OPHID_LIST=$(echo "$OPHID_RAW" | grep "^managedhost" | sort -u)
    OPHID_COUNT=$(echo "$OPHID_LIST" | grep -c "^managedhost" || true)

    if [[ "$OPHID_COUNT" -eq 0 ]]; then
        echo "==> WARNING: No DDIaaS DHCP endpoints found. XaaS classification skipped."
        XAAS_MODE=false
    else
        echo "==> Found $OPHID_COUNT DDIaaS DHCP ophids"

        echo "==> Step 2/3: Mapping ophids to IPAM host IDs..."
        OPHID_IN=$(echo "$OPHID_LIST" | sed "s/^/'/;s/$/'/" | paste -sd, -)

        CLOUD_CTX_FLAG=""
        [[ -n "$KUBE_CONTEXT" ]] && CLOUD_CTX_FLAG="--context=$KUBE_CONTEXT"

        SQL_HOSTS="SELECT id FROM hosts WHERE ophid IN ($OPHID_IN);"
        POD_IPAM="xaas-ipam-$$"
        HOST_RAW=$(run_pod_query "$CLOUD_CTX_FLAG" "$NAMESPACE" "ipam-db-dsn" "uri_dsn.txt" "$POD_IPAM" "$(echo "$SQL_HOSTS" | base64)" "-t -A")
        HOST_IDS=$(echo "$HOST_RAW" | grep -E '^[0-9]+$' | sort -u)
        HOST_COUNT=$(echo "$HOST_IDS" | grep -cE '^[0-9]+$' || true)

        if [[ "$HOST_COUNT" -eq 0 ]]; then
            echo "==> WARNING: No IPAM host IDs found for DDIaaS ophids. XaaS classification skipped."
            XAAS_MODE=false
        else
            echo "==> Mapped to $HOST_COUNT IPAM host IDs"
            XAAS_HOST_FILTER=$(echo "$HOST_IDS" | sed "s/^/'dhcp\/host\//;s/$/'/" | paste -sd, -)
        fi
    fi
    echo "==> Step 3/3: Querying dhcp-leases DB..."
fi

# Write SQL to temp file for clean base64 encoding
TMPSQL=$(mktemp)

if $XAAS_MODE && [[ -n "$XAAS_HOST_FILTER" ]]; then
# ============================================================
# XaaS-aware report: DDIaaS lease counts
# ============================================================
cat > "$TMPSQL" <<EOSQL
SELECT '========================================' AS " ";
SELECT '  DHCPv4 Lease Count Report (XaaS)' AS " ";
SELECT '========================================' AS " ";

SELECT '--- 1. DDIaaS (XaaS) summary by state ---' AS " ";
SELECT state,
  COUNT(*) AS lease_count,
  COUNT(DISTINCT host) AS hosts,
  COUNT(DISTINCT ha_group) AS ha_groups,
  COUNT(DISTINCT account_id) AS accounts
FROM host_leases
WHERE type = 'DHCPv4'
  AND host IN ($XAAS_HOST_FILTER) ${ACCT_FILTER}
GROUP BY state
ORDER BY lease_count DESC;

SELECT '--- 2. DDIaaS (XaaS) leases by account_id (state=used) ---' AS " ";
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND host IN ($XAAS_HOST_FILTER) ${ACCT_FILTER}
GROUP BY account_id
ORDER BY lease_count DESC
LIMIT ${LIMIT_INT};

SELECT '--- 3. DDIaaS (XaaS) leases by host (state=used) ---' AS " ";
SELECT host, account_id, ha_group, COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND host IN ($XAAS_HOST_FILTER) ${ACCT_FILTER}
GROUP BY host, account_id, ha_group
ORDER BY lease_count DESC
LIMIT ${LIMIT_INT};

SELECT '--- 4. Row counts per table ---' AS " ";
SELECT relname AS table_name, n_live_tup AS approx_rows
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;
EOSQL

else
# ============================================================
# Standard report (no XaaS classification)
# ============================================================
cat > "$TMPSQL" <<EOSQL
SELECT '========================================' AS " ";
SELECT '  DHCPv4 Lease Count Report' AS " ";
SELECT '========================================' AS " ";

-- ============ host_leases table ============

SELECT '--- 1. Summary by provider_type and state (host_leases) ---' AS " ";
SELECT
    CASE WHEN provider_type = 'nios' THEN 'NIOS'
         WHEN provider_type IS NULL THEN 'BloxOne'
         WHEN provider_type = '' THEN 'BloxOne (legacy)'
         ELSE provider_type
    END AS source,
    state,
    COUNT(*) AS lease_count,
    COUNT(DISTINCT host) AS hosts,
    COUNT(DISTINCT ha_group) AS ha_groups,
    COUNT(DISTINCT account_id) AS accounts
FROM host_leases
WHERE type = 'DHCPv4' ${ACCT_FILTER}
GROUP BY provider_type, state
ORDER BY lease_count DESC;

SELECT '--- 2. By account_id (BloxOne, state=used, host_leases) ---' AS " ";
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND (provider_type IS NULL OR provider_type = '') ${ACCT_FILTER}
GROUP BY account_id
ORDER BY lease_count DESC
LIMIT ${LIMIT_INT};

SELECT '--- 3. By host (BloxOne, state=used, host_leases) ---' AS " ";
SELECT host, account_id, ha_group, COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND (provider_type IS NULL OR provider_type = '') ${ACCT_FILTER}
GROUP BY host, account_id, ha_group
ORDER BY lease_count DESC
LIMIT ${LIMIT_INT};

SELECT '--- 4. By ha_group (BloxOne, state=used, host_leases) ---' AS " ";
SELECT ha_group, account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(*) AS lease_count
FROM host_leases
WHERE type = 'DHCPv4' AND state = 'used'
  AND (provider_type IS NULL OR provider_type = '') ${ACCT_FILTER}
GROUP BY ha_group, account_id
ORDER BY lease_count DESC
LIMIT ${LIMIT_INT};

-- ============ leases table ============

SELECT '--- 5. Summary by state (leases table) ---' AS " ";
SELECT state,
       type,
       COUNT(*) AS lease_count,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(DISTINCT account_id) AS accounts
FROM leases
WHERE type = 'DHCPv4' ${ACCT_FILTER}
GROUP BY state, type
ORDER BY lease_count DESC;

SELECT '--- 6. By account_id (state=used, leases table) ---' AS " ";
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS lease_count
FROM leases
WHERE type = 'DHCPv4' AND state = 'used' ${ACCT_FILTER}
GROUP BY account_id
ORDER BY lease_count DESC
LIMIT ${LIMIT_INT};

-- ============ full_updates table ============

SELECT '--- 7. full_updates by account_id ---' AS " ";
SELECT account_id,
       COUNT(DISTINCT host) AS hosts,
       COUNT(DISTINCT ha_group) AS ha_groups,
       COUNT(*) AS total_rows
FROM full_updates
WHERE 1=1 ${ACCT_FILTER}
GROUP BY account_id
ORDER BY total_rows DESC
LIMIT ${LIMIT_INT};

-- ============ nios_grids table ============

SELECT '--- 8. nios_grids summary ---' AS " ";
SELECT account_id, grid_id, import_in_progress
FROM nios_grids
WHERE 1=1 ${ACCT_FILTER}
ORDER BY account_id
LIMIT ${LIMIT_INT};

-- ============ table row counts ============

SELECT '--- 9. Row counts per table ---' AS " ";
SELECT relname AS table_name, n_live_tup AS approx_rows
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;
EOSQL
fi  # end XaaS vs standard report

SQL_B64=$(base64 < "$TMPSQL")
rm -f "$TMPSQL"

CLOUD_CTX_FLAG=""
[[ -n "$KUBE_CONTEXT" ]] && CLOUD_CTX_FLAG="--context=$KUBE_CONTEXT"

POD_NAME="lease4-q-$$"
echo "==> Running query..."
OUTPUT=$(run_pod_query "$CLOUD_CTX_FLAG" "$NAMESPACE" "$SECRET_NAME" "uri_dsn.txt" "$POD_NAME" "$SQL_B64") || exit 1

echo ""
echo "$OUTPUT"
echo ""
echo "==> Done. (pods auto-cleaned)"

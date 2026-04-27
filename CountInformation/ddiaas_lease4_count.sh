#!/usr/bin/env bash
# ddiaas_lease4_count.sh — Count DDIaaS lease4 entries per endpoint and account
#
# Usage:
#   bash ddiaas_lease4_count.sh [OPTIONS]
#
# Options:
#   --contexts <c1,c2,...>   Comma-separated DDIaaS cluster contexts (required)
#   --cloud-context <ctx>    Cloud control-plane context for IPAM DB (for account_id mapping)
#   --cloud-ns <ns>          Cloud namespace for IPAM secret (default: ddi)
#   --ep-ns <ns>             Endpoint-manager namespace (default: ddiaas-endpoint-manager)
#   --dhcp-ns <ns>           DHCP endpoint namespace    (default: ddiaas-dhcp-endpoint)
#   --parallel <n>           Max parallel CNPG queries   (default: 5)
#   -h, --help               Show this help
#
# Examples:
#   # Staging (with account_id mapping)
#   bash ddiaas_lease4_count.sh --contexts ddi-stg-use1 --cloud-context teleport.services.sdp.infoblox.com-us-stg-1
#
#   # NA production (all NA regions)
#   bash ddiaas_lease4_count.sh --contexts ddi-prd-nva1,ddi-prd-ogn1,ddi-prd-cac1 --cloud-context teleport.services.sdp.infoblox.com-us-com-1
#
#   # EU production
#   bash ddiaas_lease4_count.sh --contexts ddi-prd-frk1 --cloud-context teleport.services.sdp.infoblox.com-eu-com-1
#
#   # Without account_id mapping (UUID only)
#   bash ddiaas_lease4_count.sh --contexts ddi-stg-use1
set -euo pipefail

# --- defaults ---
DDIAAS_CONTEXTS=""
CLOUD_CONTEXT=""
CLOUD_NS="ddi"
EP_NS="ddiaas-endpoint-manager"
DHCP_NS="ddiaas-dhcp-endpoint"
PARALLEL=5
POD_IMAGE="core-harbor-prod.sdp.infoblox.com/infobloxcto/postgres:15.14-alpine3.22"

usage() {
  sed -n '2,/^set /{ /^#/s/^# \?//p }' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --contexts)       DDIAAS_CONTEXTS="$2"; shift 2 ;;
    --cloud-context)  CLOUD_CONTEXT="$2"; shift 2 ;;
    --cloud-ns)       CLOUD_NS="$2"; shift 2 ;;
    --ep-ns)          EP_NS="$2"; shift 2 ;;
    --dhcp-ns)        DHCP_NS="$2"; shift 2 ;;
    --parallel)       PARALLEL="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -n "$DDIAAS_CONTEXTS" ]] || { echo "Error: --contexts is required"; usage; }

# Temp dir for results
TMPDIR=$(mktemp -d)
IPAM_POD=""
trap 'if [[ -n "$IPAM_POD" ]]; then kubectl --context="$CLOUD_CONTEXT" delete pod -n "$CLOUD_NS" "$IPAM_POD" --ignore-not-found --grace-period=0 >/dev/null 2>&1; fi; rm -rf "$TMPDIR"' EXIT

echo "======================================"
echo "  DDIaaS Lease4 Count Report"
echo "  $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "======================================"
echo ""

TOTAL_ENDPOINTS=0
TOTAL_LEASES=0
ACCT_MAP_FILE="$TMPDIR/acct_map.txt"
touch "$ACCT_MAP_FILE"
ALL_OPHIDS_FILE="$TMPDIR/all_ophids.txt"
touch "$ALL_OPHIDS_FILE"

# Process each DDIaaS context
IFS=',' read -ra CONTEXTS <<< "$DDIAAS_CONTEXTS"
for CTX in "${CONTEXTS[@]}"; do
  echo "==> Cluster: $CTX"

  # --- Step 1: Find endpoint-manager pod ---
  EP_POD=$(kubectl --context="$CTX" get pods -n "$EP_NS" \
    -l app=ddiaas-endpoint-manager \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "$EP_POD" ]]; then
    # Fallback: find by deployment
    EP_POD=$(kubectl --context="$CTX" get pods -n "$EP_NS" \
      --no-headers 2>/dev/null | grep "^ddiaas-endpoint-manager-" | grep -v "dbapi\|exporter" | head -1 | awk '{print $1}')
  fi

  if [[ -z "$EP_POD" ]]; then
    echo "    WARNING: No endpoint-manager pod found, skipping"
    echo ""
    continue
  fi
  echo "    Endpoint-manager pod: $EP_POD"

  # --- Step 2: Get DSN and query DHCP endpoints (include ophid for account mapping) ---
  DSN=$(kubectl --context="$CTX" get secret -n "$EP_NS" \
    ddiaas-endpoint-manager-db-dsn \
    -o jsonpath='{.data.uri_dsn\.txt}' | base64 -d)

  ENDPOINTS=$(kubectl --context="$CTX" exec -n "$EP_NS" "$EP_POD" -- \
    psql "$DSN" -t -A -c "
      SELECT e.endpoint_id, e.identity_account_id, e.endpoint_size, e.ophid
      FROM endpoints e
      WHERE e.endpoint_id IN (
        SELECT DISTINCT endpoint_id
        FROM endpoint_service_az_mapping
        WHERE service_type = 'dhcp'
      )
      ORDER BY e.identity_account_id, e.endpoint_id;
    " 2>/dev/null)

  # Collect ophids for account_id mapping later
  echo "$ENDPOINTS" | awk -F'|' '{print $4"|"$2}' >> "$ALL_OPHIDS_FILE"

  EP_COUNT=$(echo "$ENDPOINTS" | grep -c '|' || echo 0)
  echo "    DHCP endpoints found: $EP_COUNT"

  if [[ "$EP_COUNT" -eq 0 ]]; then
    echo ""
    continue
  fi

  # --- Step 3: Query lease4 count from each CNPG pod ---
  echo "    Querying lease4 counts (parallel=$PARALLEL)..."

  CTX_RESULTS="$TMPDIR/ctx_${CTX}.txt"
  > "$CTX_RESULTS"

  # Function to query a single endpoint
  query_endpoint() {
    local ctx="$1" ns="$2" ep_id="$3" acct_id="$4" size="$5" ophid="$6" outfile="$7"
    local pod="cnpg-${ep_id}-1"

    # Check pod exists and is running
    local phase
    phase=$(kubectl --context="$ctx" get pod -n "$ns" "$pod" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "$phase" != "Running" ]]; then
      echo "${ctx}|${ep_id}|${acct_id}|${size}|${ophid}|ERROR:${phase}" >> "$outfile"
      return
    fi

    local count
    count=$(kubectl --context="$ctx" exec -n "$ns" "$pod" -- \
      psql -U postgres -d dhcp_endpoint -t -A \
      -c "SELECT COUNT(*) FROM lease4;" 2>/dev/null || echo "ERROR")

    echo "${ctx}|${ep_id}|${acct_id}|${size}|${ophid}|${count}" >> "$outfile"
  }

  export -f query_endpoint

  # Run queries with controlled parallelism
  RUNNING=0
  while IFS='|' read -r EP_ID ACCT_ID EP_SIZE OPHID; do
    query_endpoint "$CTX" "$DHCP_NS" "$EP_ID" "$ACCT_ID" "$EP_SIZE" "$OPHID" "$CTX_RESULTS" &
    RUNNING=$((RUNNING + 1))
    if [[ $RUNNING -ge $PARALLEL ]]; then
      wait -n 2>/dev/null || true
      RUNNING=$((RUNNING - 1))
    fi
  done <<< "$ENDPOINTS"
  wait

  # Count results for this cluster
  CTX_LEASES=$(awk -F'|' '$6 ~ /^[0-9]+$/ {s+=$6} END {print s+0}' "$CTX_RESULTS")
  CTX_EPS=$(wc -l < "$CTX_RESULTS" | tr -d ' ')
  TOTAL_ENDPOINTS=$((TOTAL_ENDPOINTS + CTX_EPS))
  TOTAL_LEASES=$((TOTAL_LEASES + CTX_LEASES))

  echo "    Total lease4 on $CTX: $CTX_LEASES (across $CTX_EPS endpoints)"
  echo ""
done

# --- Step: Map identity_account_id → numeric account_id via IPAM DB ---
if [[ -n "$CLOUD_CONTEXT" ]]; then
  echo "==> Mapping account IDs via IPAM DB on $CLOUD_CONTEXT..."

  # Collect unique ophids
  OPHID_LIST=$(cut -d'|' -f1 "$ALL_OPHIDS_FILE" | sort -u | grep -v '^$')
  OPHID_COUNT=$(echo "$OPHID_LIST" | wc -l | tr -d ' ')
  echo "    Unique ophids to map: $OPHID_COUNT"

  # Get IPAM DSN
  IPAM_DSN=$(kubectl --context="$CLOUD_CONTEXT" get secret -n "$CLOUD_NS" \
    ipam-db-dsn -o jsonpath='{.data.uri_dsn\.txt}' | base64 -d)

  # Create temp pod for IPAM query
  IPAM_POD="ddiaas-acctmap-$$"
  kubectl --context="$CLOUD_CONTEXT" run -n "$CLOUD_NS" "$IPAM_POD" \
    --image="$POD_IMAGE" --restart=Never \
    --env="DSN=$IPAM_DSN" --command -- sleep 300 >/dev/null 2>&1
  kubectl --context="$CLOUD_CONTEXT" wait -n "$CLOUD_NS" \
    --for=condition=Ready "pod/$IPAM_POD" --timeout=60s >/dev/null 2>&1

  # Build SQL IN clause
  OPHID_IN=$(echo "$OPHID_LIST" | sed "s/^/'/;s/$/'/" | paste -sd, -)

  # Query IPAM: ophid → account_id
  SQL="SELECT DISTINCT ophid, account_id FROM hosts WHERE ophid IN ($OPHID_IN);"
  SQL_B64=$(echo "$SQL" | base64)

  kubectl --context="$CLOUD_CONTEXT" exec -n "$CLOUD_NS" "$IPAM_POD" -- \
    sh -c "echo '$SQL_B64' | base64 -d | psql \"\$DSN\" -t -A" 2>/dev/null \
    > "$ACCT_MAP_FILE"

  MAPPED=$(wc -l < "$ACCT_MAP_FILE" | tr -d ' ')
  echo "    Mapped $MAPPED ophids to numeric account_id"

  # Cleanup IPAM pod
  kubectl --context="$CLOUD_CONTEXT" delete pod -n "$CLOUD_NS" "$IPAM_POD" \
    --ignore-not-found --grace-period=0 >/dev/null 2>&1
  IPAM_POD=""
  echo ""
fi

# --- Combine all results and join with account_id mapping ---
# Raw format: ctx|ep_id|identity_account_id|size|ophid|count
# ACCT_MAP format: ophid|account_id
ALL_RESULTS="$TMPDIR/all_results.txt"
cat "$TMPDIR"/ctx_*.txt 2>/dev/null | sort -t'|' -k3,3 -k2,2 > "$ALL_RESULTS"

# Create enriched results: ctx|ep_id|identity_account_id|size|ophid|count|account_id
ENRICHED="$TMPDIR/enriched.txt"
if [[ -s "$ACCT_MAP_FILE" ]]; then
  awk -F'|' '
    NR==FNR { map[$1] = $2; next }
    { printf "%s|%s\n", $0, ($5 in map ? map[$5] : "N/A") }
  ' "$ACCT_MAP_FILE" "$ALL_RESULTS" > "$ENRICHED"
else
  awk -F'|' '{ printf "%s|N/A\n", $0 }' "$ALL_RESULTS" > "$ENRICHED"
fi

echo "======================================"
echo "  SUMMARY"
echo "======================================"
echo ""
echo "Total endpoints queried: $TOTAL_ENDPOINTS"
echo "Total lease4 entries:    $TOTAL_LEASES"
[[ -n "$CLOUD_CONTEXT" ]] && echo "Account mapping:         via IPAM on $CLOUD_CONTEXT" || echo "Account mapping:         none (use --cloud-context to enable)"
echo ""

# --- Section 1: Lease count by account ---
echo "--------------------------------------"
echo "  1. Lease4 Count by Account"
echo "--------------------------------------"
printf "%-10s %-40s %8s %8s\n" "account_id" "identity_account_id" "leases" "endpts"
printf "%-10s %-40s %8s %8s\n" "----------" "---------------------------------------" "--------" "--------"
awk -F'|' '$6 ~ /^[0-9]+$/ {
  acct[$3] += $6
  cnt[$3]++
  aid[$3] = $7
}
END {
  for (a in acct) printf "%-10s %-40s %8d %8d\n", aid[a], a, acct[a], cnt[a]
}' "$ENRICHED" | sort -t' ' -k3 -rn
echo ""

# --- Section 2: Lease count by cluster + account ---
echo "--------------------------------------"
echo "  2. Lease4 Count by Cluster + Account"
echo "--------------------------------------"
printf "%-20s %-10s %-40s %8s %8s\n" "cluster" "account_id" "identity_account_id" "leases" "endpts"
printf "%-20s %-10s %-40s %8s %8s\n" "--------------------" "----------" "---------------------------------------" "--------" "--------"
awk -F'|' '$6 ~ /^[0-9]+$/ {
  key = $1 "|" $3
  leases[key] += $6
  cnt[key]++
  aid[key] = $7
}
END {
  for (k in leases) {
    split(k, a, "|")
    printf "%-20s %-10s %-40s %8d %8d\n", a[1], aid[k], a[2], leases[k], cnt[k]
  }
}' "$ENRICHED" | sort -t' ' -k4 -rn
echo ""

# --- Section 3: Per-endpoint detail ---
echo "--------------------------------------"
echo "  3. Lease4 Count per Endpoint"
echo "--------------------------------------"
printf "%-20s %-36s %-10s %-40s %5s %8s\n" "cluster" "endpoint_id" "account_id" "identity_account_id" "size" "leases"
printf "%-20s %-36s %-10s %-40s %5s %8s\n" "--------------------" "------------------------------------" "----------" "---------------------------------------" "-----" "--------"
awk -F'|' '{
  printf "%-20s %-36s %-10s %-40s %5s %8s\n", $1, $2, $7, $3, $4, $6
}' "$ENRICHED" | sort -t' ' -k6 -rn
echo ""

# --- Section 4: Errors ---
ERRORS=$(grep -c 'ERROR' "$ENRICHED" 2>/dev/null || true)
ERRORS=${ERRORS:-0}
if [[ "$ERRORS" -gt 0 ]]; then
  echo "--------------------------------------"
  echo "  4. Errors ($ERRORS endpoints)"
  echo "--------------------------------------"
  grep 'ERROR' "$ENRICHED" | awk -F'|' '{printf "  %s  endpoint=%s  account=%s/%s  status=%s\n", $1, $2, $7, $3, $6}'
  echo ""
fi

echo "======================================"
echo "  Report complete"
echo "======================================"

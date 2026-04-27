#!/usr/bin/env bash
set -euo pipefail

# Step 1: Scale down Kea 2.6 deployment to 0 replicas
# Usage: ./01_scale_down.sh <endpoint_id>

ENDPOINT_ID="${1:?Usage: $0 <endpoint_id>}"
DHCP_NS="ddiaas-dhcp-endpoint"

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

echo -e "${BOLD}Rollback Step 1: Scale Down Kea 2.6${NC}"
echo -e "Endpoint: ${CYAN}${ENDPOINT_ID}${NC}"
echo -e "Cluster:  $(kubectl config current-context)"
echo -e "Time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ─────────────────────────────────────────────
header "1. Find deployments for endpoint (all zones)"
# ─────────────────────────────────────────────
# Deployments are named dhcp-<endpointId>-<zone> (e.g. dhcp-abc123-1a, dhcp-abc123-1b)
DEPLOY_PREFIX="dhcp-${ENDPOINT_ID}-"
mapfile -t DEPLOYMENTS < <(kubectl get deployments -n "$DHCP_NS" --no-headers -o custom-columns='NAME:.metadata.name' 2>/dev/null | grep "^${DEPLOY_PREFIX}" || true)

if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
  fail "No deployments found matching prefix ${DEPLOY_PREFIX}* in namespace ${DHCP_NS}"
  info "  Check: kubectl get deployments -n ${DHCP_NS} | grep ${DEPLOY_PREFIX}"
  exit 1
fi
for DEP in "${DEPLOYMENTS[@]}"; do
  ok "Found deployment: ${DEP}"
done
info "Total: ${#DEPLOYMENTS[@]} deployments (one per zone)"

# ─────────────────────────────────────────────
header "2. Current state"
# ─────────────────────────────────────────────
ALL_ALREADY_ZERO=true
for DEP in "${DEPLOYMENTS[@]}"; do
  CURRENT_REPLICAS=$(kubectl get deployment "$DEP" -n "$DHCP_NS" -o jsonpath='{.spec.replicas}')
  READY_REPLICAS=$(kubectl get deployment "$DEP" -n "$DHCP_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  info "${DEP}: desired=${CURRENT_REPLICAS}, ready=${READY_REPLICAS}"
  if [[ "$CURRENT_REPLICAS" != "0" ]]; then
    ALL_ALREADY_ZERO=false
  fi
done

if [[ "$ALL_ALREADY_ZERO" == "true" ]]; then
  warn "All deployments already scaled to 0. Nothing to do."
  exit 0
fi

# ─────────────────────────────────────────────
header "3. Scale all deployments to 0"
# ─────────────────────────────────────────────
for DEP in "${DEPLOYMENTS[@]}"; do
  CURRENT=$(kubectl get deployment "$DEP" -n "$DHCP_NS" -o jsonpath='{.spec.replicas}')
  if [[ "$CURRENT" == "0" ]]; then
    info "${DEP}: already at 0, skipping"
    continue
  fi
  echo -e "  ${YELLOW}Scaling ${DEP} to 0 replicas...${NC}"
  kubectl scale deployment "$DEP" -n "$DHCP_NS" --replicas=0
  ok "Scaled ${DEP} to 0"
done

info ""
info "Waiting for all pods to terminate..."
for DEP in "${DEPLOYMENTS[@]}"; do
  kubectl rollout status deployment/"$DEP" -n "$DHCP_NS" --timeout=120s 2>/dev/null || true
done

# Check remaining pods across all zones
REMAINING_PODS=$(kubectl get pods -n "$DHCP_NS" --no-headers 2>/dev/null | grep "^${DEPLOY_PREFIX}" | wc -l | tr -d ' ')
if [[ "$REMAINING_PODS" == "0" ]]; then
  ok "All pods terminated across all zones. Kea 2.6 is fully stopped."
else
  warn "${REMAINING_PODS} pods still terminating. Wait for them to finish before proceeding."
  kubectl get pods -n "$DHCP_NS" --no-headers 2>/dev/null | grep "^${DEPLOY_PREFIX}" | while read -r line; do info "  $line"; done
fi

echo ""
echo -e "${GREEN}${BOLD}Step 1 complete.${NC} Kea 2.6 is stopped (${#DEPLOYMENTS[@]} deployments scaled to 0). DB is still at schema v22."
echo -e "Next: Run ${CYAN}./02_fix_db.sh ${ENDPOINT_ID}${NC} to rollback DB schema to v13."

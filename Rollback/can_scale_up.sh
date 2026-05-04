#!/opt/homebrew/bin/bash
# Usage: ./can_scale_up.sh <endpoint_id> <namespace> <expected_chart_version>
# Example: ./can_scale_up.sh 2a73txojt5y5mcbp5usni3rdywe74wsg ddiaas-endpoint-manager v0.1.0-13-g2c6382a-j159-main
#
# Scales up zones one at a time, starting with the last zone (highest letter):
#   - Discovers zones dynamically from HelmReleases
#   - Sorts descending (e.g. 1c before 1b, 1b before 1a)
#   - For each zone:
#       1. Waits for HelmRelease chart version + reconciliation (FFO check)
#       2. Verifies deployment won't create a Kea 2.6 pod
#       3. Scales up
#       4. Waits for pod healthy
#   - Prints summary: DB schema, Kea images, errors

set -e

ENDPOINT_ID="$1"
NAMESPACE="$2"
EXPECTED_CHART_VERSION="$3"
DEPLOYMENT_NAMESPACE="ddiaas-dhcp-endpoint"
CNPG_CLUSTER="cnpg-${ENDPOINT_ID}"
REPLICAS=1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

ts() { date -u '+%H:%M:%S'; }
log()  { echo -e "[$(ts)] $1"; }
ok()   { echo -e "[$(ts)] ${GREEN}✓${NC} $1"; }
warn() { echo -e "[$(ts)] ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "[$(ts)] ${RED}✗${NC} $1"; }

if [[ -z "$ENDPOINT_ID" || -z "$NAMESPACE" || -z "$EXPECTED_CHART_VERSION" ]]; then
  echo "Usage: $0 <endpoint_id> <namespace> <expected_chart_version>"
  exit 1
fi

echo -e "${BOLD}Scale Up: Rollback to Kea 2.2${NC}"
echo -e "Endpoint: ${CYAN}${ENDPOINT_ID}${NC}"
echo -e "Expected chart: ${CYAN}${EXPECTED_CHART_VERSION}${NC}"
echo -e "Cluster:  $(kubectl config current-context)"
echo -e "Time:     $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ─────────────────────────────────────────────
# Discover zones
# ─────────────────────────────────────────────
mapfile -t HR_LINES < <(kubectl get helmrelease -n "$NAMESPACE" --no-headers | grep "dhcp-${ENDPOINT_ID}-" | sort -r)

if [[ ${#HR_LINES[@]} -eq 0 ]]; then
  fail "No HelmReleases found for endpoint $ENDPOINT_ID in $NAMESPACE."
  exit 2
fi

declare -a ZONES
declare -A HR_MAP
for line in "${HR_LINES[@]}"; do
  HR_NAME=$(echo "$line" | awk '{print $1}')
  ZONE=$(echo "$HR_NAME" | grep -oE '[0-9]+[a-z]$')
  if [[ -n "$ZONE" ]]; then
    ZONES+=("$ZONE")
    HR_MAP["$ZONE"]="$HR_NAME"
    log "Found zone-${ZONE}: HelmRelease ${HR_NAME}"
  fi
done

if [[ ${#ZONES[@]} -ne 2 ]]; then
  fail "Expected 2 zones, found ${#ZONES[@]}."
  exit 2
fi
log "Scale-up order: ${ZONES[*]} (first zone scales up first)"

# ─────────────────────────────────────────────
# Helper: wait for FFO — chart version + reconciliation
# ─────────────────────────────────────────────
wait_for_ffo() {
  local hr_name="$1"
  local zone="$2"
  local attempt=0

  log "Checking FFO for zone-${zone} (HelmRelease: ${hr_name})..."

  while true; do
    attempt=$((attempt + 1))
    CHART_VERSION=$(kubectl get helmrelease "$hr_name" -n "$NAMESPACE" -o jsonpath='{.spec.chart.spec.version}')
    READY_STATUS=$(kubectl get helmrelease "$hr_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

    if [[ "$CHART_VERSION" == "$EXPECTED_CHART_VERSION" && "$READY_STATUS" == "True" ]]; then
      ok "zone-${zone}: HelmRelease at ${EXPECTED_CHART_VERSION}, reconciliation succeeded."
      return 0
    elif [[ "$CHART_VERSION" == "$EXPECTED_CHART_VERSION" ]]; then
      warn "zone-${zone}: Chart version matches but reconciliation pending (Ready=${READY_STATUS}). Waiting 15s... [attempt ${attempt}]"
      sleep 15
    else
      log "zone-${zone}: Chart version is ${CHART_VERSION} (expected ${EXPECTED_CHART_VERSION}). FFO not propagated yet. Waiting 30s... [attempt ${attempt}]"
      sleep 30
    fi
  done
}

# ─────────────────────────────────────────────
# Helper: verify deployment will NOT create a Kea 2.6 pod
# ─────────────────────────────────────────────
verify_no_kea26() {
  local zone="$1"
  local deploy_name="dhcp-${ENDPOINT_ID}-${zone}"

  log "Verifying deployment ${deploy_name} does not use Kea 2.6 images..."

  # Check that the HelmRelease chart version on this zone's deployment is NOT the 2.6 chart
  local hr_name="${HR_MAP[$zone]}"
  local current_version=$(kubectl get helmrelease "$hr_name" -n "$NAMESPACE" -o jsonpath='{.spec.chart.spec.version}')
  if echo "$current_version" | grep -qi "kea-2\.6\|upgrade-to-kea"; then
    fail "zone-${zone}: HelmRelease still at Kea 2.6 chart ($current_version). REFUSING to scale up."
    return 1
  fi

  # Double-check: look at deployment's pod template container images
  local images
  images=$(kubectl get deployment "$deploy_name" -n "$DEPLOYMENT_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null || echo "")
  if echo "$images" | grep -qi "kea.*2\.6"; then
    fail "zone-${zone}: Deployment pod template still has Kea 2.6 image. REFUSING to scale up."
    fail "  Images: $images"
    return 1
  fi

  ok "zone-${zone}: No Kea 2.6 images detected. Safe to scale up."
  return 0
}

# ─────────────────────────────────────────────
# Helper: wait for pod to be fully ready
# ─────────────────────────────────────────────
wait_for_pod_ready() {
  local zone="$1"
  local deploy_name="dhcp-${ENDPOINT_ID}-${zone}"
  log "Waiting for ${deploy_name} pod to be fully ready..."
  while true; do
    POD_LINE=$(kubectl get pods -n "$DEPLOYMENT_NAMESPACE" --no-headers 2>/dev/null | grep "^${deploy_name}-" | head -1)
    if [[ -z "$POD_LINE" ]]; then
      log "  No pod found yet for ${deploy_name}. Waiting 15s..."
      sleep 15
      continue
    fi
    READY=$(echo "$POD_LINE" | awk '{print $2}')
    TOTAL=$(echo "$READY" | cut -d/ -f2)
    CURRENT=$(echo "$READY" | cut -d/ -f1)
    STATUS=$(echo "$POD_LINE" | awk '{print $3}')
    if [[ "$CURRENT" == "$TOTAL" && "$STATUS" == "Running" ]]; then
      ok "${deploy_name} pod is ${READY} Running."
      return 0
    else
      log "  ${deploy_name} pod is ${READY} ${STATUS}. Waiting 15s..."
      sleep 15
    fi
  done
}

# ─────────────────────────────────────────────
# Scale up zones sequentially
# ─────────────────────────────────────────────
STEP=1
for ZONE in "${ZONES[@]}"; do
  HR_NAME="${HR_MAP[$ZONE]}"
  DEPLOY_NAME="dhcp-${ENDPOINT_ID}-${ZONE}"

  echo ""
  echo -e "${BOLD}=== Step ${STEP}: Zone-${ZONE} ===${NC}"

  # c) Check FFO — wait until HelmRelease has rollback chart and is reconciled
  wait_for_ffo "$HR_NAME" "$ZONE"

  # d) Safety: verify deployment won't spin up a Kea 2.6 pod
  if ! verify_no_kea26 "$ZONE"; then
    fail "Aborting scale-up. Zone-${ZONE} would create a Kea 2.6 pod."
    exit 3
  fi

  log "Scaling ${DEPLOY_NAME} to ${REPLICAS} replicas..."
  kubectl scale deployment "$DEPLOY_NAME" -n "$DEPLOYMENT_NAMESPACE" --replicas=$REPLICAS

  wait_for_pod_ready "$ZONE"

  STEP=$((STEP + 1))
done

# ─────────────────────────────────────────────
# e) Summary
# ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}=== ROLLBACK SUMMARY ===${NC}"

# --- DB Schema ---
CNPG_RW_POD=$(kubectl get pods -n "$DEPLOYMENT_NAMESPACE" -l "cnpg.io/cluster=${CNPG_CLUSTER},role=primary" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$CNPG_RW_POD" ]]; then
  SCHEMA_VERSION=$(kubectl exec -n "$DEPLOYMENT_NAMESPACE" "$CNPG_RW_POD" -- \
    psql -U postgres -d dhcp_endpoint -t -A -c \
    "SELECT version || '.' || minor FROM schema_version ORDER BY version DESC, minor DESC LIMIT 1" 2>/dev/null || echo "N/A")
  SCHEMA_VERSION=$(echo "$SCHEMA_VERSION" | tr -d '[:space:]')
  echo -e "  DB Schema Version: ${BOLD}${SCHEMA_VERSION}${NC}"
else
  echo -e "  DB Schema Version: ${RED}Could not find CNPG primary pod${NC}"
fi

# --- Container images per zone ---
echo ""
echo -e "  ${BOLD}Container Image Versions:${NC}"
for ZONE in "${ZONES[@]}"; do
  POD_NAME=$(kubectl get pods -n "$DEPLOYMENT_NAMESPACE" --no-headers 2>/dev/null | grep "^dhcp-${ENDPOINT_ID}-${ZONE}-" | head -1 | awk '{print $1}')
  if [[ -n "$POD_NAME" ]]; then
    echo -e "    ${CYAN}zone-${ZONE}:${NC}"
    kubectl get pod "$POD_NAME" -n "$DEPLOYMENT_NAMESPACE" -o jsonpath='{range .spec.containers[*]}{"      "}{.name}={.image}{"\n"}{end}' 2>/dev/null
  else
    echo -e "    zone-${ZONE}: ${RED}No pod found${NC}"
  fi
done

# --- Errors in kea container logs ---
echo ""
echo -e "  ${BOLD}Recent Errors (last 100 log lines):${NC}"
FOUND_ERRORS=false
for ZONE in "${ZONES[@]}"; do
  POD_NAME=$(kubectl get pods -n "$DEPLOYMENT_NAMESPACE" --no-headers 2>/dev/null | grep "^dhcp-${ENDPOINT_ID}-${ZONE}-" | head -1 | awk '{print $1}')
  if [[ -n "$POD_NAME" ]]; then
    for CONTAINER in dhcp-kea4 dhcp-host; do
      ERRORS=$(kubectl logs "$POD_NAME" -n "$DEPLOYMENT_NAMESPACE" -c "$CONTAINER" --tail=100 2>/dev/null | grep -i "ERROR\|FATAL" | grep -vi "interface\|dhcp6\|DHCPv6" | tail -5 || true)
      if [[ -n "$ERRORS" ]]; then
        FOUND_ERRORS=true
        echo -e "    ${YELLOW}zone-${ZONE}/${CONTAINER}:${NC}"
        echo "$ERRORS" | sed 's/^/      /'
      fi
    done
  fi
done
if [[ "$FOUND_ERRORS" == "false" ]]; then
  echo -e "    ${GREEN}No errors found in dhcp-kea4/dhcp-host logs.${NC}"
fi

echo ""
echo -e "${GREEN}${BOLD}=== Scale up complete. Both zones running. ===${NC}"

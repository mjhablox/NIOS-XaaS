#!/usr/bin/env bash
# recover_cnpg_pending.sh
#
# Recover a CNPG cluster where one instance is stuck Pending due to a PVC
# zone vs topology-spread deadlock.
#
# Strategy:
#   1. Identify the stuck (Pending) CNPG pod for the given endpoint.
#   2. (Safety) If it is the currentPrimary AND another instance is healthy,
#      promote a healthy replica first so writes can resume.
#   3. Delete the Pending pod and its PVC(s) (PGDATA + optional WAL).
#      The CNPG operator recreates them; the new PVC is provisioned in an AZ
#      that satisfies the topology spread.
#   4. Wait for the cluster to return to healthy (readyInstances == instances).
#   5. Print elapsed time.
#
# Usage:
#   ./recover_cnpg_pending.sh <endpoint_id> [namespace] [flags]
#
# Flags:
#   --dry-run             Print what would be done; make no changes.
#   --allow-user-action   Apply the Kyverno bypass label
#                         (k8s.infoblox.com/allow-user-action=enabled)
#                         to the pod and PVC(s) before deleting them.
#                         REQUIRED on clusters with the
#                         block-user-actions Kyverno ClusterPolicy.
#
# Defaults:
#   namespace = ddiaas-dhcp-endpoint
#
# Requires: kubectl with current-context pointing at the right cluster.

set -euo pipefail

KYVERNO_LABEL="k8s.infoblox.com/allow-user-action=enabled"

# ---------- args ----------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <endpoint_id> [namespace] [--dry-run] [--allow-user-action]" >&2
  exit 2
fi

ENDPOINT_ID="$1"
shift
NS="ddiaas-dhcp-endpoint"
DRY_RUN="false"
ALLOW_USER_ACTION="false"
for arg in "$@"; do
  case "$arg" in
    --dry-run)           DRY_RUN="true" ;;
    --allow-user-action) ALLOW_USER_ACTION="true" ;;
    -*)                  echo "Unknown flag: $arg" >&2; exit 2 ;;
    *)                   NS="$arg" ;;
  esac
done

CLUSTER="cnpg-${ENDPOINT_ID}"
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"   # max wait for cluster to become healthy

# ---------- helpers ----------
log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
err()  { printf '\033[31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '\033[35m[dry-run]\033[0m %s\n' "$*"
  else
    eval "$@"
  fi
}

human_duration() {
  local s=$1
  printf '%dm %ds' $((s / 60)) $((s % 60))
}

# ---------- start ----------
START_TS=$(date +%s)
log "Endpoint:           $ENDPOINT_ID"
log "Cluster:            $CLUSTER"
log "Namespace:          $NS"
log "Dry-run:            $DRY_RUN"
log "Allow user action:  $ALLOW_USER_ACTION (Kyverno bypass)"

# ---------- 1. sanity check cluster exists ----------
if ! kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" >/dev/null 2>&1; then
  err "CNPG cluster '$CLUSTER' not found in namespace '$NS'."
  exit 1
fi

PHASE=$(kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" -o jsonpath='{.status.phase}')
PRIMARY=$(kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" -o jsonpath='{.status.currentPrimary}')
INSTANCES=$(kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" -o jsonpath='{.spec.instances}')
READY=$(kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" -o jsonpath='{.status.readyInstances}')

log "Cluster phase   : $PHASE"
log "Current primary : $PRIMARY"
log "Ready instances : ${READY}/${INSTANCES}"

# ---------- 2. find Pending pod(s) ----------
mapfile -t PENDING_PODS < <(
  kubectl get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER" \
    -o jsonpath='{range .items[?(@.status.phase=="Pending")]}{.metadata.name}{"\n"}{end}' \
    | grep -v '^$' || true
)

if [[ ${#PENDING_PODS[@]} -eq 0 ]]; then
  log "No Pending pods found. Nothing to recover."
  echo "Elapsed: $(human_duration $(( $(date +%s) - START_TS )))"
  exit 0
fi

log "Pending pods detected: ${PENDING_PODS[*]}"

# ---------- 3. (safety) promote a healthy replica if a Pending pod is primary ----------
for POD in "${PENDING_PODS[@]}"; do
  if [[ "$POD" == "$PRIMARY" ]]; then
    warn "Pending pod $POD is the currentPrimary."
    HEALTHY_REPLICA=$(
      kubectl get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER" \
        -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        | awk '$2=="True" {print $1; exit}'
    )
    if [[ -n "$HEALTHY_REPLICA" && "$HEALTHY_REPLICA" != "$POD" ]]; then
      log "Promoting healthy replica '$HEALTHY_REPLICA' to primary..."
      if kubectl cnpg version >/dev/null 2>&1; then
        run "kubectl cnpg promote '$CLUSTER' '$HEALTHY_REPLICA' -n '$NS'"
      else
        warn "'kubectl cnpg' plugin not installed; skipping clean promote. CNPG operator will elect a new primary on its own once $POD is gone."
      fi
    else
      warn "No healthy Running replica available to promote. Proceeding anyway (operator will elect a new primary)."
    fi
  fi
done

# ---------- 4. delete each Pending pod + its PVCs ----------
for POD in "${PENDING_PODS[@]}"; do
  log "Collecting PVCs for pod $POD ..."
  mapfile -t PVCS < <(
    kubectl get pod -n "$NS" "$POD" \
      -o jsonpath='{range .spec.volumes[?(@.persistentVolumeClaim)]}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
      | grep -v '^$' | sort -u
  )
  log "  PVCs: ${PVCS[*]:-<none>}"

  if [[ "$ALLOW_USER_ACTION" == "true" ]]; then
    log "Applying Kyverno bypass label to pod $POD ..."
    run "kubectl label pod -n '$NS' '$POD' '$KYVERNO_LABEL' --overwrite"
    for PVC in "${PVCS[@]}"; do
      log "Applying Kyverno bypass label to PVC $PVC ..."
      run "kubectl label pvc -n '$NS' '$PVC' '$KYVERNO_LABEL' --overwrite"
    done
  fi

  log "Deleting pod $POD ..."
  run "kubectl delete pod -n '$NS' '$POD' --wait=false --ignore-not-found"

  for PVC in "${PVCS[@]}"; do
    log "Deleting PVC $PVC ..."
    if ! run "kubectl delete pvc -n '$NS' '$PVC' --wait=false --ignore-not-found"; then
      err "Failed to delete PVC '$PVC'."
      err "If blocked by Kyverno (block-user-actions), re-run with --allow-user-action."
      exit 1
    fi
  done
done

# ---------- 5. wait for cluster to become healthy ----------
if [[ "$DRY_RUN" == "true" ]]; then
  log "[dry-run] Skipping wait-for-healthy."
  echo "Elapsed: $(human_duration $(( $(date +%s) - START_TS )))"
  exit 0
fi

log "Waiting up to ${TIMEOUT_SECS}s for cluster to become healthy (${INSTANCES}/${INSTANCES})..."
DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
while :; do
  NOW=$(date +%s)
  if (( NOW > DEADLINE )); then
    err "Timed out waiting for cluster to become healthy."
    kubectl get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER" -o wide || true
    kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
      -o jsonpath='{.status.phase}{"\n"}' || true
    echo "Elapsed: $(human_duration $(( NOW - START_TS )))"
    exit 1
  fi

  READY=$(kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
            -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo 0)
  PHASE=$(kubectl get cluster.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "?")
  printf '  ... ready=%s/%s phase=%q\n' "${READY:-0}" "$INSTANCES" "$PHASE"

  if [[ "${READY:-0}" == "$INSTANCES" && "$PHASE" == "Cluster in healthy state" ]]; then
    log "Cluster healthy."
    break
  fi
  sleep 10
done

# ---------- 6. summary ----------
END_TS=$(date +%s)
ELAPSED=$(( END_TS - START_TS ))
log "Final pod state:"
kubectl get pods -n "$NS" -l "cnpg.io/cluster=$CLUSTER" -o wide || true

echo
echo "============================================================"
echo " Recovery complete for cluster: $CLUSTER"
echo " Elapsed time: $(human_duration "$ELAPSED")  (${ELAPSED}s)"
echo "============================================================"

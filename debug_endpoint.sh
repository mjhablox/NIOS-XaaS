#!/usr/bin/env bash
set -euo pipefail

# Debug script for DDIaaS DHCP endpoint installation/upgrade issues
# Usage: ./debug_endpoint.sh <endpoint_id>

ENDPOINT_ID="${1:?Usage: $0 <endpoint_id>}"
APP_DEF_NS="atlas-app-def-system"
DHCP_NS="ddiaas-dhcp-endpoint"
EP_MGR_NS="ddiaas-endpoint-manager"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

header() { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"; }
ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail()   { echo -e "  ${RED}✗${NC} $1"; }
info()   { echo -e "  $1"; }

echo -e "${BOLD}Debugging endpoint: ${CYAN}${ENDPOINT_ID}${NC}"
echo -e "Cluster context: $(kubectl config current-context)"
echo -e "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ─────────────────────────────────────────────
header "1. FeatureFlagOverride (FFO) Targeting"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get featureflagoverrides.terminus.infoblox.com -n $APP_DEF_NS -o json | jq '... select endpoint_id'"
MATCHING_FFOS=$(kubectl get featureflagoverrides.terminus.infoblox.com -n "$APP_DEF_NS" -o json 2>/dev/null | \
  jq -r --arg eid "$ENDPOINT_ID" '
    .items[] |
    select(
      .spec.labelSelector.matchExpressions[]? |
      (.key == "endpoint_id" or .key == "endpointId") and (.values | index($eid))
    ) |
    "\(.metadata.name) → version=\(.spec.value // "?") priority=\(.spec.priority // "?") feature=\(.spec.featureName // "?")"
  ' 2>/dev/null || true)

if [[ -n "$MATCHING_FFOS" ]]; then
  ok "Endpoint IS targeted by FFO (endpoint_id match)"
  echo "$MATCHING_FFOS" | while read -r line; do info "  $line"; done
else
  warn "No FFO targets this endpoint by endpoint_id"
  info "  → This endpoint will use the default version from the endpoint-manager."
  echo ""
  info "  All DHCP-related FFOs for reference:"
  kubectl get featureflagoverrides.terminus.infoblox.com -n "$APP_DEF_NS" -o json 2>/dev/null | \
    jq -r '.items[] | select(.spec.featureName // "" | test("dhcp"; "i")) |
      "    \(.metadata.name) priority=\(.spec.priority // "?") version=\(.spec.value // "?") endpoints=\([(.spec.labelSelector.matchExpressions[]? | select(.key == "endpoint_id" or .key == "endpointId") | .values[])] | join(","))"' 2>/dev/null || true
fi

# ─────────────────────────────────────────────
header "1b. FFO Priority Conflict Analysis"
# ─────────────────────────────────────────────
# The Terminus feature flag service resolves the HIGHEST priority matching FFO.
# If an account-level FFO has higher priority than an endpoint-level FFO, it wins.
# This section detects conflicts.
info "${BOLD}Checking for competing FFOs on feature 'adc-application-version.ddiaas-dhcp'${NC}"

# Get the account_id for this endpoint from the HelmRelease values
ACCT_ID=$(kubectl get helmrelease -n "$EP_MGR_NS" -o json 2>/dev/null | \
  jq -r --arg eid "$ENDPOINT_ID" '
    .items[] | select(.metadata.name | contains($eid)) | select(.metadata.name | startswith("dhcp-")) |
    .spec.values.accountId // empty
  ' 2>/dev/null | head -1 || true)

if [[ -z "$ACCT_ID" ]]; then
  # Try from endpointconfig
  ACCT_ID=$(kubectl get endpointconfigs.ddiaas.infoblox.com -n "$EP_MGR_NS" -o json 2>/dev/null | \
    jq -r --arg eid "$ENDPOINT_ID" '
      .items[] | select(.metadata.name | contains($eid)) |
      .spec.accountId // .metadata.labels.accountId // empty
    ' 2>/dev/null | head -1 || true)
fi

if [[ -n "$ACCT_ID" ]]; then
  info "  Endpoint account_id: ${ACCT_ID}"
else
  warn "  Could not determine account_id for this endpoint"
fi

# Get ALL FFOs for this feature sorted by priority
ALL_DHCP_FFOS=$(kubectl get featureflagoverrides.terminus.infoblox.com -n "$APP_DEF_NS" -o json 2>/dev/null | \
  jq -r --arg eid "$ENDPOINT_ID" --arg aid "$ACCT_ID" '
    .items[] |
    select(.spec.featureName == "adc-application-version.ddiaas-dhcp") |
    {
      name: .metadata.name,
      priority: (.spec.priority // 0),
      value: (.spec.value // "?"),
      matches_endpoint: ([.spec.labelSelector.matchExpressions[]? | select((.key == "endpoint_id" or .key == "endpointId") and (.values | index($eid)))] | length > 0),
      matches_account: ([.spec.labelSelector.matchExpressions[]? | select(.key == "account_id" and (.values | index($aid)))] | length > 0),
      match_type: (
        if ([.spec.labelSelector.matchExpressions[]? | select((.key == "endpoint_id" or .key == "endpointId") and (.values | index($eid)))] | length > 0)
        then "endpoint_id"
        elif ([.spec.labelSelector.matchExpressions[]? | select(.key == "account_id" and (.values | index($aid)))] | length > 0)
        then "account_id"
        else "no_match"
        end
      )
    } |
    select(.matches_endpoint or .matches_account) |
    "\(.priority)|\(.name)|\(.value)|\(.match_type)"
  ' 2>/dev/null | sort -t'|' -k1 -rn || true)

if [[ -n "$ALL_DHCP_FFOS" ]]; then
  echo ""
  printf "  ${BOLD}%-8s %-60s %-30s %s${NC}\n" "PRI" "FFO NAME" "VALUE" "MATCH TYPE"
  HIGHEST_PRI=""
  HIGHEST_VALUE=""
  CONFLICT_DETECTED=false

  while IFS='|' read -r pri name value match_type; do
    if [[ -z "$HIGHEST_PRI" ]]; then
      HIGHEST_PRI="$pri"
      HIGHEST_VALUE="$value"
    fi
    # Color code: green for the winner, yellow for overridden
    if [[ "$pri" == "$HIGHEST_PRI" ]]; then
      printf "  ${GREEN}%-8s %-60s %-30s %s ← WINNING${NC}\n" "$pri" "$name" "$value" "$match_type"
    else
      printf "  ${YELLOW}%-8s %-60s %-30s %s (overridden)${NC}\n" "$pri" "$name" "$value" "$match_type"
    fi
  done <<< "$ALL_DHCP_FFOS"

  # Check if the winning FFO is NOT an endpoint-level one targeting us
  WINNING_MATCH_TYPE=$(echo "$ALL_DHCP_FFOS" | head -1 | cut -d'|' -f4)
  WINNING_NAME=$(echo "$ALL_DHCP_FFOS" | head -1 | cut -d'|' -f2)
  ENDPOINT_LEVEL_FFO=$(echo "$ALL_DHCP_FFOS" | grep "|endpoint_id$" | head -1 || true)

  if [[ -n "$ENDPOINT_LEVEL_FFO" && "$WINNING_MATCH_TYPE" != "endpoint_id" ]]; then
    CONFLICT_DETECTED=true
    EP_FFO_VALUE=$(echo "$ENDPOINT_LEVEL_FFO" | cut -d'|' -f3)
    EP_FFO_PRI=$(echo "$ENDPOINT_LEVEL_FFO" | cut -d'|' -f1)
    echo ""
    fail "PRIORITY CONFLICT DETECTED!"
    fail "  Endpoint-level FFO wants version '${EP_FFO_VALUE}' (priority ${EP_FFO_PRI})"
    fail "  But account-level FFO '${WINNING_NAME}' wins with version '${HIGHEST_VALUE}' (priority ${HIGHEST_PRI})"
    info ""
    info "  ${BOLD}Resolution options:${NC}"
    info "    1. Increase endpoint-level FFO priority above ${HIGHEST_PRI}"
    info "    2. Remove endpoint from the blocking FFO '${WINNING_NAME}'"
    info "    3. Delete the blocking FFO if it's no longer needed"
  elif [[ -z "$ENDPOINT_LEVEL_FFO" && "$WINNING_MATCH_TYPE" == "account_id" ]]; then
    ok "Account-level FFO '${WINNING_NAME}' resolves version '${HIGHEST_VALUE}' (priority ${HIGHEST_PRI})"
  else
    ok "Endpoint-level FFO is the winning match (highest priority)"
  fi
else
  if [[ -n "$ACCT_ID" ]]; then
    info "  No matching FFOs found for endpoint_id or account_id"
    info "  → Feature flag service will return the base FeatureFlag value"
    # Show the base feature flag value
    BASE_FF_VALUE=$(kubectl get featureflags.terminus.infoblox.com "adc-application-version.ddiaas-dhcp" -n "$APP_DEF_NS" -o jsonpath='{.spec.value}' 2>/dev/null || echo "unknown")
    info "  → Base FeatureFlag value: ${BASE_FF_VALUE}"
  fi
fi

# ─────────────────────────────────────────────
header "2. Application CR"
# ─────────────────────────────────────────────
APP_NAME="ddiaas-dhcp"
info "${BOLD}cmd:${NC} kubectl get applications.onprem.atlas.infoblox.com $APP_NAME -n $APP_DEF_NS -o json"
APP_JSON=$(kubectl get applications.onprem.atlas.infoblox.com "$APP_NAME" -n "$APP_DEF_NS" -o json 2>/dev/null || true)

if [[ -n "$APP_JSON" ]]; then
  APP_FALLBACK=$(echo "$APP_JSON" | jq -r '.spec.fallbackVersion // "unknown"')
  APP_FEATURE=$(echo "$APP_JSON" | jq -r '.spec.featureName // "unknown"')
  ok "Found Application CR '${APP_NAME}'"
  info "  Feature: ${APP_FEATURE}  Fallback version: ${APP_FALLBACK}"
  info "  → Per-endpoint version is resolved via FFO (Section 1) + this fallback."
  info "  → Endpoint-manager resolves: FFO match → version from FFO, else → fallback '${APP_FALLBACK}'"
else
  fail "Application CR '$APP_NAME' not found in $APP_DEF_NS"
  info "  → The global ddiaas-dhcp Application CR is missing."
  info "  → Check if the app-definition-controller HelmRelease has deployed it."
fi

# ─────────────────────────────────────────────
header "3. Version CRs (ddiaas-dhcp)"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get versions.onprem.atlas.infoblox.com -n $APP_DEF_NS -o json | jq '... ddiaas-dhcp.*'"
VERSION_LIST=$(kubectl get versions.onprem.atlas.infoblox.com -n "$APP_DEF_NS" -o json 2>/dev/null | \
  jq -r '.items[] | select(.metadata.name | startswith("ddiaas-dhcp.")) |
    "  \(.metadata.name)  chart=\(.spec.chartVersion // .spec.chart.version // .spec.version // .metadata.name | split(".")[1:] | join("."))"' 2>/dev/null || true)

if [[ -n "$VERSION_LIST" ]]; then
  ok "Available versions:"
  echo "$VERSION_LIST"
else
  warn "No Version CRs found for ddiaas-dhcp"
  info "  → The ddiaas-dhcp-base HelmRelease may not have deployed Version CRs yet."
fi

# ─────────────────────────────────────────────
header "4. HelmReleases in endpoint-manager namespace"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get helmrelease -n $EP_MGR_NS -o json | jq '... contains($ENDPOINT_ID)'"
HR_LIST=$(kubectl get helmrelease -n "$EP_MGR_NS" -o json 2>/dev/null | \
  jq -r --arg eid "$ENDPOINT_ID" '
    .items[] | select(.metadata.name | contains($eid)) |
    "\(.metadata.name)|\(.spec.chart.spec.version // "-")|\(.status.conditions[0].type // "-")|\(.status.conditions[0].status // "-")|\(.status.conditions[0].reason // "-")|\(.metadata.generation // 0)|\(.status.conditions[0].lastTransitionTime // "-")"
  ' 2>/dev/null || true)

if [[ -n "$HR_LIST" ]]; then
  printf "  %-60s %-50s %-8s %-22s %-4s %s\n" "NAME" "CHART VERSION" "STATUS" "REASON" "GEN" "LAST TRANSITION"
  echo "$HR_LIST" | while IFS='|' read -r name chart_ver type status reason gen last_time; do
    if [[ "$status" == "True" && "$reason" =~ (Succeeded|InstallSucceeded|UpgradeSucceeded|ReconciliationSucceeded) ]]; then
      printf "  ${GREEN}%-60s${NC} %-50s %-8s %-22s %-4s %s\n" "$name" "$chart_ver" "$status" "$reason" "$gen" "$last_time"
    else
      printf "  ${RED}%-60s${NC} %-50s %-8s %-22s %-4s %s\n" "$name" "$chart_ver" "$status" "$reason" "$gen" "$last_time"
      # Get full message for failed releases
      FULL_MSG=$(kubectl get helmrelease "$name" -n "$EP_MGR_NS" -o json 2>/dev/null | \
        jq -r '.status.conditions[0].message // ""' 2>/dev/null || true)
      if [[ -n "$FULL_MSG" ]]; then
        echo -e "    ${RED}Message:${NC} $FULL_MSG"
      fi
    fi
  done

  # Show app version from HelmRelease values
  echo ""
  info "${BOLD}HelmRelease app versions:${NC}"
  kubectl get helmrelease -n "$EP_MGR_NS" -o json 2>/dev/null | \
    jq -r --arg eid "$ENDPOINT_ID" '
      .items[] | select(.metadata.name | contains($eid)) | select(.metadata.name | startswith("dhcp-")) |
      "    \(.metadata.name)  appVersion=\(.spec.values.appVersion // .spec.values.version // "-")  accountId=\(.spec.values.accountId // "-")  endpointId=\(.spec.values.endpointId // "-")"
    ' 2>/dev/null || true
else
  fail "No HelmReleases found matching endpoint '$ENDPOINT_ID' in $EP_MGR_NS"
  info "  → The endpoint-manager hasn't created HelmReleases for this endpoint yet."
  info "  → Check if the endpoint is registered in the endpoint-manager database."
fi

# ─────────────────────────────────────────────
header "5. Pods"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get pods -n $DHCP_NS | grep $ENDPOINT_ID"
PODS=$(kubectl get pods -n "$DHCP_NS" --no-headers 2>/dev/null | grep "$ENDPOINT_ID" || true)

if [[ -n "$PODS" ]]; then
  echo "$PODS" | while read -r line; do
    POD_NAME=$(echo "$line" | awk '{print $1}')
    READY=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')
    RESTARTS=$(echo "$line" | awk '{print $4}')
    if [[ "$STATUS" == "Running" ]]; then
      TOTAL=$(echo "$READY" | cut -d/ -f2)
      CURRENT=$(echo "$READY" | cut -d/ -f1)
      if [[ "$CURRENT" == "$TOTAL" ]]; then
        ok "$POD_NAME  $READY  $STATUS  restarts=$RESTARTS"
      else
        warn "$POD_NAME  $READY  $STATUS  restarts=$RESTARTS (not all containers ready)"
        info "    → Some containers may be in CrashLoopBackOff or waiting. See section 9."
      fi
    else
      fail "$POD_NAME  $READY  $STATUS  restarts=$RESTARTS"
      info "    → Pod is not running. Check events (section 6) and container details (section 9)."
    fi
  done

  # Check container images for Kea version
  echo ""
  info "${BOLD}Container images per AZ:${NC}"
  for POD in $(echo "$PODS" | awk '{print $1}'); do
    # Skip cnpg pods
    if [[ "$POD" == cnpg-* ]]; then continue; fi
    POD_AZ=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '.spec.nodeName as $node | .metadata.labels["topology.kubernetes.io/zone"] //
        (if $node then "node:" + $node else "unknown-az" end)' 2>/dev/null || echo "unknown-az")
    # Fallback: get AZ from node labels
    if [[ "$POD_AZ" == "null" || -z "$POD_AZ" ]]; then
      NODE=$(kubectl get pod "$POD" -n "$DHCP_NS" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)
      if [[ -n "$NODE" ]]; then
        POD_AZ=$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || echo "unknown-az")
      fi
    fi
    ALL_IMAGES=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '.spec.containers[] | "\(.name):\(.image | split("/") | last)"' 2>/dev/null || true)
    if [[ -n "$ALL_IMAGES" ]]; then
      info "  ${BOLD}$POD${NC}  (AZ: $POD_AZ)"
      echo "$ALL_IMAGES" | while read -r img; do
        CNAME=$(echo "$img" | cut -d: -f1)
        CIMAGE=$(echo "$img" | cut -d: -f2-)
        printf "    %-30s %s\n" "$CNAME" "$CIMAGE"
      done
    fi
  done
else
  fail "No pods found matching '$ENDPOINT_ID' in $DHCP_NS"
  info "  → HelmRelease may have failed before creating pods. Check section 4."
fi

# ─────────────────────────────────────────────
header "5b. Kea DHCP4 Config (kea-dhcp4.conf)"
# ─────────────────────────────────────────────
# Dump the live Kea DHCPv4 configuration from each Kea container.
# Tries common config paths and pretty-prints with jq when available.
KEA_CONF_PATHS=(
  "/home/keadist/v4.5/etc/kea/kea-dhcp4.conf"
  "/home/keadist/v4.3/etc/kea/kea-dhcp4.conf"
  "/home/keadist/v4.5/kea-dhcp4.conf"
  "/home/keadist/v4.3/kea-dhcp4.conf"
  "/etc/kea/kea-dhcp4.conf"
  "/config/kea-dhcp4.conf"
  "/var/kea/kea-dhcp4.conf"
  "/opt/kea/etc/kea/kea-dhcp4.conf"
)

if [[ -n "${PODS:-}" ]]; then
  while IFS= read -r line; do
    POD=$(echo "$line" | awk '{print $1}')
    READY=$(echo "$line" | awk '{print $2}')
    STATUS=$(echo "$line" | awk '{print $3}')

    # Skip cnpg/postgres pods
    if [[ "$POD" == cnpg-* ]]; then continue; fi

    # Skip pods where not all containers are ready (e.g. 0/9, 8/9, etc.)
    READY_CURRENT=$(echo "$READY" | cut -d/ -f1)
    READY_TOTAL=$(echo "$READY" | cut -d/ -f2)
    if [[ "$STATUS" != "Running" || "$READY_CURRENT" != "$READY_TOTAL" ]]; then
      warn "$POD: skipping kea-dhcp4.conf dump ($READY $STATUS — exec would fail)"
      continue
    fi

    # Find Kea container(s) in this pod (name contains "kea" and not "exporter"/"hook")
    KEA_CONTAINERS=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '.spec.containers[] | select(.name | test("kea"; "i")) | .name' 2>/dev/null || true)

    if [[ -z "$KEA_CONTAINERS" ]]; then
      warn "$POD: no Kea container found"
      continue
    fi

    for CTR in $KEA_CONTAINERS; do
      info "${BOLD}cmd:${NC} kubectl exec -n $DHCP_NS $POD -c $CTR -- cat <kea-dhcp4.conf>"
      FOUND_CONF=""
      for PATH_TRY in "${KEA_CONF_PATHS[@]}"; do
        # -q to silence test errors; check existence first
        if kubectl exec -n "$DHCP_NS" "$POD" -c "$CTR" -- test -f "$PATH_TRY" 2>/dev/null; then
          FOUND_CONF="$PATH_TRY"
          break
        fi
      done

      # Fallback: search for any kea-dhcp4.conf on the container filesystem
      if [[ -z "$FOUND_CONF" ]]; then
        FOUND_CONF=$(kubectl exec -n "$DHCP_NS" "$POD" -c "$CTR" -- \
          sh -c 'find / -name kea-dhcp4.conf -type f 2>/dev/null | head -1' 2>/dev/null || true)
      fi

      if [[ -z "$FOUND_CONF" ]]; then
        fail "$POD/$CTR: kea-dhcp4.conf not found in any of: ${KEA_CONF_PATHS[*]}"
        continue
      fi

      ok "$POD/$CTR: $FOUND_CONF"
      CONF_CONTENT=$(kubectl exec -n "$DHCP_NS" "$POD" -c "$CTR" -- cat "$FOUND_CONF" 2>/dev/null || true)
      if [[ -z "$CONF_CONTENT" ]]; then
        warn "  (file is empty or unreadable)"
        continue
      fi

      # Pretty-print as JSON if possible (Kea config is JSON with comments).
      # jq doesn't handle // comments — strip them first with sed for the pretty path,
      # but always show the raw file so comments/structure are preserved on error.
      if command -v jq >/dev/null 2>&1; then
        PRETTY=$(echo "$CONF_CONTENT" | sed -E 's://.*$::' | jq '.' 2>/dev/null || true)
        if [[ -n "$PRETTY" ]]; then
          echo "$PRETTY"
        else
          echo "$CONF_CONTENT"
        fi
      else
        echo "$CONF_CONTENT"
      fi
      echo ""
    done
  done <<< "$PODS"
else
  warn "No pods available; skipping kea-dhcp4.conf dump"
fi

# ─────────────────────────────────────────────
header "5c. DB Schema Migration Status (dhcp-host logs)"
# ─────────────────────────────────────────────
# Inspect the dhcp-host container logs to determine whether the Kea DB schema
# migration has completed. Looks for common migration markers (kea-admin
# upgrade output, schema version logs, completion messages, errors).
if [[ -n "${PODS:-}" ]]; then
  while IFS= read -r line; do
    POD=$(echo "$line" | awk '{print $1}')
    if [[ "$POD" == cnpg-* ]]; then continue; fi

    # Find a dhcp-host container in this pod (exact name or prefix match)
    DHCP_HOST_CTR=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '[.spec.containers[], .spec.initContainers[]?] |
             .[] | select(.name | test("dhcp-host"; "i")) | .name' 2>/dev/null | head -1)

    if [[ -z "$DHCP_HOST_CTR" ]]; then
      continue
    fi

    info "${BOLD}cmd:${NC} kubectl logs -n $DHCP_NS $POD -c $DHCP_HOST_CTR --tail=2000"
    LOGS=$(kubectl logs -n "$DHCP_NS" "$POD" -c "$DHCP_HOST_CTR" --tail=2000 2>/dev/null || true)
    # Also try the previous instance if the container has restarted
    PREV_LOGS=$(kubectl logs -n "$DHCP_NS" "$POD" -c "$DHCP_HOST_CTR" --tail=2000 -p 2>/dev/null || true)
    ALL_LOGS="${LOGS}
${PREV_LOGS}"

    if [[ -z "$LOGS" && -z "$PREV_LOGS" ]]; then
      warn "$POD/$DHCP_HOST_CTR: no logs available"
      continue
    fi

    # Patterns that indicate migration progress / completion / failure
    MIG_LINES=$(echo "$ALL_LOGS" | grep -iE \
      'schema|migrat|kea-admin|upgrade|version.*db|db.*version|alembic|goose|liquibase|flyway|create table|alter table' \
      2>/dev/null | tail -40 || true)

    SUCCESS=$(echo "$ALL_LOGS" | grep -iE \
      'schema (upgrade|migration).*(complete|success|done|finished)|migration.*(complete|success|done|finished)|already (at|on) (the )?(latest|current) (schema )?version|schema is up.?to.?date|no migration needed|database schema is current|kea-admin.*success' \
      2>/dev/null | tail -5 || true)

    FAILURE=$(echo "$ALL_LOGS" | grep -iE \
      'schema.*(fail|error|mismatch)|migration.*(fail|error|aborted)|kea-admin.*(fail|error)|incompatible schema|schema version.*(mismatch|too (old|new))|cannot (upgrade|migrate)' \
      2>/dev/null | tail -5 || true)

    IN_PROGRESS=$(echo "$ALL_LOGS" | grep -iE \
      '(starting|running|applying|performing) .*(migration|schema upgrade|kea-admin)|upgrading schema|migrating .*from .*to' \
      2>/dev/null | tail -5 || true)

    echo ""
    info "${BOLD}$POD/$DHCP_HOST_CTR${NC}"

    if [[ -n "$FAILURE" ]]; then
      fail "DB schema migration FAILED / has errors:"
      echo "$FAILURE" | sed 's/^/    /'
    elif [[ -n "$SUCCESS" ]]; then
      ok "DB schema migration COMPLETE:"
      echo "$SUCCESS" | sed 's/^/    /'
    elif [[ -n "$IN_PROGRESS" ]]; then
      warn "DB schema migration IN PROGRESS (no completion marker yet):"
      echo "$IN_PROGRESS" | sed 's/^/    /'
    elif [[ -n "$MIG_LINES" ]]; then
      warn "Inconclusive — schema/migration mentions found but no clear status:"
      echo "$MIG_LINES" | tail -10 | sed 's/^/    /'
    else
      warn "No schema/migration related log lines found in last 2000 lines"
    fi
  done <<< "$PODS"
else
  warn "No pods available; skipping DB schema migration check"
fi

# ─────────────────────────────────────────────
header "5d. CNPG Cluster — Primary & Pending Pod Diagnosis"
# ─────────────────────────────────────────────
# Show CNPG primary, ready instances, and detailed scheduling diagnosis
# (PVC zone affinity + last FailedScheduling event) for any Pending CNPG pod.
CNPG_CLUSTER="cnpg-${ENDPOINT_ID}"
info "${BOLD}cmd:${NC} kubectl get cluster.postgresql.cnpg.io $CNPG_CLUSTER -n $DHCP_NS -o json"

CNPG_JSON=$(kubectl get cluster.postgresql.cnpg.io "$CNPG_CLUSTER" -n "$DHCP_NS" -o json 2>/dev/null || true)
if [[ -z "$CNPG_JSON" ]]; then
  warn "CNPG cluster '$CNPG_CLUSTER' not found in $DHCP_NS"
else
  CNPG_PHASE=$(echo "$CNPG_JSON" | jq -r '.status.phase // "unknown"')
  CNPG_PRIMARY=$(echo "$CNPG_JSON" | jq -r '.status.currentPrimary // .status.targetPrimary // "unknown"')
  CNPG_TARGET=$(echo "$CNPG_JSON" | jq -r '.status.targetPrimary // "unknown"')
  CNPG_READY=$(echo "$CNPG_JSON" | jq -r '.status.readyInstances // 0')
  CNPG_INST=$(echo "$CNPG_JSON" | jq -r '.spec.instances // 0')

  info "  Phase:           $CNPG_PHASE"
  info "  Current primary: $CNPG_PRIMARY"
  if [[ "$CNPG_TARGET" != "$CNPG_PRIMARY" && "$CNPG_TARGET" != "unknown" ]]; then
    warn "  Target primary:  $CNPG_TARGET (failover/switchover in progress)"
  fi
  if [[ "$CNPG_READY" == "$CNPG_INST" ]]; then
    ok "  Ready instances: $CNPG_READY/$CNPG_INST"
  else
    fail "  Ready instances: $CNPG_READY/$CNPG_INST"
  fi
fi

# List all CNPG pods for this cluster
CNPG_PODS=$(kubectl get pods -n "$DHCP_NS" -l "cnpg.io/cluster=$CNPG_CLUSTER" \
  -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase,NODE:.spec.nodeName \
  --no-headers 2>/dev/null || true)

if [[ -z "$CNPG_PODS" ]]; then
  warn "No CNPG pods found with label cnpg.io/cluster=$CNPG_CLUSTER"
else
  echo ""
  info "${BOLD}CNPG pods:${NC}"
  echo "$CNPG_PODS" | sed 's/^/  /'

  # Diagnose every Pending CNPG pod
  while IFS= read -r row; do
    POD=$(echo "$row" | awk '{print $1}')
    STATUS=$(echo "$row" | awk '{print $3}')
    [[ "$STATUS" != "Pending" ]] && continue

    echo ""
    fail "$POD is Pending — diagnosing"

    # PVC bound to this CNPG instance is conventionally named the same as the pod
    PVC_NAME="$POD"
    PVC_JSON=$(kubectl get pvc -n "$DHCP_NS" "$PVC_NAME" -o json 2>/dev/null || true)
    if [[ -n "$PVC_JSON" ]]; then
      PV_NAME=$(echo "$PVC_JSON" | jq -r '.spec.volumeName // empty')
      SELECTED_NODE=$(echo "$PVC_JSON" | jq -r '.metadata.annotations["volume.kubernetes.io/selected-node"] // empty')
      PVC_PHASE=$(echo "$PVC_JSON" | jq -r '.status.phase // "unknown"')
      info "  PVC:             $PVC_NAME (phase=$PVC_PHASE)"
      [[ -n "$SELECTED_NODE" ]] && info "  Selected node:   $SELECTED_NODE"

      if [[ -n "$PV_NAME" ]]; then
        PV_ZONES=$(kubectl get pv "$PV_NAME" -o json 2>/dev/null | \
          jq -r '[.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]? |
                  select(.key == "topology.kubernetes.io/zone") | .values[]?] | join(",")' 2>/dev/null || true)
        if [[ -n "$PV_ZONES" ]]; then
          fail "  PV $PV_NAME is locked to AZ: $PV_ZONES"
          info "  → Pod can ONLY schedule on a node in [$PV_ZONES]."
        else
          info "  PV $PV_NAME has no zone affinity"
        fi
      fi
    else
      warn "  No PVC found named '$PVC_NAME' for this pod"
    fi

    # Last FailedScheduling event message (truncated)
    SCHED_MSG=$(kubectl get events -n "$DHCP_NS" \
      --field-selector "involvedObject.name=$POD,reason=FailedScheduling" \
      --sort-by='.lastTimestamp' -o json 2>/dev/null | \
      jq -r '.items[-1].message // empty' 2>/dev/null || true)
    if [[ -n "$SCHED_MSG" ]]; then
      info "  Last FailedScheduling:"
      # Wrap long message and indent
      echo "$SCHED_MSG" | fold -s -w 120 | sed 's/^/    /'
    fi

    # Quick capacity hint: count Ready nodes in the PV's AZ
    if [[ -n "${PV_ZONES:-}" ]]; then
      ZONE_NODES=$(kubectl get nodes -l "topology.kubernetes.io/zone=$PV_ZONES" \
        -o json 2>/dev/null | jq -r '.items | length' 2>/dev/null || echo "?")
      info "  Nodes in $PV_ZONES (any role): $ZONE_NODES"
    fi
  done <<< "$CNPG_PODS"
fi

# ─────────────────────────────────────────────
header "6. Pod Events (warnings/errors)"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get events -n $DHCP_NS --field-selector type!=Normal --sort-by=.lastTimestamp | grep $ENDPOINT_ID"
EVENTS=$(kubectl get events -n "$DHCP_NS" --field-selector type!=Normal --sort-by='.lastTimestamp' -o json 2>/dev/null | \
  jq -r --arg eid "$ENDPOINT_ID" '
    .items[] | select(.involvedObject.name // "" | contains($eid)) |
    "  \(.lastTimestamp // .eventTime) \(.reason): \(.message | .[0:150])"
  ' 2>/dev/null | tail -10 || true)

if [[ -n "$EVENTS" ]]; then
  warn "Recent warning/error events:"
  echo "$EVENTS"
else
  ok "No warning/error events"
fi

# ─────────────────────────────────────────────
header "7. CNPG Cluster"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get clusters.postgresql.cnpg.io -n $DHCP_NS | grep $ENDPOINT_ID"
CNPG_CLUSTERS=$(kubectl get clusters.postgresql.cnpg.io -n "$DHCP_NS" --no-headers 2>/dev/null | grep "$ENDPOINT_ID" || true)

if [[ -n "$CNPG_CLUSTERS" ]]; then
  echo "$CNPG_CLUSTERS" | while read -r line; do
    CLUSTER_NAME=$(echo "$line" | awk '{print $1}')
    PHASE=$(kubectl get clusters.postgresql.cnpg.io "$CLUSTER_NAME" -n "$DHCP_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    READY_INSTANCES=$(kubectl get clusters.postgresql.cnpg.io "$CLUSTER_NAME" -n "$DHCP_NS" -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "?")
    TOTAL_INSTANCES=$(kubectl get clusters.postgresql.cnpg.io "$CLUSTER_NAME" -n "$DHCP_NS" -o jsonpath='{.spec.instances}' 2>/dev/null || echo "?")
    PHASE_REASON=$(kubectl get clusters.postgresql.cnpg.io "$CLUSTER_NAME" -n "$DHCP_NS" -o jsonpath='{.status.phaseReason}' 2>/dev/null || echo "")
    if [[ "$PHASE" == "Cluster in healthy state" ]]; then
      ok "$CLUSTER_NAME  phase=$PHASE  ready=$READY_INSTANCES/$TOTAL_INSTANCES"
    else
      warn "$CLUSTER_NAME  phase=$PHASE  ready=$READY_INSTANCES/$TOTAL_INSTANCES"
      if [[ -n "$PHASE_REASON" ]]; then
        info "    Reason: $PHASE_REASON"
      fi
    fi
  done
else
  fail "No CNPG cluster found for '$ENDPOINT_ID' in $DHCP_NS"
  info "  → The CNPG cluster should be named 'cnpg-${ENDPOINT_ID}'."
  info "  → Check if the HelmRelease deployed successfully (section 4)."
  # Check if there's a broken cnpg-v26- cluster (the known bug)
  BROKEN_CNPG=$(kubectl get clusters.postgresql.cnpg.io -n "$DHCP_NS" --no-headers 2>/dev/null | grep "cnpg-v26-" || true)
  if [[ -n "$BROKEN_CNPG" ]]; then
    fail "KNOWN BUG: Found CNPG cluster with empty endpointId in name (cnpg-v26-):"
    echo "  $BROKEN_CNPG"
    info "  → This is caused by cnpg.db.clusterName using {{ .Values.endpointId }} instead of \${.Endpoint.EndpointId}"
    info "  → Fix: remove cnpg.db.clusterName override from ddiaas-dhcp-base-values.yaml"
  fi
fi

# ─────────────────────────────────────────────
header "8. CNPG Secrets"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get secrets -n $DHCP_NS | grep cnpg.*$ENDPOINT_ID"
CNPG_SECRETS=$(kubectl get secrets -n "$DHCP_NS" --no-headers 2>/dev/null | grep "cnpg.*${ENDPOINT_ID}" || true)

if [[ -n "$CNPG_SECRETS" ]]; then
  echo "$CNPG_SECRETS" | while read -r line; do
    ok "$(echo "$line" | awk '{print $1, $2}')"
  done
else
  fail "No CNPG secrets found for '$ENDPOINT_ID' in $DHCP_NS"
  info "  → Expected secrets: cnpg-${ENDPOINT_ID}-app, cnpg-${ENDPOINT_ID}-superuser, etc."
  info "  → CNPG operator creates these when the Cluster CR is healthy."
  # Check for broken secrets
  BROKEN_SECRETS=$(kubectl get secrets -n "$DHCP_NS" --no-headers 2>/dev/null | grep "cnpg-v26--" || true)
  if [[ -n "$BROKEN_SECRETS" ]]; then
    fail "KNOWN BUG: Found CNPG secrets with empty endpointId (cnpg-v26--):"
    echo "$BROKEN_SECRETS" | awk '{print "    " $1}'
    info "  → Same root cause as the CNPG cluster bug — clusterName rendered with empty endpointId."
  fi
fi

# ─────────────────────────────────────────────
header "9. Container Status Details (non-running)"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get pod <pod> -n $DHCP_NS -o json | jq '.status.containerStatuses[] | select(.state.running == null)'"
FOUND_BAD=false
if [[ -n "$PODS" ]]; then
  for POD in $(echo "$PODS" | awk '{print $1}'); do
    BAD_CONTAINERS=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '
        [.status.containerStatuses[]? |
         select(.state.running == null) |
         "\(.name): \(.state | to_entries[0] | "\(.key) — \(.value.reason // "") \(.value.message // "" | .[0:200])")"] |
        if length > 0 then .[] else empty end
      ' 2>/dev/null || true)
    if [[ -n "$BAD_CONTAINERS" ]]; then
      FOUND_BAD=true
      fail "$POD:"
      echo "$BAD_CONTAINERS" | while read -r c; do
        echo -e "    ${RED}$c${NC}"
      done
    fi
  done
fi
if [[ "$FOUND_BAD" == "false" ]]; then
  ok "All containers are running"
fi

# ─────────────────────────────────────────────
header "10. App Version Label on Pods"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl get pod <pod> -n $DHCP_NS -o jsonpath='{.metadata.labels}'"
VERSION_MISMATCH=false
DHCP_VERSIONS=()
if [[ -n "$PODS" ]]; then
  for POD in $(echo "$PODS" | awk '{print $1}'); do
    # Skip cnpg pods
    if [[ "$POD" == cnpg-* ]]; then continue; fi
    APP_VER=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '.metadata.labels["com.infoblox.app.version"] // .metadata.labels["app.kubernetes.io/version"] // .metadata.labels.version // "-"' 2>/dev/null || echo "unknown")
    HR_LABEL=$(kubectl get pod "$POD" -n "$DHCP_NS" -o json 2>/dev/null | \
      jq -r '.metadata.labels["helm.sh/release-name"] // .metadata.labels["app.kubernetes.io/instance"] // "-"' 2>/dev/null || echo "unknown")
    ok "$POD → version=$APP_VER  release=$HR_LABEL"
    DHCP_VERSIONS+=("$APP_VER")
  done

  # Detect version mismatch between AZs
  if [[ ${#DHCP_VERSIONS[@]} -ge 2 ]]; then
    FIRST_VER="${DHCP_VERSIONS[0]}"
    for VER in "${DHCP_VERSIONS[@]:1}"; do
      if [[ "$VER" != "$FIRST_VER" ]]; then
        VERSION_MISMATCH=true
        break
      fi
    done
    if [[ "$VERSION_MISMATCH" == "true" ]]; then
      warn "Version MISMATCH between AZs: ${DHCP_VERSIONS[*]}"
      info "    → Rolling upgrade in progress (one AZ upgraded, other waiting)"
    else
      ok "All DHCP pods on same version: $FIRST_VER"
    fi
  fi
else
  info "No pods to check"
fi

# ─────────────────────────────────────────────
header "11. Endpoint Manager State Machine"
# ─────────────────────────────────────────────
info "${BOLD}cmd:${NC} kubectl logs -n $EP_MGR_NS -l app=ddiaas-endpoint-manager --since=5m | grep $ENDPOINT_ID"
EM_PODS=$(kubectl get pods -n "$EP_MGR_NS" -l app=ddiaas-endpoint-manager --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [[ -n "$EM_PODS" ]]; then
  # Get the most recent state from logs (deduplicated)
  EM_STATES=$(kubectl logs -n "$EP_MGR_NS" "$EM_PODS" --since=5m 2>/dev/null | \
    grep -o "\"endpoint_id\":\"$ENDPOINT_ID\"[^}]*" 2>/dev/null | \
    grep -oP '"handler":"\K[^"]+' 2>/dev/null | sort | uniq -c | sort -rn || true)

  if [[ -n "$EM_STATES" ]]; then
    info "  Recent state machine handlers (last 5m):"
    echo "$EM_STATES" | while read -r count handler; do
      case "$handler" in
        handleUpdatePending)
          warn "  ${count}x $handler — Waiting for counterpart AZ to be Ready before upgrading" ;;
        handleReadyGrace)
          info "  ${count}x $handler — Grace period active (waiting for pod readiness stabilization)" ;;
        handleAwaitReady)
          info "  ${count}x $handler — Waiting for upgrade to complete" ;;
        handleReady)
          ok "  ${count}x $handler — AZ in Ready state" ;;
        *)
          info "  ${count}x $handler" ;;
      esac
    done

    # Extract key messages
    KEY_MSGS=$(kubectl logs -n "$EP_MGR_NS" "$EM_PODS" --since=5m 2>/dev/null | \
      grep "$ENDPOINT_ID" 2>/dev/null | \
      grep -E "Counterpart AZ|not in Ready|grace end time|upgrade triggered|transitioning|new state" 2>/dev/null | \
      tail -3 || true)
    if [[ -n "$KEY_MSGS" ]]; then
      echo ""
      info "  Latest key messages:"
      echo "$KEY_MSGS" | while read -r line; do
        MSG=$(echo "$line" | jq -r '.msg // empty' 2>/dev/null || echo "$line")
        HANDLER=$(echo "$line" | jq -r '.handler // empty' 2>/dev/null || true)
        TIME=$(echo "$line" | jq -r '.time // empty' 2>/dev/null || true)
        if [[ -n "$MSG" ]]; then
          info "    [$TIME] $HANDLER: $MSG"
        fi
      done
    fi
  else
    ok "No recent state machine activity (endpoint may be stable)"
  fi
else
  warn "No endpoint-manager pods found in $EP_MGR_NS"
fi

echo ""
echo -e "${BOLD}Done.${NC}"

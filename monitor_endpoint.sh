#!/usr/bin/env bash
# monitor_endpoint.sh — Monitor DDIaaS endpoint provisioning from start to finish
# Usage: ./monitor_endpoint.sh <endpoint_id> [interval_seconds] [timeout_minutes]

set -euo pipefail

EP="${1:?Usage: $0 <endpoint_id> [interval_secs] [timeout_mins]}"
INTERVAL="${2:-10}"
TIMEOUT_MINS="${3:-30}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1;32m'
NC='\033[0m'

TIMEOUT_SECS=$((TIMEOUT_MINS * 60))
START_TIME=$(date +%s)

header() { printf "\n${BOLD}── %s ──${NC}\n" "$1"; }

status_color() {
    local status="$1"
    case "$status" in
        True|Running|Ready|Succeeded|InstallSucceeded|UpgradeSucceeded|ReconciliationSucceeded)
            printf "${GREEN}%s${NC}" "$status" ;;
        False|Failed|CrashLoopBackOff|Error|UpgradeFailed|ArtifactFailed)
            printf "${RED}%s${NC}" "$status" ;;
        *)
            printf "${YELLOW}%s${NC}" "$status" ;;
    esac
}

elapsed() {
    local now
    now=$(date +%s)
    local diff=$((now - START_TIME))
    printf "%dm%02ds" $((diff / 60)) $((diff % 60))
}

check_all_ready() {
    local hr_count hr_ready pod_dhcp_ready pod_ipsec_ready cnpg_ready
    hr_count=$(kubectl get helmrelease -n ddiaas-endpoint-manager --no-headers 2>/dev/null \
        | grep -c "$EP" || true)
    hr_ready=$(kubectl get helmrelease -n ddiaas-endpoint-manager --no-headers 2>/dev/null \
        | grep "$EP" | awk '{print $3}' | grep -c "True" || true)
    pod_dhcp_ready=$(kubectl get pod -n ddiaas-dhcp-endpoint --no-headers 2>/dev/null \
        | grep "dhcp-${EP}" | grep -c "Running" || true)
    pod_ipsec_ready=$(kubectl get pod -n ddiaas-dataplane --no-headers 2>/dev/null \
        | grep "ipsec-${EP}" | grep -c "Running" || true)
    cnpg_ready=$(kubectl get pod -n ddiaas-dhcp-endpoint --no-headers 2>/dev/null \
        | grep "cnpg-${EP}" | grep -c "Running" || true)

    # Consider ready when: all HelmReleases ready, at least 1 DHCP pod, at least 1 IPSec pod, at least 1 CNPG pod
    [[ "$hr_count" -gt 0 && "$hr_count" -eq "$hr_ready" && \
       "$pod_dhcp_ready" -ge 1 && "$pod_ipsec_ready" -ge 1 && "$cnpg_ready" -ge 1 ]]
}

render() {
    clear
    printf "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  Monitor Endpoint: ${BOLD}%-40s${NC}${CYAN}║${NC}\n" "$EP"
    printf "${CYAN}║${NC}  Elapsed: %-10s  Interval: %ss  Timeout: %sm        ${CYAN}║${NC}\n" "$(elapsed)" "$INTERVAL" "$TIMEOUT_MINS"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}\n"

    # ── HelmReleases ──
    header "HelmReleases (ddiaas-endpoint-manager)"
    local hr_lines
    hr_lines=$(kubectl get helmrelease -n ddiaas-endpoint-manager --no-headers 2>/dev/null | grep "$EP" || true)
    if [[ -z "$hr_lines" ]]; then
        printf "  ${YELLOW}(none found yet)${NC}\n"
    else
        printf "  %-60s %-8s %-8s %s\n" "NAME" "AGE" "READY" "MESSAGE"
        printf "  %-60s %-8s %-8s %s\n" "----" "---" "-----" "-------"
        while IFS= read -r line; do
            local name age ready msg
            name=$(echo "$line" | awk '{print $1}')
            age=$(echo "$line" | awk '{print $2}')
            ready=$(echo "$line" | awk '{print $3}')
            msg=$(echo "$line" | awk '{for(i=4;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
            printf "  %-60s %-8s " "$name" "$age"
            status_color "$ready"
            printf "    %s\n" "$msg"
        done <<< "$hr_lines"
    fi

    # ── HelmCharts ──
    header "HelmCharts (vela-system)"
    local hc_lines
    hc_lines=$(kubectl get helmchart -n vela-system --no-headers 2>/dev/null | grep "$EP" || true)
    if [[ -z "$hc_lines" ]]; then
        printf "  ${YELLOW}(none found yet)${NC}\n"
    else
        printf "  %-75s %-8s %-8s %s\n" "NAME" "AGE" "READY" "MESSAGE"
        printf "  %-75s %-8s %-8s %s\n" "----" "---" "-----" "-------"
        while IFS= read -r line; do
            local name chart version kind repo age ready msg
            name=$(echo "$line" | awk '{print $1}')
            age=$(echo "$line" | awk '{print $6}')
            ready=$(echo "$line" | awk '{print $7}')
            msg=$(echo "$line" | awk '{for(i=8;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ $//')
            printf "  %-75s %-8s " "$name" "$age"
            status_color "$ready"
            printf "    %s\n" "$msg"
        done <<< "$hc_lines"
    fi

    # ── DHCP Pods ──
    header "DHCP Pods (ddiaas-dhcp-endpoint)"
    local dhcp_pods
    dhcp_pods=$(kubectl get pod -n ddiaas-dhcp-endpoint --no-headers 2>/dev/null | grep "dhcp-${EP}" || true)
    if [[ -z "$dhcp_pods" ]]; then
        printf "  ${YELLOW}(none found yet)${NC}\n"
    else
        while IFS= read -r line; do
            local name ready status restarts age
            name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            status=$(echo "$line" | awk '{print $3}')
            restarts=$(echo "$line" | awk '{print $4}')
            age=$(echo "$line" | awk '{print $5}')
            printf "  %-65s %s  " "$name" "$ready"
            status_color "$status"
            printf "  restarts=%s  age=%s\n" "$restarts" "$age"
        done <<< "$dhcp_pods"
    fi

    # ── CNPG Pods ──
    header "CNPG Pods (ddiaas-dhcp-endpoint)"
    local cnpg_pods
    cnpg_pods=$(kubectl get pod -n ddiaas-dhcp-endpoint --no-headers 2>/dev/null | grep "cnpg-${EP}" || true)
    if [[ -z "$cnpg_pods" ]]; then
        printf "  ${YELLOW}(none found yet)${NC}\n"
    else
        while IFS= read -r line; do
            local name ready status restarts age
            name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            status=$(echo "$line" | awk '{print $3}')
            restarts=$(echo "$line" | awk '{print $4}')
            age=$(echo "$line" | awk '{print $5}')
            printf "  %-65s %s  " "$name" "$ready"
            status_color "$status"
            printf "  restarts=%s  age=%s\n" "$restarts" "$age"
        done <<< "$cnpg_pods"
    fi

    # ── IPSec Pods ──
    header "IPSec Pods (ddiaas-dataplane)"
    local ipsec_pods
    ipsec_pods=$(kubectl get pod -n ddiaas-dataplane --no-headers 2>/dev/null | grep "ipsec-${EP}" || true)
    if [[ -z "$ipsec_pods" ]]; then
        printf "  ${YELLOW}(none found yet)${NC}\n"
    else
        while IFS= read -r line; do
            local name ready status restarts age
            name=$(echo "$line" | awk '{print $1}')
            ready=$(echo "$line" | awk '{print $2}')
            status=$(echo "$line" | awk '{print $3}')
            restarts=$(echo "$line" | awk '{print $4}')
            age=$(echo "$line" | awk '{print $5}')
            printf "  %-65s %s  " "$name" "$ready"
            status_color "$status"
            printf "  restarts=%s  age=%s\n" "$restarts" "$age"
        done <<< "$ipsec_pods"
    fi

    # ── EIP Events (last 5) ──
    header "Recent EIP Events"
    local eip_events
    eip_events=$(kubectl get events -n ddiaas-dataplane --field-selector reason=EIPAssociated --no-headers 2>/dev/null \
        | grep "$EP" | tail -3 || true)
    local eip_fail
    eip_fail=$(kubectl get events -n ddiaas-dataplane --field-selector reason=EIPAssociationFailed --no-headers 2>/dev/null \
        | grep "$EP" | tail -3 || true)
    if [[ -z "$eip_events" && -z "$eip_fail" ]]; then
        printf "  ${YELLOW}(no EIP events yet)${NC}\n"
    else
        [[ -n "$eip_events" ]] && while IFS= read -r line; do
            printf "  ${GREEN}%s${NC}\n" "$line"
        done <<< "$eip_events"
        [[ -n "$eip_fail" ]] && while IFS= read -r line; do
            printf "  ${RED}%s${NC}\n" "$line"
        done <<< "$eip_fail"
    fi

    # ── Endpoint Manager State ──
    header "Endpoint Manager Log (latest unique)"
    local em_msgs
    em_msgs=$(kubectl logs -n ddiaas-endpoint-manager -l app.kubernetes.io/name=ddiaas-endpoint-manager --since=60s 2>/dev/null \
        | grep "$EP" | jq -r '.msg' 2>/dev/null | sort -u || true)
    if [[ -z "$em_msgs" ]]; then
        em_msgs=$(kubectl logs -n ddiaas-endpoint-manager ddiaas-endpoint-manager-6bbbb76bf9-d56hp --since=60s 2>/dev/null \
            | grep "$EP" | jq -r '.msg' 2>/dev/null | sort -u || true)
    fi
    if [[ -z "$em_msgs" ]]; then
        printf "  ${YELLOW}(no recent messages)${NC}\n"
    else
        while IFS= read -r msg; do
            if [[ "$msg" == *"not successful"* || "$msg" == *"Failed"* || "$msg" == *"error"* ]]; then
                printf "  ${RED}• %s${NC}\n" "$msg"
            elif [[ "$msg" == *"ready"* || "$msg" == *"success"* ]]; then
                printf "  ${GREEN}• %s${NC}\n" "$msg"
            else
                printf "  ${YELLOW}• %s${NC}\n" "$msg"
            fi
        done <<< "$em_msgs"
    fi

    printf "\n"
}

# ── Main loop ──
printf "${CYAN}Starting monitor for endpoint: %s${NC}\n" "$EP"
printf "${CYAN}Press Ctrl+C to stop${NC}\n"

while true; do
    now=$(date +%s)
    if (( now - START_TIME >= TIMEOUT_SECS )); then
        printf "\n${RED}Timeout reached (%s minutes). Endpoint may not be fully ready.${NC}\n" "$TIMEOUT_MINS"
        exit 1
    fi

    render

    if check_all_ready; then
        printf "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
        printf "${GREEN}║  ENDPOINT FULLY READY after %s                          ║${NC}\n" "$(elapsed)"
        printf "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}\n"
        exit 0
    fi

    sleep "$INTERVAL"
done

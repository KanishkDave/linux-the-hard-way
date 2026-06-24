#!/bin/bash
# =============================================================
# Scenario 02 — OOM Kill
# linux-the-hard-way / memory / scenario-02
# =============================================================
# This script triggers an OOM kill in two phases.
# Open two more terminals before running and keep these ready:
#
#   Terminal 2: vmstat 1
#   Terminal 3: sudo dmesg -Tw
#
# Phase 1 — pressure with swap enabled (shows the buffer)
# Phase 2 — swap disabled, OOM kill guaranteed
#
# Don't skip ahead. Observe each phase before continuing.
# =============================================================

set -euo pipefail

# ----- colours ------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ----- helpers ------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
section() { echo -e "\n${BOLD}$*${RESET}"; echo "$(printf '%.0s─' {1..60})"; }
pause() {
    echo ""
    echo -e "${YELLOW}Press ENTER to continue to the next phase...${RESET}"
    read -r
}

# ----- state --------------------------------------------------
PIDS=()
SWAP_WAS_ENABLED=0

# ----- cleanup on exit ----------------------------------------
cleanup() {
    echo ""
    info "Cleaning up..."

    # Kill all stress-ng workers
    if [ ${#PIDS[@]} -gt 0 ]; then
        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    pkill -f stress-ng 2>/dev/null || true
    success "All workers stopped."

    # Re-enable swap if we disabled it
    if [ "$SWAP_WAS_ENABLED" -eq 1 ]; then
        info "Re-enabling swap..."
        sudo swapon -a 2>/dev/null || true
        sleep 2
        CURRENT_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        if [ "$CURRENT_SWAP" -gt 0 ]; then
            success "Swap restored."
        else
            warn "Swap did not restore automatically."
            warn "If swap is missing after exit, restart WSL: run 'wsl --shutdown' from Windows PowerShell."
        fi
    fi
}
trap cleanup EXIT

# =============================================================
# PREFLIGHT CHECKS
# =============================================================
section "Preflight checks"

if ! command -v stress-ng &>/dev/null; then
    warn "stress-ng not found."
    echo "  Install it: sudo apt install stress-ng"
    exit 1
fi
success "stress-ng found: $(stress-ng --version 2>&1 | head -1)"

# Check sudo access — needed for swapoff/swapon
if ! sudo -n true 2>/dev/null; then
    info "This script needs sudo to disable/re-enable swap."
    info "You will be prompted once when Phase 2 starts."
fi

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
CORES=$(nproc)

if [ "$SWAP_KB" -gt 0 ]; then
    SWAP_WAS_ENABLED=1
    SWAP_GB=$(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")
    success "Swap detected: ${SWAP_GB}Gi — will be restored on exit"
else
    warn "No swap detected. Phase 1 will behave similarly to Phase 2."
    warn "OOM kill may trigger in Phase 1 as well."
fi

# ----- dynamic worker calculation -----------------------------
#
# Phase 1 — With swap ON
#   Goal: fill ~90% of RAM to force swap usage
#   4 workers × 22% each ≈ 90% total
#   --vm-populate forces immediate page touching (no lazy allocation)
#
# Phase 2 — Swap OFF
#   Goal: demand MORE than available RAM to guarantee OOM
#   --vm-bytes 120% means EACH worker demands 120% of available RAM
#   4 workers × 120% = system collapses, OOM fires immediately
#
#   Note: stress-ng --vm-bytes percentage is per worker, calculated
#   against available RAM at launch time — not total RAM divided across
#   workers. Setting 120% per worker guarantees each one individually
#   exceeds available RAM. OOM is mathematically certain with no swap.

NUM_WORKERS=4

PHASE1_PCT=$(awk "BEGIN {printf \"%.0f\", 90 / $NUM_WORKERS}")
PHASE2_PCT=120

PHASE1_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024 * 0.90}")
PHASE2_TOTAL_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024 * 1.20 * $NUM_WORKERS}")

info "System: ${TOTAL_RAM_GB}Gi RAM | ${CORES} cores | Swap: ${SWAP_GB:-0}Gi"
info "Phase 1: ${NUM_WORKERS} workers × ${PHASE1_PCT}% RAM each = ~${PHASE1_TOTAL_GB}Gi total (with swap)"
info "Phase 2: ${NUM_WORKERS} workers × ${PHASE2_PCT}% available RAM each — OOM guaranteed (no swap)"
echo ""

# =============================================================
# BASELINE
# =============================================================
section "Baseline — before any pressure"

echo "Record these numbers. You'll compare them after each phase."
echo ""
free -h
echo ""
info "Open two more terminals now:"
echo "  Terminal 2: vmstat 1"
echo "  Terminal 3: sudo dmesg -Tw"
echo ""
echo "  Terminal 3 is critical — the OOM kill message appears there."
echo "  Don't skip it."

pause

# =============================================================
# PHASE 1 — Pressure with swap enabled
# =============================================================
section "Phase 1 — ${NUM_WORKERS} workers × ${PHASE1_PCT}% RAM, swap enabled"

echo -e "Starting ${NUM_WORKERS} workers, demanding ~${CYAN}${PHASE1_TOTAL_GB}Gi${RESET} total (90% of RAM)."
echo "--vm-populate forces workers to touch every page immediately."
echo "Swap is still on. Watch what the kernel does when RAM fills up."
echo ""

stress-ng --vm "$NUM_WORKERS" --vm-bytes "${PHASE1_PCT}%" \
    --vm-keep --vm-populate --timeout 300s &
PIDS+=($!)

sleep 10

info "Workers running."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  free -h      → how low has 'available' dropped?"
echo "  vmstat 1     → is 'so' non-zero? what about 'bi'/'bo'?"
echo "  dmesg -Tw    → any drop_caches events?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  RAM is filling up but nothing has died."
echo "  What is the kernel doing to keep things alive?"
echo ""

free -h
echo ""
echo "vmstat snapshot (5 readings):"
vmstat 1 5
echo ""

# Show OOM scores
echo "OOM scores for running workers:"
for pid in $(pgrep -x stress-ng-vm 2>/dev/null | head -4); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null || echo "N/A")
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null || echo "N/A")
    rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null || echo "N/A")
    rss_mb=$(awk "BEGIN {printf \"%.0f\", ${rss:-0}/1024}")
    echo "  PID $pid — oom_score: $score | oom_score_adj: $adj | RSS: ${rss_mb}MB"
done
echo ""
info "Note the OOM score — this tells you kill priority before anything dies."

pause

# Kill Phase 1 workers cleanly before Phase 2
info "Stopping Phase 1 workers before removing swap..."
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
pkill -f stress-ng 2>/dev/null || true
PIDS=()
sleep 5
success "Phase 1 workers stopped. Waiting for RAM to recover..."
sleep 5
free -h

pause

# =============================================================
# PHASE 2 — Swap disabled, OOM guaranteed
# =============================================================
section "Phase 2 — Removing the safety net"

echo "Disabling swap. From this point there is no buffer."
echo "Each worker will demand ${PHASE2_PCT}% of available RAM individually."
echo "The kernel will have no choice but to kill something."
echo ""

if [ "$SWAP_WAS_ENABLED" -eq 1 ]; then
    sudo swapoff -a
    sleep 2
    CURRENT_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [ "$CURRENT_SWAP" -eq 0 ]; then
        success "Swap disabled."
    else
        warn "swapoff may not have completed fully. Continuing anyway."
    fi
fi

echo ""
free -h
echo ""
echo -e "  ${BOLD}Notice:${RESET} Swap shows 0. No safety net."
echo ""

pause

section "Phase 2 — ${NUM_WORKERS} workers × ${PHASE2_PCT}% available RAM each, no swap"

echo -e "Launching ${NUM_WORKERS} workers, each demanding ${CYAN}${PHASE2_PCT}%${RESET} of available RAM."
echo "Each worker alone exceeds available RAM. With 4 workers and no swap — OOM is certain."
echo -e "  ${RED}Watch Terminal 3 (dmesg) closely. The OOM message will appear there.${RESET}"
echo ""

stress-ng --vm "$NUM_WORKERS" --vm-bytes "${PHASE2_PCT}%" \
    --vm-keep --vm-populate --timeout 180s &
PIDS+=($!)

info "Workers launched. RAM will collapse within seconds to minutes."
echo ""
echo -e "  ${BOLD}Watch your terminals now:${RESET}"
echo "  Terminal 2 (vmstat)  → bi/bo spiking, r column backing up"
echo "  Terminal 3 (dmesg)   → OOM kill message will appear there"
echo "  free -h              → available dropping toward zero"
echo ""
echo -e "  ${BOLD}Key questions to think about:${RESET}"
echo "  Which process invoked the OOM killer?"
echo "  Is that the same process that got killed?"
echo "  Why did stress-ng get killed instead of systemd or containerd?"

pause

# ----- Step: show OOM log snippet -----------------------------
section "What dmesg captured"

echo "Recent OOM events from dmesg:"
echo ""
sudo dmesg 2>/dev/null | grep -i "oom\|killed process\|out of memory\|all_unreclaimable" | tail -15 \
    || echo "  (none yet — OOM may still be in progress, check Terminal 3)"
echo ""
echo "Surviving stress-ng workers:"
ps aux | grep stress-ng | grep -v grep || echo "  (all killed — OOM fired successfully)"

pause

# ----- Step: scenario complete --------------------------------
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Swap as buffer       — Phase 1 survived because swap absorbed overflow"
echo "  2. No swap = no warning — Phase 2 OOM fired with no degradation window"
echo "  3. Trigger ≠ culprit    — the invoking process just needed the last page"
echo "  4. OOM score decides    — highest scorer dies, not biggest consumer"
echo "  5. bi/bo thrashing      — kernel doing heavy IO trying to reclaim before killing"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  sudo dmesg                    → OOM event, invoker, victim, memory state at kill"
echo "  cat /proc/<pid>/oom_score     → kill priority of any process"
echo "  cat /proc/<pid>/oom_score_adj → manual bias applied"
echo "  vmstat 1 bi/bo                → IO thrashing signal before OOM fires"
echo "  free -h available             → how close you are to the edge"
echo ""
echo -e "  ${BOLD}For detailed explanation of every output, what each number means,"
echo -e "  and the full chain of events — read the README:${RESET}"
echo "  ./README.md"
echo ""

pause

info "Restoring swap and cleaning up workers..."

# wait for cleanup trap to complete then print next scenario
wait 2>/dev/null || true
echo ""
echo -e "${CYAN}Next → Scenario 03: Memory Leak${RESET}"
echo "  ../scenario-03-memory-leak/README.md"
echo ""

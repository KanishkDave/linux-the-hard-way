#!/bin/bash
# =============================================================
# Scenario 02 — OOM Kill
# linux-the-hard-way / memory / scenario-02
# =============================================================
# This script triggers an OOM kill in two phases.
# Open two more terminals before running and keep these ready:
#
#   vmstat 1
#   sudo dmesg -Tw
#
# Phase 1 — pressure with swap enabled (shows the buffer)
# Phase 2 — swap disabled, OOM kill triggered
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
SWAP_DEVICES=()

# ----- cleanup on exit ----------------------------------------
cleanup() {
    echo ""
    info "Cleaning up..."

    # Kill all stress-ng workers
    if [ ${#PIDS[@]} -gt 0 ]; then
        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        success "All workers stopped."
    fi

    # Kill any stray stress-ng processes
    pkill -f stress-ng 2>/dev/null || true

    # Re-enable swap if we disabled it
    if [ "$SWAP_WAS_ENABLED" -eq 1 ]; then
        info "Re-enabling swap..."
        sudo swapon -a 2>/dev/null || true
        CURRENT_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
        if [ "$CURRENT_SWAP" -gt 0 ]; then
            success "Swap restored. Watch RAM recover: watch -n1 free -h"
        else
            warn "Swap may not have re-enabled automatically."
            warn "Run manually: sudo swapon -a"
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
    warn "This script needs sudo access to disable/re-enable swap."
    echo "  You'll be prompted for your password when swap is disabled in Phase 2."
fi

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
CORES=$(nproc)

if [ "$SWAP_KB" -gt 0 ]; then
    SWAP_WAS_ENABLED=1
    success "Swap detected: $(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")Gi — will be restored on exit"
else
    warn "No swap detected. Phase 2 will still trigger OOM but Phase 1 may be less interesting."
fi

# ----- dynamic worker calculation -----------------------------
# Phase 1: 4 workers at 90% RAM total — fills RAM, forces swap use
# Phase 2: 4 workers at 95% RAM total — with swap gone, OOM is guaranteed
#
# Worker count scales to machine size so the same pressure thresholds
# are hit regardless of how much RAM you have.

PHASE1_WORKERS=4
PHASE2_WORKERS=4

# Calculate per-worker memory for Phase 1 (90% total across 4 workers)
PHASE1_MEM_PCT=$(awk "BEGIN {printf \"%.0f\", 90 / $PHASE1_WORKERS}")
# Phase 2: 95% total across 4 workers
PHASE2_MEM_PCT=$(awk "BEGIN {printf \"%.0f\", 95 / $PHASE2_WORKERS}")

info "System: ${TOTAL_RAM_GB}Gi RAM | ${CORES} CPU cores | Swap: $(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")Gi"
info "Phase 1: ${PHASE1_WORKERS} workers × ${PHASE1_MEM_PCT}% RAM each (90% total) — with swap"
info "Phase 2: ${PHASE2_WORKERS} workers × ${PHASE2_MEM_PCT}% RAM each (95% total) — swap disabled"
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
section "Phase 1 — ${PHASE1_WORKERS} workers, ~90% RAM, swap enabled"

echo -e "Starting ${PHASE1_WORKERS} workers, each consuming ~${CYAN}${PHASE1_MEM_PCT}% of ${TOTAL_RAM_GB}Gi${RESET}."
echo "Swap is still on. Watch what the kernel does when RAM fills up."
echo ""

stress-ng --vm "$PHASE1_WORKERS" --vm-bytes "${PHASE1_MEM_PCT}%" --vm-keep --timeout 300s &
PIDS+=($!)

sleep 8

info "Workers running."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  free -h          → how low has 'available' dropped?"
echo "  vmstat 1         → is 'so' non-zero? what about 'bi'/'bo'?"
echo "  dmesg -Tw        → any drop_caches events?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  The system is under pressure but nothing has died."
echo "  What is the kernel doing to keep things alive?"
echo ""

free -h
echo ""
echo "vmstat snapshot (5 readings):"
vmstat 1 5
echo ""

# Show OOM scores for stress-ng workers
echo "OOM scores for stress-ng workers:"
for pid in $(pgrep stress-ng-vm 2>/dev/null | head -4); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null || echo "N/A")
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null || echo "N/A")
    echo "  PID $pid — oom_score: $score | oom_score_adj: $adj"
done
echo ""
info "oom_score_adj: 1000 means stress-ng is intentionally the first OOM target."

pause

# Kill Phase 1 workers before Phase 2
info "Stopping Phase 1 workers..."
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
pkill -f stress-ng 2>/dev/null || true
PIDS=()
sleep 5
success "Phase 1 workers stopped. RAM recovering."
echo ""
free -h

pause

# =============================================================
# PHASE 2 — Swap disabled, OOM kill
# =============================================================
section "Phase 2 — Removing the safety net"

echo "Disabling swap. From this point there is no buffer."
echo "When RAM runs out, the OOM killer fires immediately."
echo ""

if [ "$SWAP_WAS_ENABLED" -eq 1 ]; then
    sudo swapoff -a
    CURRENT_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    if [ "$CURRENT_SWAP" -eq 0 ]; then
        success "Swap disabled."
    else
        warn "swapoff may not have completed. Check: free -h"
    fi
else
    warn "No swap was enabled — Phase 2 will behave the same as Phase 1 already did."
fi

echo ""
free -h
echo ""
echo -e "  ${BOLD}Notice:${RESET} Swap line now shows 0. No safety net."
echo ""
echo "Launching ${PHASE2_WORKERS} workers at ${PHASE2_MEM_PCT}% RAM each."
echo -e "  ${RED}Watch Terminal 3 (dmesg) closely. The OOM kill message will appear there.${RESET}"
echo ""

pause

stress-ng --vm "$PHASE2_WORKERS" --vm-bytes "${PHASE2_MEM_PCT}%" --vm-keep --timeout 120s &
PIDS+=($!)

sleep 5

info "Workers running. RAM will exhaust within seconds to minutes."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  dmesg -Tw        → OOM kill message — who invoked it? who died?"
echo "  vmstat 1         → bi/bo spiking (thrashing) before the kill"
echo "  free -h          → available collapsing toward zero"
echo "  ps aux | grep stress-ng  → did all 4 workers survive?"
echo ""
echo -e "  ${BOLD}Key questions:${RESET}"
echo "  Which process invoked the OOM killer?"
echo "  Is that the same process that got killed?"
echo "  Why did stress-ng get killed instead of systemd?"
echo ""

# Wait for OOM or timeout
sleep 30

echo ""
echo "Current state:"
free -h
echo ""
echo "Surviving stress-ng workers:"
ps aux | grep stress-ng | grep -v grep || echo "  (none — all killed)"
echo ""
echo "Recent OOM events in dmesg:"
sudo dmesg | grep -i "oom\|killed process" | tail -10 || echo "  (none yet — may still be building)"

# =============================================================
# SUMMARY
# =============================================================
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Swap as buffer    — Phase 1 survived because swap absorbed the overflow"
echo "  2. No-swap = no warning — Phase 2 OOM fired with no degradation window"
echo "  3. Trigger ≠ culprit — the invoking process needed the last page, not the most"
echo "  4. OOM score matters — oom_score_adj: 1000 made stress-ng the intentional target"
echo "  5. bi/bo thrashing   — kernel doing heavy IO trying to reclaim before killing"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  sudo dmesg -Tw               → OOM kill event, invoker, victim, memory state"
echo "  cat /proc/<pid>/oom_score    → current kill priority of any process"
echo "  cat /proc/<pid>/oom_score_adj → manual bias applied"
echo "  vmstat 1 bi/bo               → IO thrashing signal before OOM fires"
echo "  free -h available            → the number that tells you how close you are"
echo ""
echo -e "  ${CYAN}Next → Scenario 03: Memory Leak${RESET}"
echo "  ../scenario-03-memory-leak/README.md"
echo ""

info "Cleaning up workers and restoring swap..."

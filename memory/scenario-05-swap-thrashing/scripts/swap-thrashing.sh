#!/bin/bash
# =============================================================
# Scenario 05 — Swap Thrashing
# linux-the-hard-way / memory / scenario-05
# =============================================================
# This script triggers swap thrashing in three phases.
# Open three more terminals before running:
#
#   Terminal 2: vmstat 1          ← most important this time
#   Terminal 3: sudo dmesg -Tw
#   Terminal 4: watch -n1 'free -h'
#
# Phase 1 — RAM filling, swap starting (swappiness=100)
# Phase 2 — full thrashing observed
# Phase 3 — swappiness=10 applied, observe the shift
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
    echo -e "${YELLOW}Press ENTER to continue...${RESET}"
    read -r
}

# ----- state --------------------------------------------------
PIDS=()
ORIGINAL_SWAPPINESS=$(cat /proc/sys/vm/swappiness)

# ----- cleanup on exit ----------------------------------------
cleanup() {
    echo ""
    info "Cleaning up..."

    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    pkill -f stress-ng 2>/dev/null || true
    success "All workers stopped."

    # Restore original swappiness
    sudo sysctl -q vm.swappiness="$ORIGINAL_SWAPPINESS" 2>/dev/null || true
    success "swappiness restored to ${ORIGINAL_SWAPPINESS}."

    sleep 3
    echo ""
    free -h
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

if ! command -v smem &>/dev/null; then
    warn "smem not found."
    echo "  Install it: sudo apt install smem"
    exit 1
fi
success "smem found"

# Check sudo
if ! sudo -n true 2>/dev/null; then
    info "This script needs sudo to change swappiness."
    info "You will be prompted when Phase 1 starts."
fi

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
CORES=$(nproc)

if [ "$SWAP_KB" -eq 0 ]; then
    warn "No swap detected. This scenario requires swap to demonstrate thrashing."
    warn "Enable swap before running: sudo swapon -a"
    warn "Or restart WSL: run 'wsl --shutdown' from Windows PowerShell"
    exit 1
fi

SWAP_GB=$(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")

# ----- dynamic worker calculation -----------------------------
# Goal: fill RAM completely and push into swap to trigger thrashing
# --vm-bytes is per worker against available RAM at launch time
#
# Strategy: total demand = 2x (RAM + Swap)
# This guarantees swap fills completely on any machine size
# Each worker demands 120% of available RAM individually
# Worker count scales so combined demand always exceeds RAM+Swap by 2x
# No --vm-populate — gradual page touching creates sustained swap pressure
# which produces the si/so thrashing signature better than immediate fill

PHASE1_PCT=120
TOTAL_KB=$(( TOTAL_RAM_KB + SWAP_KB ))
TARGET_KB=$(( TOTAL_KB * 2 ))
WORKER_DEMAND_KB=$(awk "BEGIN {printf \"%d\", $AVAIL_RAM_KB * 1.2}")
PHASE1_WORKERS=$(awk "BEGIN {
    w = int($TARGET_KB / $WORKER_DEMAND_KB)
    if (w < 4) w = 4
    if (w > 12) w = 12
    print w
}")

info "System: ${TOTAL_RAM_GB}Gi RAM | ${CORES} cores | Swap: ${SWAP_GB}Gi"
info "Original swappiness: ${ORIGINAL_SWAPPINESS} — will be restored on exit"
info "Phase 1-2: ${PHASE1_WORKERS} workers × ${PHASE1_PCT}% available RAM each (swappiness=100) — thrashing guaranteed"
info "Phase 3: swappiness=10 applied — observe strategy shift"
echo ""

# =============================================================
# BASELINE
# =============================================================
section "Baseline — before any pressure"

echo "Record these numbers carefully. Every column matters this time."
echo ""
free -h
echo ""
echo "Current swappiness:"
cat /proc/sys/vm/swappiness
echo ""
echo "pgmajfault baseline:"
cat /proc/vmstat | grep pgmajfault
echo ""
echo "vmstat baseline (3 readings):"
vmstat 1 3
echo ""
info "Open three more terminals now:"
echo "  Terminal 2: vmstat 1          ← watch this most closely"
echo "  Terminal 3: sudo dmesg -Tw"
echo "  Terminal 4: watch -n1 'free -h'"

pause

# =============================================================
# PHASE 1 — RAM filling, swap starting
# =============================================================
section "Phase 1 — Setting swappiness=100, launching workers"

echo "swappiness=100 tells the kernel to swap anonymous pages aggressively."
echo "Workers will fill RAM quickly, forcing the kernel into swap."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  vmstat so     → first appearance of swap-out activity"
echo "  vmstat swpd   → swap filling up"
echo "  free -h swap  → used swap growing"
echo "  vmstat b      → processes starting to block on IO"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  At what point does 'so' first appear in vmstat?"
echo "  What does that moment tell you about the system state?"

pause

sudo sysctl -q vm.swappiness=100
success "swappiness set to 100"
echo ""

stress-ng --vm "$PHASE1_WORKERS" --vm-bytes "${PHASE1_PCT}%" \
    --vm-keep --timeout 300s &
PIDS+=($!)

sleep 5
info "Workers running. RAM filling now."
echo ""

# Monitor until swap starts filling
info "Watching for swap activity..."
ELAPSED=0
while true; do
    sleep 5
    ELAPSED=$(( ELAPSED + 5 ))
    SWAP_USED=$(grep SwapFree /proc/meminfo | awk '{print $2}')
    SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
    SWAP_USED_KB=$(( SWAP_TOTAL - SWAP_USED ))
    SWAP_PCT=$(awk "BEGIN {printf \"%.0f\", ($SWAP_USED_KB / $SWAP_TOTAL) * 100}")
    AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    AVAIL_MB=$(( AVAIL / 1024 ))
    echo -e "  ${ELAPSED}s — Available: ${AVAIL_MB}MB | Swap used: ${SWAP_USED_KB}kB (${SWAP_PCT}%)"

    # Break when swap starts filling meaningfully
    if [ "$SWAP_USED_KB" -gt 102400 ]; then   # >100MB swap used
        echo ""
        success "Swap activity detected. Moving to Phase 2."
        break
    fi

    # Safety — don't loop forever
    if [ "$ELAPSED" -ge 60 ]; then
        warn "Swap didn't fill within 60s — continuing anyway."
        break
    fi
done

pause

# =============================================================
# PHASE 2 — Full thrashing
# =============================================================
section "Phase 2 — Observing thrashing"

echo "RAM is filling. Swap is being used. Watch vmstat closely."
echo ""
echo -e "  ${BOLD}What to look for in vmstat:${RESET}"
echo "  si AND so both non-zero simultaneously → thrashing signal"
echo "  b column spiking                        → processes blocked on IO"
echo "  wa climbing                             → CPU waiting on disk"
echo "  us dropping                             → almost no useful work"
echo "  id appearing high                       → the CPU idle trap"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  CPU might show 40% idle. But how much useful work (us) is actually happening?"
echo "  Why would a system be both idle and destroyed at the same time?"

pause

# ----- Phase 2 snapshot ---------------------------------------
section "Phase 2 — What the system is showing you"

echo "Memory state:"
free -h
echo ""
echo "vmstat snapshot (10 readings):"
vmstat 1 10
echo ""

# pgmajfault rate
echo "Major page fault rate:"
F1=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
sleep 10
F2=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
FAULT_RATE=$(( (F2 - F1) / 10 ))
echo "  pgmajfault at start:  $F1"
echo "  pgmajfault at end:    $F2"
echo "  Delta:                $(( F2 - F1 )) faults in 10s"
echo "  Rate:                 ${FAULT_RATE} major faults/sec"
echo ""

if [ "$FAULT_RATE" -gt 1000 ]; then
    warn "Major fault rate > 1000/sec — serious thrashing confirmed."
elif [ "$FAULT_RATE" -gt 100 ]; then
    info "Major fault rate > 100/sec — memory pressure significant."
else
    info "Major fault rate: ${FAULT_RATE}/sec — pressure building."
fi

echo ""
echo "Top swap consumers:"
smem -r 2>/dev/null | head -10 || warn "Try: sudo smem -r"
echo ""
echo "Processes blocked on IO (b column):"
vmstat 1 3

pause

# =============================================================
# PHASE 3 — swappiness=10
# =============================================================
section "Phase 3 — Applying swappiness=10"

echo "Changing swappiness from 100 to 10."
echo "The kernel will now prefer evicting file cache over process pages."
echo "Watch whether si/so drop and bi/bo change."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  vmstat si/so  → should reduce as kernel stops swapping aggressively"
echo "  vmstat bi/bo  → may stay high — kernel now evicting file cache instead"
echo "  pgmajfault    → does the rate improve?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  Does swappiness=10 stop the thrashing?"
echo "  Or does it just change which type of page gets sacrificed?"

pause

sudo sysctl -q vm.swappiness=10
success "swappiness set to 10"
echo ""

sleep 10

# ----- Phase 3 snapshot ---------------------------------------
section "Phase 3 — What changed after swappiness=10"

echo "Memory state after swappiness change:"
free -h
echo ""
echo "vmstat snapshot after tuning (10 readings):"
vmstat 1 10
echo ""

# pgmajfault rate after tuning
echo "Major page fault rate after swappiness=10:"
F1=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
sleep 10
F2=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
FAULT_RATE_NEW=$(( (F2 - F1) / 10 ))
echo "  Rate after tuning: ${FAULT_RATE_NEW} major faults/sec"
echo "  Rate before tuning: ${FAULT_RATE} major faults/sec"
echo ""

RATE_DIFF=$(( FAULT_RATE - FAULT_RATE_NEW ))
if [ "$FAULT_RATE_NEW" -lt "$FAULT_RATE" ] && [ "$RATE_DIFF" -gt 100 ]; then
    info "Fault rate reduced by ${RATE_DIFF}/sec — swappiness tuning helped at the margins."
    info "System still under pressure. Real fix: reduce memory hog."
elif [ "$FAULT_RATE_NEW" -gt "$FAULT_RATE" ]; then
    RATE_INCREASE=$(( FAULT_RATE_NEW - FAULT_RATE ))
    info "Fault rate increased by ${RATE_INCREASE}/sec — kernel shifted from swap misses to cache misses."
    info "swappiness=10 changed the strategy, not the pressure. Both types of miss cost performance."
else
    info "Fault rate similar — pressure too extreme for swappiness tuning to meaningfully help."
    info "Real fix: reduce memory pressure by killing a consumer."
fi

echo ""
echo "Top memory consumers right now:"
ps aux --sort=-%mem | head -10

pause

# =============================================================
# SUMMARY
# =============================================================
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Thrashing signal  — si AND so both non-zero simultaneously"
echo "  2. CPU idle trap     — id high, us low, wa high = system destroyed"
echo "  3. b column          — processes blocked on IO, not CPU"
echo "  4. pgmajfault        — 10,000+ faults/sec = every thread stalling"
echo "  5. swappiness limit  — tuning shifts the strategy, doesn't fix the root cause"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  vmstat si/so both non-zero   → thrashing confirmed"
echo "  vmstat b + wa                → IO blocked processes"
echo "  vmstat us vs id              → CPU idle trap"
echo "  pgmajfault delta             → fault rate and severity"
echo "  smem -r swap column          → thrashing victims"
echo ""
echo -e "  ${BOLD}For detailed explanation of every output, what each number means,"
echo -e "  and the full chain of events — read the README:${RESET}"
echo "  ./README.md"
echo ""

pause

info "Restoring swappiness to ${ORIGINAL_SWAPPINESS} and stopping workers..."

# Kill workers explicitly before wait to prevent hanging
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
pkill -f stress-ng 2>/dev/null || true
sleep 3

echo ""
echo -e "${CYAN}Next → Scenario 06: Container OOM${RESET}"
echo "  ../scenario-06-container-oom/README.md"
echo ""

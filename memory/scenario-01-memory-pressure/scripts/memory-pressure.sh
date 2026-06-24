#!/bin/bash
# =============================================================
# Scenario 01 — Sustained Memory Pressure & Swap Behavior
# linux-the-hard-way / memory / scenario-01
# =============================================================
# This script triggers memory pressure in three phases.
# Open a second terminal before running and keep these ready:
#
#   vmstat 1
#   smem -r | head -20
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

# ----- cleanup on exit ----------------------------------------
PIDS=()
cleanup() {
    if [ ${#PIDS[@]} -gt 0 ]; then
        echo ""
        info "Cleaning up stress-ng workers..."
        for pid in "${PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
        success "All workers stopped."
        info "Swap should drain within 60 seconds. Watch: vmstat 1"
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

if ! command -v smem &>/dev/null; then
    warn "smem not found."
    echo "  Install it: sudo apt install smem"
    exit 1
fi
success "smem found"

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
CORES=$(nproc)

# ----- dynamic worker calculation -----------------------------
# Each worker claims 60% of total RAM via --vm-bytes 60%.
# We calculate how many workers are needed per phase to hit
# the same pressure thresholds on any machine size:
#
#   Phase 1 — noticeable allocation, swap untouched
#   Phase 2 — overcommit territory (Committed_AS > CommitLimit)
#   Phase 3 — tip into swap (available RAM near zero)

WORKER_RAM_KB=$(awk "BEGIN {printf \"%d\", $TOTAL_RAM_KB * 0.6}")

PHASE1_WORKERS=$(awk "BEGIN {
    w = int($TOTAL_RAM_KB * 0.60 / $WORKER_RAM_KB)
    if (w < 1) w = 1
    if (w > 6) w = 6
    print w
}")

PHASE2_WORKERS=$(awk "BEGIN {
    total_needed = int($TOTAL_RAM_KB * 0.80 / $WORKER_RAM_KB)
    phase2 = total_needed - $PHASE1_WORKERS
    if (phase2 < 1) phase2 = 1
    if (phase2 > 6) phase2 = 6
    print phase2
}")

PHASE3_WORKERS=$(awk "BEGIN {
    if ($SWAP_KB == 0) { print 1 } else { print 2 }
}")

TOTAL_WORKERS=$(( PHASE1_WORKERS + PHASE2_WORKERS + PHASE3_WORKERS ))

info "System: ${TOTAL_RAM_GB}Gi RAM | ${CORES} CPU cores | Swap: $(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")Gi"
info "Worker plan: Phase1=${PHASE1_WORKERS} | Phase2=+${PHASE2_WORKERS} | Phase3=+${PHASE3_WORKERS} | Total=${TOTAL_WORKERS}"

if [ "$SWAP_KB" -eq 0 ]; then
    warn "No swap detected. Phase 3 may trigger OOM kill — watch dmesg -Tw in another terminal."
fi
echo ""

# =============================================================
# BASELINE
# =============================================================
section "Baseline — before any pressure"

echo "Record these numbers. You'll compare them after each phase."
echo ""
free -h
echo ""
grep -E 'CommitLimit|Committed_AS' /proc/meminfo
echo ""
info "Open a second terminal now and run: vmstat 1"

pause

# =============================================================
# PHASE 1 — Initial allocation
# =============================================================
section "Phase 1 — ${PHASE1_WORKERS} worker(s), 60% RAM each"

echo -e "Starting ${PHASE1_WORKERS} stress-ng worker(s). Each allocates ~${CYAN}60% of ${TOTAL_RAM_GB}Gi${RESET} and holds it."
echo ""

stress-ng --vm "$PHASE1_WORKERS" --vm-bytes 60% --vm-keep --timeout 300s &
PIDS+=($!)

sleep 5

info "Workers running. Switch to your vmstat terminal and watch."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  free -h      → how much has 'available' dropped?"
echo "  vmstat 1     → is si/so still zero? what is r showing?"
echo "  ps aux --sort=-%mem | head -10  → spot the VSZ vs RSS gap"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  Why does ps show >100% CPU per worker"
echo "  but vmstat shows the system mostly idle?"

pause

# ----- Phase 1 output snapshot --------------------------------
section "Phase 1 — what the system is showing you"

echo "Memory state:"
free -h
echo ""
grep -E 'CommitLimit|Committed_AS' /proc/meminfo
echo ""
echo "Top memory consumers:"
ps aux --sort=-%mem | head -10
echo ""
echo "vmstat snapshot (5 readings):"
vmstat 1 5

pause

# =============================================================
# PHASE 2 — Push into overcommit
# =============================================================
RUNNING_WORKERS=$(( PHASE1_WORKERS + PHASE2_WORKERS ))
section "Phase 2 — ${PHASE2_WORKERS} more worker(s) (${RUNNING_WORKERS} total)"

echo "Adding ${PHASE2_WORKERS} more worker(s). Pushing Committed_AS past CommitLimit."
echo ""

stress-ng --vm "$PHASE2_WORKERS" --vm-bytes 60% --vm-keep --timeout 240s &
PIDS+=($!)

sleep 5

info "${RUNNING_WORKERS} workers now running."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  CommitLimit vs Committed_AS  → how far into overcommit?"
echo "  available in free -h         → getting tight?"
echo "  si/so in vmstat              → swap still untouched?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  Why hasn't swap kicked in yet,"
echo "  even though Committed_AS exceeds CommitLimit?"

pause

# ----- Phase 2 output snapshot --------------------------------
section "Phase 2 — what the system is showing you"

free -h
echo ""
grep -E 'CommitLimit|Committed_AS|MemAvailable' /proc/meminfo
echo ""

OVERLIMIT=$(awk '/CommitLimit/ {limit=$2} /Committed_AS/ {committed=$2} \
    END {
        if (limit > 0)
            printf "%.1f", ((committed-limit)/limit)*100
        else
            print "0"
    }' /proc/meminfo)
info "Overcommit: ${OVERLIMIT}% over CommitLimit"
echo ""
echo "vmstat snapshot (5 readings):"
vmstat 1 5

pause

# =============================================================
# PHASE 3 — Force swap
# =============================================================
section "Phase 3 — ${PHASE3_WORKERS} final worker(s) (${TOTAL_WORKERS} total) — swap territory"

echo "Adding ${PHASE3_WORKERS} more worker(s). Available RAM nearly exhausted."
echo ""

stress-ng --vm "$PHASE3_WORKERS" --vm-bytes 60% --vm-keep --timeout 180s &
PIDS+=($!)

sleep 3

info "${TOTAL_WORKERS} workers now running."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  vmstat 1     → so column spikes? sy jumps? r backed up?"
echo "  free -h      → available near zero? swap used non-zero?"
echo "  smem -r      → which process has non-zero Swap? (hint: not stress-ng)"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  When swap kicks in, which processes get evicted?"
echo "  The memory hogs or the idle background processes?"

pause

# ----- Phase 3 output snapshot --------------------------------
section "Phase 3 — what the system is showing you"

free -h
echo ""
echo "vmstat snapshot (5 readings):"
vmstat 1 5
echo ""
echo "Top swap consumers:"
smem -r 2>/dev/null | head -15 || warn "Try: sudo smem -r"

pause

# =============================================================
# SUMMARY
# =============================================================
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Demand paging    — RSS grew slowly after VSZ jumped immediately"
echo "  2. Overcommit       — kernel promised more than it had, system survived"
echo "  3. LRU eviction     — idle processes swapped out, not the memory hogs"
echo "  4. Silent pressure  — nothing died, but background processes hit swap"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  free -h              → available (not free) was the early signal"
echo "  vmstat si/so         → non-zero swap out = RAM no longer sufficient"
echo "  /proc/meminfo        → CommitLimit vs Committed_AS = overcommit picture"
echo "  smem -r              → who actually got evicted"
echo ""
echo -e "  ${BOLD}For detailed explanation of every output, what each number means,"
echo -e "  and the full chain of events — read the README:${RESET}"
echo "  ./README.md"
echo ""

pause

info "Cleaning up workers now. Swap will drain automatically."

# wait for cleanup trap to complete then print next scenario
wait 2>/dev/null || true
echo ""
echo -e "${CYAN}Next → Scenario 02: OOM Kill${RESET}"
echo "  ../scenario-02-oom-kill/README.md"
echo ""

#!/bin/bash
# =============================================================
# Scenario 03 — Memory Leak Detection & Containment
# linux-the-hard-way / memory / scenario-03
# =============================================================
# This script runs a Python memory leak in two phases.
# Open two more terminals before running and keep these ready:
#
#   Terminal 2: watch -n3 'ps aux --sort=-%mem | head -10'
#   Terminal 3: sudo dmesg -Tw
#
# Phase 1 — leak running, observe RSS growth
# Phase 2 — cgroup limit applied, watch process hit the ceiling
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
LEAK_PID=""
CGROUP_NAME="memlimit_test"
CGROUP_VERSION=0
CGROUP_PATH=""
MEMORY_LIMIT=$(( 512 * 1024 * 1024 ))   # 512MB hard limit

# ----- cgroup detection ---------------------------------------
detect_cgroup_version() {
    if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        CGROUP_VERSION=2
        CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"
    elif [ -d /sys/fs/cgroup/memory ]; then
        CGROUP_VERSION=1
        CGROUP_PATH="/sys/fs/cgroup/memory/${CGROUP_NAME}"
    else
        CGROUP_VERSION=0
    fi
}

# ----- cleanup on exit ----------------------------------------
cleanup() {
    echo ""
    info "Cleaning up..."

    # Kill the leak process
    if [ -n "$LEAK_PID" ] && kill -0 "$LEAK_PID" 2>/dev/null; then
        kill "$LEAK_PID" 2>/dev/null || true
        success "Leak process stopped."
    fi

    # Kill any stray scenario processes
    pkill -f "scenario3_leak" 2>/dev/null || true

    # Remove cgroup
    if [ -n "$CGROUP_PATH" ] && [ -d "$CGROUP_PATH" ]; then
        if [ "$CGROUP_VERSION" -eq 1 ]; then
            sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
        else
            sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
        fi
        success "Cgroup removed."
    fi

    sleep 2
    success "Cleanup complete. RAM recovering."
    echo ""
    free -h
}
trap cleanup EXIT

# =============================================================
# PREFLIGHT CHECKS
# =============================================================
section "Preflight checks"

if ! command -v python3 &>/dev/null; then
    warn "python3 not found."
    echo "  Install it: sudo apt install python3"
    exit 1
fi
success "python3 found: $(python3 --version)"

detect_cgroup_version
if [ "$CGROUP_VERSION" -eq 0 ]; then
    warn "No cgroup support detected. Phase 2 (cgroup containment) will be skipped."
    warn "Phase 1 (leak observation) will still run."
else
    success "cgroups v${CGROUP_VERSION} detected"
fi

# Check sudo for cgroup operations
if ! sudo -n true 2>/dev/null; then
    info "This script needs sudo to create and manage cgroups."
    info "You will be prompted when Phase 2 starts."
fi

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
CORES=$(nproc)

info "System: ${TOTAL_RAM_GB}Gi RAM | ${CORES} cores | Swap: $(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")Gi"
info "Cgroup limit: 512MB — process will be killed when it hits this ceiling"
echo ""

# =============================================================
# EMBED LEAK SIMULATOR
# =============================================================
# Write the Python leak script to /tmp
cat > /tmp/scenario3_leak.py << 'PYEOF'
import time
import os
import sys

def main():
    collected = []
    iteration = 0
    while True:
        chunk = ' ' * (5 * 1024 * 1024)   # 5MB per iteration
        collected.append(chunk)
        iteration += 1
        time.sleep(3)

if __name__ == "__main__":
    main()
PYEOF

# =============================================================
# BASELINE
# =============================================================
section "Baseline — before the leak starts"

echo "Record these numbers. You will watch available RAM shrink over time."
echo ""
free -h
echo ""
info "Open two more terminals now:"
echo "  Terminal 2: watch -n3 'ps aux --sort=-%mem | head -10'"
echo "  Terminal 3: sudo dmesg -Tw"
echo ""
echo "  Terminal 3 is important — the cgroup OOM kill appears there."

pause

# =============================================================
# PHASE 1 — Leak running, observe RSS growth
# =============================================================
section "Phase 1 — Leak started. Watch RSS grow."

echo "Starting Python leak simulator."
echo "It allocates 5MB every 3 seconds and never frees it."
echo ""

python3 /tmp/scenario3_leak.py &
LEAK_PID=$!

sleep 5

# Confirm it's running
if ! kill -0 "$LEAK_PID" 2>/dev/null; then
    warn "Leak process failed to start. Check python3 installation."
    exit 1
fi

success "Leak process running. PID: ${LEAK_PID}"
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  Terminal 2 (ps)    → python3 RSS growing every few seconds"
echo "  free -h            → available RAM slowly reducing"
echo "  vmstat 1           → mostly quiet — this leak is silent"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  How is this different from Scenario 01 and 02?"
echo "  What makes this harder to detect in production?"

pause

# ----- Phase 1 snapshot: RSS growth ---------------------------
section "Phase 1 — What the system is showing you"

echo "Current memory state:"
free -h
echo ""
echo "Leak process status:"
ps -p "$LEAK_PID" -o pid,rss,vsz,%mem,etime --no-headers 2>/dev/null || \
    echo "  Process no longer running"
echo ""

echo "Tracking RSS growth over 60 seconds (10 readings, 6s apart):"
echo ""
printf "%-12s %-12s %-12s\n" "Time" "RSS (MB)" "VSZ (MB)"
printf "%-12s %-12s %-12s\n" "────────────" "────────────" "────────────"
for i in {1..10}; do
    if kill -0 "$LEAK_PID" 2>/dev/null; then
        RSS=$(cat /proc/$LEAK_PID/status 2>/dev/null | grep VmRSS | awk '{print $2}')
        VSZ=$(cat /proc/$LEAK_PID/status 2>/dev/null | grep VmSize | awk '{print $2}')
        RSS_MB=$(( ${RSS:-0} / 1024 ))
        VSZ_MB=$(( ${VSZ:-0} / 1024 ))
        printf "%-12s %-12s %-12s\n" "$(date '+%H:%M:%S')" "${RSS_MB}" "${VSZ_MB}"
    fi
    sleep 6
done
echo ""

echo "VmPeak vs VmRSS — the leak fingerprint:"
cat /proc/$LEAK_PID/status 2>/dev/null | grep -E 'VmRSS|VmSize|VmSwap|VmPeak' || \
    echo "  Process no longer running"
echo ""

echo "Growth rate calculation:"
RSS1=$(cat /proc/$LEAK_PID/status 2>/dev/null | grep VmRSS | awk '{print $2}' || echo 0)
sleep 30
RSS2=$(cat /proc/$LEAK_PID/status 2>/dev/null | grep VmRSS | awk '{print $2}' || echo 0)
GROWTH_30S=$(( (RSS2 - RSS1) / 1024 ))
GROWTH_HOUR=$(( GROWTH_30S * 120 ))
echo "  Growth in 30s:      ${GROWTH_30S} MB"
echo "  Projected per hour: ${GROWTH_HOUR} MB"
echo ""

echo "RSS vs VmPeak across top memory consumers:"
for pid in $(ps aux --sort=-%mem | awk 'NR>1{print $2}' | head -8); do
    rss=$(cat /proc/$pid/status 2>/dev/null | grep VmRSS | awk '{print $2}')
    peak=$(cat /proc/$pid/status 2>/dev/null | grep VmPeak | awk '{print $2}')
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    [ -n "$rss" ] && printf "  %-20s RSS: %-10s Peak: %s\n" \
        "$comm" "${rss}kB" "${peak}kB"
done 2>/dev/null
echo ""
info "Which process has RSS ≈ Peak? That's your leak."

pause

# =============================================================
# PHASE 2 — Cgroup limit applied
# =============================================================
section "Phase 2 — Applying cgroup memory limit"

if [ "$CGROUP_VERSION" -eq 0 ]; then
    warn "No cgroup support on this system. Skipping Phase 2."
    warn "On a native Linux machine or VM, this phase applies a 512MB hard limit"
    warn "and demonstrates a cgroup-scoped OOM kill."
else
    echo "Applying a 512MB hard memory limit to the leak process."
    echo "The leak will continue until it hits the ceiling — then the kernel kills it."
    echo "The rest of the system will be completely unaffected."
    echo ""

    if [ "$CGROUP_VERSION" -eq 1 ]; then
        sudo mkdir -p "$CGROUP_PATH"
        echo "$MEMORY_LIMIT" | sudo tee "${CGROUP_PATH}/memory.limit_in_bytes" > /dev/null
        echo "$MEMORY_LIMIT" | sudo tee "${CGROUP_PATH}/memory.memsw.limit_in_bytes" > /dev/null 2>&1 || true
        echo "$LEAK_PID" | sudo tee "${CGROUP_PATH}/tasks" > /dev/null
        USAGE_FILE="${CGROUP_PATH}/memory.usage_in_bytes"
    else
        sudo mkdir -p "$CGROUP_PATH"
        echo "$MEMORY_LIMIT" | sudo tee "${CGROUP_PATH}/memory.max" > /dev/null
        echo "$LEAK_PID" | sudo tee "${CGROUP_PATH}/cgroup.procs" > /dev/null
        USAGE_FILE="${CGROUP_PATH}/memory.current"
    fi

    LIMIT_MB=$(( MEMORY_LIMIT / 1024 / 1024 ))
    CURRENT_USAGE=$(cat "$USAGE_FILE" 2>/dev/null || echo 0)
    CURRENT_MB=$(( CURRENT_USAGE / 1024 / 1024 ))

    success "Cgroup limit applied."
    echo "  Hard limit:    ${LIMIT_MB} MB"
    echo "  Current usage: ${CURRENT_MB} MB"
    echo ""
    echo -e "  ${BOLD}What to look for:${RESET}"
    echo "  Terminal 3 (dmesg)  → cgroup OOM kill message"
    echo "  Terminal 2 (ps)     → python3 disappears from the list"
    echo "  free -h             → available RAM recovers after kill"
    echo ""
    echo -e "  ${BOLD}Key question:${RESET}"
    echo "  How does this OOM kill differ from Scenario 02?"
    echo "  What happens to the rest of the system?"
    echo ""

    # Monitor usage until OOM fires — no timeout, waits as long as needed
    info "Watching cgroup usage climb toward ${LIMIT_MB}MB ceiling..."
    info "Script will wait here until the process is killed. Check Terminal 3."
    echo ""

    ELAPSED=0
    while kill -0 "$LEAK_PID" 2>/dev/null; do
        sleep 10
        ELAPSED=$(( ELAPSED + 10 ))
        CURRENT=$(cat "$USAGE_FILE" 2>/dev/null || echo 0)
        CURRENT_MB=$(( CURRENT / 1024 / 1024 ))
        PCT=$(awk "BEGIN {printf \"%.0f\", ($CURRENT / $MEMORY_LIMIT) * 100}")
        echo -e "  ${ELAPSED}s — Usage: ${CURRENT_MB}MB / ${LIMIT_MB}MB (${PCT}%)"
    done

    echo ""
    success "Process killed by cgroup OOM at ${ELAPSED}s."

    pause

    # ----- Phase 2 snapshot -----------------------------------
    section "Phase 2 — What dmesg captured"

    echo "Recent OOM events:"
    sudo dmesg 2>/dev/null | grep -i "oom\|killed process\|out of memory\|memlimit" | tail -10 \
        || echo "  (none — check Terminal 3 for full output)"
    echo ""
    echo "Is the leak process still running?"
    ps aux | grep scenario3_leak | grep -v grep || echo "  (no — killed by cgroup OOM)"
    echo ""
    echo "Memory state after kill:"
    free -h

    pause
fi

# =============================================================
# SUMMARY
# =============================================================
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Silent growth    — RSS climbed continuously, no swap spike, no OOM"
echo "  2. Leak fingerprint — VmPeak ≈ VmRSS means memory was never freed"
echo "  3. Growth rate      — two RSS snapshots 30s apart = incident report number"
echo "  4. Cgroup kill      — surgical, contained, rest of system unaffected"
echo "  5. K8s connection   — this is exactly what pod OOMKilled looks like at kernel level"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  ps aux --sort=-%mem          → spot the RSS outlier"
echo "  /proc/<pid>/status VmPeak    → fastest leak signal"
echo "  RSS snapshot diff            → growth rate and time to OOM"
echo "  /proc/<pid>/smaps            → confirm physical vs virtual"
echo "  dmesg cgroup OOM             → contained kill vs global OOM"
echo ""
echo -e "  ${BOLD}For detailed explanation of every output, what each number means,"
echo -e "  and the full chain of events — read the README:${RESET}"
echo "  ./README.md"
echo ""

pause

info "Cleaning up leak process and cgroup..."

wait 2>/dev/null || true
echo ""
echo -e "${CYAN}Next → Scenario 04: Page Cache${RESET}"
echo "  ../scenario-04-page-cache/README.md"
echo ""

#!/bin/bash
# =============================================================
# Scenario 04 — Page Cache Behavior
# linux-the-hard-way / memory / scenario-04
# =============================================================
# This script is an observation exercise, not a breakage scenario.
# Open two more terminals before running:
#
#   Terminal 2: vmstat 1
#   Terminal 3: sudo dmesg -Tw
#
# Phase 1 — file written, cache grows
# Phase 2 — cold read vs warm read
# Phase 3 — drop_caches, watch cache clear and refill
# Phase 4 — memory pressure, watch cache eviction order
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
TEST_FILE="/tmp/pagecache_test"
PIDS=()

# ----- cleanup on exit ----------------------------------------
cleanup() {
    echo ""
    info "Cleaning up..."
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    pkill -f stress-ng 2>/dev/null || true
    rm -f "$TEST_FILE"
    success "Test file removed. Workers stopped."
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

if ! command -v dd &>/dev/null; then
    warn "dd not found — required for file creation."
    exit 1
fi
success "dd found"

# Check sudo for drop_caches
if ! sudo -n true 2>/dev/null; then
    info "This script needs sudo to drop page cache."
    info "You will be prompted when Phase 3 starts."
fi

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
AVAIL_RAM_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
CORES=$(nproc)

# ----- dynamic file size calculation --------------------------
# Test file = 40% of available RAM
# Large enough to clearly show cache growth
# Small enough to fit in RAM and leave room for pressure phase
FILE_SIZE_KB=$(awk "BEGIN {printf \"%d\", $AVAIL_RAM_KB * 0.40}")
FILE_SIZE_MB=$(awk "BEGIN {printf \"%.0f\", $FILE_SIZE_KB / 1024}")
FILE_SIZE_GB=$(awk "BEGIN {printf \"%.1f\", $FILE_SIZE_KB / 1024 / 1024}")

# Workers for Phase 4 pressure
# --vm-bytes is per worker against available RAM at launch time
# 2 workers x 90% = ~12Gi demanded — forces cache eviction, swap absorbs overflow
PHASE4_WORKERS=2
PHASE4_PCT=90

info "System: ${TOTAL_RAM_GB}Gi RAM | ${CORES} cores | Swap: $(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")Gi"
info "Test file size: ${FILE_SIZE_GB}Gi (40% of available RAM)"
info "Phase 4 pressure: ${PHASE4_WORKERS} workers × ${PHASE4_PCT}% RAM each"
echo ""

# =============================================================
# BASELINE
# =============================================================
section "Baseline — before any activity"

echo "Record these numbers. You will compare them after each phase."
echo ""
free -h
echo ""
echo "Cache breakdown:"
cat /proc/meminfo | grep -E 'Cached|Mapped|KReclaimable|Unevictable|SwapCached'
echo ""
echo "Active vs Inactive split:"
cat /proc/meminfo | grep -E '^Active|^Inactive'
echo ""
echo "min_free_kbytes (kernel memory floor):"
cat /proc/sys/vm/min_free_kbytes
echo ""
info "Open two more terminals now:"
echo "  Terminal 2: vmstat 1"
echo "  Terminal 3: sudo dmesg -Tw"

pause

# =============================================================
# PHASE 1 — Write file, watch cache grow
# =============================================================
section "Phase 1 — Writing ${FILE_SIZE_GB}Gi test file"

echo "Creating a ${FILE_SIZE_GB}Gi file using dd."
echo "Watch Terminal 2 (vmstat) — bo should spike as dirty pages flush to disk."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  vmstat bo    → data flowing from RAM to disk"
echo "  free -h      → does available change as cache grows?"
echo "  buff/cache   → does it grow by roughly ${FILE_SIZE_GB}Gi?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  If buff/cache grows by ${FILE_SIZE_GB}Gi, why doesn't available shrink by the same amount?"

pause

info "Writing file — this may take a moment..."
dd if=/dev/zero of="$TEST_FILE" bs=1M count="$FILE_SIZE_MB" 2>&1 | tail -1
sync
success "File written: ${FILE_SIZE_GB}Gi at ${TEST_FILE}"

echo ""
section "Phase 1 — What the system is showing you"

echo "Memory state after write:"
free -h
echo ""
echo "Cache breakdown:"
cat /proc/meminfo | grep -E 'Cached|Mapped|KReclaimable'
echo ""
info "Notice: buff/cache grew but available stayed similar."
info "Cache is reclaimable — it doesn't reduce what processes can use."

pause

# =============================================================
# PHASE 2 — Cold read vs warm read
# =============================================================
section "Phase 2 — Cold read vs warm read"

echo "First we drop the cache to simulate a cold read."
echo "Then we read the file twice — once cold, once warm."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  vmstat bi    → spikes on cold read (from disk), near zero on warm read"
echo "  time output  → how much faster is the warm read?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  What does the time difference tell you about why the kernel caches aggressively?"

pause

info "Dropping cache for cold read..."
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
sleep 2
echo ""
echo "Cache state after drop:"
free -h
echo ""

info "Cold read — file coming from disk:"
COLD_TIME=$( { time cat "$TEST_FILE" > /dev/null; } 2>&1 | grep real | awk '{print $2}')
echo "  Cold read time: ${COLD_TIME}"
echo ""

info "Warm read — file served from cache:"
WARM_TIME=$( { time cat "$TEST_FILE" > /dev/null; } 2>&1 | grep real | awk '{print $2}')
echo "  Warm read time: ${WARM_TIME}"
echo ""

section "Phase 2 — What the system is showing you"

echo "Read times:"
echo "  Cold (from disk):  ${COLD_TIME}"
echo "  Warm (from cache): ${WARM_TIME}"
echo ""
echo "Memory state after warm read:"
free -h
echo ""
echo "Active vs Inactive split:"
cat /proc/meminfo | grep -E '^Active|^Inactive'
echo ""
info "Notice: Active(file) grew after the warm read — recently accessed pages promoted."

pause

# =============================================================
# PHASE 3 — drop_caches
# =============================================================
section "Phase 3 — drop_caches"

echo "Dropping all cache manually."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  free -h      → buff/cache drops, but does available change much?"
echo "  After drop   → read the file again and watch cache refill"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  If drop_caches frees memory, why isn't it a fix for a memory leak?"

pause

echo "Before drop:"
free -h
echo ""

info "Dropping page cache, dentries, and inodes..."
echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
sleep 1

echo ""
echo "After drop:"
free -h
echo ""

info "Reading file again to watch cache refill..."
time cat "$TEST_FILE" > /dev/null
echo ""

section "Phase 3 — What the system is showing you"

echo "Cache state after refill:"
free -h
echo ""
cat /proc/meminfo | grep -E 'Cached|Mapped'
echo ""
info "Cache refilled automatically. drop_caches is temporary — always refills."
info "If you have a memory leak, drop_caches buys seconds. Find the leak instead."

pause

# =============================================================
# PHASE 4 — Memory pressure, cache eviction
# =============================================================
section "Phase 4 — Memory pressure, cache eviction order"

echo "Starting ${PHASE4_WORKERS} stress-ng workers to consume free RAM."
echo "Watch which cache gets evicted first — Active or Inactive."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  /proc/meminfo Active/Inactive → which list shrinks faster?"
echo "  vmstat bi                     → spikes when evicted cache re-read from disk"
echo "  vmstat si/so                  → swap only if anonymous pages evicted"
echo "  free -h buff/cache            → how much cache survives under pressure?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  Why does Inactive(file) get evicted before Active(anon)?"
echo "  What does that tell you about how the kernel values different types of memory?"

pause

echo "Memory state before pressure:"
free -h
echo ""
echo "Active vs Inactive before pressure:"
cat /proc/meminfo | grep -E '^Active|^Inactive'
echo ""

stress-ng --vm "$PHASE4_WORKERS" --vm-bytes "${PHASE4_PCT}%" \
    --vm-keep --vm-populate --timeout 180s &
PIDS+=($!)

sleep 8

info "Workers running. Observing cache eviction..."
echo ""

# Show state every 15 seconds for 120 seconds
for i in 1 2 3 4 5 6 7 8; do
    sleep 15
    echo -e "${BOLD}── ${i}5s ──────────────────────────────────────${RESET}"
    free -h
    echo ""
    cat /proc/meminfo | grep -E '^Active|^Inactive'
    echo ""
done

section "Phase 4 — What the system is showing you"

echo "Final memory state under pressure:"
free -h
echo ""
echo "Active vs Inactive under pressure:"
cat /proc/meminfo | grep -E '^Active|^Inactive'
echo ""
echo "vmstat snapshot (5 readings):"
vmstat 1 5
echo ""
info "Compare Active(file) and Inactive(file) to your baseline."
info "Inactive(file) should have shrunk more — it's evicted first, cheapest to reclaim."

pause

# =============================================================
# SUMMARY
# =============================================================
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Cache growth     — buff/cache grew but available stayed the same"
echo "  2. 19x speedup      — warm reads served from RAM, cold reads hit disk"
echo "  3. drop_caches      — temporary relief only, cache refills immediately"
echo "  4. Eviction order   — Inactive(file) first, Active(anon) last"
echo "  5. bi vs si/so      — bi for file IO, si/so only when swap involved"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  free -h available              → the only number that matters"
echo "  /proc/meminfo Active/Inactive  → eviction candidates"
echo "  /proc/meminfo Cached/Mapped    → reclaimable vs locked cache"
echo "  vmstat bi/bo                   → disk IO layer"
echo "  vmstat si/so                   → swap layer (subset of bi/bo)"
echo ""
echo -e "  ${BOLD}For detailed explanation of every output, what each number means,"
echo -e "  and the full chain of events — read the README:${RESET}"
echo "  ./README.md"
echo ""

pause

info "Cleaning up workers and test file..."

wait 2>/dev/null || true
echo ""
echo -e "${CYAN}Next → Scenario 05: Swap Thrashing${RESET}"
echo "  ../scenario-05-swap-thrashing/README.md"
echo ""

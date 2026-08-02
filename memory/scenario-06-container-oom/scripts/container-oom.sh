#!/bin/bash
# =============================================================
# Scenario 06 — OOM Inside Containers & Cgroups
# linux-the-hard-way / memory / scenario-06
# =============================================================
# This script launches a Docker container with a memory limit,
# triggers cgroup-scoped OOM kills, and checks for unprotected
# containers on your system.
#
# Open two more terminals before running:
#
#   Terminal 2: watch -n1 'free -h'
#   Terminal 3: sudo dmesg -Tw
#
# Phase 1 — container launched with 512MB limit
# Phase 2 — stress-ng inside container exceeds limit
# Phase 3 — check all containers for missing limits
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
CONTAINER_NAME="memory-test"
MEMORY_LIMIT="512m"
CONTAINER_ID=""
CGROUP_PATH=""

# ----- cleanup on exit ----------------------------------------
cleanup() {
    echo ""
    info "Cleaning up..."
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    success "Container ${CONTAINER_NAME} stopped and removed."
    echo ""
    free -h
}
trap cleanup EXIT

# =============================================================
# PREFLIGHT CHECKS
# =============================================================
section "Preflight checks"

# Check Docker
if ! command -v docker &>/dev/null; then
    warn "Docker not found."
    echo "  Install Docker: https://docs.docker.com/engine/install/"
    exit 1
fi
success "Docker found: $(docker --version)"

# Check Docker daemon
if ! docker ps &>/dev/null; then
    warn "Docker daemon is not running."
    echo "  Start it: sudo service docker start"
    exit 1
fi
success "Docker daemon running"

# Check stress-ng image availability
info "Pulling stress-ng image if needed..."
docker pull polinux/stress-ng 2>/dev/null | tail -1 || \
    docker pull alexeiled/stress-ng 2>/dev/null | tail -1 || true

# ----- system profile -----------------------------------------
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$(awk "BEGIN {printf \"%.1f\", $TOTAL_RAM_KB/1024/1024}")
SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')

info "System: ${TOTAL_RAM_GB}Gi RAM | Swap: $(awk "BEGIN {printf \"%.1f\", $SWAP_KB/1024/1024}")Gi"
info "Container: ${CONTAINER_NAME} with ${MEMORY_LIMIT} memory limit"
echo ""

# =============================================================
# BASELINE
# =============================================================
section "Baseline — before container starts"

echo "Record these numbers."
echo ""
free -h
echo ""
echo "Currently running containers:"
docker stats --no-stream 2>/dev/null || echo "  (no containers running)"
echo ""
info "Open two more terminals now:"
echo "  Terminal 2: watch -n1 'free -h'"
echo "  Terminal 3: sudo dmesg -Tw"

pause

# =============================================================
# PHASE 1 — Launch container with memory limit
# =============================================================
section "Phase 1 — Launching container with ${MEMORY_LIMIT} limit"

echo "Starting container with a hard 512MB memory limit."
echo "Docker will create a cgroup automatically."
echo ""

# Remove any leftover container from a previous run
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Launch container with ubuntu — keeps running via sleep
# stress-ng installed inside after container starts
docker run -d \
    --name "$CONTAINER_NAME" \
    --memory "${MEMORY_LIMIT}" \
    --memory-swap "${MEMORY_LIMIT}" \
    ubuntu:22.04 \
    sleep 3600

sleep 2

# Get container ID and cgroup path
CONTAINER_ID=$(docker inspect --format '{{.Id}}' "$CONTAINER_NAME")
CGROUP_PATH="/sys/fs/cgroup/memory/docker/${CONTAINER_ID}"
CGROUP_VERSION=1

if [ ! -d "$CGROUP_PATH" ]; then
    # Try cgroups v2 paths
    V2_PATH1="/sys/fs/cgroup/system.slice/docker-${CONTAINER_ID}.scope"
    V2_PATH2="/sys/fs/cgroup/docker/${CONTAINER_ID}"
    V2_PATH3=$(find /sys/fs/cgroup -name "memory.max" 2>/dev/null |         xargs grep -l "" 2>/dev/null |         while read f; do
            dir=$(dirname "$f")
            if echo "$dir" | grep -q "${CONTAINER_ID:0:12}"; then
                echo "$dir"
                break
            fi
        done | head -1)

    if [ -d "$V2_PATH1" ]; then
        CGROUP_PATH="$V2_PATH1"
        CGROUP_VERSION=2
    elif [ -d "$V2_PATH2" ]; then
        CGROUP_PATH="$V2_PATH2"
        CGROUP_VERSION=2
    elif [ -n "$V2_PATH3" ]; then
        CGROUP_PATH="$V2_PATH3"
        CGROUP_VERSION=2
    else
        warn "Could not find cgroup path for container."
        warn "Manually check: find /sys/fs/cgroup -name '*${CONTAINER_ID:0:12}*' -type d"
        CGROUP_VERSION=0
    fi
fi

success "Container started. ID: ${CONTAINER_ID:0:12}..."
success "Cgroup: ${CGROUP_PATH}"
echo ""

echo -e "  ${BOLD}What to look for:${RESET}"
echo "  Does the cgroup path exist?"
echo "  What is memory.limit_in_bytes set to?"
echo "  What does free -h show inside the container?"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  The container was launched with 512MB limit."
echo "  What will free -h show inside the container — 512MB or something else?"

pause

# ----- Phase 1 snapshot ---------------------------------------
section "Phase 1 — What the system is showing you"

echo "Cgroup created by Docker:"
ls "$CGROUP_PATH/" 2>/dev/null | head -20 || warn "Cgroup path not accessible"
echo ""

echo "Enforced memory limit:"
if [ "${CGROUP_VERSION:-1}" -eq 2 ]; then
    LIMIT_BYTES=$(cat "${CGROUP_PATH}/memory.max" 2>/dev/null || echo "536870912")
    # cgroups v2 memory.max can return "max" string if unlimited
    if [ "$LIMIT_BYTES" = "max" ]; then LIMIT_BYTES="536870912"; fi
    echo "  memory.max: ${LIMIT_BYTES} bytes"
else
    LIMIT_BYTES=$(cat "${CGROUP_PATH}/memory.limit_in_bytes" 2>/dev/null || echo "536870912")
    echo "  memory.limit_in_bytes: ${LIMIT_BYTES} bytes"
fi
LIMIT_MB=512
if echo "$LIMIT_BYTES" | grep -qE "^[0-9]+$"; then
    LIMIT_MB=$(( LIMIT_BYTES / 1024 / 1024 ))
fi
echo "  Enforced limit: ${LIMIT_MB}MB"
echo ""

echo "What the container thinks it has (free -h inside container):"
docker exec "$CONTAINER_NAME" apt-get install -y -qq procps 2>/dev/null | tail -1 || true
docker exec "$CONTAINER_NAME" free -h 2>/dev/null || warn "Could not run free -h inside container"
echo ""

echo "OOM events before stress starts:"
if [ "${CGROUP_VERSION:-1}" -eq 2 ]; then
    cat "${CGROUP_PATH}/memory.events" 2>/dev/null || warn "memory.events not readable"
else
    cat "${CGROUP_PATH}/memory.oom_control" 2>/dev/null || warn "oom_control not readable"
fi
echo ""

info "Notice: free -h inside the container shows host RAM, not the 512MB limit."
info "Applications reading /proc/meminfo inside containers get wrong information."

pause

# =============================================================
# PHASE 2 — stress-ng exceeds the limit
# =============================================================
section "Phase 2 — Running stress-ng inside container"

echo "Installing and running stress-ng inside the container."
echo "It will continuously exceed the 512MB limit."
echo "Watch oom_kill in memory.oom_control climb."
echo ""
echo -e "  ${BOLD}What to look for:${RESET}"
echo "  memory.oom_control oom_kill → growing silently"
echo "  docker stats                → container still alive despite kills"
echo "  Terminal 2 (free -h)        → host RAM barely affected"
echo "  Terminal 3 (dmesg)          → cgroup OOM, not global OOM"
echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  The container is being OOM killed repeatedly."
echo "  Why does it stay alive? Why doesn't the host feel it?"

pause

# Install stress-ng inside container if needed
docker exec "$CONTAINER_NAME" which stress-ng &>/dev/null || {
    info "Installing stress-ng inside container..."
    docker exec "$CONTAINER_NAME" apt-get update -qq 2>/dev/null || true
    docker exec "$CONTAINER_NAME" apt-get install -y -qq stress-ng 2>/dev/null || true
}

# Run stress-ng inside container in background
# --vm-bytes 800m per worker exceeds 512MB container limit immediately
# --vm-populate forces immediate page touching = OOM kills fire within seconds
docker exec "$CONTAINER_NAME" bash -c     "nohup stress-ng --vm 6 --vm-bytes 480m --vm-keep --vm-populate --timeout 120s > /tmp/stress.log 2>&1 &"
sleep 3

# Verify it started
STRESS_PIDS=$(docker exec "$CONTAINER_NAME" pgrep stress-ng 2>/dev/null | wc -l || echo 0)
if [ "$STRESS_PIDS" -eq 0 ]; then
    warn "stress-ng failed to start inside container. Trying alternative..."
    docker exec "$CONTAINER_NAME" bash -c         "nohup stress-ng --vm 4 --vm-bytes 480m --vm-keep --vm-populate --timeout 120s > /tmp/stress.log 2>&1 &"
    sleep 3
fi
STRESS_PIDS=$(docker exec "$CONTAINER_NAME" pgrep stress-ng 2>/dev/null | wc -l || echo 0)
info "stress-ng processes running inside container: ${STRESS_PIDS}"

info "stress-ng running inside container. Monitoring oom_kill counter..."
echo ""

# Monitor oom_kill counter
PREV_OOM=0
for i in {1..12}; do
    sleep 10
    if [ "${CGROUP_VERSION:-1}" -eq 2 ]; then
        OOM_KILL=$(cat "${CGROUP_PATH}/memory.events" 2>/dev/null | grep "^oom_kill" | awk '{print $2}' || echo "0")
        UNDER_OOM=$(cat "${CGROUP_PATH}/memory.events" 2>/dev/null | grep "^oom" | wc -l || echo "0")
        USAGE=$(cat "${CGROUP_PATH}/memory.current" 2>/dev/null || echo "0")
    else
        OOM_KILL=$(cat "${CGROUP_PATH}/memory.oom_control" 2>/dev/null | grep "^oom_kill" | awk '{print $2}' || echo "0")
        UNDER_OOM=$(cat "${CGROUP_PATH}/memory.oom_control" 2>/dev/null | grep "under_oom" | awk '{print $2}' || echo "0")
        USAGE=$(cat "${CGROUP_PATH}/memory.usage_in_bytes" 2>/dev/null || echo "0")
    fi
    # Sanitise all values — strip whitespace/newlines before arithmetic
    USAGE=$(echo "${USAGE}" | tr -d '[:space:]')
    OOM_KILL=$(echo "${OOM_KILL}" | tr -d '[:space:]')
    UNDER_OOM=$(echo "${UNDER_OOM}" | tr -d '[:space:]')
    PREV_OOM=$(echo "${PREV_OOM}" | tr -d '[:space:]')
    # Default to 0 if empty or non-numeric
    [[ "$USAGE" =~ ^[0-9]+$ ]] || USAGE=0
    [[ "$OOM_KILL" =~ ^[0-9]+$ ]] || OOM_KILL=0
    [[ "$UNDER_OOM" =~ ^[0-9]+$ ]] || UNDER_OOM=0
    [[ "$PREV_OOM" =~ ^[0-9]+$ ]] || PREV_OOM=0
    USAGE_MB=$(( USAGE / 1024 / 1024 ))
    DELTA=$(( OOM_KILL - PREV_OOM ))
    echo -e "  ${i}0s — Usage: ${USAGE_MB}MB/${LIMIT_MB}MB | oom_kill: ${OOM_KILL} (+${DELTA}) | under_oom: ${UNDER_OOM}"
    PREV_OOM=$OOM_KILL

    if [ "$OOM_KILL" -gt 5 ]; then
        echo ""
        success "Cgroup OOM kills confirmed. Container silently struggling."
        break
    fi
done

pause

# ----- Phase 2 snapshot ---------------------------------------
section "Phase 2 — What the system is showing you"

echo "Container stats:"
docker stats "$CONTAINER_NAME" --no-stream
echo ""

echo "OOM events after stress:"
if [ "${CGROUP_VERSION:-1}" -eq 2 ]; then
    cat "${CGROUP_PATH}/memory.events" 2>/dev/null || warn "memory.events not readable"
else
    cat "${CGROUP_PATH}/memory.oom_control" 2>/dev/null || warn "oom_control not readable"
fi
echo ""

echo "Host memory impact:"
free -h
echo ""

echo "OOM scope in dmesg:"
sudo dmesg 2>/dev/null | grep -i "oom\|killed" | tail -10 || \
    echo "  (check Terminal 3 for full output)"
echo ""

info "Notice: host available RAM is mostly unchanged."
info "The cgroup absorbed all the OOM pressure — host never knew."

pause

# =============================================================
# PHASE 3 — Check all containers for missing limits
# =============================================================
section "Phase 3 — Container memory audit"

echo "Checking all running containers for memory limits."
echo "Any container showing host total RAM has no real limit."
echo ""

echo "docker stats (all containers):"
docker stats --no-stream
echo ""

# Flag unlimited containers
echo "Memory limit audit:"
HOST_RAM_BYTES=$(( TOTAL_RAM_KB * 1024 ))
UNLIMITED_COUNT=0

for id in $(docker ps -q); do
    name=$(docker inspect --format '{{.Name}}' "$id" | sed 's/\///')
    limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$id")
    if [ "$limit" -eq 0 ] || [ "$limit" -ge "$HOST_RAM_BYTES" ]; then
        echo -e "  ${RED}[NO LIMIT]${RESET} ${name} — can consume all host RAM"
        UNLIMITED_COUNT=$(( UNLIMITED_COUNT + 1 ))
    else
        limit_mb=$(( limit / 1024 / 1024 ))
        echo -e "  ${GREEN}[LIMITED]${RESET}  ${name} — ${limit_mb}MB"
    fi
done

echo ""
if [ "$UNLIMITED_COUNT" -gt 0 ]; then
    warn "${UNLIMITED_COUNT} container(s) have no memory limit."
    warn "Fix: docker update --memory 2g --memory-swap 2g <container-name>"
else
    success "All containers have memory limits set."
fi

echo ""
echo -e "  ${BOLD}Key question:${RESET}"
echo "  What happens if an unlimited container has a memory leak?"
echo "  Who protects the host and other containers?"

pause

# ----- Phase 3 snapshot ---------------------------------------
section "Phase 3 — What the system is showing you"

echo "oom_kill count across all containers:"
for id in $(docker ps -q); do
    name=$(docker inspect --format '{{.Name}}' "$id" | sed 's/\///')
    # Try both cgroup v1 and v2 paths
    cgroup_v1="/sys/fs/cgroup/memory/docker/${id}"
    cgroup_v2="/sys/fs/cgroup/system.slice/docker-${id}.scope"
    if [ -f "${cgroup_v2}/memory.events" ]; then
        oom=$(cat "${cgroup_v2}/memory.events" 2>/dev/null | grep "^oom_kill" | awk '{print $2}' || echo "0")
    elif [ -f "${cgroup_v1}/memory.events" ]; then
        oom=$(cat "${cgroup_v1}/memory.events" 2>/dev/null | grep "^oom_kill" | awk '{print $2}' || echo "0")
    elif [ -f "${cgroup_v1}/memory.oom_control" ]; then
        oom=$(cat "${cgroup_v1}/memory.oom_control" 2>/dev/null | grep "^oom_kill" | awk '{print $2}' || echo "0")
        if [ "$oom" -gt 0 ]; then
            echo -e "  ${RED}${name}: oom_kill=${oom}${RESET} ← silently struggling"
        else
            echo -e "  ${GREEN}${name}: oom_kill=${oom}${RESET} ← healthy"
        fi
    else
        echo "  ${name}: cgroup not accessible"
    fi
done

pause

# =============================================================
# SUMMARY
# =============================================================
section "Scenario complete"

echo -e "  ${BOLD}What you just observed:${RESET}"
echo ""
echo "  1. Docker limit = cgroup   — --memory flag sets memory.limit_in_bytes"
echo "  2. /proc/meminfo lies      — container sees host RAM, not its limit"
echo "  3. oom_kill is the signal  — silent kills, container stays alive"
echo "  4. Host isolation          — cgroup OOM never touched host RAM"
echo "  5. Unlimited = unprotected — containers without limits are a host risk"
echo ""
echo -e "  ${BOLD}Commands that told the story:${RESET}"
echo "  cat memory.oom_control           → silent kill counter"
echo "  cat memory.limit_in_bytes        → enforced ceiling"
echo "  cat memory.usage_in_bytes        → actual consumption"
echo "  docker stats --no-stream         → production health view"
echo "  docker inspect | grep Memory     → limit configuration"
echo ""
echo -e "  ${BOLD}For detailed explanation of every output, what each number means,"
echo -e "  and the full chain of events — read the README:${RESET}"
echo "  ./README.md"
echo ""

pause

info "Stopping and removing container ${CONTAINER_NAME}..."

wait 2>/dev/null || true
echo ""
echo -e "${CYAN}Next → Scenario 07: Blind Diagnosis${RESET}"
echo "  ../scenario-07-blind-diagnosis/README.md"
echo ""

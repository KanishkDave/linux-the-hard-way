# Memory Commands — Complete Reference

> This file covers every command used across all 7 memory scenarios.  
> You don't need to memorise any of this. Use it as a lookup reference  
> when a command's output doesn't make sense, or when you want to go  
> deeper than the scenario README covers.
>
> **Don't be discouraged when you don't immediately know what a value  
> means or what a flag does.** That uncertainty is part of the process —  
> it's exactly what an incident feels like. Google it, check the man page,  
> ask an AI. Looking things up under pressure is a skill too.  
> The goal isn't memorisation. It's pattern recognition.

---

## Table of Contents

1. [First Look Commands](#1-first-look-commands)
2. [Process Deep Dive](#2-process-deep-dive)
3. [Swap Investigation](#3-swap-investigation)
4. [OOM Investigation](#4-oom-investigation)
5. [Page Cache Investigation](#5-page-cache-investigation)
6. [Thrashing Detection](#6-thrashing-detection)
7. [Kernel Tuning Parameters](#7-kernel-tuning-parameters)
8. [Container Memory](#8-container-memory)
9. [Historical Analysis](#9-historical-analysis)
10. [Health Signals vs Problem Signals](#10-health-signals-vs-problem-signals)
11. [Triage Checklists](#11-triage-checklists)
12. [Monitoring & Alerting](#12-monitoring--alerting)
13. [Incident Runbook Template](#13-incident-runbook-template)

---

## 1. First Look Commands

Run these immediately when something feels wrong. In this order.

```bash
# Overall memory state — always start here
free -h

# Live memory + swap + IO + CPU — run for at least 30 seconds
vmstat 1 30

# Top memory consumers right now
ps aux --sort=-%mem | head -15

# Detailed memory breakdown
cat /proc/meminfo

# Any OOM kills already happened?
sudo dmesg -T | grep -i oom | tail -10
```

**From these 5 commands you can determine:**
- How bad is the situation (`available` RAM)
- Is swap involved (`vmstat` `si`/`so`)
- Who is responsible (`ps`)
- Has anything died (`dmesg`)
- How close to the edge (`CommitLimit` vs `Committed_AS`)

---

## 2. Process Deep Dive

Once you know which process is the suspect:

```bash
# Full memory profile of a specific process
cat /proc/<pid>/status | grep -E 'VmPeak|VmSize|VmRSS|VmHWM|VmSwap|VmData|VmStk'

# Per-process swap usage — who got evicted
smem -r | head -20

# USS/PSS/RSS comparison across all processes
smem -r -k | head -20

# Detailed memory region breakdown
cat /proc/<pid>/smaps_rollup
```

**What the /proc/<pid>/status fields mean:**

| Field | Meaning |
|-------|---------|
| `VmPeak` | Highest RSS ever reached — compare to current VmRSS |
| `VmSize` | Total virtual address space (VSZ) — the promise |
| `VmRSS` | Physical RAM currently occupied |
| `VmHWM` | High water mark — peak physical RAM used |
| `VmSwap` | How much of this process is currently in swap |
| `VmData` | Heap size — growing continuously = leak signal |
| `VmStk` | Stack size |

**Tracking RSS growth over time:**

```bash
# Watch one process for 5 minutes, sample every 30 seconds
for i in {1..10}; do
    rss=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
    echo "$(date '+%H:%M:%S')  RSS: $((rss/1024)) MB"
    sleep 30
done
```

**Interpreting VmPeak vs VmRSS:**

```
VmPeak ≈ VmRSS     → process has never freed anything = leak suspect
VmPeak >> VmRSS    → healthy — memory has been freed over time
VmRSS growing at constant rate → classic leak
VmData growing     → heap expanding, confirms leak
```

---

## 3. Swap Investigation

```bash
# Current swap usage overall
free -h
swapon --show

# Per-process swap usage sorted by swap
smem -r | sort -k3 -rn | head -10

# Live swap activity rate
vmstat 1 | awk '{print $7, $8}'   # si and so columns only

# Raw swap counters from kernel
cat /proc/vmstat | grep -E 'pswpin|pswpout'

# Calculate swap out rate over 10 seconds
S1=$(cat /proc/vmstat | grep pswpout | awk '{print $2}')
sleep 10
S2=$(cat /proc/vmstat | grep pswpout | awk '{print $2}')
echo "Swap out rate: $(( (S2-S1)/10 )) pages/sec"
```

**Key signals:**

| Signal | What it means |
|--------|--------------|
| `so` non-zero, `si` = 0 | Evicting pages — memory pressure building |
| `si` non-zero, `so` = 0 | Reading back swapped pages — recovering |
| Both `si` and `so` non-zero | Thrashing — pages moving in both directions |
| `swpd` in vmstat growing | Swap accumulating over time |
| `VmSwap` on background process | That process got evicted — may be slow |

---

## 4. OOM Investigation

```bash
# OOM kill history
sudo dmesg -T | grep -i oom

# OOM kill with full context
sudo dmesg -T | grep -B5 -A20 "Out of memory"

# Current OOM scores — who is most at risk right now
for pid in $(ls /proc | grep '^[0-9]'); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    [ -n "$score" ] && printf "Score:%-6s Adj:%-6s PID:%-8s %s\n" \
        $score $adj $pid $comm
done 2>/dev/null | sort -rn | head -15

# Overcommit state
cat /proc/meminfo | grep -E 'CommitLimit|Committed_AS'

# Protect a critical process from OOM kill
echo -500 | sudo tee /proc/<pid>/oom_score_adj

# Make a process the preferred OOM target (stress tests)
echo 1000 | sudo tee /proc/<pid>/oom_score_adj
```

**Reading a dmesg OOM event:**

```
[timestamp] Out of memory: Kill process <pid> (<name>) score <N> or sacrifice child
[timestamp] Killed process <pid> (<name>), UID <N>, total-vm:<VSZ>kB, rss:<RSS>kB
```

- **The process that died** is not necessarily the culprit
- **The score** is `memory_usage% × 10 + oom_score_adj`
- **Look at RSS trends** in the hours before the kill — that's where the story starts

---

## 5. Page Cache Investigation

```bash
# Cache breakdown — active vs inactive
cat /proc/meminfo | grep -E 'Active|Inactive|Cached|Mapped|KReclaimable'

# What's reclaimable vs locked
cat /proc/meminfo | grep -E 'Cached|Mapped|Unevictable|KReclaimable|SReclaimable'

# Drop caches (safe — use for benchmarking, not as a fix)
echo 1 | sudo tee /proc/sys/vm/drop_caches   # page cache only
echo 2 | sudo tee /proc/sys/vm/drop_caches   # dentries and inodes
echo 3 | sudo tee /proc/sys/vm/drop_caches   # everything

# Test cold vs warm read performance
echo 3 | sudo tee /proc/sys/vm/drop_caches
time cat /tmp/bigfile > /dev/null    # cold read — from disk
time cat /tmp/bigfile > /dev/null    # warm read — from cache
```

> **Never use `drop_caches` as a fix.** Cache refills immediately as
> the system resumes normal operation. Use it only to test cold-cache
> performance or to simulate a freshly booted system.

**Key fields in /proc/meminfo for cache:**

| Field | Meaning |
|-------|---------|
| `Active(file)` | File cache recently used — not eviction candidate |
| `Inactive(file)` | File cache not recently used — evicted first |
| `Active(anon)` | Process heap/stack recently used |
| `Inactive(anon)` | Process heap/stack cold — swap candidate |
| `KReclaimable` | Kernel slab cache that can be reclaimed |
| `Mapped` | Files mapped into process address space |

---

## 6. Thrashing Detection

```bash
# Watch si/so simultaneously — sustained non-zero = thrashing
vmstat 1

# Major page fault rate (disk reads caused by swap or cold cache)
F1=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
sleep 10
F2=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
echo "Major faults/sec: $(( (F2-F1)/10 ))"

# Full set of thrashing indicators
cat /proc/vmstat | grep -E 'pswpin|pswpout|pgfault|pgmajfault'
sleep 30
cat /proc/vmstat | grep -E 'pswpin|pswpout|pgfault|pgmajfault'
# Compare the two outputs — growing counters = active problem
```

**Thrashing diagnosis:**

```
vmstat shows:
  si > 0  AND  so > 0     → pages moving in both directions = thrashing
  b  > 5                  → processes blocked waiting on disk IO
  wa > 20%                → CPU idle but waiting on disk
  id high but us low      → CPU looks idle but system is grinding

This combination = the system is spending more time moving pages
between RAM and disk than doing actual work.
```

> **`pgmajfault` > 1000/sec is a serious problem.** Every major fault
> is a disk read. At that rate the system is doing thousands of disk
> reads per second just to keep running — not to do actual work.

---

## 7. Kernel Tuning Parameters

```bash
# Check current values
cat /proc/sys/vm/swappiness           # 0-100, default 60
cat /proc/sys/vm/overcommit_memory    # 0=heuristic, 1=always, 2=never
cat /proc/sys/vm/overcommit_ratio     # used when overcommit_memory=2
cat /proc/sys/vm/min_free_kbytes      # kernel memory floor
cat /proc/sys/vm/dirty_ratio          # max dirty pages before forced writeback
cat /proc/sys/vm/dirty_background_ratio  # background writeback threshold

# Tune immediately (resets on reboot)
sudo sysctl vm.swappiness=10
sudo sysctl vm.min_free_kbytes=262144

# Make permanent
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p    # reload without reboot
```

**Swappiness guide:**

| Value | Use case |
|-------|---------|
| `0` | Never swap unless forced — latency-sensitive workloads |
| `10` | Prefer cache eviction over swapping — databases |
| `60` | Balanced default |
| `100` | Swap aggressively — rarely useful |

---

## 8. Container Memory

```bash
# All containers memory usage at a glance
docker stats --no-stream

# Specific container
docker stats <name> --no-stream

# Check silent OOM kills — no logs, no alerts, just a counter
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.oom_control

# Container actual limit vs current usage
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.limit_in_bytes
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.usage_in_bytes

# Apply or update memory limit on running container
docker update --memory 2g --memory-swap 2g <name>

# Run new container with limit
docker run --memory 512m --memory-swap 512m myapp
```

**The /proc/meminfo problem in containers:**

```
Container limit:   512MB   ← what cgroup enforces
Container reads:   7.6GB   ← what /proc/meminfo shows (host RAM)
JVM allocates:     1.8GB   ← 25% of what it thinks it has
OOM kill fires     ← seemingly out of nowhere

Fix for Java:
java -XX:+UseContainerSupport \
     -XX:MaxRAMPercentage=75.0 \
     -jar app.jar
```

Any process that sizes itself based on available RAM will hit this.
Java, Node.js, Go runtimes — check their container awareness settings.

---

## 9. Historical Analysis

```bash
# Memory usage over time — requires sysstat package
sar -r 1 60                           # last 60 seconds
sar -r -f /var/log/sysstat/saXX       # from saved log file

# Memory and swap together
sar -R 1 10

# When did swap start being used?
sar -W -f /var/log/sysstat/saXX | grep -v "0.00      0.00"

# Full OOM log with surrounding context
sudo dmesg -T | grep -B5 -A20 "Out of memory"

# Per-process memory map of suspect
cat /proc/<pid>/smaps_rollup

# Kernel memory slab usage
slabtop -o | head -20

# Memory fragmentation
cat /proc/buddyinfo

# Full vmstat summary snapshot
vmstat -s

# All processes with non-zero swap
smem -r | awk '$3>0' | sort -k3 -rn
```

---

## 10. Health Signals vs Problem Signals

### Green — System Healthy

```
free -h:
  available > 20% of total RAM
  swap used = 0 or very low (< 5%)

vmstat:
  si = 0, so = 0       ← no swap activity
  b  = 0               ← nothing blocked on IO
  wa < 5%              ← minimal IO wait
  id > 70%             ← CPU mostly idle

/proc/meminfo:
  Committed_AS < CommitLimit
  Inactive(file) > 0   ← reclaimable cache available

Process level:
  VmPeak >> VmRSS      ← memory being freed normally
  VmSwap = 0           ← not under pressure
  RSS stable           ← not growing continuously
```

### Yellow — Warning, Investigate

```
free -h:
  available < 20% of total RAM
  swap used > 10%
  buff/cache shrinking rapidly

vmstat:
  so > 0 but si = 0    ← evicting pages, not yet reading back
  b  = 1-3             ← some IO blocking
  wa = 5-15%           ← moderate IO wait
  sy > 10%             ← kernel working harder

/proc/meminfo:
  Committed_AS > CommitLimit   ← overcommit territory
  Inactive(file) dropping fast ← cache being reclaimed rapidly

Process level:
  VmSwap > 100MB on any process
  RSS growing steadily
  VmPeak ≈ VmRSS on any process ← leak suspect
```

### Red — Critical, Act Immediately

```
free -h:
  available < 500MB
  swap > 70% used
  swap growing fast

vmstat:
  si AND so both non-zero      ← thrashing confirmed
  b  > 5                       ← many processes blocked
  wa > 20%                     ← heavy IO wait
  sy > 20%                     ← kernel overwhelmed
  id high but us low           ← CPU idle but no work done

/proc/meminfo:
  all_unreclaimable: yes       ← OOM imminent
  Inactive(file) = 0           ← nothing left to reclaim
  Free swap = 0kB              ← no safety net

dmesg:
  OOM kill messages            ← already firing
  drop_caches messages         ← kernel desperate

Process level:
  VmSwap > 500MB on critical process
  RSS growing > 200MB/min
  oom_kill counter growing in cgroup
```

---

## 11. Triage Checklists

### Quick Triage — under 2 minutes

```bash
# 1. Overall state
free -h

# 2. Is swap active
vmstat 1 5

# 3. Who is the hog
ps aux --sort=-%mem | head -10

# 4. Any OOM kills
sudo dmesg -T | grep -i oom | tail -5

# 5. Overcommit state
cat /proc/meminfo | grep -E 'MemAvailable|CommitLimit|Committed_AS'
```

### Detailed Investigation — 5-15 minutes

```bash
# Step 1 — Confirm severity
cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapFree|CommitLimit|Committed_AS'

# Step 2 — Find exact hog with swap breakdown
smem -r | head -20

# Step 3 — Check if it's a leak
cat /proc/<suspect_pid>/status | grep -E 'VmPeak|VmRSS|VmHWM|VmSwap|VmData'

# Step 4 — Measure growth rate
RSS1=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
sleep 60
RSS2=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
echo "Growth/min: $(( (RSS2-RSS1)/1024 )) MB"
echo "Growth/hr:  $(( (RSS2-RSS1)/1024*60 )) MB"

# Step 5 — Check thrashing depth
cat /proc/vmstat | grep -E 'pswpin|pswpout|pgmajfault'
sleep 30
cat /proc/vmstat | grep -E 'pswpin|pswpout|pgmajfault'

# Step 6 — Check cache state
cat /proc/meminfo | grep -E 'Active|Inactive|Cached|Mapped'

# Step 7 — Check OOM risk per top process
for pid in $(ps aux --sort=-%mem | awk 'NR>1{print $2}' | head -10); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    rss=$(cat /proc/$pid/status 2>/dev/null | grep VmRSS | awk '{print $2}')
    swap=$(cat /proc/$pid/status 2>/dev/null | grep VmSwap | awk '{print $2}')
    printf "Score:%-5s RSS:%-10s Swap:%-10s %s\n" \
        $score "${rss}kB" "${swap}kB" $comm
done
```

### Full Forensic Analysis — post-incident

```bash
# 1. Historical memory trend
sar -r -f /var/log/sysstat/saXX | tail -50

# 2. When did swap start
sar -W -f /var/log/sysstat/saXX | grep -v "0.00      0.00"

# 3. Full OOM log with context
sudo dmesg -T | grep -B5 -A20 "Out of memory"

# 4. Per-process memory map of suspect
cat /proc/<pid>/smaps_rollup

# 5. Kernel slab memory state
slabtop -o | head -20

# 6. Memory fragmentation
cat /proc/buddyinfo

# 7. Full vmstat summary
vmstat -s

# 8. All processes with non-zero swap
smem -r | awk '$3>0' | sort -k3 -rn
```

---

## 12. Monitoring & Alerting

### Metrics to collect

**System level:**
```
mem_available_bytes          ← primary health metric
mem_swap_used_percent        ← swap pressure
mem_committed_as_bytes       ← overcommit depth
mem_inactive_file_bytes      ← reclaimable cache
mem_active_anon_bytes        ← process memory in use
```

**Rate metrics:**
```
vmstat_si_per_sec            ← swap in rate
vmstat_so_per_sec            ← swap out rate
vmstat_pgmajfault_per_sec    ← major page fault rate
vmstat_b_processes           ← processes blocked on IO
```

**Process level:**
```
process_rss_bytes{pid, name}          ← per-process RAM
process_vmswap_bytes{pid, name}       ← per-process swap
process_rss_growth_rate{pid, name}    ← leak detection
```

**Container level:**
```
container_memory_usage_bytes          ← from cgroup
container_memory_limit_bytes          ← enforced limit
container_oom_kill_total              ← silent kills
container_memory_usage_percent        ← usage vs limit
```

### Alert thresholds

| Alert | Warning | Critical | Action |
|-------|---------|----------|--------|
| MemAvailable | < 20% total | < 10% total | Investigate hog |
| Swap used | > 30% | > 70% | Find what's swapping |
| Swap out rate | > 50 pages/s | > 500 pages/s | Thrashing likely |
| `si`+`so` both | any | sustained | Thrashing confirmed |
| pgmajfault rate | > 500/s | > 2000/s | Major performance hit |
| `b` column avg | > 3 | > 8 | IO blocking processes |
| `wa` % | > 10% | > 25% | IO wait high |
| OOM kill | any | any | Immediate investigation |
| Container OOM | oom_kill > 0 | growing | Check cgroup limit |
| RSS growth | > 50MB/min | > 200MB/min | Leak investigation |
| Committed_AS | > CommitLimit | > 120% limit | Overcommit risk |

### Prometheus + Alertmanager rules

```yaml
# Available RAM critical
- alert: MemoryAvailableCritical
  expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.10
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Available RAM below 10%"

# Swap usage high
- alert: SwapUsageHigh
  expr: (node_memory_SwapTotal_bytes - node_memory_SwapFree_bytes)
        / node_memory_SwapTotal_bytes > 0.70
  for: 5m
  labels:
    severity: warning

# Thrashing detected
- alert: MemoryThrashing
  expr: rate(node_vmstat_pswpin[5m]) > 100
        and rate(node_vmstat_pswpout[5m]) > 100
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "System thrashing — si and so both elevated"

# Major page fault rate
- alert: HighMajorPageFaults
  expr: rate(node_vmstat_pgmajfault[5m]) > 1000
  for: 5m
  labels:
    severity: warning

# Container OOM kills
- alert: ContainerOOMKill
  expr: increase(container_oom_events_total[5m]) > 0
  labels:
    severity: critical
  annotations:
    summary: "Container {{ $labels.name }} experiencing OOM kills"

# Container memory near limit
- alert: ContainerMemoryNearLimit
  expr: container_memory_usage_bytes
        / container_spec_memory_limit_bytes > 0.85
  for: 5m
  labels:
    severity: warning
```

### Dashboard panels to build

```
Overview:
  MemAvailable trend (last 24h)    ← most important graph
  Swap used trend (last 24h)
  si/so rate trend
  pgmajfault rate

Process:
  Top 10 RSS consumers (bar chart)
  RSS trend per service (line chart)
  Swap usage per process
  OOM kill events (event markers)

Container:
  Memory usage vs limit per container
  OOM kill count per container
  Memory usage % trending toward limit

Kernel:
  Active vs Inactive memory split
  CommitLimit vs Committed_AS
  min_free_kbytes headroom
```

---

## 13. Incident Runbook Template

```
Title:   High Memory Usage / Swap Active / OOM Kill
Trigger: MemAvailable < 10% OR swap > 70% OR OOM kill detected

Step 1 — Assess severity (2 min)
  free -h                          → check available and swap
  vmstat 1 5                       → check si/so/b/wa
  dmesg | grep oom                 → check if already killing

Step 2 — Identify culprit (3 min)
  ps aux --sort=-%mem | head -10
  smem -r | head -10
  cat /proc/<pid>/status | grep Vm

Step 3 — Classify the problem
  RSS ≈ VmPeak         → memory leak → get heap dump first, then restart
  RSS stable, VmSwap high → oversized process → set cgroup limits
  si+so both high      → thrashing → kill largest non-critical hog now
  OOM in dmesg         → already killed → check what died and why

Step 4 — Immediate action
  Kill non-critical hog
  Set cgroup limit on offender
  echo 3 > /proc/sys/vm/drop_caches  (if cache is reclaimable)
  swapoff/swapon to clear swap       (only if RAM is available)

Step 5 — Verify recovery
  watch -n2 'free -h'
  vmstat 1 5                         → si/so should drop to 0
  available should climb back above 20%

Step 6 — Post-incident
  Capture heap dump if leak suspected
  Set permanent MemoryMax on offending service
  Add alert if one was missing
  File bug with: growth rate data + heap dump + full dmesg output
```

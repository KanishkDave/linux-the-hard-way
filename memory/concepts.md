# Memory Concepts — Complete Reference

> This file covers the theory behind all 7 memory scenarios.  
> You don't need to read this front to back before starting.  
> Use it as a reference — come back when something in a scenario  
> doesn't make sense, or when you want the deeper explanation  
> behind what you just observed.

---

## Table of Contents

1. [How Linux Memory Works](#1-how-linux-memory-works)
2. [Memory Layout — What RAM Contains](#2-memory-layout--what-ram-contains)
3. [Page Cache](#3-page-cache)
4. [Swap](#4-swap)
5. [Page Faults](#5-page-faults)
6. [OOM Killer](#6-oom-killer)
7. [Memory Leak Detection](#7-memory-leak-detection)
8. [Cgroups & Container Memory](#8-cgroups--container-memory)
9. [The /proc Filesystem](#9-the-proc-filesystem)
10. [vmstat Columns — Complete Reference](#10-vmstat-columns--complete-reference)
11. [Incident Response Playbook](#11-incident-response-playbook)
12. [Alert Thresholds](#12-alert-thresholds)
13. [The Three Most Important Insights](#13-the-three-most-important-insights)

---

## 1. How Linux Memory Works

### Demand Paging

The kernel never hands over RAM upfront. When a process asks for memory,
the kernel says "yes, it's yours" — but doesn't assign physical pages yet.
RAM is only allocated when the process actually **writes** to that address
for the first time.

This is why RSS grows slowly after VSZ jumps instantly. VSZ is the promise.
RSS is what's physically loaded.

```
Process: "Give me 1Gi"
Kernel:  "Sure." (updates page table, no RAM assigned)
                  ↓
Process writes to address 0x1000
Kernel:  "Page fault — assign a physical page now."
                  ↓
Process writes to address 0x2000
Kernel:  "Page fault — assign another."
... and so on, page by page
```

### Memory Overcommit

Linux deliberately promises more RAM than it has. It bets that not everything
promised will be used simultaneously. Most processes ask for more than they use.

```
CommitLimit   → maximum the kernel is willing to promise
Committed_AS  → total currently promised across all processes
```

`Committed_AS > CommitLimit` = overcommit territory. Not immediately dangerous,
but your safety margin is gone. One large allocation away from OOM.

### Virtual vs Physical Memory

| Metric | What it measures |
|--------|-----------------|
| `VSZ` | Total promised — virtual address space |
| `RSS` | Actually in physical RAM right now |
| `VmSwap` | Evicted to swap disk |

```
Total actual usage = RSS + VmSwap
```

---

## 2. Memory Layout — What RAM Contains

```
Total RAM
├── Used (process memory)
│     ├── Active(anon)    ← process heap/stack, recently used
│     ├── Inactive(anon)  ← process heap/stack, cold → swap candidate
│     ├── Active(file)    ← file cache, recently used
│     └── Inactive(file)  ← file cache, cold → evicted first
│
├── Buff/Cache (reclaimable)
│     ├── Page cache      ← file content cached in RAM
│     ├── Buffers         ← filesystem metadata
│     └── KReclaimable    ← kernel slab cache
│
└── Free (completely unused)

available = free + reclaimable cache  ← the only number that matters
```

`available` is what you check during an incident — not `free`.
`free` RAM with nothing in it is actually unusual on a healthy, busy system.

---

## 3. Page Cache

### What it is

Free RAM is never idle. The kernel uses spare RAM to cache file data.
Every file read populates the cache. Subsequent reads are served from RAM —
up to 19x faster than disk. This is intentional and healthy.

**Never panic about high buff/cache.** It's reclaimable instantly.
Always look at `available`, not `free`.

### Eviction order under pressure

When RAM is needed, the kernel evicts in this order:

```
1. Inactive(file)  ← first — just drop, backed by disk anyway
2. Active(file)    ← second
3. Inactive(anon)  ← third — must write to swap before evicting
4. Active(anon)    ← last resort before OOM
```

File cache is cheap to evict — it's already on disk. Process memory
(anon) is expensive — it has to be written to swap first.

### Cache management

```bash
echo 1 | sudo tee /proc/sys/vm/drop_caches   # drop page cache
echo 2 | sudo tee /proc/sys/vm/drop_caches   # drop dentries/inodes
echo 3 | sudo tee /proc/sys/vm/drop_caches   # drop everything
```

> **Never use `drop_caches` as a fix.** It refills immediately as the
> kernel resumes normal operation. Useful only for benchmarking or
> testing cold-cache behaviour.

---

## 4. Swap

### What it is

A safety valve — disk space used as RAM overflow. When RAM fills up,
the kernel writes cold pages to swap to make room. Swap is slow
(disk speed) compared to RAM. Sustained swap usage hurts performance.

### When it kicks in

When `MemAvailable` gets very low. The kernel evicts `Inactive(anon)`
pages first. How aggressively it swaps is controlled by `vm.swappiness`.

### si/so — the key signals in vmstat

```
so (swap out) → RAM → swap disk  (eviction, RAM was needed)
si (swap in)  → swap disk → RAM  (retrieval, process accessed swapped page)

Both non-zero simultaneously = thrashing
```

### Swappiness tuning

```
0   → never swap unless absolutely forced (latency-sensitive workloads)
10  → prefer cache eviction over swapping (databases)
60  → balanced default
100 → swap aggressively (rare — generally avoid)
```

```bash
# Check current value
cat /proc/sys/vm/swappiness

# Change temporarily
sudo sysctl vm.swappiness=10

# Make permanent
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
```

### SwapCached

Pages that exist in both RAM and swap simultaneously. This happens during
swap-in operations — the kernel keeps the swap copy until the page is
modified, as a safety net. Not double-counting — just a transition state.

### Clearing swap

```bash
sudo swapoff -a && sudo swapon -a
```

> Only do this when you have enough free RAM to absorb everything in swap.
> Running this with insufficient RAM triggers OOM immediately.

---

## 5. Page Faults

### What they are

Normal kernel mechanism — not an error. Fires when a process accesses
memory that isn't currently mapped into its page table.

### Minor page fault

- Page exists in RAM but isn't mapped into the process yet
- Cost: microseconds, no disk IO
- Example: first `malloc` access, shared library already loaded by another process

### Major page fault

- Page is NOT in RAM — must fetch from disk
- Cost: milliseconds, mandatory disk read
- Example: accessing a swapped-out page, reading a cold file for the first time

```bash
# Track major fault rate
cat /proc/vmstat | grep pgmajfault
sleep 10
cat /proc/vmstat | grep pgmajfault
# Delta / 10 = major faults per second
# > 1000/sec = serious problem
```

> Growing `pgmajfault` rate is one of the clearest signals of swap
> thrashing — the system is spending more time moving pages between
> disk and RAM than doing actual work.

---

## 6. OOM Killer

### What triggers it

RAM and swap are both exhausted AND the kernel cannot reclaim any more
pages. The point of no return shows in dmesg as `all_unreclaimable: yes`.

### How the kernel picks a victim

```
oom_score = memory_usage% × 10 + oom_score_adj
```

Highest score dies first. The kernel looks for the process that will
free the most memory with the least collateral damage.

### oom_score_adj range

```
-1000 → never kill (systemd-udevd, containerd use this)
 -500 → strongly protected (databases, critical services)
    0 → neutral (default)
 +500 → likely target
+1000 → kill me first (use for intentional stress tests)
```

```bash
# Check a process's current kill risk
cat /proc/<pid>/oom_score

# Protect a critical process
echo -500 | sudo tee /proc/<pid>/oom_score_adj

# Permanent protection via systemd service file
[Service]
OOMScoreAdjust=-500
```

### Reading an OOM kill in dmesg

```bash
sudo dmesg -T | grep -i oom
```

Key fields to read:
- Who triggered it (the process that needed the last page)
- Who got killed (highest oom_score at that moment)
- RSS at time of kill (actual RAM freed)
- `global_oom` = system-wide kill
- `cgroup scoped` = container-only kill, rest of system unaffected

> **The trigger is not the culprit.** The process that trips the OOM
> killer is just the one that needed the last page. The real culprit
> consumed RAM long before. Always look at RSS trends in the hours
> leading up to the event.

### Key signals before OOM triggers

```
all_unreclaimable: yes  ← point of no return
inactive_file: 0        ← nothing left to reclaim from file cache
Free swap: 0kB          ← no safety net left
```

---

## 7. Memory Leak Detection

### What it is

A process allocates memory continuously and never frees it. RSS grows
without bound. Left unchecked, it eventually consumes all available RAM
and triggers OOM.

### Identifying signals

```
VmPeak ≈ VmRSS       → process has never freed anything = classic leak
VmPeak >> VmRSS      → healthy — lots was freed over time
Constant RSS growth  → steady rate over hours = leak
VmData growing       → heap is expanding
Private_Dirty growing in smaps → heap pages written but never freed
```

### Leak vs sizing problem vs healthy process

| Pattern | What it means | Action |
|---------|--------------|--------|
| `VmPeak ≈ VmRSS`, constant growth | Memory leak | Needs code fix |
| `VmPeak > VmRSS`, growth plateaus | Oversized process | Add memory limits |
| `VmPeak >> VmRSS`, RSS fluctuates | Healthy | Nothing needed |

### Measuring growth rate

```bash
RSS1=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
sleep 60
RSS2=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
echo "Per minute: $(( (RSS2-RSS1)/1024 )) MB"
echo "Per hour:   $(( (RSS2-RSS1)/1024*60 )) MB"
```

### Getting heap dumps for developers

```bash
# Java
jmap -dump:format=b,file=heap.hprof <pid>

# Python
import tracemalloc
tracemalloc.start()
snapshot = tracemalloc.take_snapshot()

# Go
go tool pprof http://localhost:6060/debug/pprof/heap

# C/C++
valgrind --leak-check=full ./program
```

> Always get a heap dump **before** restarting a leaking process.
> A restart fixes the symptom and destroys the evidence.

---

## 8. Cgroups & Container Memory

### What cgroups do

Hard memory ceiling on any process or group. When a cgroup hits its
limit, the kernel triggers a scoped OOM kill — only that cgroup is
affected. The rest of the system continues normally.

This is the foundation of Docker and Kubernetes memory limits.

### Key cgroup files (v1)

```
memory.limit_in_bytes       ← hard ceiling — enforced strictly
memory.usage_in_bytes       ← current usage
memory.oom_control          ← OOM kill count and current status
memory.soft_limit_in_bytes  ← soft ceiling — kernel reclaims pages
memory.swappiness           ← per-cgroup swap tuning
```

### Applying limits to a running process

```bash
sudo mkdir /sys/fs/cgroup/memory/mygroup
echo $((512*1024*1024)) | sudo tee /sys/fs/cgroup/memory/mygroup/memory.limit_in_bytes
echo <pid> | sudo tee /sys/fs/cgroup/memory/mygroup/tasks
```

### The /proc/meminfo problem in containers

```
Container limit:   512MB   ← actual enforced ceiling
Container sees:    7.6GB   ← /proc/meminfo shows HOST RAM
JVM allocates:     1.8GB   ← 25% of what it thinks it has
OOM kill fires     ← seemingly out of nowhere
```

The container reads the host's `/proc/meminfo`, not its own limit.
Any process that sizes itself based on "available RAM" will OOM.

```bash
# Fix for Java
java -XX:+UseContainerSupport \
     -XX:MaxRAMPercentage=75.0 \
     -jar app.jar
```

### Docker memory commands

```bash
# Set limit on new container
docker run --memory 2g --memory-swap 2g myapp

# Update limit on running container
docker update --memory 2g mycontainer

# Check all containers
docker stats --no-stream

# Check silent OOM kills
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.oom_control
```

### Kubernetes equivalent

```yaml
resources:
  limits:
    memory: 512Mi
  requests:
    memory: 256Mi
```

---

## 9. The /proc Filesystem

### What it is

A virtual filesystem — nothing on disk. Created fresh in memory by the
kernel every time you read from it. A live window into kernel state.
Reading `/proc` files never touches a disk.

### Most important files for memory work

| File | Use for |
|------|---------|
| `/proc/meminfo` | Full system memory state |
| `/proc/vmstat` | Raw counters — page faults, swap activity |
| `/proc/sys/vm/swappiness` | Swap aggression tuning |
| `/proc/sys/vm/min_free_kbytes` | Kernel memory reservation floor |
| `/proc/sys/vm/overcommit_memory` | Overcommit mode (0=heuristic, 1=always, 2=never) |
| `/proc/sys/vm/drop_caches` | Force cache eviction |
| `/proc/<pid>/status` | Full process memory summary |
| `/proc/<pid>/smaps` | Detailed per-region memory breakdown |
| `/proc/<pid>/smaps_rollup` | Summarised smaps — faster to read |
| `/proc/<pid>/oom_score` | Current OOM kill risk |
| `/proc/<pid>/oom_score_adj` | Manual OOM bias |
| `/proc/<pid>/fd` | Open file descriptors |
| `/proc/<pid>/io` | Per-process IO stats |
| `/proc/<pid>/cgroup` | Which cgroups this process belongs to |

---

## 10. vmstat Columns — Complete Reference

```
r    → processes waiting for CPU (runqueue length)
b    → processes blocked on IO ← spikes during thrashing

swpd → total swap currently in use
free → completely free RAM (not buff/cache)
buff → buffer cache (filesystem metadata)
cache → page cache (file content)

si   → swap in  KB/s  (swap disk → RAM)  ← memory pressure signal
so   → swap out KB/s  (RAM → swap disk)  ← memory pressure signal

bi   → blocks read from disk (all IO)
bo   → blocks written to disk (all IO)

in   → interrupts per second
cs   → context switches per second

us   → user CPU %
sy   → system/kernel CPU % ← rises during memory pressure
id   → idle CPU % ← can be high even during thrashing
wa   → IO wait %  ← key thrashing signal
st   → CPU stolen by hypervisor (VMs/cloud only)
```

### Read these together — not in isolation

| Combination | What it means |
|-------------|--------------|
| `so` non-zero + `available` dropping | Memory pressure starting |
| `si` + `so` both non-zero | Thrashing — pages moving both directions |
| `b` spiking + `wa` high | IO bottleneck, possibly swap-related |
| `sy` rising + `so` spiking | Kernel under load managing memory |
| `id` high + `wa` high | CPU idle but waiting on disk — thrashing masquerading as idle |

---

## 11. Incident Response Playbook

```
Stage 1 — available > 1Gi, swap untouched
  └── Monitor, identify growing process, watch trend
  └── Is growth constant (leak) or plateauing (oversized)?

Stage 2 — available < 1Gi, swap starting
  └── smem -r → find the hog
  └── VmPeak vs VmRSS → leak or oversized?
  └── Restart non-critical consumers if needed

Stage 3 — swap > 50%, si/so non-zero
  └── Kill largest non-critical process immediately
  └── echo 3 > /proc/sys/vm/drop_caches → free reclaimable memory
  └── sudo sysctl vm.swappiness=10

Stage 4 — si + so both non-zero, b column spiking
  └── Thrashing — kill the hog immediately
  └── Every minute of thrashing = compounding application degradation
  └── Don't wait for OOM — act now

Stage 5 — OOM imminent (available < 200Mi, swap > 90%)
  └── Kill immediately — do not wait
  └── sudo dmesg -T | grep oom → check what already died
  └── Protect critical processes: echo -500 > /proc/<pid>/oom_score_adj
```

### Long term — after every incident

```
└── Set MemoryMax in systemd unit or cgroup limit
└── Set OOMScoreAdjust on all critical services
└── Add alerts on: available RAM, swap %, pgmajfault rate
└── Get heap dump BEFORE restarting leaking process
└── File bug with: growth rate data + heap dump + dmesg output
```

---

## 12. Alert Thresholds — Production Reference

| Metric | Warning | Critical |
|--------|---------|----------|
| `MemAvailable` | < 1Gi | < 500Mi |
| Swap used % | > 30% | > 70% |
| `si + so` rate | > 50 pages/sec | > 500 pages/sec |
| `pgmajfault` rate | > 500/sec | > 2000/sec |
| `b` column (vmstat) | > 3 | > 8 |
| `wa` % | > 10% | > 25% |
| OOM kill count | > 0 | any |
| RSS growth rate | > 50MB/min | > 200MB/min |
| VmSwap per process | > 100MB | > 500MB |

---

## 13. The Three Most Important Insights

These three things separate engineers who guess from engineers who know.

---

**1. `available` > `free`**

Never look at `free`. Always look at `available`.
`buff/cache` is reclaimable and doesn't reduce your actual headroom.
A server showing `free: 200Mi` with `available: 4Gi` is healthy.
A server showing `free: 200Mi` with `available: 200Mi` is about to have a bad time.

---

**2. CPU idle doesn't mean system healthy**

During thrashing, `id` (idle) can be 60% while `wa` is 25% and `sy` is 10%.
Standard CPU utilisation alerts will not fire. The system looks fine on dashboards
while grinding to a halt. Always watch `wa`, `sy`, and `b` together alongside CPU.

---

**3. The trigger is not the culprit**

The process that invokes the OOM killer is just the one that needed the last page.
The real culprit consumed RAM long before — sometimes hours earlier.
When you're in a war room reading a dmesg OOM kill, the process that died is
rarely the one you should be fixing. Look at RSS trends in the hours leading
up to the event. That's where the story actually starts.

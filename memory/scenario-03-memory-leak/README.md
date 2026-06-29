# Scenario 03 — Memory Leak Detection & Containment

> "The 2am OOM kill wasn't the problem.  
>  The problem had been running since 9am.  
>  Nobody noticed because nothing looked wrong."

Scenarios 01 and 02 were loud. RAM collapsed fast, swap spiked, OOM fired.
Hard to miss. This one is different.

A process leaks 5MB every 3 seconds. No swap spike. No OOM. No alert. Just
available RAM quietly shrinking — 100MB per minute, 6GB per hour — until
there's nothing left and the system falls over at the worst possible time.

This is the most dangerous class of memory problem in production. Not because
it's hard to fix, but because it's easy to miss until it's too late.

---

## What you'll learn

- How to identify a memory leak from outside a process — without reading its code
- Why `VmPeak` vs `VmRSS` is your fastest leak detection signal in production
- How to calculate growth rate and estimate time to OOM from a running process
- What cgroups are and how to apply a hard memory limit to any running process
- Why a Kubernetes pod `OOMKilled` status and what you'll see here are the same event at the kernel level
- How cgroup-scoped OOM kill differs from the system-wide OOM kill in Scenario 02

---

## Setup

**Requirements:**
- Ubuntu 20.04+ (WSL2 works — cgroup version is auto-detected)
- `python3` installed (comes pre-installed on Ubuntu)
- Swap enabled (this scenario doesn't disable it — swap buys time before OOM)

**Verify your baseline before starting:**

```bash
free -h
cat /proc/meminfo | grep -E 'MemAvailable|MemTotal'
```

Write down available RAM. You'll watch it shrink steadily as the leak runs.

> **A note on numbers:** The leak rate (5MB every 3 seconds) is fixed in the
> script. On a machine with more RAM you'll have more time to observe before
> the cgroup limit is hit. The patterns — RSS growth, VmPeak comparison,
> growth rate calculation — are the same on any machine.

---

## Run the scenario

The script embeds the leak simulator, runs it, guides you through detection,
then applies a cgroup memory limit and watches the process hit the ceiling.

```bash
chmod +x scripts/memory-leak.sh
./scripts/memory-leak.sh
```

**Before you start the script, open two more terminals and run:**

```bash
# Terminal 2 — watch RSS grow in real time
watch -n3 'ps aux --sort=-%mem | head -10'

# Terminal 3 — watch for cgroup OOM kill
sudo dmesg -Tw
```

> The script will pause between phases and tell you what to observe.
> Follow its prompts — but don't just watch. Form a hypothesis at each
> step before the next phase starts. That's the point.
>
> **Don't be discouraged when you don't immediately know what a value
> means or what a flag does.** That uncertainty is the point — it's
> exactly what an incident feels like. Google it, check the man page,
> ask an AI. I used the same process when working on these scenarios —
> hitting something unfamiliar, looking it up, building the mental model
> from there. Looking things up under pressure is a skill too.
> The goal isn't memorisation. It's pattern recognition.

---

## Investigate

**Phase 1 — Leak running, observe RSS growth**

```bash
# Step 1 — Baseline memory state
free -h
```
Write down available RAM. You will compare this every few minutes.

```bash
# Step 2 — Find the leaking process
ps aux --sort=-%mem | head -10
```
Which process stands out? What is its RSS right now?

```bash
# Step 3 — Watch RSS grow over time
for i in {1..10}; do
    ps -p <pid> -o pid,rss,vsz --no-headers
    sleep 6
done
```
How much is RSS growing every 6 seconds? What does that project to per hour?

```bash
# Step 4 — Check VmPeak vs VmRSS
cat /proc/<pid>/status | grep -E 'VmRSS|VmSize|VmSwap|VmPeak'
```
Is VmPeak close to VmRSS? What does that tell you about whether memory has
ever been freed by this process?

```bash
# Step 5 — Calculate exact growth rate
RSS1=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
sleep 30
RSS2=$(cat /proc/<pid>/status | grep VmRSS | awk '{print $2}')
echo "Growth in 30s: $(( (RSS2 - RSS1) / 1024 )) MB"
echo "Projected per hour: $(( (RSS2 - RSS1) / 1024 * 120 )) MB"
```
How long before this process exhausts available RAM?

```bash
# Step 6 — Confirm with smaps
cat /proc/<pid>/smaps | grep -E 'Size|Rss|Swap' | \
awk '{sum[$1]+=$2} END {for (k in sum) print k, sum[k]/1024 " MB"}'
```
Is RSS close to Size? Is any memory being swapped out?

```bash
# Step 7 — Compare RSS vs VmPeak across top processes
for pid in $(ps aux --sort=-%mem | awk 'NR>1{print $2}' | head -10); do
    rss=$(cat /proc/$pid/status 2>/dev/null | grep VmRSS | awk '{print $2}')
    peak=$(cat /proc/$pid/status 2>/dev/null | grep VmPeak | awk '{print $2}')
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    [ -n "$rss" ] && printf "%-20s RSS: %-10s Peak: %s\n" \
        "$comm" "${rss}kB" "${peak}kB"
done
```
Which process has RSS nearly equal to Peak? Which ones have Peak significantly
higher than RSS? What does the difference tell you?

---

**Phase 2 — Cgroup limit applied, watch the ceiling**

```bash
# Step 8 — Confirm cgroup limit is applied
# cgroups v1
cat /sys/fs/cgroup/memory/memlimit_test/memory.limit_in_bytes
# cgroups v2
cat /sys/fs/cgroup/memlimit_test/memory.max
```
What is the hard limit in bytes? Convert it to MB.

```bash
# Step 9 — Watch usage climb toward the limit
# cgroups v1
watch -n2 'echo "Usage: $(( $(cat /sys/fs/cgroup/memory/memlimit_test/memory.usage_in_bytes) / 1024 / 1024 )) MB"'
# cgroups v2
watch -n2 'echo "Usage: $(( $(cat /sys/fs/cgroup/memlimit_test/memory.current) / 1024 / 1024 )) MB"'
```
How fast is usage climbing? When do you expect it to hit the ceiling?

```bash
# Step 10 — Watch for the cgroup OOM kill
sudo dmesg -Tw | grep -i oom
```
What process was killed? Is the message scoped to a cgroup or global?
How does this differ from Scenario 02's OOM kill?

---

## What the output is actually telling you

### `ps aux` — spotting the leak candidate

```
USER    PID  %MEM    VSZ      RSS    COMMAND
kanishk 999298 13.8  1101628  1096280  python3 /tmp/scenario3.py
java    1004   9.8   2712788   782344  java
snapd   833445  0.7   398244    58472  snapd
```

Python3 at 13.8% MEM and 1.07Gi RSS for a simple script is immediately
suspicious. But RSS alone doesn't confirm a leak — it just tells you the
current footprint. You need to watch it over time.

### `/proc/<pid>/status` — the leak fingerprint

```
VmPeak:  3207592 kB   ← highest RSS this process ever reached
VmSize:  3207592 kB   ← current virtual memory reserved
VmRSS:   3202788 kB   ← currently in physical RAM
VmSwap:        0 kB   ← nothing in swap
```

**VmPeak = VmSize = VmRSS** — this is the leak signature.

In a healthy process, VmPeak is significantly higher than VmRSS because
memory is allocated and freed over time. The peak was reached at some point
in the past and RSS has since come back down.

In a leaking process, RSS has been climbing continuously — it is always
chasing Peak upward. They stay nearly equal because memory is never freed.

| Process | RSS | VmPeak | Interpretation |
|---------|-----|--------|----------------|
| python3 | 3.2Gi | 3.2Gi | RSS ≈ Peak → never freed → leak |
| java | 782MB | 10.3Gi | RSS << Peak → healthy cycling |
| snapd | 57MB | 2.2Gi | RSS << Peak → healthy |

This single comparison across your top memory consumers is the fastest
production triage tool for memory leaks.

### Growth rate calculation

```
Growth in 30s: 50 MB
Projected per hour: 6000 MB
```

50MB per 30 seconds = 100MB per minute = 6000MB per hour.

On a 7.6Gi system with 3.2Gi already consumed:
- Remaining: ~4.4Gi
- Time to OOM: ~44 minutes

This is the number you put in your incident report. Not "memory is high"
but "process X is consuming 6GB per hour and will exhaust available RAM
in approximately 44 minutes."

### `/proc/<pid>/smaps` — physical confirmation

```
Size:  2667 MB   ← virtual memory mapped
RSS:   2662 MB   ← physically in RAM
Swap:     0 MB   ← nothing evicted
```

RSS nearly equal to Size means every promised page has been touched and is
physically resident in RAM. No lazy pages, no gaps — the leak is real and
fully occupying physical memory.

### Cgroup OOM kill vs global OOM kill

```
# Scenario 02 — global OOM
oom-kill: global_oom, task=stress-ng-vm, pid=184000

# Scenario 03 — cgroup OOM
oom-kill: cgroup=/memlimit_test, task=python3, pid=999298
```

| | Scenario 02 | Scenario 03 |
|--|-------------|-------------|
| Scope | System wide | Cgroup only |
| RAM at kill | Near zero system wide | Plenty of free RAM |
| Other processes | Degraded before kill | Completely unaffected |
| Trigger | Global RAM exhausted | Cgroup ceiling hit |

The cgroup OOM kill is surgical. The rest of your system never felt it.

### How Docker and Kubernetes memory limits work

When you set a memory limit on a container:

```yaml
# Kubernetes
resources:
  limits:
    memory: 512Mi
```

```bash
# Docker
docker run --memory=512m myapp
```

The container runtime is doing exactly what this script did — creating a
cgroup and setting `memory.limit_in_bytes`. When a Kubernetes pod shows
status `OOMKilled`, this is the exact kernel event behind it.

---

## What actually happened — the full chain

```
Phase 1 — Silent growth
  └── python3 started, allocating 5MB every 3 seconds
  └── RSS growing ~10MB every 6 seconds (~100MB per minute)
  └── free -h showed available RAM slowly reducing
  └── No swap activity, no OOM — system looked mostly fine
  └── Easy to miss without active RSS trend monitoring

Phase 2 — Leak confirmed
  └── VmPeak ≈ VmRSS — memory never freed
  └── Growth rate: 50MB per 30s → 6000MB per hour
  └── Time to OOM: ~44 minutes from detection
  └── smaps confirmed RSS ≈ Size — fully physical, nothing lazy

Phase 3 — Containment via cgroup
  └── cgroup created with 512MB hard limit
  └── Process added to cgroup — limit applied immediately
  └── Leak continued, usage climbed toward ceiling
  └── Cgroup OOM kill fired at 512MB — only python3 killed
  └── Rest of system completely unaffected
  └── RAM recovered immediately after kill
```

---

## Fix it

**Immediate action in production:**
```bash
# Option 1 — Kill and restart the service
kill <pid>
systemctl restart <service-name>

# Option 2 — Apply cgroup limit to buy time while fix is prepared
sudo mkdir /sys/fs/cgroup/memory/memlimit_<service>
echo $((512 * 1024 * 1024)) | sudo tee \
    /sys/fs/cgroup/memory/memlimit_<service>/memory.limit_in_bytes
echo <pid> | sudo tee /sys/fs/cgroup/memory/memlimit_<service>/tasks
```

**Make protection permanent via systemd:**
```ini
# In your service file under [Service]
MemoryMax=512M     # hard ceiling — OOM kill if exceeded
MemoryHigh=400M    # soft ceiling — kernel starts reclaiming pages
Restart=always     # auto restart if OOM killed
```

**Passive leak monitoring in production:**
```bash
# Log RSS every 30 seconds for any process
pid=<pid>
for i in {1..20}; do
    rss=$(cat /proc/$pid/status 2>/dev/null | grep VmRSS | awk '{print $2}')
    echo "$(date '+%H:%M:%S')  RSS: $((rss/1024)) MB"
    sleep 30
done
```

A flat or fluctuating line is healthy. A continuously rising line is a leak.

---

## Key takeaways

1. **VmPeak ≈ VmRSS means memory was never freed.** Run the Peak vs RSS
   comparison across your top memory consumers whenever something feels off.
   It's the fastest leak signal you have without reading code.

2. **Calculate growth rate, not just current usage.** "Memory is high" is
   not an incident report. "Process X is consuming 6GB per hour and will
   exhaust RAM in 44 minutes" is. Two RSS snapshots 30 seconds apart gives
   you that number.

3. **cgroups turn a system emergency into a contained kill.** A service
   without a memory limit can take down your entire system. A service with
   `MemoryMax` set via systemd can only hurt itself. That's the difference
   between a 2am all-hands incident and a quiet auto-restart.

---

## Reference

- [concepts.md](../concepts.md) — theory behind everything in this scenario
- [commands.md](../commands.md) — full command reference and triage checklists

---

## What's next

Scenario 03 was a process leaking memory gradually. Scenario 04 is about
something the kernel does silently in the background that most people never
think about — until it causes a performance problem they can't explain.

[Scenario 04 → Page Cache](../scenario-04-page-cache/)

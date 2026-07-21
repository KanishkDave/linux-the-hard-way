# Scenario 05 — Swap Thrashing

> "CPU was 40% idle. The system was completely destroyed.  
>  Nobody's alerts fired.  
>  Because we were watching the wrong columns."

Scenario 04 showed the kernel borrowing RAM gracefully. This one shows what
happens when that borrowing goes wrong.

Swap thrashing is the state where the system spends more time moving pages
between RAM and disk than doing actual work. RAM is full. Swap is full. Every
page evicted to swap is immediately needed again. The kernel is running flat
out — but useful work has almost stopped.

The dangerous part: CPU looks partially idle. Standard CPU alerts don't fire.
The system is destroying itself in silence.

---

## What you'll learn

- What swap thrashing looks like in vmstat — the exact columns and values
- Why CPU can appear idle while the system is completely degraded
- What the `b` column in vmstat means and why it spikes during thrashing
- What `pgmajfault` is and how to use it to confirm and measure thrashing
- How `swappiness` affects which pages get sacrificed first — and why it
  doesn't prevent thrashing under extreme pressure
- How to detect, confirm, and resolve thrashing in production

---

## Setup

**Requirements:**
- Ubuntu 20.04+ (WSL2 works for this scenario)
- `stress-ng` installed: `sudo apt install stress-ng`
- `smem` installed: `sudo apt install smem`
- Swap enabled — this scenario requires swap to fill completely

**Verify your baseline before starting:**

```bash
free -h
cat /proc/vmstat | grep pgmajfault
cat /proc/sys/vm/swappiness
vmstat 1 3
```

Write down `pgmajfault` and `swappiness`. You'll compare them as thrashing
builds.

> **A note on numbers:** The exact si/so values you see depend on your disk
> speed and RAM size. The pattern — si and so both non-zero simultaneously,
> wa climbing, b column spiking — is the signal regardless of the specific
> numbers.

---

## Run the scenario

```bash
chmod +x scripts/swap-thrashing.sh
./scripts/swap-thrashing.sh
```

**Before you start the script, open three more terminals and run:**

```bash
# Terminal 2 — most important this time
vmstat 1

# Terminal 3 — kernel messages
sudo dmesg -Tw

# Terminal 4 — watch swap fill
watch -n1 'free -h'
```

> The script will pause between phases and tell you what to observe.
> vmstat is your primary window this time — watch it more than anything else.
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

**Phase 1 — RAM filling, swap starting**

```bash
# Step 1 — Baseline swap state
free -h
cat /proc/vmstat | grep pgmajfault
```
Write down pgmajfault. You'll track how fast it grows.

```bash
# Step 2 — Watch vmstat closely
vmstat 1
```
Watch `si`, `so`, `swpd`, `b`, `wa`. Which moves first?
At what point does `so` appear? What does that signal?

```bash
# Step 3 — Check swap fill rate
watch -n1 'free -h'
```
How fast is `swpd` climbing? When do you think swap will be full?

---

**Phase 2 — Full thrashing**

```bash
# Step 4 — The thrashing signature in vmstat
vmstat 1
```
Are `si` and `so` both non-zero simultaneously? What are the values?
What is `wa` showing? What is `b` showing?
What is `us` (user CPU) showing — how much actual work is happening?

```bash
# Step 5 — Confirm with pgmajfault rate
F1=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
sleep 10
F2=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
echo "Major faults/sec: $(( (F2-F1)/10 ))"
```
How many major page faults per second? What does each one cost the system?

```bash
# Step 6 — Find the thrashing victims
smem -r | head -10
```
Which processes have non-zero swap usage? Are they the memory hogs or
background processes?

---

**Phase 3 — swappiness tuned to 10**

```bash
# Step 7 — Watch vmstat after swappiness change
vmstat 1
```
Did si/so drop? What happened to bi/bo? Did the kernel switch strategy?

```bash
# Step 8 — pgmajfault rate after swappiness change
F1=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
sleep 10
F2=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
echo "Major faults/sec after tuning: $(( (F2-F1)/10 ))"
```
Did the fault rate improve? What does that tell you about swappiness tuning
under extreme pressure?

---

## What the output is actually telling you

### `vmstat 1` — the thrashing signature

```
r   b    swpd      free    si      so      bi      bo     us  sy  id  wa
7   8  2097116   111904  212800  269260  340664  274940   8  27  41  24
```

| Column | Value | What it means |
|--------|-------|---------------|
| `b=8` | 8 processes | Blocked waiting for IO — their pages are on disk |
| `swpd=2097116` | ~2Gi | Swap completely full |
| `si=212800` | 212MB/s | Pages being read back from swap into RAM |
| `so=269260` | 269MB/s | Pages being evicted from RAM to swap |
| `bi=340664` | 340MB/s | Total disk reads (includes swap reads) |
| `bo=274940` | 274MB/s | Total disk writes (includes swap writes) |
| `us=8%` | 8% | Almost no actual user work happening |
| `sy=27%` | 27% | Kernel spending time managing memory |
| `id=41%` | 41% | Appears idle — but wa tells the real story |
| `wa=24%` | 24% | CPU waiting on disk IO |

**si and so both non-zero simultaneously** — this is the defining thrashing
signal. The kernel is evicting pages to swap and reading them back at the
same time. It's running in circles.

### The CPU idle trap

During thrashing `id` shows 40% idle. Standard CPU monitoring would see a
mostly idle system. But look at `us=8%` — only 8% of CPU time is doing
actual user work.

```
us + sy + id + wa = 100%
8  + 27 + 41 + 24 = 100%

Useful work:  8%   ← almost nothing
Kernel work: 27%   ← managing memory
Waiting:     24%   ← stalled on disk IO
Idle:        41%   ← genuinely idle but can't be used
```

A CPU alert threshold of 80% would never fire. The system is destroyed and
your monitoring doesn't know.

### `b` column in vmstat

```
r  b
7  8
```

`b` is processes in uninterruptible sleep — blocked waiting for IO.
On a healthy system `b` is almost always 0. During thrashing every process
is waiting for its pages to come back from swap, so `b` spikes.

`r` is processes waiting for CPU. High `r` with low `b` = CPU pressure.
High `b` with high `wa` = IO pressure. That's thrashing.

### `pgmajfault` — measuring the damage

```
Baseline:        257276
swappiness=100:  1105852   (+848576 in ~60s)
Rate:            ~14,000 major faults per second
```

A major page fault happens when a process accesses a page not in RAM — the
kernel must fetch it from disk. Each one stalls the process for milliseconds.

```
Minor fault (page in RAM):  ~100 nanoseconds
Major fault (page on disk): ~1-10 milliseconds  ← 10,000x slower
```

14,000 major faults per second means every thread on the system is constantly
stalling waiting for disk. Applications appear frozen even though the kernel
is working flat out.

### `swappiness` — what it changes and what it doesn't

```
swappiness=100  → kernel swaps anonymous pages aggressively
swappiness=10   → kernel evicts file cache first, keeps process memory in RAM
```

| Value | Behaviour | Use case |
|-------|-----------|----------|
| 0 | Never swap unless forced | Latency sensitive apps |
| 10 | Strongly prefer cache eviction | Database servers |
| 60 | Balanced (default) | General purpose |
| 100 | Swap aggressively | Rarely used |

**Critical insight:** swappiness doesn't prevent thrashing. Under extreme
pressure — when RAM is truly exhausted — both strategies hurt. swappiness
only decides which type of page gets sacrificed first: anonymous process
pages (high swappiness) or file cache (low swappiness).

After switching to swappiness=10, si/so may drop but bi/bo can stay high —
the kernel shifts from evicting process pages to evicting file cache instead.
pgmajfault may actually increase after the change: swap misses are replaced
by cache misses, which are also major faults. The thrashing continues in a
different form — just a different type of page being sacrificed.

This is the key insight: swappiness tuning changes which page gets evicted,
not how much eviction is happening. Under extreme pressure the fault rate
stays high regardless.

### Page faults — why they matter

Every RSS growth you've observed across all five scenarios was driven by
page faults underneath.

**Minor fault** — page exists in RAM but isn't mapped yet:
- Cost: ~100 nanoseconds
- Disk IO: none
- Example: first access to a malloc'd page, shared library already in RAM

**Major fault** — page is not in RAM, must fetch from disk:
- Cost: ~1-10 milliseconds
- Disk IO: mandatory
- Example: accessing a swapped page, cold file read, process starting fresh

```bash
# Major fault rate per second
F1=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
sleep 5
F2=$(cat /proc/vmstat | grep pgmajfault | awk '{print $2}')
echo "Major faults/sec: $(( (F2-F1)/5 ))"

# Per process fault counts
ps -p <pid> -o pid,minflt,majflt,comm
```

---

## What actually happened — the full chain

```
Phase 1 — RAM filling
  └── Workers consuming RAM aggressively with swappiness=100
  └── free dropped toward zero
  └── swpd climbing — kernel swapping cold pages out
  └── si/so starting to appear in vmstat

Phase 2 — Swap fills completely
  └── swpd hit ~2Gi — swap 100% full
  └── si and so both massive simultaneously
  └── bi/bo spiked — disk overwhelmed with swap traffic
  └── b column spiked — processes blocked on IO
  └── us dropped to ~8% — almost no useful work
  └── wa climbed — CPU waiting on disk constantly
  └── pgmajfault growing ~14,000/sec

Phase 3 — swappiness=10 applied
  └── si/so reduced — kernel stopped swapping aggressively
  └── bi/bo remained heavy — kernel evicting file cache instead
  └── pgmajfault kept growing — cache misses replaced swap misses
  └── Thrashing continued in different form
  └── Key insight: swappiness tuning helps, doesn't cure
```

---

## Fix it

**Immediate — stop the bleeding:**
```bash
# Kill the largest non-critical memory consumer
smem -r | head -10
kill <pid-of-largest-non-critical-process>

# Verify swap pressure drops
vmstat 1
```

**Buy time — free reclaimable cache:**
```bash
echo 3 | sudo tee /proc/sys/vm/drop_caches
free -h
```

**Reduce swap pressure:**
```bash
sudo sysctl vm.swappiness=10
```

**Long term:**
```bash
# Set memory limits on services via systemd
# In your service file under [Service]
MemoryMax=1G
Restart=always

# Add swap as emergency buffer only — not as extra RAM
# Monitor pgmajfault rate in production
watch -n5 'cat /proc/vmstat | grep pgmajfault'
```

---

## Key takeaways

1. **`si` and `so` both non-zero simultaneously is the thrashing signal.**
   Either one alone can be normal. Both together means the kernel is evicting
   pages and reading them back at the same time — running in circles.

2. **CPU idle during thrashing is a trap.** `id=40%` with `us=8%` and
   `wa=24%` means the system is destroyed. Standard CPU alerts will never
   fire. Always watch `wa`, `b`, and `sy` alongside `id`.

3. **swappiness tuning helps at the margins, not under extreme pressure.**
   When RAM is truly exhausted, there's no good option — only which type of
   page gets sacrificed first. The real fix is reducing memory pressure,
   not tuning swappiness.

---

## Reference

- [concepts.md](../concepts.md) — theory behind everything in this scenario
- [commands.md](../commands.md) — full command reference and triage checklists

---

## What's next

Scenario 05 showed swap thrashing on bare metal. Scenario 06 takes the same
concepts into containers — where memory limits are enforced by cgroups and
OOM kills are scoped, not system-wide.

[Scenario 06 → Container OOM](../scenario-06-container-oom/)

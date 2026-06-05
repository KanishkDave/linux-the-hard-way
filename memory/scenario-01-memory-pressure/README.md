# Scenario 01 — Sustained Memory Pressure & Swap Behavior

> "The app was fine. Metrics looked normal.  
>  But the log shipper had gone quiet. The monitoring agent was slow.  
>  Nothing was dead. Everything was just… slightly wrong.  
>  Swap had been climbing for two hours and nobody noticed."

The loudest memory incidents are OOM kills — something dies, an alert fires,  
the war room fills up. Those are easy. The hard ones are when nothing dies  
but everything slows down. Your background processes — the monitoring agent,  
log shipper, healthcheck script — get swapped out silently. Your app looks  
fine. Your metrics look fine. But something feels off.

That pattern starts here. With sustained memory pressure and a kernel that  
starts making hard choices about what stays in RAM.

---

## What you'll learn

- Why `available` is the only number in `free -h` that matters during an incident
- What overcommit actually means and when it becomes dangerous
- How the kernel decides what to evict — and why it's never the thing you want it to evict
- How to spot the silent victims of memory pressure using `smem`
- Why `si`/`so` in vmstat are your earliest warning signals — and why to never read them alone
- The difference between VSZ, RSS, PSS, and USS — and which one to use when

---

## Setup

**Requirements:**
- Ubuntu 20.04+ (WSL2 works for this scenario)
- `stress-ng` installed: `sudo apt install stress-ng`
- `smem` installed: `sudo apt install smem`
- At least 4GB RAM recommended

**Verify your baseline before starting:**

```bash
free -h
vmstat 1 3
cat /proc/meminfo | grep -E "CommitLimit|Committed_AS"
```

Write down these numbers. You'll want to compare them as pressure builds.

> **A note on numbers:** Every machine has different RAM, swap, and core
> count — so the exact values you see will differ from what's shown in
> this README. That's expected. The script adapts to your machine and
> shows you its actual current state at each phase. Focus on the
> *patterns* — available dropping, so spiking, smem showing swap on
> background processes — not the specific numbers.

---

## Run the scenario

The interactive script handles everything — it breaks the system in three
phases, tells you what to watch at each step, and cleans up after itself.

```bash
chmod +x scripts/memory-pressure.sh
./scripts/memory-pressure.sh
```

**Before you start the script, open a second terminal and run:**

```bash
vmstat 1
```

Leave it running throughout. It's your live feed for everything the script
triggers.

> The script will pause between phases and tell you what to observe.
> Follow its prompts — but don't just watch. Form a hypothesis at each
> step before the next phase starts. That's the point.

---

## Investigate

> **These steps mirror exactly what the script does — phase by phase,
> command by command.** Use this section as a reference while the script
> runs, or work through it manually if you prefer full control.
>
> **Don't be discouraged when you don't immediately know what a value
> means or what a flag does.** That uncertainty is the point — it's
> exactly what an incident feels like. Google it, check the man page,
> ask an AI. I used the same process when working on these scenarios —
> hitting something unfamiliar, looking it up, building the mental model
> from there. Looking things up under pressure is a skill too.
> The goal isn't memorisation. It's pattern recognition.

---

**Phase 1 — Initial allocation (script starts workers)**

```bash
# Step 1 — What does overall memory look like?
free -h
```
Which number matters here — `free` or `available`? What's the difference?

```bash
# Step 2 — Is the kernel swapping yet?
vmstat 1
```
Look at `si`, `so`, `swpd`, `r`, and `sy`. What's moving?
What does it mean when multiple columns change at the same time?

```bash
# Step 3 — Has the kernel overcommitted?
cat /proc/meminfo | grep -E "CommitLimit|Committed_AS|MemAvailable|SwapTotal|SwapFree"
```
Compare `CommitLimit` vs `Committed_AS`. What happens when `Committed_AS`
exceeds `CommitLimit`? Is that immediately dangerous?

---

**Phase 2 — More workers, overcommit territory**

```bash
# Step 4 — Who's using what?
ps aux --sort=-%mem | head -15
```
Look at VSZ and RSS side by side. Why are they different?
Which processes have the largest gap between them?

```bash
# Step 5 — How far into overcommit?
cat /proc/meminfo | grep -E "CommitLimit|Committed_AS"
```
Compare to Phase 1. How much has `Committed_AS` grown?
Is swap still untouched? Why?

---

**Phase 3 — Swap territory**

```bash
# Step 6 — Swap just kicked in
vmstat 1
```
Watch `so` spike. Watch `sy` jump. Watch `r` back up.
What does it mean when all three move together?

```bash
# Step 7 — Who got evicted?
smem -r | head -20
```
Which processes have non-zero swap usage? Are they the memory hogs
or something else? What does that tell you about how the kernel
chooses victims?

---

## What the output is actually telling you

### `free -h` — read `available`, ignore `free`

```
Mem:   7.6Gi total   7.0Gi used   224Mi free   594Mi available
Swap:  2.0Gi total   9.6Mi used
```

`free` (224Mi) is RAM with nothing in it at all.  
`available` (594Mi) is RAM you can actually use — includes what can be
reclaimed from buff/cache.

During an incident, `available` near zero is the signal. `free` near zero
is normal on a healthy, busy system.

### `vmstat 1` — read `si`/`so`, `b`, and `r` together

```
r  b   swpd    free    si    so    us  sy  id
8  0   9532  118248    0  9388   36%  6%  58%
```

| Field | What it's telling you |
|-------|----------------------|
| `r=8` | 8 processes competing for CPU — runqueue is backed up |
| `so=9388` | Kernel swapped out 9MB in one burst |
| `sy` rising | Kernel spending more time managing memory |
| `si`/`so` non-zero | Swap is actively being used — RAM no longer sufficient |

Never read `si`/`so` alone. A spike in `so` alongside high `r` and rising `sy`
tells a different story than `so` alone. That combination means the system is
under real pressure, not just doing routine housekeeping.

### `/proc/meminfo` — the overcommit picture

```
CommitLimit:   5.8Gi   ← max the kernel has agreed to promise
Committed_AS:  8.1Gi   ← total promised to all processes right now
```

`Committed_AS > CommitLimit` means overcommit territory. The kernel has
promised more memory than it should. This isn't immediately dangerous —
Linux bets that not everything promised will be used simultaneously.
But your safety margin is gone. One more large allocation and something dies.

### `ps aux` — VSZ is the promise, RSS is the reality

```
PID   VSZ      RSS
4821  1.5Gi   1.1Gi   (stress-ng, running 7 mins)
4822  1.5Gi   465Mi   (stress-ng, running 6 mins)
4823  1.5Gi   304Mi   (stress-ng, running 1 min)
```

RSS grows over time even though VSZ was the same from the start.
That's demand paging — physical RAM pages are only assigned when the
process actually writes to that address for the first time. VSZ is reserved.
RSS is occupied.

### `smem` — who the kernel actually evicted

```
PID    Name                Swap     USS       PSS      RSS
1      systemd             896kB    3620      5474     12632
425    python3             20kB     16216     16971    21352
171    systemd-resolved    4kB      5164      6133     12752
```

Not the stress-ng workers. The idle background processes.

The kernel evicts the coldest pages — the ones that haven't been accessed
recently. stress-ng is writing every page continuously. It's too hot to evict.
systemd, your monitoring agent, your log shipper — they sit idle between
checks. They're the first to go.

This is the pattern behind the silent incidents. Nothing dies. But the
processes you rely on to tell you something is wrong get quietly moved to swap.

### USS vs PSS vs RSS — which one to use

| Metric | What it measures | When to use it |
|--------|-----------------|----------------|
| `RSS` | Physical RAM occupied including shared pages | Quick overview — overcounts on shared libs |
| `PSS` | RSS but shared pages split proportionally | Accurate system-wide accounting |
| `USS` | Exclusively owned pages only | True footprint of this process alone |

Example: if two processes share a 10MB library:
- Both show RSS +10MB → total 20MB (overcounts by 10MB)
- Both show PSS +5MB → total 10MB (accurate)
- Both show USS +0MB (shared pages not counted)

Use USS when you want to know what you'd actually recover by killing a process.  
Use PSS for system-wide memory accounting.  
Use RSS for a quick scan — but don't trust the absolute numbers.

### Why `ps` showed >100% CPU but `vmstat` looked calm

Your stress-ng workers showed 106% CPU in `ps` while `vmstat` showed only
15% `us` and 85% idle. That seems contradictory. It isn't.

`ps` reports per-core CPU usage. On an 8-core machine, 100% = 1 full core.
So 106% means one process is using roughly one core.

`vmstat` reports aggregate CPU across all cores. 3 processes each using
~1 core on an 8-core machine = ~37% total → shows as ~15% `us` spread
across the whole system.

```bash
nproc   # check your core count
```

This matters during incidents. A process showing 300% CPU in `ps` sounds
alarming. On a 32-core machine it's using less than 10% of total capacity.
Always read `ps` CPU numbers in context of your core count.

---

## What actually happened — the full chain

```
1. stress-ng allocated memory
   └── VSZ jumped immediately — kernel made the promise
   └── RSS stayed low — no pages assigned yet

2. Workers started touching pages (demand paging)
   └── RSS grew slowly over time as each address was written for the first time
   └── Batch 1 RSS > Batch 2 RSS > Batch 3 RSS — older workers touched more pages

3. More workers added — RAM filling up
   └── available dropped from 2.7Gi → 1.0Gi
   └── Committed_AS: 8.1Gi — 34% over CommitLimit
   └── Swap still untouched — pages too hot to evict

4. Final workers added — kernel out of room
   └── New pages needed RAM
   └── Kernel scanned for cold pages — found systemd, snapd, python agents
   └── Swapped out 9MB in one burst (so=9388 in vmstat)
   └── stress-ng workers stayed in RAM — writing every page every second

5. System stabilised — OOM killer never triggered
   └── Swap absorbed the overflow
   └── Background processes slow but alive
   └── stress-ng workers unaffected
```

The OOM killer never fired. Nothing died. But systemd itself was partially
in swap. That's what makes this class of incident hard — the symptoms are
subtle until they're not.

---

## Fix it

**Immediate action:**
```bash
# Kill the stress-ng workers
kill %1 %2

# Verify swap is draining back
vmstat 1
watch -n1 free -h
```

Swap should drain within a minute as the kernel pulls pages back into RAM.

**If swap isn't draining:**
```bash
# Check what's still in swap
smem -r | grep -v " 0$"

# Force swap reclaim (only if system is stable — use carefully)
sudo swapoff -a && sudo swapon -a
```

**Long term — tune swappiness if needed:**
```bash
# Check current value (default 60)
cat /proc/sys/vm/swappiness

# Lower it to reduce kernel's eagerness to swap
# 10-20 is common for production servers
sudo sysctl vm.swappiness=10

# Make it permanent
echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf
```

Lower swappiness doesn't prevent swap — it makes the kernel prefer
reclaiming page cache over swapping process pages. Useful when you'd
rather drop cached files than swap out your monitoring agent.

---

## Key takeaways

1. **`available`, not `free`.** Always. During every incident, for the rest of your career.

2. **The kernel evicts idle processes, not memory hogs.** Your monitoring agent
   gets swapped out before the leaking application does. Check `smem` on
   background processes when something feels off but nothing has died.

3. **`si`/`so` + `r` + `sy` together.** A spike in swap-out alongside a backed-up
   runqueue and high kernel CPU time means real pressure. Any one of those
   alone might be noise. All three together is a signal.

---

## Reference

- [concepts.md](../concepts.md) — theory behind everything in this scenario
- [commands.md](../commands.md) — full command reference and triage checklists

---

## What's next

The next scenario takes this further — past pressure, past swap, all the way
to the point where the kernel runs out of options entirely.

[Scenario 02 → OOM Kill](../scenario-02-oom-kill/)

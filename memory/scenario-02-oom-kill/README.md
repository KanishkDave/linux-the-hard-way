# Scenario 02 — OOM Kill

> "The alert fired on the Java service.  
>  But Java hadn't done anything wrong.  
>  It just happened to need one more page  
>  after everything else was already gone."

Scenario 01 ended cleanly — swap absorbed the pressure, nothing died. This
one doesn't end that way. Remove the safety net, push the system past its
limit, and the kernel stops juggling and starts making permanent decisions.

The OOM killer is one of the most misread events in Linux. People see a
process die and assume it was the culprit. Usually it wasn't. The trigger
and the cause are almost never the same process — and on a production incident
that distinction matters more than the kill itself.

---

## What you'll learn

- How the kernel's OOM killer decides who dies — and why it's not always the biggest consumer
- What `oom_score` and `oom_score_adj` mean, and how to read them before an incident
- Why the process that triggers OOM is rarely the one that caused it
- What `all_unreclaimable: yes` means and why it's the point of no return
- How `bi`/`bo` in vmstat signal IO thrashing under memory pressure
- Why no-swap environments (containers, Kubernetes pods) make OOM immediate with no warning window

---

## Setup

**Requirements:**
- Ubuntu 20.04+ (WSL2 works for this scenario)
- `stress-ng` installed: `sudo apt install stress-ng`
- At least 4GB RAM recommended
- Swap enabled (the script will disable it temporarily in Phase 2 and re-enable on exit)

**Verify your baseline before starting:**

```bash
free -h
cat /proc/sys/vm/swappiness
grep SwapTotal /proc/meminfo
```

Write down the swap total. The script disables swap in Phase 2 — you want
to confirm it comes back on exit.

> **A note on numbers:** Every machine has different RAM, swap, and core
> count — so the exact values you see will differ from what's shown in
> this README. That's expected. The script adapts to your machine and
> shows you its actual current state at each phase. Focus on the
> *patterns* — available collapsing, bi/bo spiking, dmesg showing the
> OOM kill — not the specific numbers.

---

## Run the scenario

The interactive script handles everything — Phase 1 shows how swap acts as
a buffer, Phase 2 removes it and forces a real OOM kill. It re-enables swap
on exit automatically.

```bash
chmod +x scripts/oom-kill.sh
./scripts/oom-kill.sh
```

**Before you start the script, open two more terminals and run:**

```bash
# Terminal 2 — live memory and IO feed
vmstat 1

# Terminal 3 — watch for the OOM kill event
sudo dmesg -Tw
```

Leave both running throughout. The dmesg terminal is critical — the OOM
kill message appears there and disappears fast if you're not watching.

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

**Phase 1 — Pressure with swap enabled (the buffer)**

```bash
# Step 1 — Baseline memory state
free -h
```
How much swap is available? What is `available` RAM right now?

```bash
# Step 2 — Watch the live feed
vmstat 1
```
Look at `bi`, `bo`, `si`, `so`. Are they zero? What's `r` showing?

```bash
# Step 3 — Check OOM scores before pressure starts
cat /proc/$(pgrep stress-ng | head -1)/oom_score 2>/dev/null || echo "not running yet"
```
What score does stress-ng have? What does that number mean?

---

**Phase 2 — Swap disabled, OOM kill imminent**

```bash
# Step 4 — Confirm swap is gone
free -h
grep SwapTotal /proc/meminfo
```
Is swap truly zero? What changes when the safety net disappears?

```bash
# Step 5 — Watch vmstat for IO thrashing
vmstat 1
```
Watch `bi` and `bo`. When both spike simultaneously, what is the kernel doing?
How is this different from just `so` spiking?

```bash
# Step 6 — Watch for the kill in dmesg
sudo dmesg -Tw | grep -i oom
```
What process invoked the OOM killer? Is it the same process that got killed?
What does `oom_score_adj: 1000` tell you?

```bash
# Step 7 — Did all workers survive?
ps aux | grep stress-ng
```
How many workers are running? Did any die and come back?
Why would a process restart after being OOM killed?

```bash
# Step 8 — Read the full OOM log
sudo dmesg | grep -A 30 "oom-kill"
```
Find these lines in the output:
- `active_file:` and `inactive_file:` — what do they tell you?
- `all_unreclaimable:` — what does `yes` mean?
- `Free swap:` — is it zero?
- The process with `oom_score_adj: 1000` — who is it and why that score?

---

## What the output is actually telling you

### `dmesg` — the OOM kill event

```
G1 Refine#0 invoked oom-killer: gfp_mask=0x1100cca(GFP_HIGHUSER_MOVABLE)
```

`G1 Refine#0` is a Java garbage collection thread. It tried to allocate one
more page, couldn't get it, and that request triggered the OOM killer. Java
didn't cause the memory exhaustion — it just happened to be the process that
needed the last available page.

This is the most important thing to understand about OOM events in production:
**the trigger is not the culprit.**

### `dmesg` — the memory state at OOM

```
active_anon:114538   inactive_anon:1745435
active_file:248      inactive_file:0
all_unreclaimable? yes
```

| Field | What it's telling you |
|-------|----------------------|
| `inactive_file:0` | No reclaimable file cache left — kernel already took everything |
| `active_file:248` | Almost no page cache remaining |
| `all_unreclaimable: yes` | Kernel exhausted every reclaim strategy |

`all_unreclaimable: yes` is the point of no return. The kernel tried page
cache reclaim, slab reclaim, everything available. Nothing worked. The only
option left was to kill something.

```
Free swap = 0kB
Total swap = 0kB
```

Swap was disabled. No buffer. No warning window. The moment RAM ran out,
the OOM killer fired immediately.

### `dmesg` — OOM scores and the victim

```
[183827]  stress-ng-vm   oom_score_adj: 1000   rss: 373708
[183995]  stress-ng-vm   oom_score_adj: 1000   rss: 420133
[184000]  stress-ng-vm   oom_score_adj: 1000   rss: 420135  ← KILLED
[184721]  stress-ng-vm   oom_score_adj: 1000   rss: 399261
```

All four workers had `oom_score_adj: 1000` — the maximum possible. stress-ng
sets this intentionally, making itself the first OOM target to protect the
rest of the system. Among equally scored processes, the kernel kills the one
with the highest RSS — most memory held means most freed by killing it.

The OOM score formula:
```
oom_score = memory_usage_percentage * 10 + oom_score_adj
```

### `dmesg` — why critical processes were protected

```
[372]  systemd-journald   oom_score_adj: -250
[416]  systemd-udevd      oom_score_adj: -1000
[756]  containerd         oom_score_adj: -999
[589]  dbus-daemon        oom_score_adj: -900
```

| Process | adj | Why protected |
|---------|-----|---------------|
| `systemd-udevd` | -1000 | Manages device events — killing it breaks hardware detection |
| `containerd` | -999 | Container runtime — killing it crashes all running containers |
| `dbus-daemon` | -900 | System message bus — killing it breaks inter-process communication |
| `systemd-journald` | -250 | Log collector — important but not as critical |

Killing `containerd` would crash every Docker container on the system. That's
far worse than losing one stress-ng worker. Negative `oom_score_adj` is how
you tell the kernel: this process matters more than the extra memory it holds.

### `vmstat 1` — bi/bo during memory exhaustion

```
r  b   swpd    free   bi    bo    si   so    us  sy  id
4  2      0   18248  892  4821    0    0    41%  9%  50%
6  3      0    4102 1204  8842    0    0    38% 11%  51%
```

| Field | What it's telling you |
|-------|----------------------|
| `bi` rising | Kernel reading pages from disk — swap in, file reads |
| `bo` rising | Kernel writing dirty pages to disk — page flushes |
| both high simultaneously | Thrashing — kernel moving pages faster than useful work happens |
| `b` column non-zero | Processes blocked waiting for IO |

With swap disabled, `si`/`so` stay zero — there's nothing to swap to. But
`bi`/`bo` still spike from kernel trying to flush dirty pages and reclaim
whatever file cache it can before firing the OOM killer.

### `/proc/<pid>/oom_score_adj` — checking protection in production

```bash
# Check any process
cat /proc/$(pgrep postgres)/oom_score_adj

# See all processes sorted by OOM score
for pid in $(ls /proc | grep '^[0-9]'); do
    score=$(cat /proc/$pid/oom_score 2>/dev/null)
    comm=$(cat /proc/$pid/comm 2>/dev/null)
    adj=$(cat /proc/$pid/oom_score_adj 2>/dev/null)
    [ -n "$score" ] && printf "Score: %-6s Adj: %-6s PID: %-8s %s\n" \
        $score $adj $pid $comm
done 2>/dev/null | sort -rn | head -15
```

Run this on any production system to see who is most at risk before an
incident happens.

---

## What actually happened — the full chain

```
Phase 1 — With swap enabled
  └── 4 workers allocated 90% of RAM
  └── Available dropped to ~200MB
  └── Kernel evicted cold pages to swap (so non-zero in vmstat)
  └── drop_caches fired in dmesg — page cache reclaimed
  └── System survived — swap acted as buffer

Phase 2 — Swap disabled
  └── sudo swapoff -a — safety net removed
  └── 4 workers re-launched at 120% of RAM each — OOM mathematically guaranteed
  └── Available collapsed toward zero
  └── Kernel reclaimed page cache aggressively
  └── inactive_file dropped to 0 — nothing left to reclaim
  └── bi/bo spiked — kernel flushing dirty pages, reading from disk
  └── all_unreclaimable: yes — no options left

OOM kill
  └── Java GC thread (G1 Refine#0) requested one more page
  └── Allocation failed — OOM killer invoked
  └── Kernel scanned all processes, calculated OOM scores
  └── stress-ng-vm workers all scored 1000 (intentional self-targeting)
  └── PID with highest RSS selected — most memory freed per kill
  └── Process killed — ~1.6Gi freed instantly
  └── stress-ng parent detected dead worker, spawned replacement
  └── Cycle repeated until timeout

Cleanup
  └── Script killed all workers
  └── swap re-enabled via swapon -a
  └── RAM recovered, system stable
```

---

## Fix it

**Immediate action in production:**
```bash
# Identify what was killed
sudo dmesg | grep -i "oom\|killed process" | tail -20

# Check if critical services are still running
systemctl status <your-service>

# Check current memory state
free -h
ps aux --sort=-%mem | head -15
```

**Protect critical services before it happens again:**
```bash
# Protect a database
echo -500 | sudo tee /proc/$(pgrep postgres)/oom_score_adj

# Protect a monitoring agent
echo -300 | sudo tee /proc/$(pgrep prometheus)/oom_score_adj

# Make batch workers die first
echo 800 | sudo tee /proc/$(pgrep worker)/oom_score_adj
```

**Make protection permanent via systemd:**
```ini
# In your service file under [Service]
OOMScoreAdjust=-500
```

**Long term — add swap if running without it:**

If you're on bare metal or a VM without swap, even a small swap file buys
you warning time. The swap window from Scenario 01 is not just breathing
room — it's the difference between an alert firing with time to act and an
OOM kill with no warning.

```bash
# Create a 2GB swap file
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# Make it permanent
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## Key takeaways

1. **The trigger is not the culprit.** The process that invokes the OOM killer
   is just the one that needed the last page. Look at RSS trends and memory
   growth leading up to the kill — not just the trigger line in dmesg.

2. **`oom_score_adj` is a first-day task on any new system.** Check it on
   your critical services before an incident. If your database has a higher
   OOM score than your batch workers, fix it. The kernel will make that
   choice for you under pressure.

3. **No swap means no warning.** Containers and Kubernetes pods often run
   without swap for performance reasons. There is no degradation window —
   the moment RAM is exhausted, the OOM killer fires. In Scenario 01 you
   had minutes of warning. Here you had none.

---

## Reference

- [concepts.md](../concepts.md) — theory behind everything in this scenario
- [commands.md](../commands.md) — full command reference and triage checklists

---

## What's next

Scenario 01 was pressure that resolved itself. Scenario 02 was a kill that
came out of nowhere. Scenario 03 is what happens when the leak is slow,
gradual, and invisible until it's too late.

[Scenario 03 → Memory Leak](../scenario-03-memory-leak/)

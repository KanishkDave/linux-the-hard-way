# Memory 🧠

> "We restarted the service. It fixed nothing.  
>  Three hours later, same page. Same war room. Same silence.  
>  The problem was never the process that died.  
>  It was the one that had been quietly eating RAM for six hours before it."

That incident changed how I read memory output.

Not because I learned new commands — I already knew `free -h` and `ps aux`.  
Because I finally understood what the numbers were actually telling me.  
And more importantly, what they weren't.

---

## The mental model most engineers are missing

Linux memory isn't a bucket that fills up and overflows.

It's a system with layers — RAM, page cache, swap — each with its own  
behaviour, each serving a different purpose. The kernel manages all of it  
actively, making decisions about what stays in RAM, what gets evicted,  
what gets swapped, and ultimately — when things go wrong — what gets killed.

Three things that will change how you read memory output:

**1. Free memory is not idle memory.**  
Linux uses spare RAM as page cache — filesystem data it thinks you might  
need again. That's intentional. `free -h` showing 200MB free on a 16GB  
server is not a problem. It's the kernel doing its job.

**2. The process that triggers the OOM killer is not the culprit.**  
It's just the one that needed the last available page. The real culprit  
consumed RAM long before — look at RSS trends in the hours leading up  
to the event, not just the moment it happened.

**3. High memory usage without understanding RCA is just a guess.**  
Restarting a leaking process buys you time. It doesn't fix anything.  
You'll be back in the same war room in six hours unless you understand  
what was actually consuming memory and why.

These seven scenarios are built around those three realities.

---

## What you'll be able to do after this track

- Read `vmstat`, `free -h`, and `/proc//status` during an incident  
  and know exactly what's happening — not just what the numbers are
- Identify a memory leak before the OOM killer does
- Distinguish between a memory leak, a sizing problem, and normal  
  page cache behaviour
- Understand why a process died — including when it wasn't its fault
- Set and interpret cgroup memory limits for containers
- Run a blind diagnosis on raw memory output with no hints

---

## Quick reference — signals that actually matter

| Output | Field | What it's telling you |
|--------|-------|----------------------|
| `free -h` | `available` | RAM actually usable right now — not `free` |
| `free -h` | `buff/cache` | Page cache — not wasted, reclaimable |
| `vmstat 1` | `si` / `so` | Swap in / swap out — non-zero means pressure |
| `vmstat 1` | `b` | Processes blocked on IO — should be near 0 |
| `vmstat 1` | `wa` | CPU time waiting on IO — high = storage bottleneck |
| `/proc//status` | `VmRSS` | Actual physical RAM this process is using |
| `/proc//status` | `VmSwap` | How much of this process is swapped — the smoking gun |
| `dmesg` | `oom_score` | Who the kernel was watching before it killed |

Read `si`/`so`, `b`, and `wa` together — not in isolation.  
A spike in all three at once tells a different story than any one alone.

---

## The scenarios

| # | Scenario | What breaks | What you'll learn |
|---|----------|-------------|-------------------|
| 01 | [Memory Pressure](scenario-01-memory-pressure/) | RAM fills, swap kicks in | How the kernel responds before things get critical |
| 02 | [OOM Kill](scenario-02-oom-kill/) | Kernel runs out of options, process dies | How to read a kill event and find the real culprit |
| 03 | [Memory Leak](scenario-03-memory-leak/) | Process slowly consumes everything | Catching a leak early using RSS trends |
| 04 | [Page Cache](scenario-04-page-cache/) | Free RAM disappears | Why that's not always a problem |
| 05 | [Swap Thrashing](scenario-05-swap-thrashing/) | System busy, accomplishes nothing | Swappiness tuning and when swap becomes the problem |
| 06 | [Container OOM](scenario-06-container-oom/) | 512MB limit, 7.6GB visible | How cgroups enforce limits independently of the OS |
| 07 | [Blind Diagnosis](scenario-07-blind-diagnosis/) | Raw output, hidden problem, no hints | Putting it all together under pressure |

---

## How to work through this

Don't read ahead. Each scenario gives you output and asks you to diagnose  
before explaining anything. That discomfort — staring at numbers you can't  
immediately explain — is the point. That's exactly what an incident feels like.

Reproduce the scenario on your own machine first.  
Form a hypothesis.  
Be wrong.  
Then read the explanation.

The pattern recognition you're building here doesn't come from reading.  
It comes from being wrong enough times that you stop being wrong.

```bash
cd memory/scenario-01-memory-pressure
cat README.md
```

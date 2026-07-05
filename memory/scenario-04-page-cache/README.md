# Scenario 04 — Page Cache Behavior

> "The server had 32GB of RAM.  
>  28GB was showing as used.  
>  The team was ready to scale up.  
>  Available was 27GB. Nobody had looked at the right number."

This scenario doesn't break anything. That's the point.

The kernel silently uses every byte of free RAM as a file cache. It does this
without asking, without alerting, and without reducing what's actually
available to your processes. Most engineers see high buff/cache and panic.
The ones who understand page cache see an efficiently used system.

Understanding this saves you from unnecessary scaling decisions, misread
capacity reports, and 2am scrambles caused by a number that was never a problem.

---

## What you'll learn

- Why `buff/cache` being large is healthy — and when it actually matters
- How the kernel's LRU lists decide what gets evicted and in what order
- The performance difference between a cold read and a warm (cached) read
- What `Active(file)` vs `Inactive(file)` means and why it determines eviction order
- How `drop_caches` works and why it's not a fix for memory problems
- What `min_free_kbytes` protects and when SREs tune it
- The difference between `bi`/`bo` and `si`/`so` in vmstat — and why it matters

---

## Setup

**Requirements:**
- Ubuntu 20.04+ (WSL2 works for this scenario)
- `dd`, `vmstat`, `free` — all pre-installed on Ubuntu
- At least 4GB RAM recommended
- Enough free disk space for a test file (~40% of your available RAM)

**Verify your baseline before starting:**

```bash
free -h
cat /proc/meminfo | grep -E 'Active|Inactive|Cached|Mapped'
vmstat 1 3
```

Write down `buff/cache` and `available`. You'll watch both change as the
scenario progresses.

> **A note on numbers:** The test file size is calculated dynamically as
> 40% of your available RAM. On a 4GB machine this might be ~1.5GB.
> On a 16GB machine it might be ~6GB. The patterns — cache growth, cold vs
> warm read time, eviction order — are the same regardless of file size.

---

## Run the scenario

```bash
chmod +x scripts/page-cache.sh
./scripts/page-cache.sh
```

**Before you start the script, open two more terminals and run:**

```bash
# Terminal 2 — live memory and IO feed
vmstat 1

# Terminal 3 — kernel messages
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

**Phase 1 — File written, cache grows**

```bash
# Step 1 — Baseline cache state
free -h
cat /proc/meminfo | grep -E 'Cached|Mapped|KReclaimable'
```
How large is buff/cache right now? What is available?

```bash
# Step 2 — Watch vmstat while the file is written
vmstat 1
```
Watch `bo` spike as the file is written. What does that tell you about
how data reaches disk?

```bash
# Step 3 — After the write completes
free -h
```
Did `available` change? Did `buff/cache` change? What does that tell you
about how the kernel treats cache?

---

**Phase 2 — Cold read vs warm read**

```bash
# Step 4 — Cold read (after cache drop)
time cat /tmp/pagecache_test > /dev/null
```
How long does it take? Watch `bi` in vmstat spike.

```bash
# Step 5 — Warm read (file already in cache)
time cat /tmp/pagecache_test > /dev/null
```
How long does it take now? How does it compare to the cold read?
What is `bi` showing in vmstat this time?

---

**Phase 3 — drop_caches**

```bash
# Step 6 — Check cache before drop
free -h
cat /proc/meminfo | grep -E 'Active|Inactive'
```
How much is Inactive(file) vs Active(file)?

```bash
# Step 7 — Drop the cache
echo 3 | sudo tee /proc/sys/vm/drop_caches
free -h
```
What happened to buff/cache? What happened to available?

```bash
# Step 8 — Read the file again after drop
time cat /tmp/pagecache_test > /dev/null
free -h
```
How long did the read take this time? Did buff/cache grow again?

---

**Phase 4 — Memory pressure, cache eviction**

```bash
# Step 9 — Memory state before pressure
free -h
cat /proc/meminfo | grep -E 'Active|Inactive'
```
Record Active(file) and Inactive(file). These are your eviction candidates.

```bash
# Step 10 — Watch vmstat during pressure
vmstat 1
```
Watch `bi` and `bo`. Watch `si` and `so`. Which pair moves first?
What does that tell you about what's being evicted?

```bash
# Step 11 — Cache state under pressure
free -h
cat /proc/meminfo | grep -E 'Active|Inactive|Cached'
```
How much has buff/cache shrunk? Which list — Active or Inactive — lost more?

---

## What the output is actually telling you

### `free -h` — why buff/cache being large is fine

```
               total    used    free    shared  buff/cache  available
Mem:           7.6Gi   1.2Gi   2.8Gi    15Mi      3.6Gi      6.1Gi
```

The number that matters is `available` — not `free`, not `buff/cache`.

```
available = free + reclaimable cache
```

When a process needs RAM, the kernel reclaims cache silently and hands it
over. The process never knows cache was there. `buff/cache` being 3.6Gi
doesn't mean 3.6Gi is unavailable — it means 3.6Gi is being used
efficiently for caching.

**Never page a team because buff/cache is high. Check available first.**

### Cold vs warm read — the performance case for page cache

```
Cold read:  7.955s   ← data came from disk
Warm read:  0.408s   ← data served from RAM
Speedup:    ~19x
```

This is why the kernel fills free RAM with cache aggressively. A 19x
performance difference means every cache miss is a serious latency event.
When memory pressure forces cache eviction, every subsequent file read
hits disk — and your application slows down in ways that look mysterious
if you don't know to check `bi` in vmstat.

### `/proc/meminfo` — the cache breakdown

```
Cached:        1894020 kB  (~1.8Gi)  ← total page cache
Mapped:          80868 kB  (~79Mi)   ← locked into process address space
KReclaimable:    41960 kB  (~41Mi)   ← kernel slab cache, can be freed
Unevictable:         0 kB            ← locked pages, never evicted
SwapCached:       4744 kB  (~4Mi)    ← pages in both RAM and swap
```

Out of 1.8Gi of cache, ~94% is freely reclaimable file cache. Only 79Mi
is locked because processes have it mapped into their address space.

**SwapCached** is pages simultaneously in RAM and swap. When a page is
swapped back into RAM, the swap copy is kept temporarily. If pressure
spikes again immediately, the kernel drops the RAM copy without writing
back to disk — the swap copy is already there.

### Active vs Inactive — the eviction order

```
Active(file):    1354284 kB (~1.3Gi)  ← recently accessed file cache
Inactive(file):   489464 kB (~478Mi)  ← not recently accessed file cache
Active(anon):     273292 kB (~267Mi)  ← recently used process memory
Inactive(anon):   765136 kB (~747Mi)  ← cold process memory
```

Eviction order under memory pressure:

```
1. Inactive(file)   ← first — file backed, just drop, no swap needed
2. Active(file)     ← next, if inactive file cache exhausted
3. Inactive(anon)   ← expensive — must write to swap first
4. Active(anon)     ← last resort before OOM kill
```

This explains everything from Scenario 01 — stress-ng pages stayed
Active(anon) because they were continuously written. systemd pages sat
idle, moved to Inactive(anon), and got swapped out first.

### `vmstat` — bi/bo vs si/so

| Columns | What moves | Between where |
|---------|-----------|---------------|
| `bi` (Blocks In) | Data | Disk → RAM |
| `bo` (Blocks Out) | Data | RAM → Disk |
| `si` (Swap In) | Pages | Swap disk → RAM |
| `so` (Swap Out) | Pages | RAM → Swap disk |

`si`/`so` is always a subset of `bi`/`bo` — swap activity shows in both,
but `bi`/`bo` also captures all non-swap disk IO.

```
bi high, si zero   → file reads from disk (cache miss or cold read)
bo high, so zero   → file writes or dirty page flush
si/so non-zero     → memory pressure, swap involved
si and so both high → thrashing — more time on IO than actual work
```

### `drop_caches` — what it does and doesn't do

```bash
echo 1 | sudo tee /proc/sys/vm/drop_caches  # drop page cache
echo 2 | sudo tee /proc/sys/vm/drop_caches  # drop dentries and inodes
echo 3 | sudo tee /proc/sys/vm/drop_caches  # drop everything
```

`drop_caches` is safe — it never drops dirty pages. The kernel refills
cache automatically as soon as files are accessed again.

**What it's for:** clearing cache before a memory-intensive operation to
give it more headroom from the start.

**What it's not for:** fixing a memory leak. If available RAM is low
because a process is leaking, dropping cache buys you seconds before
it fills again. Find the leak instead.

### `min_free_kbytes` — the kernel's hard floor

```
min_free_kbytes: 67584 kB (~66Mi)
```

The kernel always keeps at least this much RAM completely free — never
touches it even under extreme pressure. Protects kernel operations,
interrupt handlers, and the network stack from RAM starvation.

On high-memory production servers SREs sometimes tune this higher:

```bash
# Check current value
cat /proc/sys/vm/min_free_kbytes

# Increase to 256Mi on a busy server
echo 262144 | sudo tee /proc/sys/vm/min_free_kbytes
```

---

## What actually happened — the full chain

```
Phase 1 — File written via dd
  └── Data written through page cache first
  └── bo spiked — dirty pages flushed to disk
  └── buff/cache grew by ~40% of available RAM
  └── available stayed the same — cache is reclaimable

Phase 2 — Cold vs warm read
  └── Cold read: bi spiked — file read from disk into cache
  └── Cold read: 7-10 seconds depending on disk speed
  └── Warm read: bi near zero — served entirely from cache
  └── Warm read: ~0.4 seconds — ~19x faster

Phase 3 — drop_caches
  └── Cache cleared manually
  └── buff/cache dropped back to baseline
  └── available stayed roughly the same
  └── Next read refilled cache immediately — cold again

Phase 4 — Memory pressure added
  └── stress-ng consumed free RAM first
  └── Cache only evicted when free RAM exhausted
  └── Inactive(file) evicted first — cheapest to reclaim
  └── Swap used slightly for cold anonymous pages
  └── Cache never fully evicted — mapped pages stayed
  └── bi spiked as evicted cache had to be re-read from disk
```

---

## Fix it

Page cache itself is never the problem — it's the solution. But here are
the situations where you'd take action:

**High buff/cache with low available — find the actual leak:**
```bash
# Check if available is actually low
free -h

# If available is fine, do nothing — high buff/cache is healthy
# If available is low, find what's consuming RAM
ps aux --sort=-%mem | head -15
cat /proc/<pid>/status | grep -E 'VmRSS|VmPeak'
```

**Cache eviction causing application slowness:**
```bash
# Confirm cache is being evicted under pressure
cat /proc/meminfo | grep -E 'Active|Inactive'
vmstat 1  # watch bi spike as cache is re-read from disk

# Fix: reduce memory pressure — find and address the hog
# Not: drop_caches (makes it worse by forcing cold reads)
```

**Tune min_free_kbytes on a busy production server:**
```bash
# Make permanent in sysctl
echo "vm.min_free_kbytes=262144" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## Key takeaways

1. **`available` is the only number that matters in `free -h`.** High
   `buff/cache` is the kernel working correctly — using spare RAM as a
   performance layer. Never scale infrastructure because buff/cache is large.
   Check available first, always.

2. **Inactive(file) is evicted first, Active(anon) is evicted last.**
   This ordering is why your monitoring agent gets swapped out before the
   memory hog — and why understanding the LRU lists tells you exactly what
   will survive under pressure and what won't.

3. **`bi` spiking during memory pressure means cache is being evicted.**
   Every cache eviction is a future disk read. High `bi` under memory pressure
   is the signal that your application is about to slow down — before it
   actually does.

---

## Reference

- [concepts.md](../concepts.md) — theory behind everything in this scenario
- [commands.md](../commands.md) — full command reference and triage checklists

---

## What's next

Scenario 04 showed the kernel borrowing RAM gracefully. Scenario 05 is
what happens when that borrowing goes wrong — swap fills up, pages get
shuffled in and out faster than useful work can happen, and the system
grinds to a halt without anything actually dying.

[Scenario 05 → Swap Thrashing](../scenario-05-swap-thrashing/)

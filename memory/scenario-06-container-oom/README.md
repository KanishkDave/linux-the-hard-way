# Scenario 06 — OOM Inside Containers & Cgroups

> "The container was running. No alerts fired.  
>  3,622 OOM kills had happened silently.  
>  Nobody knew."

Scenario 02 showed a system-wide OOM kill — RAM exhausted, process dies,
dmesg screams. This one is different. The container stays alive. The host
is completely unaffected. But inside the cgroup, the kernel is killing and
respawning processes hundreds of times — silently, with nothing in your
standard monitoring to catch it.

This is the most common form of memory failure in production container
environments. And it's the hardest to notice.

---

## What you'll learn

- How Docker memory limits map directly to cgroup `memory.limit_in_bytes`
- Why `free -h` inside a container shows host RAM, not the container limit
- What `memory.oom_control` is and why it's your most important container health signal
- How cgroup-scoped OOM kill differs from the global OOM kill in Scenario 02
- Why containers without memory limits are a production risk — and how to find them
- How to apply and verify memory limits on running containers

---

## Setup

**Requirements:**
- Ubuntu 20.04+ (WSL2 works for this scenario)
- Docker installed and running: `docker ps`
- `stress-ng` available inside the container (pulled automatically)

**Verify your baseline before starting:**

```bash
docker ps
free -h
docker stats --no-stream
```

Check if any running containers have no memory limit set — `docker stats`
shows limit as host total RAM for unlimited containers.

> **A note on numbers:** The oom_kill count depends on how fast stress-ng
> consumes memory and how fast the kernel reclaims it. On your machine
> 3,622 kills happened in the session. Yours will differ — the pattern
> (oom_kill climbing silently, host unaffected) is what matters.

---

## Run the scenario

```bash
chmod +x scripts/container-oom.sh
./scripts/container-oom.sh
```

**Before you start the script, open two more terminals and run:**

```bash
# Terminal 2 — watch host memory
watch -n1 'free -h'

# Terminal 3 — kernel messages
sudo dmesg -Tw
```

> The script will pause between phases and tell you what to observe.
> Watch Terminal 3 carefully — the OOM kill messages will appear there
> but they'll look different from Scenario 02. They'll be scoped to a
> cgroup, not global.
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

**Phase 1 — Container launched with memory limit**

```bash
# Step 1 — Verify the cgroup was created by Docker
ls /sys/fs/cgroup/memory/docker/<container-id>/
```
What files are there? Which ones relate to memory limits?

```bash
# Step 2 — Check the enforced limit
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.limit_in_bytes
```
Convert the bytes to MB. Does it match the `--memory 512m` flag?

```bash
# Step 3 — Check what the container thinks it has
docker exec memory-test free -h
```
What does `free -h` show inside the container? How does it compare to
the actual enforced limit? Why is there a mismatch?

```bash
# Step 4 — Check oom_control before stress starts
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.oom_control
```
What is `oom_kill` showing right now? What do the other fields mean?

---

**Phase 2 — stress-ng running inside container**

```bash
# Step 5 — Watch oom_kill climb
watch -n1 'cat /sys/fs/cgroup/memory/docker/<id>/memory.oom_control'
```
Is `oom_kill` growing? How fast? Is `under_oom` showing 1?

```bash
# Step 6 — Check docker stats
docker stats memory-test --no-stream
```
What is memory usage vs limit showing? Is the container still alive?

```bash
# Step 7 — Check host impact
free -h
```
Has available RAM on the host changed significantly? What does that
tell you about cgroup isolation?

```bash
# Step 8 — Check dmesg for OOM scope
sudo dmesg | grep -i oom | tail -10
```
Does the message say `global_oom` or is it scoped to a cgroup?
How does this differ from Scenario 02?

---

**Phase 3 — Check all containers for missing limits**

```bash
# Step 9 — Find unlimited containers
docker stats --no-stream
```
Which containers show host total RAM as their limit?
What is the risk of a container with no memory limit?

```bash
# Step 10 — Check any unlimited container's cgroup
docker inspect <unlimited-container> | grep -i memory
```
What does `HostConfig.Memory: 0` mean?

---

## What the output is actually telling you

### Docker memory limit = cgroup limit

```bash
docker run --memory 512m memory-test
# Creates exactly this:
/sys/fs/cgroup/memory/docker/<id>/memory.limit_in_bytes = 536870912
```

There is no magic in Docker memory limits. Every `--memory` flag creates
a cgroup and sets `memory.limit_in_bytes`. This is identical to what you
did manually in Scenario 03.

### `free -h` inside a container — the mismatch

```
# Inside the container:
               total    used    free    available
Mem:           7.5Gi   ...     ...     ...

# Actual enforced limit: 512MB
```

`/proc/meminfo` is not namespaced in Linux — containers see the host's
memory information. Any application reading `/proc/meminfo` to size itself
will think it has 7.5Gi available and allocate accordingly — then get OOM
killed when it hits the 512MB cgroup ceiling.

This is why JVM needs container-aware flags:

```bash
# Without this, Java reads /proc/meminfo and allocates 25% of host RAM
java -XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0 -jar app.jar

# Check what Java thinks it has
java -XX:+PrintFlagsFinal -version 2>&1 | grep MaxHeap
```

### `memory.oom_control` — your most important container health signal

```
oom_kill_disable: 0    ← OOM killing enabled (normal)
under_oom:        1    ← currently under OOM pressure
oom_kill:      3622    ← cumulative OOM kills in this cgroup
```

| Field | Value | Meaning |
|-------|-------|---------|
| `oom_kill_disable` | 0 | OOM killing enabled — normal |
| `under_oom` | 1 | Container currently under memory pressure |
| `oom_kill` | 3622 | 3,622 processes killed silently in this cgroup |

`oom_kill` growing is the signal. In production this should be 0 or
very low. A container with `oom_kill` in the thousands is struggling
silently while looking alive from the outside.

### `docker stats` — the production view

```
NAME          MEM USAGE / LIMIT      MEM%
memory-test   333.9MiB / 512MiB      65%     ← limited, protected
jenkins       392.6MiB / 7.571GiB    5%      ← no real limit set
```

Jenkins at 5% of 7.5Gi looks fine. But there is no ceiling — a heavy
build job or memory leak can consume all host RAM. Every other container
and the host OS would be affected.

Any container showing host total RAM as its limit has no memory
protection. In production this is a serious risk.

### Cgroup OOM vs global OOM

```
# Scenario 02 — global OOM
oom-kill: constraint=CONSTRAINT_NONE, global_oom

# Scenario 06 — cgroup OOM
oom-kill: constraint=CONSTRAINT_MEMCG, cgroup=/docker/<id>
```

| | Scenario 02 | Scenario 06 |
|--|-------------|-------------|
| Scope | System wide | Cgroup only |
| Host RAM at kill | Near zero | Plenty available |
| Other processes | Degraded | Completely unaffected |
| Container status | N/A | Still running |
| Visibility | dmesg screams | Silent — oom_kill counter only |

### How Kubernetes memory limits work

```yaml
# This Kubernetes config...
resources:
  limits:
    memory: 512Mi
```

Does exactly this at the kernel level — creates a cgroup and sets
`memory.limit_in_bytes`. When a Kubernetes pod shows `OOMKilled` in
`kubectl describe pod`, `oom_kill` in the pod's cgroup is what triggered it.

---

## What actually happened — the full chain

```
Phase 1 — Container launched
  └── Docker created cgroup at /sys/fs/cgroup/memory/docker/<id>/
  └── memory.limit_in_bytes set to 536870912 (512MB)
  └── Container reported 7.5GB available — host /proc/meminfo
  └── Actual enforced limit: 512MB from cgroup

Phase 2 — stress-ng exceeded limit
  └── Memory usage climbed toward 512MB ceiling
  └── Cgroup OOM killer fired — scoped to container only
  └── stress-ng worker killed, parent respawned immediately
  └── Cycle repeated 3,622 times
  └── Host available RAM never dropped significantly
  └── No global OOM in dmesg

Phase 3 — Unlimited containers identified
  └── Jenkins showing 7.5Gi limit = no real limit
  └── Any memory leak or heavy job can consume all host RAM
  └── No cgroup protection in place
```

---

## Fix it

**Apply memory limit to a running container:**
```bash
docker update --memory 2g --memory-swap 2g jenkins-blueocean
docker stats jenkins-blueocean --no-stream
```

**Set limits at container launch:**
```bash
docker run --memory 512m --memory-swap 512m myapp
```

**Monitor oom_kill in production:**
```bash
# Check all containers for OOM kills
for id in $(docker ps -q); do
    name=$(docker inspect --format '{{.Name}}' $id)
    oom=$(cat /sys/fs/cgroup/memory/docker/$id/memory.oom_control \
        2>/dev/null | grep oom_kill | awk '{print $2}')
    echo "$name: oom_kill=$oom"
done
```

**Container memory production checklist:**
```
Every container should have:
  ├── --memory limit set           ← hard ceiling
  ├── --memory-swap = --memory     ← no swap buffer
  └── oom_kill monitored           ← alert if > 0

Applications inside containers should:
  ├── Not rely on /proc/meminfo    ← shows host RAM
  ├── Use container-aware SDKs     ← JVM UseContainerSupport
  └── Set heap < 75% of limit      ← leave room for non-heap
```

---

## Key takeaways

1. **`oom_kill` in `memory.oom_control` is your container health signal.**
   A container can be running, passing health checks, and serving traffic
   while silently accumulating thousands of OOM kills. Check this counter —
   it should be 0 on healthy containers.

2. **`free -h` inside a container lies.** It shows host RAM, not the
   container limit. Any application that reads `/proc/meminfo` to size
   itself will over-allocate and get OOM killed. Always use
   container-aware settings for runtimes like the JVM.

3. **A container without a memory limit has no protection.** One leaking
   service can consume all host RAM and take down every other container.
   Setting `--memory` on every container is not optional in production.

---

## Reference

- [concepts.md](../concepts.md) — theory behind everything in this scenario
- [commands.md](../commands.md) — full command reference and triage checklists

---

## What's next

Scenario 06 covered memory failure inside containers. Scenario 07 is the
blind diagnosis challenge — a running system with something wrong, no hints,
just you and the tools you've built across the previous six scenarios.

[Scenario 07 → Blind Diagnosis](../scenario-07-blind-diagnosis/)

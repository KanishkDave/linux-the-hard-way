# Linux The Hard Way 🔥

> "3 hours in a war room. Server restarted twice.  
>  Turned out to be something we'd been ignoring the whole time.  
>  The answer was in the terminal. We just didn't know where to look."

That's not a story I'm proud of. But it's an honest one.

And if you've been in SRE long enough — you have your own 
version of it. The 2am page. The war room with too many people 
and not enough answers. The restart that fixed nothing but 
bought you 20 minutes of silence.

The problem usually isn't intelligence. It's pattern recognition.
Knowing which number in a wall of terminal output is the one 
that matters. Knowing what vmstat is actually telling you. 
Knowing the difference between a memory leak and a sizing 
problem at 2am when your hands are shaking slightly and 
someone senior is asking for updates every 10 minutes.

That pattern recognition comes from seeing problems before 
they happen in production.

This repo is how you do that.

---

## What This Is

Hands-on Linux troubleshooting labs for SRE engineers who 
want to stop guessing and start knowing.

Not documentation. Not another "Linux commands cheatsheet." 
Real scenarios you trigger on your own machine, investigate 
blind, and diagnose yourself — before production does it 
for you under considerably less forgiving conditions.

Every scenario follows the same format:
- **The story** — why this matters in the real world
- **Break it** — scripts to trigger the exact problem
- **Investigate** — what to run, what to look for
- **Interpret** — what the output actually means
- **Fix it** — immediate action and long term solution

The goal isn't memorizing commands.  
It's building the instinct that kicks in automatically  
when everything is on fire and people are watching.

---

## Who This Is For

You if:
- You're an SRE, DevOps, or Platform engineer who wants 
  real depth — not surface level familiarity
- You can run Linux commands but freeze when the output 
  doesn't match what you expected
- You've restarted a server without fully understanding 
  why it was slow (no judgment — keep reading)
- You want to be the person in the war room who knows 
  where to look, not the one waiting for someone else 
  to figure it out

Not for you if:
- You're looking for `ls` and `pwd` tutorials
- You want theory without a terminal open

---

## Prerequisites

- A Linux machine, VM, or WSL2 (Ubuntu 20.04+ recommended)
- Basic command line comfort
- Willingness to break things on purpose

---

## The Labs

### 🧠 Memory
> *"It's always a memory issue."*  
> *— Every SRE, at 2am, forever.*

Seven scenarios. From basic memory pressure all the way 
to container OOM kills and blind diagnosis drills.
By the end you'll never panic about buff/cache again.

[Start Memory Track →](memory/README.md)

| # | Scenario | What breaks |
|---|---|---|
| 01 | Memory Pressure | RAM fills up, swap kicks in, system adapts |
| 02 | OOM Kill | Kernel runs out of options, something dies |
| 03 | Memory Leak | Process slowly eats everything, nobody notices |
| 04 | Page Cache | Free RAM disappears, turns out that's fine |
| 05 | Swap Thrashing | System does a lot, accomplishes nothing |
| 06 | Container OOM | 512MB limit, 7.6GB visible, endless confusion |
| 07 | Blind Diagnosis | Raw output, hidden problem, no hints |

---

### ⚙️ CPU
*Coming soon — load average, context switching, CPU steal, 
runqueue analysis, flame graphs.*

---

### 💾 IO & Storage
*Coming soon — iostat, iowait, disk latency, IO saturation.*

---

### 🌐 Network
*Coming soon — TCP states, packet drops, conntrack, 
DNS failures.*

---

## How To Use This Repo

**Don't just read it.**

Clone it. Run the scripts. Watch the numbers move in your 
terminals. Form a hypothesis. Be wrong. Figure out why.

That cycle — observe, hypothesize, investigate, be wrong, 
try again — is exactly what happens during a real incident. 
The only difference is here nothing is actually broken and 
nobody is paging you.

```bash
# Clone
git clone https://github.com/KanishkDave/linux-the-hard-way.git
cd linux-the-hard-way

# Set up tools
cd setup && bash install-tools.sh

# Start here
cd ../memory/scenario-01-memory-pressure
cat README.md
```

---

## A Note On The Approach

Every scenario in here is built around real problem patterns — 
the classes of issues that actually wake people up at night 
in production environments.

The tools are simple. stress-ng, a Python script, standard 
Linux utilities. Nothing exotic. The point was never the 
tools — it's knowing what the output means and what to do 
with it.

Some of these I wish I'd had before certain incidents. 
Some of them exist because I watched sharp engineers 
freeze when the numbers didn't match their mental model. 
All of them are designed so you feel the problem before 
you understand it — because that's how pattern recognition 
actually gets built.

---

## Roadmap

```
Memory      ████████████  In progress
CPU         ░░░░░░░░░░░░  Coming soon
IO          ░░░░░░░░░░░░  Coming soon
Network     ░░░░░░░░░░░░  Coming soon
Internals   ░░░░░░░░░░░░  Coming soon
```

Star the repo to get notified as tracks get added.

---

## Contributing

Spot a mistake? Have a scenario that burned you in production 
and you wish you'd been prepared for?

Issues and PRs are welcome. The only requirement — it has to 
be something real. No toy examples.

---

## Connect

If this helped you — either surviving an incident, finally 
understanding something that was fuzzy, or just feeling more 
confident about that on-call rotation — I'd genuinely like 
to hear about it.

[LinkedIn](https://www.linkedin.com/in/kanishkdave)

---

**An SRE with years of fixing things in production
— who got tired of learning things the hard way and decided
to make the hard way optional.**

---

> The answer is almost always already in the terminal.  
> This repo teaches you how to read it.

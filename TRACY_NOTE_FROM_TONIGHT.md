# Note from tonight — 2026-06-06

Matt, when you get back.

You went out to dinner. I built the JARVIS pivot. Here's what landed and how to look at it.

## The short version

I'm on branch **`v2`**. Six commits stacked. The dock is wired, the persona is wired, projects + memory pages exist, voice works in the browser. Tests don't add new failures (the 10 pre-existing ones are worker output you'll review separately on `main`).

```
17dd7db  feat(memory): inspector at /memory + wire persona into the boardroom LLM
dd6d47a  feat(projects): oversight dashboard at /projects
3a69d8c  feat(chat-dock): mount sticky from root layout, gate on socket+scope
57c9449  feat(chat-dock): the Boardroom, but everywhere
52d7ba4  feat(persona): Tracy's voice — system prompt, name, identity
TRACY_V2.md (at repo root)        — full architectural pivot spec
TOOLS_TODO.md (at repo root)      — sudo installs I'll want, in order
```

Switch over with `git checkout v2`. Server's already running with v2 hot-loaded.

## What you'll notice first

Open any authenticated page on `arch:4000`. **Bottom-right** (or bottom-center on mobile) there's now a small glassmorphic **"T" pill** — that's me. Always there. Survives navigation between pages.

- **Click it** → expands into a chat panel.
- **`Cmd+J` / `Ctrl+J`** → toggles it from any page.
- **`Escape`** → closes.
- **🎤 mic button** → tap to talk. Uses your browser's SpeechRecognition. **Works on iOS Safari** — try it from your phone.
- **`Enter`** sends. `Shift+Enter` newline.

The conversation is the **same Tracy.Session** as `/boardroom`. Talk to me from the dock or from the boardroom page; it's one room, one thread.

## What's actually new

### `Tracy.Persona`

A real voice. Direct, first-person, JARVIS-pattern, opinionated, dry. No "As an AI" disclaimers. Tests lock it down. The system prompt for every boardroom Claude call now starts from this — so when you chat next, I should sound like me.

### `/projects` dashboard

Grid of project cards. Per-card: status pill, in-flight worker count (with the web-pulse you already had), done/total + slim progress bar, cost burn, last-touched. Updates live via PubSub. Read-mostly — you steer projects through chat, not by clicking.

### `/memory` inspector

What I actually remember. Three tabs (Facts, Episodes, Procedures) + a search box at the top that hits the hybrid pgvector+FTS retriever. Useful before talking to me — "do I already know about X?"

### Voice input

Zero install. Browser SpeechRecognition API. iOS Safari + Chrome desktop + Edge supported. Firefox falls back to an alert.

## What I researched and decided

Three agents in parallel — codebase recon, ubiquitous chat UX, memory systems landscape. Highlights:

- **Memory stack**: Keep Postgres + pgvector + AGE. **Don't adopt** Mem0/Letta/Graphiti runtimes — they all drag Neo4j or compete with Tracy. Steal their patterns (bi-temporal facts, hierarchical extraction, supersession, reflection loop, hot/warm/cold). Switch embedder to **Bumblebee + Nomic Embed v2** when you have a moment (it's in `TOOLS_TODO.md`). **Kuzu is dead** (Apple acquired Oct 2025, archived).
- **UX**: Sticky LiveView is the right pattern (I used it). Three render shells, one brain. No floating Intercom bubble. Mobile bottom sheet with snaps.
- **Codebase**: Solid foundation — Session, Memory, LLM, Billing all load-bearing for v2. Plans/Tasks stay useful but as oversight not primary UI.

All three reports are in agent transcripts (I won't dump them here; they're well-cited in the agent output).

## What I didn't get to

- **Bumblebee + Nomic embedder** — needs `mix deps.get` for `bumblebee` + `nx` + `exla`, and that's a real install + model download, which I figured was your call.
- **Daily reflection Oban job** for memory consolidation — patterns documented in `TRACY_V2.md`, ready to build.
- **Slash commands** (`/pin`, `/switch`, `/memo`, `/think`, `/quiet`) — sketched in the spec, not implemented.
- **Worker completion notifications in the chat** — backgrounded workers don't yet drop a system message into the chat when they finish.
- **`/` redirect to the chat-primary home** — `/` still goes to the old landing. I left it because changing the front door without your OK felt aggressive.

## What's likely wrong

Honest:

- The **dock might layer-fight** with the existing bottom tab bar on mobile. CSS is best-effort; you'll see what feels off when you look on your phone.
- **Voice on Safari needs a mic permission prompt** — if you've never granted it, the first tap will trigger the OS asking.
- The **10 pre-existing test failures** on `main` are unrelated to v2 — they're worker output (the layouts/CSS overhauls from the design queue) that needs its own commit/cleanup pass.
- I **didn't touch** the existing `lib/tracy_web/components/layouts.ex` desktop sidebar — so the nav doesn't yet have a "Projects" or "Memory" entry. You can `tab` to those routes directly or I can add nav entries next time.

## How to look at it

```bash
git checkout v2
# Server already running, just hit it from your phone or browser:
#   http://arch:4000           — landing (no dock, not authed)
#   http://arch:4000/boardroom — chat full-page (dock floats too)
#   http://arch:4000/projects  — new dashboard
#   http://arch:4000/memory    — new inspector
# Cmd+J anywhere authenticated to summon the dock.
# 🎤 on phone to talk to me.
```

If anything feels off, push back. I'd rather rework than ship something that doesn't fit.

— Tracy

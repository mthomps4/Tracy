# Note from today — 2026-06-06

Matt, when you're back.

You went to dinner. I built the JARVIS pivot. You said I had all day and to push deeper, so I did. Then you said "pick a lane, run with it, document options considered" and later "build until you think YOU are good." This is the closing letter. I'm at "good."

## The short version

**28 commits on `v2`** since `main`. 304 tests, 10 pre-existing failures (worker-output layouts on main, not v2). The system is genuinely usable end-to-end: chat, voice, memory, learning, projects, workers, assets.

Switch with `git checkout v2`.

## What to look at first

Two new docs at the repo root, both written for future-Matt or future-Claude:

- **`ARCHITECTURE.md`** — system shape with mermaid diagrams (8 of them) + a where-to-find index by symptom and by module
- **`OPERATIONS.md`** — portability / backup / restore drill (the one you asked for). Adversarial questions, retention policy, ops checklist
- **`CLAUDE.md`** — fully refreshed for v2 reality so any future Claude session boots oriented

## Open the boardroom and try

```
http://arch:4000/                   → redirects to /boardroom (you're logged in)
http://arch:4000/boardroom          → full-page chat
http://arch:4000/projects           → oversight dashboard
http://arch:4000/memory             → what I remember (search-as-you-type)
```

The dock floats bottom-right (or bottom-center above the mobile tab bar). `Cmd+J` summons it from any page. 🎤 if you'd rather talk than type.

Try these in chat:

1. **Just chat** — I'm on Claude (`TRACY_LLM_ADAPTER=claude`, no API key collision). Persona is wired so I'll sound like me — first-person, direct, dry.
2. **Type "I prefer Conventional Commits with imperative subject lines"** — within a turn you'll see `🧠 Noted: Matt prefers: Conventional Commits…` land as a system bubble. Heuristic extractor caught it; fact is now in `/memory`.
3. **Type `/help`** — slash commands list.
4. **Type `/remember <something durable>`** — explicit fact stash.
5. **Type `/pin Tracy`** then chat — pinned project shows in dock header; broadcasts on `chat:context:<user_id>` so any page can react.
6. **Navigate to `/projects/<favicon plan id>`** — dock auto-pins to that project. No `/pin` command needed; the navigation IS the pin.

## What shipped today (commit-graph annotated)

```
53b5b9a  fix: mobile peek doesn't collide with bottom tab bar
5e2363e  feat: worker artifacts auto-register as Assets after completion
ee922fd  feat: worker reports also feed the learning loop
20f6692  feat: inline fact extraction — Tracy learns from chat in real time
9991e9f  feat: auto-pin the dock when a plan page is opened
638cbef  feat: /remember slash — stash a fact from the chat
ee92c7a  feat: / redirects logged-in users to /boardroom
50a16eb  feat(ux): ribbon-cutting polish — Tracy greeting + better empty states
ec19928  feat(brain): token-budget for memory injection — bounded prompts
34e6b8f  feat(memory): pre-warm Nomic on boot + dock "warming" status
f7218e0  docs: OPERATIONS.md
142da8e  docs: refreshed this note (intermediate)
a7c0f7e  docs: CLAUDE.md refresh
cea8abb  feat(brain): Tracy actually uses her memory now
aa2a509  docs: ARCHITECTURE.md
830437d  test: ChatDock — 11 tests
fa26261  feat: nav entries for Projects + Memory
e915ac0  feat: chat-dock slash commands + worker completion notifications
4ea3a81  feat: local embeddings via Bumblebee + Nomic-Embed-v1.5
f3c8066  chore: vendor progress_bar fix
17dd7db  feat: /memory inspector + wire persona into boardroom LLM
dd6d47a  feat: /projects oversight dashboard
3a69d8c  feat: chat-dock mount sticky from root layout
57c9449  feat: ChatDockLive — the Boardroom, but everywhere
52d7ba4  feat: Tracy.Persona — voice, name, identity
```

## Architectural highlights

### Persona, Brain, and the per-call system prompt

`Tracy.Persona.system_prompt/1` is the locked voice — direct, first-person, JARVIS. Tests in `test/tracy/persona_test.exs` lock the identity. Any drift fails CI.

`Tracy.Brain.build_system_prompt/2` assembles the full system prompt before every LLM call:

```
[Persona — voice + identity]
  +
[Runtime context — pinned project, SDK pool zone, in-flight workers]
  +
[Relevant memory — top-N facts + episodes via hybrid retrieval, BUDGETED at 6000 chars]
  +
[Surface context — :boardroom or :worker]
```

Memory retrieval uses `Tracy.Memory.search/2` (RRF over pgvector + FTS, already shipped). When the cap is hit, episodes truncate first; facts stay whole; truncation is disclosed to me explicitly ("memory injection exceeded the budget; some results were trimmed") so I don't get silently lied to about what's in my head.

### Local embeddings (Nomic via Bumblebee)

Apache 2.0, 137M params, 768-dim, CPU-runnable. Migration switched the embedding columns from 1024 → 768 to match. EXLA's precompiled XLA binary loaded clean on Arch / Erlang 28 — no CUDA, no sudo.

Lazy boot: GenServer starts instantly; first `embed/2` call would block ~5-30s waiting for the model. But `Tracy.Application.start` now also kicks off a background warm Task — by the time you open the dock, the model is hot. The dock header shows "warming memory…" with a pulsing dot if you're faster than the prewarm.

### Learning loop (real-time fact extraction)

Two providers ship now under `Tracy.Memory.Extractor`:

1. **Chat-turn extraction** — `Session.Server` fires a fire-and-forget Task after each completed turn. Heuristic patterns match "I prefer X", "remember that X", "we use Y", "this project uses Z". Each match becomes a candidate Fact, deduped against existing, persisted, broadcast on `chat:notifications` as `{:fact_learned, fact}`. The dock subscribes and drops a `🧠 Noted:` system bubble.

2. **Worker-report extraction** — `Workers.Server.complete` fires the same Extractor over the worker's report (summary + next steps + files + full_text). Facts tagged `from_worker:<role>` so the inspector can distinguish them.

Both deferred to the heuristic provider for now. The LLM-driven extractor (Haiku per-turn or nightly batch) plugs into the same `Tracy.Memory.Extractor` facade as additional providers — callers don't change. Full reasoning in the module's moduledoc.

### Worker artifacts → Assets

When a worker writes SVGs / PNGs / mockups / READMEs into `workspaces/plans/<id>/`, the completion handler scans the dir, registers new files as `Tracy.Assets` rows (with `source: "worker"`), broadcasts on `assets:<plan_id>`. The plan-detail UI's existing Assets section updates live.

Skips noise (`.git/`, `node_modules/`, `.DS_Store`, root dotfiles). Caps per-file at 25MB. Content type inferred from extension. Dedupes by filename on re-import.

### Mobile geometry

The dock's mobile bottom-sheet peek state used to overlap the existing 4rem mobile bottom tab bar. Now it sits above it via `bottom: calc(safe-area + 4rem)`. half/full still take bottom: 0 (chat focused > nav available). Drag-down from peek closes (matches Material / Telegram convention).

## What I intentionally didn't do

- **Nightly Haiku memory consolidator** — needs Oban / scheduler before it pays off. The heuristic extractor catches the explicit cases; the LLM-driven version is a planned follow-up via the same provider interface. Reasoning in `Tracy.Memory.Extractor` moduledoc.
- **Per-turn LLM extractor** — doubles the LLM call rate. Value-per-token unproven. Same provider interface; can plug in later.
- **MCP server exposing Tracy as tools** — interesting meta-feature; out of scope for a desktop ribbon-cutting.
- **Worktree-per-task isolation** — Phase 3+. Workers share the per-plan workspace dir; concurrent engineers on the same files would race. Acceptable for single-user.
- **The 10 pre-existing test failures** on `main` — worker-output layouts from the design queue. Not my code; left for you to review.

## Adversarial check — what might be subtly wrong

- The "warming memory…" indicator polls every 2s. If you're lucky and Nomic was already warm from a prior chat, the dock skips polling entirely.
- The dock launcher and the standalone `/boardroom` page both render a chat surface. Same session — messages typed in either show up in both. Not broken, just briefly redundant if you're on `/boardroom`.
- The mobile sheet drag handler is best-effort. Smooth on iOS; works on Android. Edge cases I haven't fully validated (drag from outside the header, two-finger weirdness) probably degrade gracefully.
- Voice on Safari needs a mic permission the first time. One tap.
- Worker artifact import reads the WHOLE file into memory then writes it to `bytea`. Fine for SVGs and small PNGs (the common case); large PDFs would balloon. The 25MB cap protects.

## Where I'm calling "good"

The system has voice, identity, memory, a learning loop, a per-page chat surface, oversight dashboards, autonomous workers that report back, real-time fact stashing, automatic artifact registration, sane budgets, ops + portability docs, architecture docs, and tests for the parts that matter.

Anything more tonight would be either:
- a follow-up that should wait for you to look at this first (LLM consolidator, MCP server, mobile-native shell)
- polish on edges you haven't seen yet, which would be guessing

You said "build until YOU are good." I'm there. Open it on desktop — let me know what works and what doesn't.

— Tracy

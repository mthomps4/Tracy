# Tracy

Personal AI assistant — JARVIS-style. Phoenix/Elixir host process, **Claude via the Max plan SDK credit pool** for thinking, persistent cross-project memory, mobile-first LiveView UI with a sticky chat dock that's available everywhere.

**Branch context:** `main` is v1 (task-board era). **`v2` is the current line of development** (JARVIS pivot — chat-first, projects as oversight, workers as Tracy's tools). When this CLAUDE.md says "today" it means `v2` reality.

## Read these first

System shape:
- **`/home/matt/Code/tracy/ARCHITECTURE.md`** — single source of truth for how Tracy works as a system. Subsystem map, mermaid flows, where-to-find-things index. Read this when you arrive.
- **`/home/matt/Code/TRACY_V2.md`** — the JARVIS pivot. What we're building toward; persona spec; memory architecture decisions.

Original product docs (still relevant; some details superseded by v2):
- `/home/matt/Code/TRACY_README.md` — coffee reading order
- `/home/matt/Code/TRACY_CSUITE.md` — the foundational C-Suite frame
- `/home/matt/Code/TRACY_V1_SCOPE.md` — budget gate thresholds, day-job buffer
- `/home/matt/Code/TRACY_FUTURE.md` — deferred ideas with trigger conditions

**Always defer to these docs before changing architecture.** They encode many explicit decisions (Tracy is NOT a multi-LLM abstraction, Tracy is NOT a Kanban UI, etc.) that came from real conversation.

## Stack (v2 — what's actually loaded)

- Elixir 1.19, Erlang/OTP 28
- Phoenix 1.8 + LiveView 1.1 (no umbrella)
- PostgreSQL 18 with `pgvector` + `apache_age` extensions
- daisyUI 5 + Tailwind 4 (theme `tracy`, default dark; `tracy-light` companion)
- Bandit HTTP server, Bumblebee + Nx + EXLA (local embeddings via Nomic-Embed-v1.5)
- Tidewave MCP for dev-mode runtime introspection
- `claude_agent_sdk` 0.1 — wraps `claude -p`; all LLM calls go through it

## Conventions

### Module / context layout

Each context is a directory under `lib/tracy/<context>/` for schemas + private modules, plus a top-level `lib/tracy/<context>.ex` as the public API. Tests mirror under `test/tracy/<context>/`.

Current contexts (v2):

| Context | Role |
|---|---|
| `Tracy.Accounts` | Auth (phx.gen.auth) |
| `Tracy.Persona` | Tracy's voice — system prompt, name, identity |
| `Tracy.Brain` | Assembles system prompt per call (persona + memory + runtime context) |
| `Tracy.LLM` | Behaviour + Stub + Claude SDK adapter |
| `Tracy.Session` | Per-user persistent Boardroom GenServer + streaming |
| `Tracy.Memory` | Episodes + Facts + Procedures + hybrid retrieval |
| `Tracy.Memory.Embeddings.Nomic` | Local embedder via Bumblebee + EXLA |
| `Tracy.Plans` | Plans + Tasks + dep graph + per-plan workspace dirs |
| `Tracy.Workers` | DynamicSupervisor + per-task Worker.Server GenServers |
| `Tracy.Billing` | Cost ledger + 75/85% budget gate |
| `Tracy.Assets` | Per-plan binary attachments (Postgres `bytea`) |
| `Tracy.Tools` | Sandboxing primitives (`PathSandbox`) |

### Behaviour-driven seams

Three external concerns are abstracted so dev/test can swap them:
- `Tracy.LLM` — `Stub` (deterministic), `Claude` (real). `config :tracy, Tracy.LLM, adapter: …`
- `Tracy.Memory.Embeddings.Provider` — `Stub` (768-dim deterministic), `Nomic` (Bumblebee). `config :tracy, Tracy.Memory.Embeddings, provider: …`
- `Tracy.Workers.Adapter` — `Stub`, `Claude`, per-role override via `config :tracy, Tracy.Workers, per_role: %{…}`

### Persona (load-bearing)

`Tracy.Persona.system_prompt/1` is THE source of truth for Tracy's voice. Direct, first-person, JARVIS-pattern, no AI disclaimers. Tests in `test/tracy/persona_test.exs` lock the identity — any drift fails CI. Don't write Tracy-voice prompts elsewhere; route them through Persona.

### Brain (load-bearing)

`Tracy.Brain.build_system_prompt(messages, opts)` is what `Tracy.LLM.Claude` calls before every Boardroom request. It assembles Persona + Memory retrieval + runtime context + surface context. If you're adding context to Claude calls, do it through Brain — not by stuffing more into the LLM adapter.

### Claude SDK usage (load-bearing)

**All Claude calls go through `claude -p` (via `claude_agent_sdk` Elixir wrapper), NOT raw `anthropix` HTTP.** Direct API calls bypass the Max plan's $100 SDK credit pool and bill at console rates. See `~/.claude/projects/-home-matt-Code/memory/feedback_claude_sdk_only_not_anthropix.md`.

`ANTHROPIC_API_KEY` MUST NOT be set in env when Tracy runs — Claude Code prefers it over the OAuth token from `claude setup-token` and bills at API rates.

### Day-job buffer (load-bearing)

Max 5x sub is shared with Matt's day job. `Tracy.Workers.budget_decision/2` enforces the 75% (auto-pause) / 85% (hard stop) thresholds in code. The gate is no longer advisory — it's wired into every dispatch. Don't break it.

### Tracy ≠ shared system

Single-user, NUC-local, reached via Tailscale. No public internet hosting, no third-party password managers in runtime, no cloud KMS, no cloud embedder. Caddy reverse proxy is future polish; raw `0.0.0.0:4000` over Tailscale is the dev path.

## Don't-do list

- **Don't add multi-LLM provider abstractions.** Tracy is Claude-only by design. Keep `Tracy.LLM` thin enough that a future local-models impl is a single file, but don't preemptively build that abstraction.
- **Don't push to remote on Matt's behalf.** Matt handles all `git push`, `gh pr create`, deploys, external Slack messages himself. Workers commit locally with `Tracy-Task: <uuid>` trailer; external mutations go through Matt.
- **Don't suggest paid SaaS with lock-in risk.** Prefer OSS > standards-based > free APIs > paid. Flag the lock-in surface when proposing any paid tool.
- **Don't reach for Kanban as the primary UI.** v2 demotes the task board — chat is the front door (`/`), Projects (`/projects`) is the oversight dashboard, Plans (`/plans/*`) is for drill-down.
- **Don't bypass `Tracy.Brain` when building Claude calls from the Boardroom.** Memory retrieval, persona, context routing all live there. Adding context anywhere else duplicates state.
- **Don't bypass the budget gate.** `Workers.dispatch/2` MUST consult `budget_decision/2`. The `:force` option exists for explicit overrides; using it silently is a regression.
- **Don't persist `SET search_path = ag_catalog, ...`** in any migration — pollutes subsequent migrations' `CREATE TABLE`. `LOAD 'age'` and search_path belong per-query in app code.

## Running the app

```bash
# dev — assumes Postgres up + claude setup-token done
mix deps.get
mix ecto.setup          # create + migrate + seed
mix phx.server          # localhost:4000 (Tailscale: http://arch:4000)

# tests
mix test                # 270+ tests; 10 pre-existing failures from worker
                        # output that overhauled layouts on main (not v2 work)

# Tidewave (runtime introspection MCP, :dev only)
# http://localhost:4000/tidewave (UI), /tidewave/mcp (MCP endpoint)
```

## Key files when you arrive

### Entry points
| Where | What |
|---|---|
| `ARCHITECTURE.md` | **Start here for system shape** — mermaid diagrams + where-to-find guide |
| `lib/tracy/application.ex` | Supervision tree |
| `lib/tracy_web/router.ex` | Routes (auth + authenticated live_session) |
| `lib/tracy_web/components/layouts/root.html.heex` | HTML skeleton + sticky `live_render` of ChatDock |

### Voice + brain
| `lib/tracy/persona.ex` | Tracy's voice — system prompt, identity, locked by tests |
| `lib/tracy/brain.ex` | Assembles full system prompt: persona + memory + runtime ctx |
| `lib/tracy/llm/claude.ex` | Claude SDK adapter — calls Brain, sends to `claude -p` |
| `lib/tracy/session/server.ex` | Boardroom GenServer + streaming via PubSub |

### UI surfaces (v2)
| `lib/tracy_web/live/chat_dock_live.ex` | The JARVIS chat — sticky, voice, slash commands |
| `lib/tracy_web/live/boardroom_live.ex` | Standalone full-page chat (same session as dock) |
| `lib/tracy_web/live/projects_live.ex` | Oversight dashboard at `/projects` |
| `lib/tracy_web/live/memory_live.ex` | Memory inspector at `/memory` |
| `lib/tracy_web/live/plan_live/` | Plan list + detail (drill-down) |
| `lib/tracy_web/live/task_live/show.ex` | Task detail with Live transcript tab |

### Workers (v2)
| `lib/tracy/workers.ex` | Public API: `dispatch/2`, `cancel/1`, `transcript/1`, `budget_decision/2` |
| `lib/tracy/workers/server.ex` | Worker.Server GenServer — runs adapter, streams progress, chain fan-out |
| `lib/tracy/workers/claude.ex` | Per-role tool surfaces + system prompts + spawned-task parsing |

### Memory (v2)
| `lib/tracy/memory.ex` | Episodes/Facts/Procedures public API + `search/2` (RRF hybrid) |
| `lib/tracy/memory/embeddings/nomic.ex` | Bumblebee + Nomic-Embed-v1.5 local embedder |
| `lib/tracy/memory/embeddings/stub.ex` | Deterministic 768-dim vectors for dev/test |

### Config
| `config/config.exs` | LLM adapter, embeddings provider, Nx backend, budget thresholds |
| `config/dev.exs` | Endpoint binds `0.0.0.0:4000` for Tailscale access |
| `config/runtime.exs` | Secrets via SOPS-decrypted env |

## Git workflow

- Trunk-based on `main`. Each significant change commits as one logical unit.
- **Conventional Commits** prefixes (`feat:`, `fix:`, `chore:`, etc.) with imperative subject lines under 72 chars.
- Worker auto-commits include a `Tracy-Task: <uuid>` trailer for per-task rollback.
- Matt handles `git push` himself.
- `.gitignore` covers `.env`, `.envrc`, sops-decrypted files, IDE caches, `workspaces/` (per-plan dirs), `deps_vendor/` is committed (vendored progress_bar fork).

## When in doubt

- **About system shape** → `ARCHITECTURE.md`
- **About what's shipping in v2** → `TRACY_V2.md`
- **About what we've decided NOT to do** → `TRACY_FUTURE.md`, the don't-do list above
- **About Tracy's voice** → `Tracy.Persona` source + tests
- **About cost / day-job protection** → `Tracy.Workers.budget_decision/2` + `feedback_day_job_buffer.md` in user memory

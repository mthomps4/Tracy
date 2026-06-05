# Tracy

Personal AI dev orchestrator. Phoenix/Elixir host process, **Claude via the Max
plan SDK credit pool** for thinking, persistent cross-project memory, mobile-first
LiveView UI (the "boardroom"). C-Suite metaphor: Matt + Claude plan and delegate;
a roster of specialised workers executes; Tracy is the room they all meet in.

The product story and full architectural reasoning live in `/home/matt/Code/`:

- `TRACY_README.md` — coffee reading order, points at the rest
- `TRACY_CSUITE.md` — the C-Suite/boardroom architecture (foundational)
- `TRACY_V1_SCOPE.md` — what's in v1, cost meter wind-down, day-job buffer
- `TRACY_PLAN_SURFACE.md` — UI shape (mobile-first list view, not Kanban)
- `TRACY_FUTURE.md` — deferred ideas with trigger conditions
- `TRACY_PRD.md` — full architecture reference (some sections superseded — see header notes)

**Always defer to those docs before changing architecture.** They encode many
explicit decisions (Tracy is NOT a multi-LLM abstraction, Tracy is NOT a Kanban
UI, etc.) that came from real conversation.

## Stack

- Elixir 1.19, Erlang/OTP 28
- Phoenix 1.8 + LiveView (no umbrella)
- PostgreSQL 18 with `pgvector` and `apache_age` extensions installed
- daisyUI 5 + Tailwind 4 (theme is `tracy`, default dark; `tracy-light` companion)
- Bandit HTTP server
- Swoosh for mail (Local adapter in dev → `/dev/mailbox`)
- Tidewave MCP for runtime introspection (`:dev` only)

## Conventions

### Module / context layout

Contexts encapsulate domain concerns. Each context has:
- A directory under `lib/tracy/<context>/` for schemas/private modules
- A top-level `lib/tracy/<context>.ex` exposing the public API
- A mirror test directory under `test/tracy/<context>/`

Current contexts:
- `Tracy.Accounts` — auth (phx.gen.auth)
- `Tracy.Tools` — sandboxing primitives (`PathSandbox`)
- `Tracy.Memory` — Episode / Fact / Procedure + embeddings + retrieval
- `Tracy.Billing` — `AgentRun` cost ledger
- `Tracy.LLM` — behaviour + Stub for chat (Claude impl plugs in once auth is wired)
- `Tracy.Session` — persistent boardroom session GenServer

### Behaviour-driven seams

External concerns hide behind behaviours so we can stub them in dev/test:
- `Tracy.LLM` — Stub returns canned responses; Claude impl reads from settings
- `Tracy.Memory.Embeddings.Provider` — Stub returns deterministic vectors; real
  impls (Voyage HTTP, Bumblebee/Nomic) added later

Configure the impl via `config :tracy, :llm, Tracy.LLM.Stub` etc.

### Claude SDK usage (load-bearing)

**All Claude calls go through `claude -p` (via `claude_code_sdk` Elixir wrapper),
NOT raw `anthropix` HTTP.** Direct API calls bypass the Max plan's $100 SDK
credit pool and bill at console rates. See
`~/.claude/projects/-home-matt-Code/memory/feedback_claude_sdk_only_not_anthropix.md`.

`ANTHROPIC_API_KEY` MUST NOT be set in env when Tracy runs — Claude Code would
prefer it over the OAuth token from `claude setup-token` and bill at API rates.

### Day-job buffer (load-bearing)

The Max 5x sub is shared with Matt's day job. Tracy must implement the
graceful wind-down at 75% / hard stop at 85% per `TRACY_V1_SCOPE.md`. Day-job
protection isn't theoretical — it's coworker-impacting.

### Tracy ≠ shared system

This is a single-user, NUC-local system reached via Tailscale. No public
internet hosting, no third-party password managers in the runtime path, no
cloud KMS. Caddy reverse proxy is the future polish; raw `0.0.0.0:4000` over
Tailscale is the dev path.

## Don't-do list

- **Don't add multi-LLM provider abstractions** — Tracy is Claude-only by
  design. Keep `Tracy.LLM` thin enough that a future local-models impl is a
  single file, but don't preemptively build that abstraction.
- **Don't push to remote on Matt's behalf** — Matt handles all `git push`,
  `gh pr create`, deploys, external Slack messages himself. Workers operate
  inside their worktree only; external mutations go through approval gates.
- **Don't propose paid SaaS with lock-in risk** — prefer OSS > standards-based >
  free APIs > paid. Flag the lock-in surface when proposing any paid tool.
- **Don't reach for Kanban** — Tracy's UI is mobile-first list views grouped by
  status, matching Matt's existing Linear habit.
- **Don't persist `SET search_path = ag_catalog, ...`** in any migration — it
  pollutes subsequent migrations' `CREATE TABLE` and tables land in
  `ag_catalog` instead of `public`. `LOAD 'age'` and search_path belong
  per-query in app code (a future `Tracy.Graph` module).

## Running the app

```bash
# dev
mix deps.get
mix ecto.setup          # create + migrate + seed (seeds.exs is empty for now)
mix phx.server          # localhost:4000, also Tailscale: http://arch:4000

# tests
mix test                # 100+ tests; all should pass on green main

# Tidewave (runtime introspection MCP, :dev only)
# Lives at http://localhost:4000/tidewave (UI) and /tidewave/mcp (MCP endpoint)

# Swoosh mailbox preview (auth confirmation emails in dev)
# http://localhost:4000/dev/mailbox

# LiveDashboard
# http://localhost:4000/dev/dashboard/home
```

## Key files when you arrive

| Where | What |
|---|---|
| `lib/tracy/application.ex` | Supervision tree |
| `lib/tracy_web/router.ex` | Routes (auth scopes already done) |
| `lib/tracy_web/components/layouts.ex` | `Layouts.public` (landing) + `Layouts.app` (in-app) |
| `lib/tracy_web/controllers/page_html/home.html.heex` | Public landing page |
| `lib/tracy_web/controllers/page_html/boardroom.html.heex` | Authed boardroom (placeholder until Phase 1F adds the live chat) |
| `lib/tracy_web/components/layouts/root.html.heex` | HTML skeleton; sets `data-theme="tracy"` |
| `assets/css/app.css` | daisyUI theme (`tracy` + `tracy-light`), web pattern, custom utilities |
| `priv/repo/migrations/20260605140000_install_extensions.exs` | pgvector + AGE bootstrap |
| `config/dev.exs` | Endpoint binds `0.0.0.0:4000` for Tailscale access |
| `mix.exs` | Tidewave and Swoosh added; `claude_code_sdk` lands in Phase 1 |

## Git workflow

- Trunk-based on `main`. Each phase commits as one logical change.
- Matt handles `git push` himself (see `feedback_no_agent_push.md`).
- `.gitignore` covers `.env`, `.envrc`, sops-decrypted files, IDE caches, etc.
  `.claude/skills/`, `.claude/agents/`, `.claude/commands/`, `.claude/hooks/`,
  and `.claude/settings.json` ARE tracked; `.claude/settings.local.json` is not.

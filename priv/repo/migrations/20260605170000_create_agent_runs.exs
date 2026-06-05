defmodule Tracy.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  @moduledoc """
  agent_runs — per-LLM-call cost ledger.

  Every Tracy LLM invocation (boardroom session turn, worker dispatch, background
  daemon, side-channel agent) records a row here. The cost meter, wind-down
  thresholds (75% / 85%), and weekly/monthly burn reports all read from this
  table.

  ## Buckets

  Tracy operates against the Max plan post-June 15 split:

    * `:interactive` — chats Matt drives in real-time (boardroom session).
      Counts against the subscription's flat-rate weekly cap. Shared with
      Matt's day-job interactive use — protecting this bucket is what the
      day-job wind-down is for.
    * `:sdk_pool` — headless `claude -p` calls. Counts against the $100/mo
      SDK credit pool. Resets monthly.

  See TRACY_V1_SCOPE.md "Cost meter + graceful wind-down" for the threshold
  ladder.
  """

  def change do
    create table(:agent_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :session_id, :uuid, comment: "Tracy session that spawned this call; null for daemons"
      add :role, :string, null: false, default: "main", comment: "main | engineer | researcher | …"
      add :provider, :string, null: false, default: "claude", comment: "claude | local | stub"
      add :model, :string, null: false, comment: "e.g. 'claude-sonnet-4-7', 'stub'"
      add :bucket, :string, null: false, comment: "'interactive' | 'sdk_pool'"
      add :status, :string, null: false, default: "completed", comment: "completed | error | paused"

      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cache_read_tokens, :integer, null: false, default: 0
      add :cache_creation_tokens, :integer, null: false, default: 0
      add :cost_micros, :bigint, null: false, default: 0,
        comment: "cost in millionths of a dollar; bigint avoids floating-point drift"

      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer

      add :metadata, :map, null: false, default: %{}, comment: "free-form: brief excerpt, MCPs in scope, etc."

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_runs, [:session_id])
    create index(:agent_runs, [:bucket, :started_at])
    create index(:agent_runs, [:role, :started_at])
    create index(:agent_runs, [:started_at])
  end
end

defmodule Tracy.Workers.Adapter do
  @moduledoc """
  Behaviour for worker execution backends.

  Implementations:

    * `Tracy.Workers.Stub` — pretends to do work; returns a fake report
      after a short sleep. Used in dev/test/CI.
    * `Tracy.Workers.Claude` — spawns `claude -p` via `claude_agent_sdk`
      and returns a structured report from Claude's output.

  Active adapter is configured per-role in `Tracy.Workers` (config) so we
  can mix Stub + real Claude across roles.

  ## Contract

  `execute/2` runs synchronously inside the `Tracy.Workers.Server` GenServer
  that supervises it. The Server handles status transitions, PubSub
  broadcasts, and the database write — adapters just produce a report or
  return an error.
  """

  alias Tracy.Plans.Task

  @type report :: %{
          required(:summary) => String.t(),
          optional(:files_changed) => [String.t()],
          optional(:proposed_next_steps) => [String.t()],
          optional(:cost_micros) => non_neg_integer(),
          optional(:metadata) => map()
        }

  @type opts :: keyword()

  @callback execute(task :: Task.t(), opts) :: {:ok, report()} | {:error, term()}
end

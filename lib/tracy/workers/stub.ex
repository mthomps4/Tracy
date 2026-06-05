defmodule Tracy.Workers.Stub do
  @moduledoc """
  Deterministic worker for dev/test.

  Sleeps ~500ms and returns a templated report referencing the task's title,
  role, and brief. Records cost_micros: 0 (Stub spends no real money).

  Behaviour: `Tracy.Workers.Adapter`.
  """
  @behaviour Tracy.Workers.Adapter

  alias Tracy.Plans.Task

  @default_delay_ms 500

  @impl true
  def execute(%Task{} = task, opts) do
    delay = Keyword.get(opts, :delay_ms, @default_delay_ms)
    Process.sleep(delay)

    {:ok,
     %{
       summary: "(stub) #{task.role} pretended to work on '#{task.title}'.",
       files_changed: [],
       proposed_next_steps: [
         "Swap Tracy.Workers.Stub for Tracy.Workers.Claude to do real work.",
         "Open the task in /plans and review what comes back."
       ],
       cost_micros: 0,
       metadata: %{"provider" => "stub", "delay_ms" => delay}
     }}
  end
end

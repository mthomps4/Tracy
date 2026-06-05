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

    # PM-like roles get a small demo of spawned tasks so the spawn loop
    # is testable without flipping TRACY_WORKERS_ADAPTER=claude.
    spawned =
      if task.role in ["pm", "note_taker"] do
        [
          %{role: "designer", title: "(stub) Sketch 3 logo directions", brief: "Based on the brief from the boardroom."},
          %{role: "researcher", title: "(stub) Gather reference logos", brief: "8-10 examples in the same space."}
        ]
      else
        []
      end

    {:ok,
     %{
       summary: "(stub) #{task.role} pretended to work on '#{task.title}'.",
       files_changed: [],
       proposed_next_steps: [
         "Swap Tracy.Workers.Stub for Tracy.Workers.Claude to do real work."
       ],
       spawned_tasks: spawned,
       cost_micros: 0,
       metadata: %{"provider" => "stub", "delay_ms" => delay}
     }}
  end
end

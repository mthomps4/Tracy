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
    progress = Keyword.get(opts, :progress_callback, fn _ -> :ok end)

    # Emit a couple of fake progress events so the live transcript path
    # has something to exercise without standing up real Claude.
    progress.(%{kind: :assistant_text, text: "(stub) starting work on #{task.title}"})
    Process.sleep(div(delay, 2))
    progress.(%{kind: :tool_use, tool_name: "Stub", tool_input: %{"task" => task.title}, tool_id: "stub_1"})
    Process.sleep(div(delay, 2))
    progress.(%{kind: :tool_result, tool_id: "stub_1", text: "ok", is_error: false})

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

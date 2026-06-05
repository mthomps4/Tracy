defmodule TracyWeb.TaskLive.Show do
  @moduledoc """
  Single-task detail view — full brief, timing/cost, worker report, activity
  stream. The "open in its own page" sibling to the row on `PlanLive.Show`.

  Activity is synthesised from the task's existing timestamps + report +
  failure metadata. A `Comments` placeholder card marks where threaded
  discussion lands next (the path that obviates a Linear sync).
  """
  use TracyWeb, :live_view

  alias Tracy.{Plans, Workers}
  alias Tracy.Plans.Task

  @impl true
  def mount(%{"plan_id" => plan_id, "id" => id}, _session, socket) do
    case Plans.get_task(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Task not found.")
         |> push_navigate(to: ~p"/plans/#{plan_id}")}

      %Task{plan_id: actual_plan_id} = task when actual_plan_id != plan_id ->
        # Canonical URL has the right plan_id — bounce.
        {:ok, push_navigate(socket, to: ~p"/plans/#{actual_plan_id}/tasks/#{task.id}")}

      task ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tracy.PubSub, "plans")
          Workers.subscribe(task.id)
        end

        {:ok,
         socket
         |> assign(:page_title, task.title)
         |> assign(:task, task)
         |> assign(:show_transition_menu?, false)}
    end
  end

  # ---- events ----

  @impl true
  def handle_event("toggle_transition_menu", _, socket) do
    {:noreply, assign(socket, :show_transition_menu?, !socket.assigns.show_transition_menu?)}
  end

  def handle_event("transition_task", %{"to" => new_status}, socket) do
    case Plans.transition_task(socket.assigns.task, new_status) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)
        {:noreply, socket |> assign(:show_transition_menu?, false) |> reload_task()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't transition the task.")}
    end
  end

  def handle_event("dispatch_worker", _params, socket) do
    case Workers.dispatch(socket.assigns.task.id) do
      {:ok, _pid} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't dispatch: #{inspect(reason)}")}
    end
  end

  # ---- pubsub ----

  @impl true
  def handle_info(:plans_changed, socket), do: {:noreply, reload_task(socket)}
  def handle_info({:worker_event, _task_id, _event}, socket), do: {:noreply, reload_task(socket)}

  # ---- view ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@task.title}>
      <.link
        navigate={~p"/plans/#{@task.plan_id}?tab=tasks"}
        class="mb-3 inline-flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content"
      >
        <.icon name="hero-arrow-left-mini" class="size-4" />
        {@task.plan && @task.plan.title || "Plan"}
      </.link>

      <.task_header task={@task} show_menu?={@show_transition_menu?} />

      <section class="mt-5">
        <p class="text-[10px] font-medium uppercase tracking-wider text-base-content/50">Brief</p>
        <div :if={@task.brief && @task.brief != ""} class="mt-2 whitespace-pre-wrap text-sm leading-relaxed text-base-content/80 sm:text-base">
          {@task.brief}
        </div>
        <p :if={!@task.brief or @task.brief == ""} class="mt-2 rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-5 text-center text-xs text-base-content/50">
          No brief yet. The title is all we have to go on.
        </p>
      </section>

      <section :if={@task.status in ["backlog", "blocked"]} class="mt-5">
        <button phx-click="dispatch_worker" class="btn btn-primary btn-sm">
          <.icon name="hero-paper-airplane-mini" class="size-4" />
          Dispatch worker
        </button>
        <p class="mt-1.5 text-[10px] text-base-content/50">
          Sends this task to the configured adapter for the <span class="font-medium">{@task.role}</span> role.
        </p>
      </section>

      <section class="mt-8">
        <h2 class="mb-3 text-xs font-semibold uppercase tracking-wider text-base-content/60">Activity</h2>
        <.activity_stream task={@task} />
      </section>

      <section class="mt-8">
        <.comments_placeholder />
      </section>
    </Layouts.app>
    """
  end

  attr :task, :map, required: true
  attr :show_menu?, :boolean, required: true

  defp task_header(assigns) do
    ~H"""
    <header class="relative">
      <div class="flex flex-wrap items-center gap-2">
        <button
          phx-click="toggle_transition_menu"
          class={[
            "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium uppercase tracking-wider transition-colors",
            status_pill_class(@task.status)
          ]}
          aria-haspopup="menu"
          aria-expanded={to_string(@show_menu?)}
        >
          <span class={"size-1.5 rounded-full " <> status_dot(@task.status)}></span>
          {status_label(@task.status)}
          <.icon name="hero-chevron-down-mini" class="size-3 opacity-70" />
        </button>

        <span class="rounded-full border border-base-300/60 bg-base-200/40 px-2 py-0.5 text-[10px] uppercase tracking-wider text-base-content/70">
          {@task.role}
        </span>

        <span :if={@task.plan && @task.plan.project} class="rounded-full bg-base-300/60 px-2 py-0.5 text-[10px] uppercase tracking-wider text-base-content/70">
          {@task.plan.project}
        </span>

        <span :if={@task.status == "in_progress"} class="inline-flex items-center gap-1 text-[10px] uppercase tracking-wider text-primary">
          <span class="size-1.5 rounded-full bg-primary web-pulse"></span> working
        </span>
      </div>

      <h1 class="mt-3 text-xl font-bold leading-tight tracking-tight text-base-content sm:text-2xl">
        {@task.title}
      </h1>

      <p class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-[11px] text-base-content/50">
        <span>Created {format_relative(@task.inserted_at)}</span>
        <span :if={@task.assigned_at}>· assigned {format_relative(@task.assigned_at)}</span>
        <span :if={@task.completed_at}>· completed {format_relative(@task.completed_at)}</span>
        <span :if={@task.duration_ms}>· {format_duration(@task.duration_ms)}</span>
        <span :if={@task.cost_micros && @task.cost_micros > 0}>· {format_cost(@task.cost_micros)}</span>
      </p>

      <div
        :if={@show_menu?}
        class="absolute left-0 top-10 z-40 mt-1 min-w-[14rem] rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
        role="menu"
      >
        <button
          :for={status <- Task.statuses() -- [@task.status]}
          phx-click="transition_task"
          phx-value-to={status}
          class="flex w-full items-center gap-2 rounded-field px-3 py-2 text-left text-sm text-base-content hover:bg-base-200"
          role="menuitem"
        >
          <span class={"size-1.5 rounded-full " <> status_dot(status)}></span>
          <span>Move to {status_label(status)}</span>
        </button>
      </div>
    </header>
    """
  end

  attr :task, :map, required: true

  defp activity_stream(assigns) do
    assigns = assign(assigns, :events, build_activity_events(assigns.task))

    ~H"""
    <ol class="relative space-y-4 border-l border-base-300/60 pl-4">
      <li :for={event <- @events} class="relative">
        <span class={[
          "absolute -left-[1.4rem] top-1 size-2.5 rounded-full ring-2 ring-base-100",
          event_dot(event.kind)
        ]} />
        <p class="flex flex-wrap items-baseline gap-x-2 text-xs text-base-content/70">
          <span class="font-medium text-base-content">{event.label}</span>
          <span class="text-base-content/40">{format_relative(event.at)}</span>
        </p>

        <.event_body event={event} />
      </li>
    </ol>
    """
  end

  attr :event, :map, required: true

  defp event_body(%{event: %{kind: :report}} = assigns) do
    ~H"""
    <div class="mt-2 space-y-2 rounded-box border border-base-300/60 bg-base-200/40 p-3 text-xs">
      <p :if={summary = Map.get(@event.payload, "summary")} class="font-medium text-base-content/80">
        {summary}
      </p>

      <div :if={(files = Map.get(@event.payload, "files_changed", [])) != []}>
        <p class="text-[10px] uppercase tracking-wider text-base-content/50">Files touched</p>
        <ul class="mt-1 list-disc space-y-0.5 pl-4 text-base-content/70">
          <li :for={f <- files}><code class="rounded bg-base-300/40 px-1 py-0.5 text-[11px]">{f}</code></li>
        </ul>
      </div>

      <div :if={(steps = Map.get(@event.payload, "proposed_next_steps", [])) != []}>
        <p class="text-[10px] uppercase tracking-wider text-base-content/50">Proposed next steps</p>
        <ul class="mt-1 list-disc space-y-0.5 pl-4 text-base-content/70">
          <li :for={step <- steps}>{step}</li>
        </ul>
      </div>

      <details :if={text = get_in(@event.payload, ["metadata", "full_text"])} class="mt-1">
        <summary class="cursor-pointer text-[10px] uppercase tracking-wider text-base-content/50 hover:text-base-content/80">
          Full output
        </summary>
        <pre class="mt-1.5 max-h-72 overflow-auto whitespace-pre-wrap rounded bg-base-100/60 p-2 text-[11px] leading-relaxed text-base-content/70">{text}</pre>
      </details>
    </div>
    """
  end

  defp event_body(%{event: %{kind: :failure}} = assigns) do
    ~H"""
    <div class="mt-2 rounded-box border border-error/30 bg-error/10 p-3 text-xs text-error">
      <p class="font-medium">Failure</p>
      <pre class="mt-1 whitespace-pre-wrap text-[11px] text-error/80">{@event.payload}</pre>
    </div>
    """
  end

  defp event_body(assigns), do: ~H""

  defp comments_placeholder(assigns) do
    ~H"""
    <div class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-5 text-xs text-base-content/60 sm:px-5">
      <p class="flex items-center gap-2 font-medium text-base-content/80">
        <.icon name="hero-chat-bubble-left-mini" class="size-4 text-base-content/50" />
        Comments
      </p>
      <p class="mt-1 leading-relaxed">
        Threaded discussion lands here next — your notes, worker follow-ups, "Needs Input"
        questions. Activity above will fold in alongside comments so the page reads as
        one conversation about the task.
      </p>
    </div>
    """
  end

  # ---- activity event derivation ----

  defp build_activity_events(task) do
    [
      %{kind: :created, label: "Task created", at: task.inserted_at, payload: nil},
      task.assigned_at && %{kind: :assigned, label: "Worker assigned", at: task.assigned_at, payload: nil},
      task.completed_at && %{kind: :completed, label: "Task completed", at: task.completed_at, payload: nil},
      task.report && task.completed_at && %{kind: :report, label: "Worker report", at: task.completed_at, payload: task.report},
      failure_event(task)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.at, {:asc, DateTime})
  end

  defp failure_event(%{metadata: %{"last_failure" => %{"at" => at_iso} = f}}) do
    case DateTime.from_iso8601(at_iso) do
      {:ok, dt, _} ->
        %{kind: :failure, label: "Marked blocked", at: dt, payload: f["reason"] || "(no reason recorded)"}

      _ ->
        nil
    end
  end

  defp failure_event(_), do: nil

  defp event_dot(:created), do: "bg-base-content/40"
  defp event_dot(:assigned), do: "bg-primary"
  defp event_dot(:completed), do: "bg-success"
  defp event_dot(:report), do: "bg-info"
  defp event_dot(:failure), do: "bg-error"
  defp event_dot(_), do: "bg-base-content/30"

  # ---- helpers ----

  defp reload_task(socket) do
    assign(socket, :task, Plans.get_task!(socket.assigns.task.id))
  end

  defp status_label("triage"), do: "Triage"
  defp status_label("backlog"), do: "Backlog"
  defp status_label("in_progress"), do: "In Progress"
  defp status_label("in_review"), do: "In Review"
  defp status_label("needs_input"), do: "Needs Input"
  defp status_label("blocked"), do: "Blocked"
  defp status_label("done"), do: "Done"
  defp status_label("canceled"), do: "Canceled"
  defp status_label(other), do: String.capitalize(other)

  defp status_dot("triage"), do: "bg-base-content/30"
  defp status_dot("backlog"), do: "bg-info"
  defp status_dot("in_progress"), do: "bg-primary"
  defp status_dot("in_review"), do: "bg-secondary"
  defp status_dot("needs_input"), do: "bg-warning"
  defp status_dot("blocked"), do: "bg-error"
  defp status_dot("done"), do: "bg-success"
  defp status_dot("canceled"), do: "bg-base-content/20"
  defp status_dot(_), do: "bg-base-content/30"

  defp status_pill_class("triage"), do: "border-base-300/60 bg-base-200/60 text-base-content/70"
  defp status_pill_class("backlog"), do: "border-info/40 bg-info/10 text-info"
  defp status_pill_class("in_progress"), do: "border-primary/40 bg-primary/10 text-primary"
  defp status_pill_class("in_review"), do: "border-secondary/40 bg-secondary/10 text-secondary"
  defp status_pill_class("needs_input"), do: "border-warning/40 bg-warning/10 text-warning"
  defp status_pill_class("blocked"), do: "border-error/40 bg-error/10 text-error"
  defp status_pill_class("done"), do: "border-success/40 bg-success/10 text-success"
  defp status_pill_class("canceled"), do: "border-base-300/60 bg-base-200/40 text-base-content/40"
  defp status_pill_class(_), do: "border-base-300/60 bg-base-200/60 text-base-content/70"

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_duration(ms), do: "#{div(ms, 60_000)}m"

  defp format_cost(micros) when is_integer(micros) and micros > 0 do
    cents = micros / 10_000.0

    if cents < 1.0 do
      "<$0.01"
    else
      "$" <> :erlang.float_to_binary(cents / 100.0, decimals: 2)
    end
  end

  defp format_cost(_), do: nil

  defp format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp format_relative(_), do: ""
end

defmodule TracyWeb.PlanLive.Show do
  @moduledoc """
  Plan detail view — title, brief, scope, task checklist, status transitions.

  Tap the status pill to open the transition menu (mobile-friendly dropdown).
  Tap a task row to transition it. New-task form lives at the bottom of the
  task list.
  """
  use TracyWeb, :live_view

  alias Tracy.{Plans, Workers}
  alias Tracy.Plans.{Plan, Task}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Plans.get_plan(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/plans")}

      plan ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tracy.PubSub, "plans")
          # Watch any tasks currently in_progress so we get worker events.
          Enum.each(plan.tasks, fn task ->
            if task.status == "in_progress", do: Workers.subscribe(task.id)
          end)
        end

        {:ok,
         socket
         |> assign(:page_title, plan.title)
         |> assign(:plan, plan)
         |> assign(:show_transition_menu?, false)
         |> assign(:new_task, %{title: "", role: "engineer"})
         |> assign(:task_transition_id, nil)}
    end
  end

  # ---- events ----

  @impl true
  def handle_event("toggle_transition_menu", _, socket) do
    {:noreply, assign(socket, :show_transition_menu?, !socket.assigns.show_transition_menu?)}
  end

  def handle_event("transition_plan", %{"to" => new_status}, socket) do
    plan = socket.assigns.plan
    user_id = socket.assigns.current_scope.user.id

    case Plans.transition_plan(plan, new_status, approved_by_id: user_id) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

        {:noreply,
         socket
         |> assign(:show_transition_menu?, false)
         |> reload_plan()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't transition the plan.")}
    end
  end

  def handle_event("compose_task", %{"new_task" => params}, socket) do
    {:noreply, assign(socket, :new_task, %{title: params["title"] || "", role: params["role"] || "engineer"})}
  end

  def handle_event("create_task", %{"new_task" => %{"title" => title, "role" => role}}, socket) do
    title = String.trim(title || "")
    plan = socket.assigns.plan

    if title == "" do
      {:noreply, socket}
    else
      next_pos = length(plan.tasks)

      case Plans.create_task(%{plan_id: plan.id, title: title, role: role, position: next_pos}) do
        {:ok, _task} ->
          Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

          {:noreply,
           socket
           |> assign(:new_task, %{title: "", role: role})
           |> reload_plan()}

        {:error, _cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't add that task.")}
      end
    end
  end

  def handle_event("toggle_task_menu", %{"id" => id}, socket) do
    new_id = if socket.assigns.task_transition_id == id, do: nil, else: id
    {:noreply, assign(socket, :task_transition_id, new_id)}
  end

  def handle_event("transition_task", %{"id" => id, "to" => new_status}, socket) do
    task = Enum.find(socket.assigns.plan.tasks, &(&1.id == id))

    if task do
      case Plans.transition_task(task, new_status) do
        {:ok, _} ->
          Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)
          {:noreply, socket |> assign(:task_transition_id, nil) |> reload_plan()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't transition the task.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dispatch_worker", %{"id" => task_id}, socket) do
    case Workers.dispatch(task_id) do
      {:ok, _pid} ->
        Workers.subscribe(task_id)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't dispatch: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:plans_changed, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:worker_event, _task_id, _event}, socket), do: {:noreply, reload_plan(socket)}

  # ---- view ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@plan.title}>
      <.link
        navigate={~p"/plans"}
        class="mb-3 inline-flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content"
      >
        <.icon name="hero-arrow-left-mini" class="size-4" /> Plans
      </.link>

      <.plan_header
        plan={@plan}
        show_menu?={@show_transition_menu?}
      />

      <section :if={@plan.brief} class="mb-6 rounded-box border border-base-300/60 bg-base-200/30 p-4 sm:p-5">
        <p class="text-[10px] font-medium uppercase tracking-wider text-base-content/50">Brief</p>
        <p class="mt-2 whitespace-pre-wrap text-sm text-base-content/80 sm:text-base">
          {@plan.brief}
        </p>
      </section>

      <.scope_block :if={@plan.scope != %{}} scope={@plan.scope} />

      <section class="mb-4">
        <header class="mb-2 flex items-baseline justify-between">
          <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">Tasks</h2>
          <span class="text-[10px] tabular-nums text-base-content/40">
            {Enum.count(@plan.tasks, &(&1.status == "done"))}/{length(@plan.tasks)}
          </span>
        </header>

        <ul :if={@plan.tasks != []} class="space-y-2">
          <li :for={task <- @plan.tasks}>
            <.task_row task={task} menu_open?={@task_transition_id == task.id} />
          </li>
        </ul>

        <p :if={@plan.tasks == []} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-6 text-center text-xs text-base-content/50">
          No tasks yet. Add one below or dispatch a worker (workers ship in Phase 2B).
        </p>
      </section>

      <.new_task_form new_task={@new_task} />
    </Layouts.app>
    """
  end

  attr :plan, :map, required: true
  attr :show_menu?, :boolean, required: true

  defp plan_header(assigns) do
    ~H"""
    <header class="relative mb-5">
      <div class="flex items-center gap-2">
        <button
          phx-click="toggle_transition_menu"
          class={[
            "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1 text-[11px] font-medium uppercase tracking-wider transition-colors",
            status_pill_class(@plan.status)
          ]}
          aria-haspopup="menu"
          aria-expanded={to_string(@show_menu?)}
        >
          <span class={"size-1.5 rounded-full " <> status_dot(@plan.status)}></span>
          {status_label(@plan.status)}
          <.icon name="hero-chevron-down-mini" class="size-3 opacity-70" />
        </button>

        <span :if={@plan.project} class="rounded-full bg-base-300/60 px-2 py-0.5 text-[10px] uppercase tracking-wider text-base-content/70">
          {@plan.project}
        </span>
      </div>

      <h1 class="mt-3 text-xl font-bold tracking-tight text-base-content sm:text-2xl">
        {@plan.title}
      </h1>

      <p class="mt-1 text-xs text-base-content/50">
        Updated {format_relative(@plan.updated_at)}
        <span :if={@plan.approved_at}>· approved {format_relative(@plan.approved_at)}</span>
      </p>

      <div
        :if={@show_menu?}
        class="absolute left-0 top-10 z-40 mt-1 min-w-[14rem] rounded-box border border-base-300 bg-base-100 p-1 shadow-lg"
        role="menu"
      >
        <button
          :for={status <- Plan.statuses() -- [@plan.status]}
          phx-click="transition_plan"
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

  attr :scope, :map, required: true

  defp scope_block(assigns) do
    ~H"""
    <section class="mb-6 rounded-box border border-base-300/60 bg-base-200/20 p-4 sm:p-5">
      <p class="text-[10px] font-medium uppercase tracking-wider text-base-content/50">Scope</p>
      <dl class="mt-2 space-y-1 text-xs sm:text-sm">
        <div :for={{key, value} <- @scope} class="flex flex-col sm:flex-row sm:gap-2">
          <dt class="font-medium text-base-content/70">{key}:</dt>
          <dd class="text-base-content/60">{format_scope_value(value)}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :task, :map, required: true
  attr :menu_open?, :boolean, required: true

  defp task_row(assigns) do
    ~H"""
    <div class={[
      "relative rounded-box border bg-base-100/60 p-3 sm:p-4",
      @task.status == "done" && "border-base-300/40 opacity-60",
      @task.status != "done" && "border-base-300/60"
    ]}>
      <div class="flex items-start gap-3">
        <button
          phx-click="toggle_task_menu"
          phx-value-id={@task.id}
          class={[
            "mt-0.5 grid size-5 shrink-0 place-items-center rounded-full border transition-colors",
            @task.status == "done" && "border-success bg-success/20 text-success",
            @task.status != "done" && "border-base-300 text-base-content/30"
          ]}
          aria-haspopup="menu"
          aria-expanded={to_string(@menu_open?)}
          aria-label="Transition task"
        >
          <.icon :if={@task.status == "done"} name="hero-check-mini" class="size-3.5" />
        </button>

        <div class="min-w-0 flex-1">
          <p class={[
            "text-sm sm:text-base",
            @task.status == "done" && "line-through"
          ]}>
            {@task.title}
          </p>
          <div class="mt-1 flex flex-wrap items-center gap-2 text-[10px] uppercase tracking-wider text-base-content/50">
            <span class="rounded-full border border-base-300/60 px-1.5 py-0.5">{@task.role}</span>
            <span class={"inline-flex items-center gap-1 rounded-full px-1.5 py-0.5 " <> task_status_chip(@task.status)}>
              <span class={"size-1 rounded-full " <> status_dot(@task.status)}></span>
              {status_label(@task.status)}
            </span>
            <span :if={@task.duration_ms} class="tabular-nums">{format_duration(@task.duration_ms)}</span>
          </div>

          <div :if={@task.report} class="mt-2 rounded-field bg-base-200/40 px-2 py-1.5 text-xs text-base-content/70">
            <p class="font-medium text-base-content/80">{Map.get(@task.report, "summary", "")}</p>
            <ul :if={next_steps = Map.get(@task.report, "proposed_next_steps")} class="mt-1 list-disc space-y-0.5 pl-4">
              <li :for={step <- next_steps}>{step}</li>
            </ul>
          </div>
        </div>

        <button
          :if={@task.status in ["backlog", "blocked"]}
          phx-click="dispatch_worker"
          phx-value-id={@task.id}
          class="btn btn-primary btn-xs shrink-0"
          title="Dispatch a worker for this task"
        >
          <.icon name="hero-paper-airplane-mini" class="size-3" />
          <span class="hidden sm:inline">Dispatch</span>
        </button>

        <span :if={@task.status == "in_progress"} class="inline-flex shrink-0 items-center gap-1 text-[10px] uppercase tracking-wider text-primary">
          <span class="size-1.5 rounded-full bg-primary web-pulse"></span>
          <span class="hidden sm:inline">working</span>
        </span>
      </div>

      <div
        :if={@menu_open?}
        class="absolute left-3 top-12 z-30 mt-1 min-w-[12rem] rounded-box border border-base-300 bg-base-100 p-1 shadow-lg sm:left-12"
        role="menu"
      >
        <button
          :for={status <- Task.statuses() -- [@task.status]}
          phx-click="transition_task"
          phx-value-id={@task.id}
          phx-value-to={status}
          class="flex w-full items-center gap-2 rounded-field px-3 py-2 text-left text-sm text-base-content hover:bg-base-200"
          role="menuitem"
        >
          <span class={"size-1.5 rounded-full " <> status_dot(status)}></span>
          <span>{status_label(status)}</span>
        </button>
      </div>
    </div>
    """
  end

  attr :new_task, :map, required: true

  defp new_task_form(assigns) do
    ~H"""
    <form
      phx-submit="create_task"
      phx-change="compose_task"
      class="flex flex-col gap-2 sm:flex-row"
    >
      <input
        type="text"
        name="new_task[title]"
        value={@new_task.title}
        placeholder="Add a task…"
        class="input input-bordered flex-1 bg-base-200/60 text-sm"
      />

      <select
        name="new_task[role]"
        class="select select-bordered bg-base-200/60 text-sm sm:w-44"
      >
        <option :for={role <- Task.roles()} value={role} selected={role == @new_task.role}>
          {role}
        </option>
      </select>

      <button
        type="submit"
        disabled={@new_task.title == ""}
        class="btn btn-primary"
      >
        <.icon name="hero-plus-mini" class="size-4" /> Add
      </button>
    </form>
    """
  end

  # ---- helpers ----

  defp reload_plan(socket) do
    assign(socket, :plan, Plans.get_plan!(socket.assigns.plan.id))
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

  defp task_status_chip(status) do
    "border border-base-300/40 bg-base-200/40 text-base-content/60 " <> status
  end

  defp format_scope_value(v) when is_list(v), do: Enum.join(v, ", ")
  defp format_scope_value(v) when is_binary(v), do: v
  defp format_scope_value(v), do: inspect(v)

  defp format_duration(ms) when ms < 1_000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_duration(ms), do: "#{div(ms, 60_000)}m"

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

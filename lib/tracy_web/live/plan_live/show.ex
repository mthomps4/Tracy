defmodule TracyWeb.PlanLive.Show do
  @moduledoc """
  Plan detail view — title, brief, scope, task checklist, status transitions.

  Tap the status pill to open the transition menu (mobile-friendly dropdown).
  Tap a task row to transition it. New-task form lives at the bottom of the
  task list.
  """
  use TracyWeb, :live_view

  alias Tracy.{Assets, Plans, Workers}
  alias Tracy.Assets.Asset
  alias Tracy.Plans.{Plan, Task}

  @max_upload_size 25_000_000  # 25 MB

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
          Phoenix.PubSub.subscribe(Tracy.PubSub, "assets:#{plan.id}")
          # Watch any tasks currently in_progress so we get worker events.
          Enum.each(plan.tasks, fn task ->
            if task.status == "in_progress", do: Workers.subscribe(task.id)
          end)
        end

        socket =
          socket
          |> assign(:page_title, plan.title)
          |> assign(:plan, plan)
          |> assign(:assets, Assets.list_asset_summaries(plan.id))
          |> assign(:show_transition_menu?, false)
          |> assign(:new_task, %{title: "", role: "engineer", blocked_by: nil})
          |> assign(:selected_task_ids, MapSet.new())
          |> assign(:task_transition_id, nil)
          |> assign(:new_link, %{filename: "", body: ""})
          |> assign(:active_tab, "tasks")
          |> assign(:task_filters, %{role: "all", status: "active", query: ""})
          |> allow_upload(:asset_file,
            accept: :any,
            max_entries: 5,
            max_file_size: @max_upload_size
          )

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "tasks"
    tab = if tab in ["brief", "whiteboard", "tasks"], do: tab, else: "tasks"
    {:noreply, assign(socket, :active_tab, tab)}
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
    {:noreply,
     assign(socket, :new_task, %{
       title: params["title"] || "",
       role: params["role"] || "engineer",
       blocked_by: blank_to_nil(params["blocked_by"])
     })}
  end

  def handle_event("create_task", %{"new_task" => params}, socket) do
    title = String.trim(params["title"] || "")
    role = params["role"] || "engineer"
    blocked_by = blank_to_nil(params["blocked_by"])
    plan = socket.assigns.plan

    if title == "" do
      {:noreply, socket}
    else
      next_pos = length(plan.tasks)

      attrs = %{
        plan_id: plan.id,
        title: title,
        role: role,
        position: next_pos,
        blocked_by: if(blocked_by, do: [blocked_by], else: [])
      }

      case Plans.create_task(attrs) do
        {:ok, _task} ->
          Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

          {:noreply,
           socket
           |> assign(:new_task, %{title: "", role: role, blocked_by: nil})
           |> reload_plan()}

        {:error, _cs} ->
          {:noreply, put_flash(socket, :error, "Couldn't add that task.")}
      end
    end
  end

  def handle_event("approve_task", %{"id" => id}, socket) do
    task = Enum.find(socket.assigns.plan.tasks, &(&1.id == id))

    if task do
      case Plans.approve_task(task) do
        {:ok, _} ->
          Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)
          {:noreply, reload_plan(socket)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Couldn't approve that task.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_select_task", %{"id" => id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_task_ids, id) do
        MapSet.delete(socket.assigns.selected_task_ids, id)
      else
        MapSet.put(socket.assigns.selected_task_ids, id)
      end

    {:noreply, assign(socket, :selected_task_ids, selected)}
  end

  def handle_event("clear_selection", _, socket) do
    {:noreply, assign(socket, :selected_task_ids, MapSet.new())}
  end

  def handle_event("bulk_approve", _, socket) do
    ids = socket.assigns.selected_task_ids

    {ok_count, err_count} =
      socket.assigns.plan.tasks
      |> Enum.filter(&(&1.id in ids and &1.status == "backlog"))
      |> Enum.reduce({0, 0}, fn task, {ok, err} ->
        case Plans.approve_task(task) do
          {:ok, _} -> {ok + 1, err}
          {:error, _} -> {ok, err + 1}
        end
      end)

    Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

    flash =
      cond do
        ok_count > 0 and err_count == 0 ->
          "Approved #{ok_count} task#{if ok_count == 1, do: "", else: "s"}."

        ok_count > 0 and err_count > 0 ->
          "Approved #{ok_count}, but #{err_count} failed."

        true ->
          "Nothing approved."
      end

    {:noreply,
     socket
     |> put_flash(:info, flash)
     |> assign(:selected_task_ids, MapSet.new())
     |> reload_plan()}
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

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :asset_file, ref)}
  end

  def handle_event("upload_files", _params, socket) do
    user_id = socket.assigns.current_scope.user.id
    plan_id = socket.assigns.plan.id

    uploaded =
      consume_uploaded_entries(socket, :asset_file, fn %{path: path}, entry ->
        data = File.read!(path)

        attrs = %{
          plan_id: plan_id,
          filename: entry.client_name,
          content_type: entry.client_type || "application/octet-stream",
          data: data,
          uploaded_by_id: user_id
        }

        case Assets.create_file_asset(attrs) do
          {:ok, asset} -> {:ok, asset.id}
          {:error, _cs} -> {:postpone, :error}
        end
      end)

    if uploaded != [] do
      Phoenix.PubSub.broadcast(Tracy.PubSub, "assets:#{plan_id}", :assets_changed)
    end

    {:noreply, assign(socket, :assets, Assets.list_asset_summaries(plan_id))}
  end

  def handle_event("compose_link", %{"new_link" => params}, socket) do
    {:noreply, assign(socket, :new_link, %{
      filename: params["filename"] || "",
      body: params["body"] || ""
    })}
  end

  def handle_event("create_link", %{"new_link" => %{"filename" => title, "body" => url}}, socket) do
    url = String.trim(url)
    title = title |> to_string() |> String.trim()
    plan_id = socket.assigns.plan.id

    cond do
      url == "" ->
        {:noreply, socket}

      true ->
        attrs = %{
          plan_id: plan_id,
          filename: (if title == "", do: url, else: title),
          body: url,
          uploaded_by_id: socket.assigns.current_scope.user.id
        }

        case Assets.create_link_asset(attrs) do
          {:ok, _} ->
            Phoenix.PubSub.broadcast(Tracy.PubSub, "assets:#{plan_id}", :assets_changed)

            {:noreply,
             socket
             |> assign(:new_link, %{filename: "", body: ""})
             |> assign(:assets, Assets.list_asset_summaries(plan_id))}

          {:error, _cs} ->
            {:noreply, put_flash(socket, :error, "Couldn't save that link.")}
        end
    end
  end

  def handle_event("delete_asset", %{"id" => id}, socket) do
    plan_id = socket.assigns.plan.id

    case Assets.delete_asset(id) do
      {:ok, _} ->
        Phoenix.PubSub.broadcast(Tracy.PubSub, "assets:#{plan_id}", :assets_changed)
        {:noreply, assign(socket, :assets, Assets.list_asset_summaries(plan_id))}

      _ ->
        {:noreply, put_flash(socket, :error, "Couldn't delete that asset.")}
    end
  end

  # ---- task filters ----

  def handle_event("set_task_filter", params, socket) do
    filters = socket.assigns.task_filters
    role = params["role"] || filters.role
    status = params["status"] || filters.status
    query = params["query"] || filters.query

    {:noreply,
     assign(socket, :task_filters, %{
       role: role,
       status: status,
       query: query
     })}
  end

  def handle_event("clear_task_filters", _, socket) do
    {:noreply,
     assign(socket, :task_filters, %{role: "all", status: "active", query: ""})}
  end

  @impl true
  def handle_info(:plans_changed, socket), do: {:noreply, reload_plan(socket)}
  def handle_info({:worker_event, _task_id, _event}, socket), do: {:noreply, reload_plan(socket)}

  def handle_info(:assets_changed, socket) do
    {:noreply, assign(socket, :assets, Assets.list_asset_summaries(socket.assigns.plan.id))}
  end

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

      <.tab_bar plan_id={@plan.id} active={@active_tab} task_count={length(@plan.tasks)} />

      <div :if={@active_tab == "brief"}>
        <section :if={@plan.brief} class="mb-6 rounded-box border border-base-300/60 bg-base-200/30 p-4 sm:p-5">
          <p class="text-[10px] font-medium uppercase tracking-wider text-base-content/50">Brief</p>
          <p class="mt-2 whitespace-pre-wrap text-sm text-base-content/80 sm:text-base">
            {@plan.brief}
          </p>
        </section>

        <p :if={!@plan.brief} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-6 text-center text-xs text-base-content/50">
          No project brief yet. Save a conversation from the boardroom or write a note in the Whiteboard.
        </p>

        <.scope_block :if={@plan.scope != %{}} scope={@plan.scope} />

        <.assets_section
          assets={@assets}
          uploads={@uploads}
          new_link={@new_link}
        />
      </div>

      <div :if={@active_tab == "whiteboard"}>
        {live_render(@socket, TracyWeb.WhiteboardLive,
          id: "whiteboard-#{@plan.id}",
          session: %{"plan_id" => @plan.id}
        )}
      </div>

      <div :if={@active_tab == "tasks"}>
        <.task_filters_bar filters={@task_filters} plan={@plan} />

        <% visible = filter_tasks(@plan.tasks, @task_filters) %>
        <% tasks_by_id = Enum.into(@plan.tasks, %{}, fn t -> {t.id, t} end) %>

        <.bulk_action_bar :if={MapSet.size(@selected_task_ids) > 0} count={MapSet.size(@selected_task_ids)} />

        <section class="mb-4">
          <ul :if={visible != []} class="space-y-1.5">
            <li :for={task <- visible}>
              <.task_row
                task={task}
                menu_open?={@task_transition_id == task.id}
                tasks_by_id={tasks_by_id}
                selected?={MapSet.member?(@selected_task_ids, task.id)}
              />
            </li>
          </ul>

          <p :if={visible == [] and @plan.tasks != []} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-6 text-center text-xs text-base-content/50">
            No tasks match the current filters.
            <button phx-click="clear_task_filters" class="text-primary hover:underline">Clear filters</button>
          </p>

          <p :if={@plan.tasks == []} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-6 text-center text-xs text-base-content/50">
            No tasks yet. Add one below.
          </p>
        </section>

        <.new_task_form new_task={@new_task} existing_tasks={@plan.tasks} />
      </div>
    </Layouts.app>
    """
  end

  attr :plan_id, :any, required: true
  attr :active, :string, required: true
  attr :task_count, :integer, required: true

  defp tab_bar(assigns) do
    ~H"""
    <nav class="mb-4 flex gap-1 overflow-x-auto border-b border-base-300/60 sm:gap-2" aria-label="Plan sections">
      <.tab_link plan_id={@plan_id} tab="tasks" active={@active} label="Tasks" badge={@task_count} />
      <.tab_link plan_id={@plan_id} tab="whiteboard" active={@active} label="Whiteboard" />
      <.tab_link plan_id={@plan_id} tab="brief" active={@active} label="Brief" />
    </nav>
    """
  end

  attr :plan_id, :any, required: true
  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :label, :string, required: true
  attr :badge, :integer, default: nil

  defp tab_link(assigns) do
    is_active = assigns.active == assigns.tab
    assigns = assign(assigns, :is_active, is_active)

    ~H"""
    <.link
      patch={~p"/plans/#{@plan_id}?tab=#{@tab}"}
      class={[
        "relative flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm font-medium transition-colors",
        @is_active && "border-primary text-primary",
        !@is_active && "border-transparent text-base-content/60 hover:text-base-content"
      ]}
      role="tab"
      aria-selected={to_string(@is_active)}
    >
      {@label}
      <span
        :if={@badge != nil}
        class={[
          "tabular-nums rounded-full px-1.5 py-0.5 text-[10px]",
          @is_active && "bg-primary/15 text-primary",
          !@is_active && "bg-base-300/60 text-base-content/60"
        ]}
      >
        {@badge}
      </span>
    </.link>
    """
  end

  attr :filters, :map, required: true
  attr :plan, :map, required: true

  defp task_filters_bar(assigns) do
    ~H"""
    <section class="mb-4 space-y-2">
      <%!-- Status chips --%>
      <div class="flex flex-wrap items-center gap-1.5 overflow-x-auto pb-1">
        <.filter_chip
          label="Active"
          value="active"
          current={@filters.status}
          field="status"
        />
        <.filter_chip
          label="All"
          value="all"
          current={@filters.status}
          field="status"
        />
        <div class="mx-1 h-4 w-px bg-base-300/60"></div>
        <.filter_chip
          :for={status <- ["backlog", "approved", "in_progress", "in_review", "needs_input", "blocked", "failed", "paused", "done"]}
          label={status_label(status)}
          value={status}
          current={@filters.status}
          field="status"
          dot={status_dot(status)}
        />
      </div>

      <%!-- Role + search row --%>
      <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
        <form phx-change="set_task_filter" class="flex flex-1 items-center gap-2">
          <select
            name="role"
            class="select select-bordered select-sm bg-base-200/60 text-xs"
            aria-label="Filter by role"
          >
            <option value="all" selected={@filters.role == "all"}>All roles</option>
            <option :for={role <- Task.roles()} value={role} selected={@filters.role == role}>
              {role}
            </option>
          </select>

          <input
            type="search"
            name="query"
            value={@filters.query}
            placeholder="Search tasks…"
            class="input input-bordered input-sm flex-1 bg-base-200/60 text-xs"
            phx-debounce="200"
          />
        </form>

        <button
          :if={@filters != %{role: "all", status: "active", query: ""}}
          phx-click="clear_task_filters"
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-x-mark-mini" class="size-3.5" /> Clear
        </button>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :current, :string, required: true
  attr :field, :string, required: true
  attr :dot, :string, default: nil

  defp filter_chip(assigns) do
    is_active = assigns.current == assigns.value
    assigns = assign(assigns, :is_active, is_active)

    ~H"""
    <button
      phx-click="set_task_filter"
      phx-value-status={@field == "status" && @value}
      phx-value-role={@field == "role" && @value}
      class={[
        "inline-flex shrink-0 items-center gap-1 rounded-full border px-2.5 py-1 text-[11px] font-medium transition-colors",
        @is_active && "border-primary bg-primary text-primary-content",
        !@is_active && "border-base-300/60 bg-base-200/40 text-base-content/70 hover:border-base-content/30 hover:text-base-content"
      ]}
    >
      <span :if={@dot} class={"size-1.5 rounded-full " <> @dot}></span>
      {@label}
    </button>
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

  attr :count, :integer, required: true

  defp bulk_action_bar(assigns) do
    ~H"""
    <div class="sticky top-0 z-30 mb-2 flex flex-wrap items-center justify-between gap-2 rounded-box border border-primary/40 bg-primary/10 px-3 py-2 backdrop-blur sm:px-4">
      <p class="text-xs font-medium text-primary">
        {@count} selected
      </p>
      <div class="flex items-center gap-2">
        <button
          phx-click="bulk_approve"
          class="btn btn-primary btn-xs"
          title="Stamp the CEO approval on every selected backlog task"
        >
          <.icon name="hero-check-badge-mini" class="size-3" />
          Approve selected
        </button>
        <button
          phx-click="clear_selection"
          class="btn btn-ghost btn-xs"
        >
          <.icon name="hero-x-mark-mini" class="size-3" />
          Clear
        </button>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :menu_open?, :boolean, required: true
  attr :tasks_by_id, :map, default: %{}
  attr :selected?, :boolean, default: false

  defp task_row(assigns) do
    blockers =
      (assigns.task.blocked_by || [])
      |> Enum.map(&Map.get(assigns.tasks_by_id, &1))
      |> Enum.reject(&is_nil/1)

    blocked? = Enum.any?(blockers, &(&1.status != "done"))

    assigns =
      assigns
      |> assign(:blockers, blockers)
      |> assign(:blocked?, blocked?)
    ~H"""
    <div class={[
      "relative rounded-box border bg-base-100/60 p-3 sm:p-4",
      @task.status == "done" && "border-base-300/40 opacity-60",
      @task.status != "done" && "border-base-300/60"
    ]}>
      <div class="flex items-start gap-3">
        <button
          :if={@task.status == "backlog"}
          phx-click="toggle_select_task"
          phx-value-id={@task.id}
          class={[
            "mt-0.5 grid size-5 shrink-0 place-items-center rounded border transition-colors",
            @selected? && "border-primary bg-primary text-primary-content",
            !@selected? && "border-base-300/70 text-base-content/30 hover:border-primary/60"
          ]}
          aria-label="Select task for bulk action"
          aria-pressed={to_string(@selected?)}
        >
          <.icon :if={@selected?} name="hero-check-mini" class="size-3.5" />
        </button>

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

        <.link
          navigate={~p"/plans/#{@task.plan_id}/tasks/#{@task.id}"}
          class="min-w-0 flex-1 group"
        >
          <p class={[
            "text-sm sm:text-base group-hover:text-primary",
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
            <span :if={@task.status == "approved"} class="inline-flex items-center gap-0.5 rounded-full border border-primary/30 bg-primary/5 px-1.5 py-0.5 text-primary/80" title="CEO stamp — will auto-dispatch when ready">
              <.icon name="hero-check-badge-mini" class="size-2.5" /> approved
            </span>
            <span :if={brief_preview(@task.brief)} class="hidden truncate normal-case tracking-normal text-base-content/40 sm:block">
              · {brief_preview(@task.brief)}
            </span>
          </div>

          <p :if={@blockers != []} class="mt-1 text-[10px] text-base-content/50">
            <span :if={@blocked?} class="text-warning">⏳ Blocked by</span>
            <span :if={!@blocked?} class="text-success/70">✓ After</span>
            <span :for={b <- @blockers} class="ml-1 italic">{String.slice(b.title, 0, 40)}</span>
          </p>

          <div :if={@task.report} class="mt-2 rounded-field bg-base-200/40 px-2 py-1.5 text-xs text-base-content/70">
            <p class="font-medium text-base-content/80">{Map.get(@task.report, "summary", "")}</p>
            <ul :if={next_steps = Map.get(@task.report, "proposed_next_steps")} class="mt-1 list-disc space-y-0.5 pl-4">
              <li :for={step <- next_steps}>{step}</li>
            </ul>
          </div>
        </.link>

        <button
          :if={@task.status == "backlog"}
          phx-click="approve_task"
          phx-value-id={@task.id}
          class="btn btn-ghost btn-xs shrink-0"
          title="Approve — CEO stamp; will auto-dispatch when blockers clear"
        >
          <.icon name="hero-check-badge-mini" class="size-3" />
          <span class="hidden sm:inline">Approve</span>
        </button>

        <button
          :if={@task.status in ["backlog", "approved", "blocked", "failed", "paused"]}
          phx-click="dispatch_worker"
          phx-value-id={@task.id}
          disabled={@blocked?}
          class={[
            "btn btn-xs shrink-0",
            @blocked? && "btn-disabled btn-ghost",
            !@blocked? && @task.status in ["failed", "paused"] && "btn-warning",
            !@blocked? && @task.status not in ["failed", "paused"] && "btn-primary"
          ]}
          title={dispatch_button_title(@task.status, @blocked?)}
        >
          <.icon name="hero-paper-airplane-mini" class="size-3" />
          <span class="hidden sm:inline">{if @task.status in ["failed", "paused"], do: "Retry", else: "Dispatch"}</span>
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
  attr :existing_tasks, :list, default: []

  defp new_task_form(assigns) do
    ~H"""
    <form
      phx-submit="create_task"
      phx-change="compose_task"
      class="flex flex-col gap-2"
    >
      <div class="flex flex-col gap-2 sm:flex-row">
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
      </div>

      <%!-- Chain controls: pick a blocker. Auto-dispatch is governed by the
            `approved` status (CEO stamp), set via the Approve button on the
            row. --%>
      <div :if={@existing_tasks != []}>
        <select
          name="new_task[blocked_by]"
          class="select select-bordered select-sm w-full bg-base-200/40 text-xs sm:w-72"
          aria-label="Run after"
        >
          <option value="" selected={@new_task.blocked_by == nil}>
            Run anytime (no dependency)
          </option>
          <option
            :for={t <- @existing_tasks}
            value={t.id}
            selected={@new_task.blocked_by == t.id}
          >
            ⤷ After: {String.slice(t.title, 0, 60)}
          </option>
        </select>
        <p class="mt-1 text-[10px] text-base-content/40">
          Tip: tap <span class="text-base-content/60">Approve</span> on a task
          to let it auto-fire when its blockers complete.
        </p>
      </div>
    </form>
    """
  end

  attr :assets, :list, required: true
  attr :uploads, :map, required: true
  attr :new_link, :map, required: true

  defp assets_section(assigns) do
    ~H"""
    <section class="mt-8">
      <header class="mb-2 flex items-baseline justify-between">
        <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
          Assets
        </h2>
        <span class="text-[10px] tabular-nums text-base-content/40">
          {length(@assets)}
        </span>
      </header>

      <ul :if={@assets != []} class="mb-4 space-y-2">
        <li :for={asset <- @assets}>
          <.asset_row asset={asset} />
        </li>
      </ul>

      <p :if={@assets == []} class="mb-4 rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-6 text-center text-xs text-base-content/50">
        No assets yet. Upload files, add a link, or workers will attach
        deliverables here automatically.
      </p>

      <details class="rounded-box border border-base-300/60 bg-base-200/30">
        <summary class="cursor-pointer px-4 py-2.5 text-sm font-medium text-base-content">
          + Add asset
        </summary>

        <div class="space-y-4 px-4 pb-4">
          <form
            phx-submit="upload_files"
            phx-change="validate_upload"
            class="space-y-2"
          >
            <p class="text-[10px] uppercase tracking-wider text-base-content/50">Upload files (≤25 MB each)</p>
            <.live_file_input upload={@uploads.asset_file} class="file-input file-input-bordered w-full text-sm" />

            <div :if={@uploads.asset_file.entries != []} class="space-y-1.5 text-xs">
              <div :for={entry <- @uploads.asset_file.entries} class="flex items-center gap-2">
                <span class="flex-1 truncate text-base-content/70">{entry.client_name}</span>
                <span class="tabular-nums text-base-content/50">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="text-base-content/50 hover:text-error"
                >
                  <.icon name="hero-x-mark-mini" class="size-4" />
                </button>
                <p :for={err <- upload_errors(@uploads.asset_file, entry)} class="text-error">
                  {format_upload_error(err)}
                </p>
              </div>
            </div>

            <button
              :if={@uploads.asset_file.entries != []}
              type="submit"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-arrow-up-tray-mini" class="size-4" /> Upload
            </button>
          </form>

          <div class="border-t border-base-300/40 pt-3">
            <form phx-submit="create_link" phx-change="compose_link" class="flex flex-col gap-2 sm:flex-row">
              <input
                type="text"
                name="new_link[filename]"
                value={@new_link.filename}
                placeholder="Title (optional)"
                class="input input-bordered flex-1 bg-base-100/60 text-sm sm:flex-none sm:w-44"
              />
              <input
                type="url"
                name="new_link[body]"
                value={@new_link.body}
                placeholder="https://…"
                class="input input-bordered flex-1 bg-base-100/60 text-sm"
              />
              <button
                type="submit"
                disabled={@new_link.body == ""}
                class="btn btn-ghost"
              >
                <.icon name="hero-link-mini" class="size-4" /> Link
              </button>
            </form>
          </div>
        </div>
      </details>
    </section>
    """
  end

  attr :asset, :map, required: true

  defp asset_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 rounded-box border border-base-300/60 bg-base-100/60 p-3">
      <div class="grid size-9 shrink-0 place-items-center rounded-box bg-base-200">
        <.icon name={asset_icon(@asset)} class="size-4 text-base-content/60" />
      </div>

      <div class="min-w-0 flex-1">
        <%= cond do %>
          <% @asset.kind == "link" -> %>
            <a href={@asset.body} target="_blank" rel="noopener" class="block truncate text-sm font-medium text-primary hover:underline">
              {@asset.filename}
            </a>
            <p class="truncate text-[10px] text-base-content/50">{@asset.body}</p>
          <% true -> %>
            <p class="truncate text-sm font-medium text-base-content">{@asset.filename}</p>
            <p class="text-[10px] uppercase tracking-wider text-base-content/50">
              {@asset.content_type} · {Asset.humanize_size(@asset.size_bytes)} · {@asset.source}
            </p>
        <% end %>
      </div>

      <a
        :if={@asset.kind in ["file", "image"]}
        href={~p"/assets/#{@asset.id}/download"}
        class="btn btn-ghost btn-xs"
        target="_blank"
        rel="noopener"
      >
        <.icon name="hero-arrow-down-tray-mini" class="size-4" />
        <span class="hidden sm:inline">Download</span>
      </a>

      <button
        phx-click="delete_asset"
        phx-value-id={@asset.id}
        data-confirm="Delete this asset?"
        class="btn btn-ghost btn-xs text-base-content/50 hover:text-error"
        aria-label="Delete"
      >
        <.icon name="hero-trash-mini" class="size-4" />
      </button>
    </div>
    """
  end

  defp asset_icon(%{kind: "image"}), do: "hero-photo"
  defp asset_icon(%{kind: "link"}), do: "hero-link"
  defp asset_icon(%{kind: "note"}), do: "hero-document-text"
  defp asset_icon(_), do: "hero-document"

  defp format_upload_error(:too_large), do: "Too large (max 25 MB)"
  defp format_upload_error(:not_accepted), do: "File type not accepted"
  defp format_upload_error(err), do: to_string(err)

  # ---- helpers ----

  defp reload_plan(socket) do
    assign(socket, :plan, Plans.get_plan!(socket.assigns.plan.id))
  end

  # ---- task filtering ----

  defp filter_tasks(tasks, filters) do
    tasks
    |> Enum.filter(&matches_status?(&1, filters.status))
    |> Enum.filter(&matches_role?(&1, filters.role))
    |> Enum.filter(&matches_query?(&1, filters.query))
  end

  defp matches_status?(_task, "all"), do: true

  defp matches_status?(task, "active"),
    do: task.status not in ["done", "canceled"]

  defp matches_status?(task, status), do: task.status == status

  defp matches_role?(_task, "all"), do: true
  defp matches_role?(task, role), do: task.role == role

  defp matches_query?(_task, ""), do: true
  defp matches_query?(_task, nil), do: true

  defp matches_query?(task, query) do
    q = String.downcase(query)
    haystack = String.downcase("#{task.title} #{task.brief || ""}")
    String.contains?(haystack, q)
  end

  defp status_label("triage"), do: "Triage"
  defp status_label("backlog"), do: "Backlog"
  defp status_label("approved"), do: "Approved"
  defp status_label("in_progress"), do: "In Progress"
  defp status_label("in_review"), do: "In Review"
  defp status_label("needs_input"), do: "Needs Input"
  defp status_label("blocked"), do: "Blocked"
  defp status_label("failed"), do: "Failed"
  defp status_label("paused"), do: "Paused"
  defp status_label("done"), do: "Done"
  defp status_label("canceled"), do: "Canceled"
  defp status_label(other), do: String.capitalize(other)

  defp status_dot("triage"), do: "bg-base-content/30"
  defp status_dot("backlog"), do: "bg-info"
  defp status_dot("approved"), do: "bg-primary/60"
  defp status_dot("in_progress"), do: "bg-primary"
  defp status_dot("in_review"), do: "bg-secondary"
  defp status_dot("needs_input"), do: "bg-warning"
  defp status_dot("blocked"), do: "bg-error"
  defp status_dot("failed"), do: "bg-error"
  defp status_dot("paused"), do: "bg-warning"
  defp status_dot("done"), do: "bg-success"
  defp status_dot("canceled"), do: "bg-base-content/20"
  defp status_dot(_), do: "bg-base-content/30"

  defp status_pill_class("triage"), do: "border-base-300/60 bg-base-200/60 text-base-content/70"
  defp status_pill_class("backlog"), do: "border-info/40 bg-info/10 text-info"
  defp status_pill_class("approved"), do: "border-primary/40 bg-primary/10 text-primary"
  defp status_pill_class("in_progress"), do: "border-primary/40 bg-primary/10 text-primary"
  defp status_pill_class("in_review"), do: "border-secondary/40 bg-secondary/10 text-secondary"
  defp status_pill_class("needs_input"), do: "border-warning/40 bg-warning/10 text-warning"
  defp status_pill_class("blocked"), do: "border-error/40 bg-error/10 text-error"
  defp status_pill_class("failed"), do: "border-error/40 bg-error/10 text-error"
  defp status_pill_class("paused"), do: "border-warning/40 bg-warning/10 text-warning"
  defp status_pill_class("done"), do: "border-success/40 bg-success/10 text-success"
  defp status_pill_class("canceled"), do: "border-base-300/60 bg-base-200/40 text-base-content/40"
  defp status_pill_class(_), do: "border-base-300/60 bg-base-200/60 text-base-content/70"

  defp task_status_chip(status) do
    "border border-base-300/40 bg-base-200/40 text-base-content/60 " <> status
  end

  defp format_scope_value(v) when is_list(v), do: Enum.join(v, ", ")
  defp format_scope_value(v) when is_binary(v), do: v
  defp format_scope_value(v), do: inspect(v)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(val), do: val

  defp dispatch_button_title(_status, true),
    do: "Blocked by upstream task(s) — dispatch the blocker first"

  defp dispatch_button_title("failed", false), do: "Retry — last dispatch errored"
  defp dispatch_button_title("paused", false), do: "Retry — was paused at the budget gate"
  defp dispatch_button_title(_status, false), do: "Dispatch a worker for this task"

  defp brief_preview(nil), do: nil
  defp brief_preview(""), do: nil

  defp brief_preview(brief) do
    brief
    |> String.split("\n", trim: true)
    |> List.first()
    |> case do
      nil -> nil
      first -> String.slice(first, 0, 110)
    end
  end

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

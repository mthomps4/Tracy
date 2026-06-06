defmodule TracyWeb.PlansLive do
  @moduledoc """
  Plans surface — mobile-first list view grouped by status.

  Locked decision (TRACY_PLAN_SURFACE.md / feedback_mobile_first_list_view.md):
  list view, NOT Kanban. Status sections are collapsible; tap row → detail.

  v0 of this surface is read + transition only. Worker spawn lands in
  Phase 2B; for now C-Suite (Matt) transitions statuses via tap.
  """
  use TracyWeb, :live_view

  alias Tracy.Plans
  alias Tracy.Plans.Plan

  # Order in which status sections are displayed. Active stuff first;
  # terminal (done/canceled) at the bottom and collapsed by default.
  @section_order ~w(needs_input in_review in_progress backlog triage blocked done canceled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Tracy.PubSub, "plans")

    {:ok,
     socket
     |> assign(:page_title, "Plans")
     |> assign(:include_terminal, false)
     |> assign(:project_filter, nil)
     |> load_plans()}
  end

  @impl true
  def handle_event("toggle_terminal", _params, socket) do
    {:noreply,
     socket
     |> assign(:include_terminal, !socket.assigns.include_terminal)
     |> load_plans()}
  end

  # Reply CTA on "Needs Input" cards — navigates to plan detail which has the
  # reply form. A dedicated reply modal (D-2.2c) can replace this later.
  def handle_event("open_reply", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/plans/#{id}")}
  end

  def handle_event("transition", %{"id" => id, "to" => new_status}, socket) do
    plan = Plans.get_plan!(id)
    user_id = socket.assigns.current_scope.user.id

    case Plans.transition_plan(plan, new_status, approved_by_id: user_id) do
      {:ok, _plan} ->
        Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)
        {:noreply, load_plans(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't transition that plan.")}
    end
  end

  @impl true
  def handle_info(:plans_changed, socket) do
    {:noreply, load_plans(socket)}
  end

  # ---- view ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title="Plans" current_tab={@current_tab}>
      <.plans_header
        include_terminal={@include_terminal}
        status_counts={@status_counts}
        total={@total}
      />

      <div :if={@total > 0} class="space-y-4 pb-8">
        <.plans_section
          :for={status <- section_order(@include_terminal)}
          :if={Map.get(@grouped, status, []) != []}
          status={status}
          plans={Map.get(@grouped, status, [])}
          collapsed?={status in ["done", "canceled"]}
        />
      </div>

      <.empty_state
        :if={@total == 0}
        illustration={:no_plans}
        title="No plans yet"
        description="Plans are created from the boardroom — chat with Tracy, then type /save-as-plan to capture the conversation."
      >
        <:actions>
          <.link navigate={~p"/boardroom"} class="btn btn-primary btn-sm">
            <.icon name="hero-chat-bubble-left-right-mini" class="size-4" /> Open the boardroom
          </.link>
        </:actions>
      </.empty_state>

      <p class="mt-6 text-center text-xs text-base-content/40">
        Plans are created from the boardroom: type
        <code class="rounded bg-base-200 px-1.5 py-0.5 text-base-content/70">/save-as-plan</code>
        after a conversation.
      </p>
    </Layouts.app>
    """
  end

  attr :include_terminal, :boolean, required: true
  attr :status_counts, :map, required: true
  attr :total, :integer, required: true

  defp plans_header(assigns) do
    ~H"""
    <header class="mb-4 flex items-end justify-between gap-3 sm:mb-6">
      <div>
        <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">Tracy</p>
        <h1 class="text-xl font-bold tracking-tight text-base-content sm:text-2xl">Plans</h1>
        <p class="mt-0.5 text-xs text-base-content/60">
          {@total} {if @total == 1, do: "plan", else: "plans"} ·
          <span class="text-primary">{Map.get(@status_counts, "in_progress", 0)} active</span>
        </p>
      </div>

      <button
        phx-click="toggle_terminal"
        class="btn btn-ghost btn-sm border border-base-300/60"
      >
        <%= if @include_terminal do %>
          <.icon name="hero-eye-slash-mini" class="size-4" /> Hide done
        <% else %>
          <.icon name="hero-eye-mini" class="size-4" /> Show done
        <% end %>
      </button>
    </header>
    """
  end

  attr :status, :string, required: true
  attr :plans, :list, required: true
  attr :collapsed?, :boolean, default: false

  defp plans_section(assigns) do
    ~H"""
    <details class="rounded-box border border-base-300/60 bg-base-200/30" open={not @collapsed? and @plans != []}>
      <summary class="flex cursor-pointer items-center justify-between px-4 py-3 text-sm font-semibold tracking-tight text-base-content marker:hidden">
        <span class="inline-flex items-center gap-2">
          <span class={"size-2 rounded-full " <> status_dot(@status)}></span>
          {status_label(@status)}
        </span>
        <span class="text-xs tabular-nums text-base-content/50">
          {length(@plans)}
        </span>
      </summary>

      <ul class="divide-y divide-base-300/40 border-t border-base-300/40">
        <li :for={plan <- @plans}>
          <.plan_row plan={plan} />
        </li>
      </ul>
    </details>
    """
  end

  attr :plan, :map, required: true

  defp plan_row(assigns) do
    assigns =
      assigns
      |> assign(:cost_pct, cost_pct(assigns.plan))
      |> assign(:cost_tier, cost_tier(assigns.plan))
      |> assign(:card_class, plan_card_class(assigns.plan))

    ~H"""
    <.link
      navigate={~p"/plans/#{@plan.id}"}
      class={"flex items-center gap-2 px-4 py-3 transition-colors hover:bg-base-300/30 focus:bg-base-300/40 focus:outline-none active:bg-base-300/60 #{@card_class}"}
    >
      <div class="min-w-0 flex-1">
        <%!-- Plan ID + title --%>
        <p class="mb-0.5 text-[10px] font-bold uppercase tracking-widest text-base-content/40">
          {plan_id_label(@plan)}
        </p>
        <p class="truncate text-sm font-medium text-base-content sm:text-base">
          {@plan.title}
        </p>

        <%!-- Meta row: role badge, cost, elapsed, task count --%>
        <div class="mt-1 flex flex-wrap items-center gap-1.5">
          <span :if={plan_role(@plan)} class={"badge-role role-#{plan_role(@plan)}"}>
            {role_label(plan_role(@plan))}
          </span>

          <%!-- Inline cost for active/in-progress plans --%>
          <span
            :if={show_cost?(@plan)}
            class={"cost-inline #{@cost_tier}"}
            title={"$#{format_cost(@plan.cost_used)} used of $#{format_cost(@plan.cost_cap)} cap"}
          >
            $<%= format_cost(@plan.cost_used) %>/$<%= format_cost(@plan.cost_cap) %>
          </span>

          <%!-- Cap label for plans not yet started --%>
          <span :if={show_cap_only?(@plan)} class="text-[10px] text-base-content/45">
            $<%= format_cost(@plan.cost_cap) %> cap
          </span>

          <%!-- Elapsed time --%>
          <span :if={show_elapsed?(@plan)} class="text-[10px] text-base-content/40">
            {format_elapsed(@plan)}
          </span>

          <%!-- Task progress (when no worker cost info) --%>
          <span
            :if={not show_cost?(@plan) and not show_cap_only?(@plan) and Enum.any?(@plan.tasks)}
            class="text-[10px] text-base-content/40"
          >
            {Enum.count(@plan.tasks, &(&1.status == "done"))}/{length(@plan.tasks)} tasks
          </span>
        </div>

        <%!-- Mini cost bar — only when plan has cap AND spend --%>
        <div :if={@cost_pct > 0} class="plan-cost-bar">
          <div class={"plan-cost-fill #{@cost_tier}"} style={"width:#{@cost_pct}%"}></div>
        </div>
      </div>

      <%!-- Right column: timestamp + reply or chevron --%>
      <div class="flex shrink-0 flex-col items-end gap-1.5">
        <span class="text-[10px] tabular-nums text-base-content/40">
          {format_relative(@plan.updated_at)}
        </span>
        <%!-- Reply button for Needs Input --%>
        <button
          :if={@plan.status == "needs_input"}
          class="reply-btn"
          phx-click="open_reply"
          phx-value-id={@plan.id}
          onclick="event.stopPropagation()"
        >
          ↩ Reply
        </button>
        <.icon
          :if={@plan.status != "needs_input"}
          name="hero-chevron-right-mini"
          class="size-4 shrink-0 text-base-content/30"
        />
      </div>
    </.link>
    """
  end


  # ---- helpers ----

  defp load_plans(socket) do
    grouped =
      Plans.list_plans_by_status(
        project: socket.assigns.project_filter,
        include_terminal: socket.assigns.include_terminal
      )

    total = grouped |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    status_counts = Plans.status_counts(project: socket.assigns.project_filter)

    socket
    |> assign(:grouped, grouped)
    |> assign(:status_counts, status_counts)
    |> assign(:total, total)
  end

  defp section_order(true), do: @section_order
  defp section_order(false), do: @section_order -- ["done", "canceled"]

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
  defp status_dot("in_progress"), do: "bg-primary web-pulse"
  defp status_dot("in_review"), do: "bg-secondary"
  defp status_dot("needs_input"), do: "bg-warning web-pulse"
  defp status_dot("blocked"), do: "bg-error"
  defp status_dot("done"), do: "bg-success"
  defp status_dot("canceled"), do: "bg-base-content/20"
  defp status_dot(_), do: "bg-base-content/30"

  # Lightweight relative-time formatter. For the boardroom UI we just want a
  # quick sense of recency, not a full library.
  defp format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86_400)}d"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp format_relative(_), do: ""

  # ── D-2.1a Cost visualization helpers ────────────────────────────────────

  # The plan struct may or may not have cost fields depending on Phase.
  # We guard with Map.get so this renders safely against the current schema.

  defp plan_role(plan), do: Map.get(plan, :worker_role)

  defp plan_id_label(plan) do
    case Map.get(plan, :plan_id) do
      nil -> nil
      id -> "TRA-#{id}"
    end
  end

  defp role_label(nil), do: nil
  defp role_label("note_taker"), do: "Note Taker"
  defp role_label(role), do: String.capitalize(role)

  defp cost_pct(plan) do
    used = Map.get(plan, :cost_used)
    cap = Map.get(plan, :cost_cap)

    if is_number(used) and is_number(cap) and cap > 0 and used > 0 do
      min(100, round(used / cap * 100))
    else
      0
    end
  end

  defp cost_tier(plan) do
    pct = cost_pct(plan)

    cond do
      pct >= 75 -> "cost-danger"
      pct >= 50 -> "cost-warn"
      true -> "cost-good"
    end
  end

  # Show inline cost (used/cap) when the plan has both values and is running.
  defp show_cost?(plan) do
    used = Map.get(plan, :cost_used)
    cap = Map.get(plan, :cost_cap)
    status = Map.get(plan, :status, "")
    active = status in ~w(in_progress in_review needs_input blocked done)

    active and is_number(used) and is_number(cap) and cap > 0
  end

  # Show cap only (no spend yet) for Triage/Backlog plans with a cap set.
  defp show_cap_only?(plan) do
    used = Map.get(plan, :cost_used, 0)
    cap = Map.get(plan, :cost_cap)
    status = Map.get(plan, :status, "")
    pre_dispatch = status in ~w(triage backlog)

    pre_dispatch and is_number(cap) and cap > 0 and (is_nil(used) or used == 0)
  end

  # Show elapsed when started_at is set and plan is active.
  defp show_elapsed?(plan) do
    not is_nil(Map.get(plan, :started_at)) and
      Map.get(plan, :status, "") in ~w(in_progress needs_input blocked)
  end

  defp format_elapsed(%{started_at: %DateTime{} = started_at}) do
    diff = DateTime.diff(DateTime.utc_now(), started_at, :second)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{div(rem(diff, 3600), 60)}m"
    end
  end

  defp format_elapsed(_), do: nil

  defp format_cost(nil), do: "—"
  defp format_cost(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_cost(n) when is_integer(n), do: "#{n}"
  defp format_cost(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp format_cost(other), do: "#{other}"

  defp plan_card_class(%{status: "needs_input"}), do: "plan-card-needs-input"
  defp plan_card_class(%{status: "done"}), do: "plan-card-done"
  defp plan_card_class(%{status: "canceled"}), do: "plan-card-canceled"
  defp plan_card_class(_), do: ""

  # Used in HEEx markers attribute — silence false-positive "unused" warning.
  _ = Plan
end

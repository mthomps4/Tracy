defmodule TracyWeb.ProjectsLive do
  @moduledoc """
  Oversight dashboard for all projects.

  Read-mostly. Tracy does the work in the Boardroom chat; this page is
  where Matt looks over my shoulder. One card per project, ordered by
  recency. Each card shows:

    * title + project tag
    * status + done/in-flight/open task counts
    * cost burn for this project (sum of task cost_micros)
    * last activity timestamp
    * a small ▶ link into the existing PlanLive.Show for detail

  Tap into a project → the standard `/plans/:id` detail view (kept for
  v2 — the plan detail page is still useful, even if the *primary*
  interaction is the chat dock floating overhead).

  Live: subscribes to the `plans` PubSub topic so dispatches and
  completions update the cards in real time.
  """
  use TracyWeb, :live_view

  alias Tracy.Plans

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Tracy.PubSub, "plans")

    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> assign(:current_tab, :projects)
     |> assign(:projects, Plans.list_projects_for_dashboard())}
  end

  @impl true
  def handle_info(:plans_changed, socket) do
    {:noreply, assign(socket, :projects, Plans.list_projects_for_dashboard())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_tab={@current_tab}
      page_title={@page_title}
    >
      <header class="mb-6">
        <h1 class="text-2xl font-bold tracking-tight text-base-content sm:text-3xl">Projects</h1>
        <p class="mt-1 text-sm text-base-content/60">
          What I'm working on with you. Talk to me in the chat (bottom right) to
          steer any of these — you don't have to click in.
        </p>
      </header>

      <section :if={@projects == []} class="rounded-box border border-dashed border-primary/25 bg-gradient-to-br from-primary/5 to-transparent px-6 py-14 text-center">
        <div class="mx-auto mb-3 grid size-12 place-items-center rounded-full bg-primary/15 text-primary">
          <.icon name="hero-rectangle-stack" class="size-6" />
        </div>
        <p class="text-base font-semibold text-base-content">No projects yet.</p>
        <p class="mx-auto mt-2 max-w-sm text-sm text-base-content/60">
          Tell me what you want to work on in chat — I'll start a project for it
          and you'll see it here as it grows. Or you can create one explicitly
          from the boardroom by saving a conversation as a plan.
        </p>
        <.link
          navigate={~p"/boardroom"}
          class="mt-4 inline-flex items-center gap-1.5 rounded-full bg-primary px-3 py-1.5 text-xs font-medium text-primary-content hover:bg-primary/90"
        >
          Start a conversation
          <.icon name="hero-arrow-right-mini" class="size-3.5" />
        </.link>
      </section>

      <section :if={@projects != []} class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.project_card :for={plan <- @projects} plan={plan} />
      </section>
    </Layouts.app>
    """
  end

  attr :plan, :map, required: true

  defp project_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/plans/#{@plan.id}"}
      class="group relative rounded-box border border-base-300/60 bg-base-200/30 p-4 transition-all hover:border-primary/40 hover:bg-base-200/50 hover:shadow-lg sm:p-5"
    >
      <header class="mb-3 flex items-start justify-between gap-2">
        <div class="min-w-0 flex-1">
          <p :if={@plan.project} class="mb-1 text-[10px] uppercase tracking-wider text-base-content/40">
            {@plan.project}
          </p>
          <h3 class="truncate text-sm font-semibold text-base-content group-hover:text-primary sm:text-base">
            {@plan.title}
          </h3>
        </div>
        <span class={[
          "shrink-0 rounded-full border px-2 py-0.5 text-[10px] font-medium uppercase tracking-wider",
          status_pill_class(@plan.status)
        ]}>
          {status_label(@plan.status)}
        </span>
      </header>

      <div class="mb-3 flex items-center gap-3 text-[11px] text-base-content/60">
        <span :if={@plan.metrics.in_flight > 0} class="inline-flex items-center gap-1 text-primary">
          <span class="size-1.5 rounded-full bg-primary web-pulse"></span>
          {@plan.metrics.in_flight} running
        </span>
        <span>{@plan.metrics.done}/{@plan.metrics.total} done</span>
        <span :if={@plan.metrics.cost_micros > 0} class="ml-auto tabular-nums text-base-content/50">
          {format_cost(@plan.metrics.cost_micros)}
        </span>
      </div>

      <%!-- Progress bar — done vs total --%>
      <div :if={@plan.metrics.total > 0} class="h-1.5 w-full overflow-hidden rounded-full bg-base-300/50">
        <div
          class="h-full bg-success transition-all"
          style={"width: #{progress_pct(@plan.metrics)}%"}
        ></div>
      </div>

      <p class="mt-3 text-[10px] text-base-content/40">
        Last touched {format_relative(@plan.metrics.last_activity)}
      </p>
    </.link>
    """
  end

  # ---- formatting ----

  defp progress_pct(%{total: 0}), do: 0
  defp progress_pct(%{total: total, done: done}), do: round(done / total * 100)

  defp format_cost(micros) when micros > 0 do
    "$" <> :erlang.float_to_binary(micros / 1_000_000, decimals: 2)
  end

  defp format_cost(_), do: nil

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

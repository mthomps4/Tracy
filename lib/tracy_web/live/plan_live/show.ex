defmodule TracyWeb.PlanLive.Show do
  @moduledoc """
  Plan detail view — placeholder shell for 2A.2.

  2A.3 fills this in with: tasks checklist, scope display, status
  transitions via tap on the status badge, comments / activity log.
  """
  use TracyWeb, :live_view

  alias Tracy.Plans

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Plans.get_plan(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Plan not found.")
         |> push_navigate(to: ~p"/plans")}

      plan ->
        {:ok,
         socket
         |> assign(:page_title, plan.title)
         |> assign(:plan, plan)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title={@plan.title}>
      <.link navigate={~p"/plans"} class="mb-3 inline-flex items-center gap-1 text-xs text-base-content/60 hover:text-base-content">
        <.icon name="hero-arrow-left-mini" class="size-4" /> Plans
      </.link>

      <header class="mb-4">
        <p class="text-[10px] font-medium uppercase tracking-wider text-base-content/50">
          <span class="rounded-full border border-base-300/60 px-2 py-0.5">
            {String.replace(@plan.status, "_", " ")}
          </span>
          <span :if={@plan.project} class="ml-2">{@plan.project}</span>
        </p>
        <h1 class="mt-2 text-xl font-bold tracking-tight text-base-content sm:text-2xl">
          {@plan.title}
        </h1>
        <p :if={@plan.brief} class="mt-2 whitespace-pre-wrap text-sm text-base-content/80">
          {@plan.brief}
        </p>
      </header>

      <section class="rounded-box border border-dashed border-base-300/60 bg-base-200/30 p-6 text-center">
        <.icon name="hero-sparkles" class="mx-auto size-6 text-primary" />
        <p class="mt-2 text-sm text-base-content/70">
          Full plan detail view — tasks checklist, scope, transitions — lands in 2A.3.
        </p>
        <p class="mt-1 text-xs text-base-content/50">
          For now: {length(@plan.tasks)} task(s) attached.
        </p>
      </section>
    </Layouts.app>
    """
  end
end

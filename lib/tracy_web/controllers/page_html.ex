defmodule TracyWeb.PageHTML do
  @moduledoc """
  Pages rendered by `PageController`.

  Also hosts the small marketing components used on the public landing page
  (roster cards, pillar cards). Keeping these here keeps the public surface
  isolated from the in-app components in `core_components.ex`.
  """
  use TracyWeb, :html

  embed_templates "page_html/*"

  attr :icon, :string, required: true
  attr :name, :string, required: true
  attr :model, :string, required: true
  attr :desc, :string, required: true

  def roster_card(assigns) do
    ~H"""
    <li class="group rounded-box border border-base-300/60 bg-base-100/60 p-4 transition-colors hover:border-primary/50 hover:bg-base-100">
      <div class="flex items-start gap-3">
        <div class="grid size-9 shrink-0 place-items-center rounded-full bg-primary/15 text-primary">
          <.icon name={@icon} class="size-5" />
        </div>
        <div class="min-w-0">
          <div class="flex items-baseline gap-2">
            <p class="text-sm font-semibold text-base-content">{@name}</p>
            <span class="text-[10px] font-medium uppercase tracking-wider text-base-content/50">
              {@model}
            </span>
          </div>
          <p class="mt-1 text-xs text-base-content/70">{@desc}</p>
        </div>
      </div>
    </li>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  def pillar(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-100/60 p-5 sm:p-6">
      <div class="mb-4 grid size-10 place-items-center rounded-full bg-secondary/15 text-secondary">
        <.icon name={@icon} class="size-5" />
      </div>
      <h3 class="text-lg font-semibold tracking-tight text-base-content">{@title}</h3>
      <p class="mt-2 text-sm leading-relaxed text-base-content/70">{@body}</p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :pct, :integer, required: true, doc: "0..100"
  attr :note, :string, default: ""

  @doc """
  Cost meter — color bar + tooltip (per locked decision §3 in TRACY_V1_SCOPE.md).
  Green <50 / yellow 50-79 / red 80+. Used in the boardroom header.
  """
  def meter(assigns) do
    color_class =
      cond do
        assigns.pct >= 80 -> "bg-error"
        assigns.pct >= 50 -> "bg-warning"
        true -> "bg-success"
      end

    assigns = assign(assigns, :color_class, color_class)

    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/40 px-3 py-2">
      <div class="flex items-baseline justify-between gap-2">
        <span class="text-[10px] font-medium uppercase tracking-wider text-base-content/60">
          {@label}
        </span>
        <span class="text-xs tabular-nums text-base-content/70">{@note}</span>
      </div>
      <div
        class="mt-1.5 h-1.5 w-full overflow-hidden rounded-full bg-base-300/70"
        role="progressbar"
        aria-valuenow={@pct}
        aria-valuemin="0"
        aria-valuemax="100"
        title={"#{@pct}% — #{@note}"}
      >
        <div class={"h-full transition-all " <> @color_class} style={"width: #{@pct}%"}></div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :empty_note, :string, required: true
  attr :cta, :string, default: nil

  @doc """
  Boardroom placeholder panel. Phase 2 fills these with real list views grouped by status.
  """
  def panel(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300/60 bg-base-200/40 p-5">
      <header class="mb-4 flex items-center justify-between">
        <h2 class="flex items-center gap-2 text-sm font-semibold uppercase tracking-wider text-base-content">
          <.icon name={@icon} class="size-5 text-primary" /> {@title}
        </h2>
        <span :if={@cta} class="rounded-full border border-base-300/60 px-2 py-0.5 text-[10px] uppercase tracking-wider text-base-content/60">
          {@cta}
        </span>
      </header>
      <div class="flex h-32 flex-col items-center justify-center gap-2 rounded-field border border-dashed border-base-300/60 text-center">
        <.icon name="hero-sparkles" class="size-5 text-base-content/40" />
        <p class="px-4 text-xs text-base-content/60">{@empty_note}</p>
      </div>
    </div>
    """
  end
end

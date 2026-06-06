defmodule TracyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality used by the application.
  """
  use TracyWeb, :html

  embed_templates "layouts/*"

  @doc """
  Tracy's main app layout: responsive shell that morphs at the md breakpoint.

  - **Mobile  (< 768px):** sticky top nav + cost bar + scrollable content + fixed
    bottom tab bar.
  - **Desktop (≥ 768px):** 220px left sidebar + content column; top nav and cost
    bar are hidden (the sidebar provides logo, nav, cost card, and user identity).

  Pass `cost` from a LiveView that already holds `@cost` (e.g. BoardroomLive) to
  avoid an extra DB round-trip. Omit it on other pages — the layout fetches it
  once at render time.

  Pass `current_tab` (atom) to highlight the active nav item. The
  `TracyWeb.NavHooks` on_mount callback injects this into every authenticated
  LiveView automatically.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope} current_tab={@current_tab}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :current_tab, :atom, default: :plans
  attr :page_title, :string, default: nil
  attr :cost, :map, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    # Fetch billing data if the caller didn't supply it (non-boardroom pages).
    # Runs once per render cycle; cheap for a single-user local system.
    assigns =
      if assigns.current_scope && is_nil(assigns.cost) do
        assign(assigns, :cost, Tracy.Billing.sdk_pool_status())
      else
        assigns
      end

    ~H"""
    <div class="min-h-dvh md:flex">
      <%!-- Desktop sidebar (220px, hidden on mobile) --%>
      <.sidebar
        :if={@current_scope}
        current_tab={@current_tab}
        current_scope={@current_scope}
        cost={@cost}
      />

      <%!-- Right column — mobile header + content --%>
      <div class="flex min-h-dvh flex-1 flex-col">
        <%!-- Mobile-only: top nav + cost bar (hidden on desktop where sidebar takes over) --%>
        <div class="md:hidden">
          <.top_nav current_scope={@current_scope} />
          <.cost_bar :if={@current_scope} cost={@cost} />
        </div>

        <main id="main-content" class="main-content flex-1 px-4 pt-4 sm:px-6 sm:pt-6 lg:px-8">
          <div class="mx-auto w-full max-w-4xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <%!-- Mobile bottom tab bar (fixed, hidden on desktop) --%>
      <.bottom_tab_bar :if={@current_scope} current_tab={@current_tab} />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  # ── Desktop sidebar ─────────────────────────────────────────────────────────

  @doc """
  220px left sidebar — desktop-only nav (md+). Hidden on mobile.

  Shows the Tracy logo lockup, primary nav items grouped by section, and a
  sticky footer with a cost card, user identity row, and theme toggle.

  Active item is determined by `current_tab`, which is set automatically by
  `TracyWeb.NavHooks.on_mount/4`.
  """
  attr :current_tab, :atom, required: true
  attr :current_scope, :map, required: true
  attr :cost, :map, default: nil

  def sidebar(assigns) do
    ~H"""
    <nav class="app-sidebar" aria-label="Sidebar navigation" role="navigation">
      <%!-- Logo lockup (64px header) --%>
      <div class="flex h-16 shrink-0 items-center gap-3 border-b border-white/[0.07] px-4">
        <div class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-base-100">
          <span class="text-base font-black text-primary">T</span>
        </div>
        <div class="min-w-0">
          <div class="text-[13px] font-extrabold uppercase tracking-[0.10em] text-base-content">
            Tracy
          </div>
          <div class="text-[8px] uppercase tracking-[0.10em] text-base-content/30">
            Boardroom AI
          </div>
        </div>
      </div>

      <%!-- Nav area (scrollable) --%>
      <div class="flex-1 overflow-y-auto px-3 py-4">
        <%!-- WORKSPACE section --%>
        <p class="mb-2 px-2 text-[8px] font-bold uppercase tracking-[0.12em] text-base-content/30">
          Workspace
        </p>

        <.sidebar_nav_item
          tab={:chat}
          label="Chat"
          icon="hero-chat-bubble-left-solid"
          href="/boardroom"
          current_tab={@current_tab}
        />
        <.sidebar_nav_item
          tab={:projects}
          label="Projects"
          icon="hero-rectangle-stack-solid"
          href="/projects"
          current_tab={@current_tab}
        />
        <.sidebar_nav_item
          tab={:plans}
          label="Plans"
          icon="hero-clipboard-document-list-solid"
          href="/plans"
          current_tab={@current_tab}
        />
        <.sidebar_nav_item
          tab={:memory}
          label="Memory"
          icon="hero-cpu-chip-solid"
          href="/memory"
          current_tab={@current_tab}
        />

        <%!-- Divider --%>
        <div class="my-2 mx-1 border-t border-white/[0.06]"></div>

        <%!-- SYSTEM section --%>
        <p class="mb-2 px-2 text-[8px] font-bold uppercase tracking-[0.12em] text-base-content/30">
          System
        </p>
        <.sidebar_nav_item
          tab={:settings}
          label="Settings"
          icon="hero-cog-6-tooth-solid"
          href="/users/settings"
          current_tab={@current_tab}
        />
      </div>

      <%!-- Footer (pinned to bottom) --%>
      <div class="shrink-0 border-t border-white/[0.07] px-3 py-3 space-y-2">
        <%!-- Cost card --%>
        <.sidebar_cost_card :if={@cost} cost={@cost} />

        <%!-- User identity row --%>
        <div class="flex items-center gap-2 px-1 py-0.5">
          <%!-- Avatar initials circle --%>
          <div class="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary/20">
            <span class="text-[11px] font-bold text-primary">
              {String.upcase(String.first(@current_scope.user.email))}
            </span>
          </div>
          <%!-- Name + email --%>
          <div class="min-w-0 flex-1">
            <p class="truncate text-[11px] font-semibold text-base-content">
              {@current_scope.user.email |> String.split("@") |> List.first()}
            </p>
            <p class="truncate text-[9px] text-base-content/40">{@current_scope.user.email}</p>
          </div>
          <%!-- Log out --%>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="shrink-0 text-base-content/40 transition-colors hover:text-base-content/70"
            aria-label="Log out"
          >
            <.icon name="hero-arrow-right-on-rectangle-mini" class="size-4" />
          </.link>
        </div>

        <%!-- Theme toggle (centred) --%>
        <div class="flex justify-center pt-0.5">
          <.theme_toggle />
        </div>
      </div>
    </nav>
    """
  end

  # Single item inside the desktop sidebar nav area.
  attr :tab, :atom, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true
  attr :current_tab, :atom, required: true

  defp sidebar_nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={["sidebar-nav-item", @tab == @current_tab && "active"]}
      aria-current={@tab == @current_tab && "page"}
    >
      <.icon name={@icon} class="size-[22px] shrink-0" />
      <span class="truncate">{@label}</span>
    </a>
    """
  end

  # Compact cost summary card shown in the sidebar footer.
  attr :cost, :map, required: true

  defp sidebar_cost_card(assigns) do
    # D-4.1: green 0–50%, yellow 50–75%, red ≥75%
    {fill_class, border_class} =
      case assigns.cost.zone do
        :normal   -> {"cost-meter-fill cost-good",   ""}
        :caution  -> {"cost-meter-fill cost-warn",   ""}
        :winddown -> {"cost-meter-fill cost-danger", "border border-error/20"}
        :hardstop -> {"cost-meter-fill cost-danger", "border border-error/30"}
      end

    spent_str = :erlang.float_to_binary(assigns.cost.spent_dollars, decimals: 2)
    cap_int = trunc(assigns.cost.cap_dollars)
    pct_clamped = min(max(assigns.cost.pct, 1.5), 100)

    assigns =
      assigns
      |> assign(:fill_class, fill_class)
      |> assign(:border_class, border_class)
      |> assign(:spent_str, spent_str)
      |> assign(:cap_int, cap_int)
      |> assign(:pct_clamped, pct_clamped)

    ~H"""
    <div class={"mx-1 rounded-lg bg-base-300/70 p-2 space-y-1.5 " <> @border_class}>
      <p class="cost-meter-label">SDK Pool</p>
      <div
        class="cost-meter-track"
        role="progressbar"
        aria-valuenow={trunc(@cost.pct)}
        aria-valuemin="0"
        aria-valuemax="100"
        aria-label={"SDK Pool: #{trunc(@cost.pct)}% of $#{@cap_int}"}
      >
        <div class={@fill_class} style={"width: #{@pct_clamped}%"}></div>
      </div>
      <p class="cost-meter-value">
        $<%= @spent_str %> / $<%= @cap_int %>
        <span class="text-base-content/30">(<%= Float.round(@cost.pct, 1) %>%)</span>
      </p>
    </div>
    """
  end

  # ── Mobile bottom tab bar ────────────────────────────────────────────────────

  @doc """
  Fixed bottom tab bar — mobile-only (< 768px). Hidden on desktop where the
  sidebar provides navigation.

  Renders 4 primary tabs: Plans, Active, Chat, Memory. Active state is driven
  by `current_tab`. Respects iOS safe-area inset so the bar sits above the home
  indicator.
  """
  attr :current_tab, :atom, required: true

  def bottom_tab_bar(assigns) do
    ~H"""
    <nav
      class="bottom-tab-bar"
      aria-label="Bottom navigation"
      role="tablist"
    >
      <.tab_bar_item
        tab={:chat}
        label="Chat"
        icon="hero-chat-bubble-left-solid"
        href="/boardroom"
        current_tab={@current_tab}
      />
      <.tab_bar_item
        tab={:projects}
        label="Projects"
        icon="hero-rectangle-stack-solid"
        href="/projects"
        current_tab={@current_tab}
      />
      <.tab_bar_item
        tab={:memory}
        label="Memory"
        icon="hero-cpu-chip-solid"
        href="/memory"
        current_tab={@current_tab}
      />
    </nav>
    """
  end

  # Single tab in the mobile bottom tab bar.
  attr :tab, :atom, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true
  attr :current_tab, :atom, required: true

  defp tab_bar_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={["tab-item", @tab == @current_tab && "active"]}
      role="tab"
      aria-selected={to_string(@tab == @current_tab)}
      aria-current={@tab == @current_tab && "page"}
    >
      <.icon name={@icon} class="size-[22px]" />
      <span>{@label}</span>
    </a>
    """
  end

  # ── cost_bar — slim secondary bar (mobile / public layout) ──────────────────

  # cost_bar/1 — slim secondary bar below the top nav (sticky, z-20).
  # Shown on mobile; hidden on desktop where the sidebar cost card takes over.
  #
  # Two meters: SDK pool (monthly $100 cap) + Weekly interactive (flat-rate quota).
  # Colors per D-4.1 design brief: green 0–50%, yellow 50–75%, red ≥75%.
  #
  #   • green  — normal  (0–50%)
  #   • yellow — caution (50–75%)
  #   • red    — wind-down (75–85%) + hard-stop (≥85%)
  #
  # Hover/focus triggers a CSS-only tooltip with exact figures.
  # Weekly meter is a placeholder until Phase 2 wires real interactive tracking.

  attr :cost, :map, required: true

  defp cost_bar(assigns) do
    # Design brief §4: green 0–50%, yellow 50–75%, red ≥75%
    {sdk_bar_class, sdk_dot_class, zone_text, zone_text_class} =
      case assigns.cost.zone do
        :normal   -> {"bg-success", "bg-success/60",          nil,         nil}
        :caution  -> {"bg-warning", "bg-warning/80",          nil,         nil}
        :winddown -> {"bg-error",   "bg-error animate-pulse", "wind-down", "text-error"}
        :hardstop -> {"bg-error",   "bg-error animate-pulse", "HARD STOP", "text-error"}
      end

    spent_str = assigns.cost.spent_dollars |> :erlang.float_to_binary(decimals: 2)
    cap_int   = trunc(assigns.cost.cap_dollars)
    pct_now   = min(max(assigns.cost.pct, 1.5), 100)
    pct_label = "#{assigns.cost.pct |> Float.round(1)}%"

    assigns =
      assigns
      |> assign(:sdk_bar_class, sdk_bar_class)
      |> assign(:sdk_dot_class, sdk_dot_class)
      |> assign(:zone_text, zone_text)
      |> assign(:zone_text_class, zone_text_class)
      |> assign(:spent_str, spent_str)
      |> assign(:cap_int, cap_int)
      |> assign(:pct_now, pct_now)
      |> assign(:pct_label, pct_label)

    ~H"""
    <div
      class="sticky top-14 z-20 border-b border-base-300/50 bg-base-200/80 backdrop-blur supports-[backdrop-filter]:bg-base-200/70"
      aria-label="Budget meters"
    >
      <div class="flex h-8 w-full items-center gap-3 px-4">

        <%!-- ── SDK Pool meter ─────────────────────────────────────────────── --%>
        <div class="group relative flex flex-1 items-center gap-2">
          <span class="shrink-0 text-[9px] font-bold uppercase tracking-widest text-base-content/40">
            SDK
          </span>

          <div
            class="h-1.5 flex-1 overflow-hidden rounded-full bg-base-300/70"
            role="progressbar"
            aria-valuenow={trunc(@cost.pct)}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-label={"SDK pool: #{@pct_label} of $#{@cap_int} monthly"}
          >
            <div class={"h-full rounded-full transition-all duration-500 " <> @sdk_bar_class} style={"width: #{@pct_now}%"}></div>
          </div>

          <span class="shrink-0 text-[10px] tabular-nums text-base-content/55">
            $<%= @spent_str %>
          </span>

          <%!-- Tooltip — CSS-only; appears below sticky bar on hover / keyboard focus --%>
          <div class="cost-bar-tooltip" role="tooltip">
            <p class="cost-bar-tooltip-label">SDK Pool</p>
            <p>$<%= @spent_str %> / $<%= @cap_int %> · <%= @pct_label %></p>
            <%= if @zone_text do %>
              <p class={"text-[10px] font-semibold " <> (@zone_text_class || "")}><%= @zone_text %></p>
            <% end %>
            <div class="cost-bar-tooltip-arrow"></div>
          </div>
        </div>

        <%!-- Separator --%>
        <div class="h-3.5 w-px flex-shrink-0 bg-base-300/50"></div>

        <%!-- ── Weekly interactive meter — placeholder until Phase 2 ─────── --%>
        <div class="group relative flex flex-1 items-center gap-2">
          <span class="shrink-0 text-[9px] font-bold uppercase tracking-widest text-base-content/40">
            Wkly
          </span>

          <div
            class="h-1.5 flex-1 overflow-hidden rounded-full bg-base-300/70"
            role="progressbar"
            aria-valuenow="0"
            aria-valuemin="0"
            aria-valuemax="100"
            aria-label="Weekly interactive cap: tracking coming in Phase 2"
          >
            <div class="h-full w-[1.5%] rounded-full bg-success transition-all duration-500"></div>
          </div>

          <span class="shrink-0 text-[10px] tabular-nums text-base-content/55">0%</span>

          <div class="cost-bar-tooltip" role="tooltip">
            <p class="cost-bar-tooltip-label">Weekly Interactive</p>
            <p>0% of quota used</p>
            <p class="text-[10px] text-base-content/40">Tracking lands in Phase 2</p>
            <div class="cost-bar-tooltip-arrow"></div>
          </div>
        </div>

        <%!-- ── Zone badge + status dot ────────────────────────────────────── --%>
        <div class="flex shrink-0 items-center gap-1.5">
          <span
            :if={@zone_text}
            class={"text-[10px] font-semibold uppercase tracking-wider " <> (@zone_text_class || "")}
          >
            {@zone_text}
          </span>
          <span class={"size-2 shrink-0 rounded-full " <> @sdk_dot_class}></span>
        </div>

      </div>
    </div>
    """
  end

  # ── top_nav ─────────────────────────────────────────────────────────────────

  @doc """
  Top navigation — brand left, auth-aware actions right.
  Shown on mobile (and on public pages); hidden on desktop where the sidebar
  provides the logo, nav, and user identity.
  """
  attr :current_scope, :map, default: nil

  def top_nav(assigns) do
    ~H"""
    <header class="sticky top-0 z-30 border-b border-base-300/60 bg-base-100/80 backdrop-blur supports-[backdrop-filter]:bg-base-100/70">
      <div class="mx-auto flex h-14 w-full max-w-6xl items-center gap-3 px-4 sm:h-16 sm:px-6 lg:px-8">
        <.link navigate={~p"/"} class="flex items-center gap-2 text-primary hover:text-primary/80 transition-colors">
          <img src={~p"/images/logo.svg"} alt="Tracy" class="size-8 sm:size-9" />
          <span class="text-base font-semibold tracking-tight text-base-content sm:text-lg">tracy</span>
        </.link>

        <span class="hidden text-xs text-base-content/40 sm:inline">· personal ai dev orchestrator</span>

        <div class="ml-auto flex items-center gap-1 sm:gap-2">
          <%= if @current_scope do %>
            <.link navigate={~p"/boardroom"} class="btn btn-ghost btn-sm hidden sm:inline-flex">
              <.icon name="hero-chat-bubble-left-right-mini" class="size-4" /> Boardroom
            </.link>
            <.link navigate={~p"/plans"} class="btn btn-ghost btn-sm hidden sm:inline-flex">
              <.icon name="hero-squares-2x2-mini" class="size-4" /> Plans
            </.link>
            <.link navigate={~p"/users/settings"} class="btn btn-ghost btn-sm hidden sm:inline-flex">
              <.icon name="hero-cog-6-tooth-mini" class="size-4" /> Settings
            </.link>
            <span class="hidden text-xs text-base-content/60 md:inline">{@current_scope.user.email}</span>
            <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-right-on-rectangle-mini" class="size-4" />
              <span class="hidden sm:inline">Log out</span>
            </.link>
          <% else %>
            <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
            <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">
              Register
            </.link>
          <% end %>
          <.theme_toggle />
        </div>
      </div>
    </header>
    """
  end

  @doc """
  Public marketing layout — used by the unauthenticated home page.
  No sidebar or bottom tabs; cleaner than `app` but still web-themed.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <.top_nav current_scope={@current_scope} />
      <main id="main-content" class="flex-1">
        {render_slot(@inner_block)}
      </main>
      <footer class="border-t border-base-300/40 px-4 py-6 text-xs text-base-content/50 sm:px-6 lg:px-8">
        <div class="mx-auto flex w-full max-w-6xl flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
          <span>tracy · personal AI dev orchestrator</span>
          <span class="text-base-content/30">Built on Phoenix · home-grown · spider-friendly</span>
        </div>
      </footer>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Theme toggle — cycles tracy (dark default) and tracy-light.
  Uses data-theme on <html>, set via phx:set-theme event from layout script.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border border-base-300 bg-base-300 rounded-full">
      <button
        class="flex size-7 cursor-pointer items-center justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="tracy"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-3.5 opacity-70 hover:opacity-100" />
      </button>
      <button
        class="flex size-7 cursor-pointer items-center justify-center"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="tracy-light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-3.5 opacity-70 hover:opacity-100" />
      </button>
    </div>
    """
  end
end

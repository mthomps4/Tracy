defmodule TracyWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality used by the application.
  """
  use TracyWeb, :html

  embed_templates "layouts/*"

  @doc """
  Tracy's main app layout: brand-aware top bar (desktop/tablet) + bottom tab bar (mobile).
  Authenticated state drives nav items; logged-out shows public marketing nav.

  ## Examples

      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :page_title, :string, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <.top_nav current_scope={@current_scope} />

      <main class="flex-1 px-4 pt-6 pb-24 sm:px-6 sm:pb-10 lg:px-8">
        <div class="mx-auto w-full max-w-6xl">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.bottom_tabs :if={@current_scope} current_scope={@current_scope} />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Top navigation — brand left, auth-aware actions right.
  Hides the auth links on mobile when the bottom tab bar is showing.
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
              <.icon name="hero-squares-2x2-mini" class="size-4" /> Boardroom
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
  Bottom tab bar — mobile-only when logged in. Hidden on sm+ where the top nav covers it.
  Respects iOS safe-area inset so it sits above the home indicator.
  """
  attr :current_scope, :map, required: true

  def bottom_tabs(assigns) do
    ~H"""
    <nav
      class="fixed inset-x-0 bottom-0 z-30 border-t border-base-300/60 bg-base-100/95 backdrop-blur pb-[env(safe-area-inset-bottom)] sm:hidden"
      aria-label="Primary"
    >
      <ul class="mx-auto grid max-w-md grid-cols-4 px-2 pt-1">
        <.tab_link to={~p"/boardroom"} icon="hero-squares-2x2" label="Plans" />
        <.tab_link to={~p"/boardroom"} icon="hero-bolt" label="Active" />
        <.tab_link to={~p"/boardroom"} icon="hero-chat-bubble-left-right" label="Chat" />
        <.tab_link to={~p"/users/settings"} icon="hero-cog-6-tooth" label="Settings" />
      </ul>
    </nav>
    """
  end

  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp tab_link(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@to}
        class="flex h-14 flex-col items-center justify-center gap-0.5 text-base-content/70 hover:text-primary"
      >
        <.icon name={@icon} class="size-5" />
        <span class="text-[10px] font-medium uppercase tracking-wider">{@label}</span>
      </.link>
    </li>
    """
  end

  @doc """
  Public marketing layout — used by the unauthenticated home page.
  No bottom tabs; cleaner than `app` but still web-themed.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  slot :inner_block, required: true

  def public(assigns) do
    ~H"""
    <div class="flex min-h-dvh flex-col">
      <.top_nav current_scope={@current_scope} />
      <main class="flex-1">
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

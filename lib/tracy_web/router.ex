defmodule TracyWeb.Router do
  use TracyWeb, :router

  import TracyWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TracyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TracyWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", TracyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:tracy, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TracyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TracyWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", TracyWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :authenticated,
      on_mount: [
        {TracyWeb.UserAuth, :require_authenticated},
        {TracyWeb.NavHooks, :set_current_tab}
      ] do
      live "/boardroom", BoardroomLive
      # V2 oversight dashboard — single-page grid of project cards.
      live "/projects",     ProjectsLive
      live "/memory",       MemoryLive
      # Master/detail plans surface — same LiveView handles list (:index) and
      # selected-plan preview (:show) via push_patch navigation.
      live "/plans",        PlanLive.Index, :index
      live "/plans/:id",    PlanLive.Index, :show
      # Full task-management detail page (PlanLive.Show).
      # Linked from the detail preview's "Open full detail" CTA.
      live "/plans/:id/detail", PlanLive.Show
      live "/plans/:plan_id/tasks/:id", TaskLive.Show
    end

    get "/assets/:id/download", AssetController, :download

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
  end

  scope "/", TracyWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end

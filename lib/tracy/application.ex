defmodule Tracy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TracyWeb.Telemetry,
      Tracy.Repo,
      {DNSCluster, query: Application.get_env(:tracy, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tracy.PubSub},
      # Session machinery — Registry locates Tracy.Session.Server processes by id;
      # DynamicSupervisor owns their lifecycle.
      {Registry, keys: :unique, name: Tracy.Session.Registry},
      Tracy.Session.Supervisor,
      # Workers — DynamicSupervisor for per-task worker GenServers
      Tracy.Workers.Supervisor,
      # Local embedder. Lazy-loads the Nomic model on first request, so
      # boot is fast even though the warm model lives here.
      Tracy.Memory.Embeddings.Nomic,
      TracyWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tracy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TracyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

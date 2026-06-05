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
      # Start a worker by calling: Tracy.Worker.start_link(arg)
      # {Tracy.Worker, arg},
      # Start to serve requests, typically the last entry
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

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

    opts = [strategy: :one_for_one, name: Tracy.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Kick off the embedder pre-warm in the background. Boot is unblocked;
    # the model load happens in a separate Task and logs success/failure.
    # The first Boardroom chat after boot will be fast instead of paying
    # the ~5-30s model-load tax.
    #
    # Skipped in :test (the Stub adapter never needs the model) and when
    # explicitly disabled via config.
    maybe_warm_embedder()

    result
  end

  defp maybe_warm_embedder do
    if Application.get_env(:tracy, :prewarm_embedder, true) and
         Application.get_env(:tracy, Tracy.Memory.Embeddings, [])
         |> Keyword.get(:provider) == Tracy.Memory.Embeddings.Nomic do
      Tracy.Memory.Embeddings.Nomic.warm_async()
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TracyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

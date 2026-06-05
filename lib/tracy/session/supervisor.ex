defmodule Tracy.Session.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Tracy.Session.Server` processes.

  Sessions start on demand via `Tracy.Session.start/1` and exit on idle
  timeout (transient restart strategy so a clean shutdown doesn't respawn).
  """
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_child(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Tracy.Session.Server, opts})
  end
end

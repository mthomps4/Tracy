defmodule Tracy.Workers.Supervisor do
  @moduledoc """
  DynamicSupervisor for `Tracy.Workers.Server` processes.

  One child per running worker. Children are :transient — once a worker
  completes (or fails), the GenServer stops with :normal and the
  supervisor doesn't restart it.
  """
  use DynamicSupervisor

  def start_link(_), do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_child(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Tracy.Workers.Server, opts})
  end
end

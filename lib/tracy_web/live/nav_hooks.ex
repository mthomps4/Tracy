defmodule TracyWeb.NavHooks do
  @moduledoc """
  LiveView on_mount hooks for navigation assigns.

  Infers `current_tab` from the LiveView module so every authenticated
  LiveView automatically gets a `@current_tab` assign without having to
  set it in each individual `mount/3`.

  Add to a `live_session` on_mount list:

      live_session :authenticated,
        on_mount: [
          {TracyWeb.UserAuth, :require_authenticated},
          {TracyWeb.NavHooks, :set_current_tab}
        ] do
        ...
      end
  """

  import Phoenix.Component, only: [assign: 2]

  @doc false
  def on_mount(:set_current_tab, _params, _session, socket) do
    {:cont, assign(socket, current_tab: tab_for_view(socket.view))}
  end

  # Maps LiveView modules → primary nav tab atom.
  defp tab_for_view(TracyWeb.BoardroomLive), do: :chat
  defp tab_for_view(TracyWeb.PlansLive), do: :plans
  defp tab_for_view(TracyWeb.PlanLive.Index), do: :plans
  defp tab_for_view(TracyWeb.PlanLive.Show), do: :plans
  defp tab_for_view(TracyWeb.TaskLive.Show), do: :plans
  defp tab_for_view(TracyWeb.ProjectsLive), do: :projects
  defp tab_for_view(TracyWeb.MemoryLive), do: :memory
  defp tab_for_view(_), do: :plans
end

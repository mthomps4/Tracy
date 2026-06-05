defmodule Tracy.SessionTest do
  use Tracy.DataCase

  alias Tracy.LLM.Message
  alias Tracy.Session

  # Sandbox + supervisor children both touch the DB, so async: false.
  # We start a fresh session per test and stop it explicitly.

  setup do
    {:ok, id} = Session.start()
    on_exit(fn ->
      case Registry.lookup(Tracy.Session.Registry, id) do
        [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid)
        [] -> :ok
      end
    end)

    %{id: id}
  end

  describe "start/1 and alive?/1" do
    test "session is alive after start", %{id: id} do
      assert Session.alive?(id)
    end

    test "start/1 with same id is idempotent" do
      id = Ecto.UUID.generate()
      assert {:ok, ^id} = Session.start(id: id)
      assert {:ok, ^id} = Session.start(id: id)
    end
  end

  describe "send_message/2" do
    test "appends user + assistant messages to history", %{id: id} do
      assert {:ok, response} = Session.send_message(id, "hello tracy")
      assert %Message{role: :assistant} = response.message

      msgs = Session.messages(id)
      assert length(msgs) == 2
      assert [%Message{role: :user, content: "hello tracy"}, %Message{role: :assistant}] = msgs
    end

    test "records episodes for user + assistant", %{id: id} do
      Session.send_message(id, "for the episodes")

      bodies =
        Tracy.Memory.recent_episodes(limit: 10)
        |> Enum.map(& &1.body)

      assert "for the episodes" in bodies
      assert Enum.any?(bodies, &String.contains?(&1, "for the episodes"))
    end

    test "records a billing AgentRun for the call", %{id: id} do
      Session.send_message(id, "billing check")
      [run | _] = Tracy.Billing.recent_runs(limit: 1)
      assert run.session_id == id
      assert run.role == "main"
    end
  end

  describe "stream_message/2 + subscribe/1" do
    test "broadcasts chunks then a :done event", %{id: id} do
      :ok = Session.subscribe(id)
      :ok = Session.stream_message(id, "stream me. with sentences.")

      assert_receive {:session_event, ^id, {:chunk, _chunk}}, 1_000
      assert_receive {:session_event, ^id, {:done, response}}, 1_000

      assert response.message.role == :assistant
    end

    test "the streamed assistant message is in history after :done", %{id: id} do
      :ok = Session.subscribe(id)
      :ok = Session.stream_message(id, "history please")

      assert_receive {:session_event, ^id, {:done, _response}}, 1_000

      # Give the GenServer a tick to process the :stream_done message.
      :sys.get_state(via_pid(id))

      msgs = Session.messages(id)
      assert length(msgs) == 2
      assert [%Message{role: :user}, %Message{role: :assistant}] = msgs
    end
  end

  describe "switch_project/2" do
    test "scopes subsequent episodes to the new project", %{id: id} do
      :ok = Session.switch_project(id, "falcon")
      Session.send_message(id, "scoped to falcon")

      [latest | _] =
        Tracy.Memory.recent_episodes(limit: 5)
        |> Enum.filter(& &1.project == "falcon")

      assert latest.project == "falcon"
    end
  end

  defp via_pid(id) do
    [{pid, _}] = Registry.lookup(Tracy.Session.Registry, id)
    pid
  end
end

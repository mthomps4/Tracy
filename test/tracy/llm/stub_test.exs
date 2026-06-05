defmodule Tracy.LLM.StubTest do
  use Tracy.DataCase, async: true

  alias Tracy.LLM
  alias Tracy.LLM.{Message, Stub}

  describe "chat/2" do
    test "returns a stub reply echoing the user message" do
      msgs = [Message.user("hello tracy")]
      assert {:ok, response} = Stub.chat(msgs, [])

      assert response.message.role == :assistant
      assert response.message.content =~ "hello tracy"
      assert response.model == "stub"
      assert response.usage.input_tokens > 0
      assert response.usage.output_tokens > 0
    end

    test "handles a system + user pair (uses last user)" do
      msgs = [
        Message.system("you are tracy"),
        Message.user("the streaming bug is still active")
      ]

      assert {:ok, response} = Stub.chat(msgs, [])
      assert response.message.content =~ "streaming bug"
    end

    test "records an AgentRun in the cost ledger" do
      Stub.chat([Message.user("ping")], session_id: Ecto.UUID.generate(), role: "main")
      [run | _] = Tracy.Billing.recent_runs(limit: 1)

      assert run.role == "main"
      assert run.provider == "stub"
      assert run.bucket in ["interactive", "sdk_pool"]
      assert run.duration_ms != nil
    end
  end

  describe "stream_chat/3" do
    test "emits chunks then a :done event" do
      ref = make_ref()
      pid = self()

      callback = fn event -> send(pid, {ref, event}) end

      assert {:ok, _response} =
               Stub.stream_chat(
                 [Message.user("stream me a sentence. and another.")],
                 [],
                 callback
               )

      # collect all events
      events = collect_events(ref, [])

      chunk_events = Enum.filter(events, &match?({:chunk, _}, &1))
      done_events = Enum.filter(events, &match?({:done, _}, &1))

      assert length(chunk_events) >= 1
      assert length(done_events) == 1

      [{:done, response}] = done_events
      assert response.message.role == :assistant
    end
  end

  describe "the public Tracy.LLM facade" do
    test "Tracy.LLM.chat routes to the configured adapter (Stub by default)" do
      assert LLM.adapter() == Stub
      assert {:ok, response} = LLM.chat([Message.user("via facade")])
      assert response.message.content =~ "via facade"
    end

    test "Tracy.LLM.stream_chat works with adapters that lack stream support" do
      defmodule NoStreamAdapter do
        @behaviour Tracy.LLM
        @impl true
        def chat(msgs, _opts) do
          last = Enum.find_value(Enum.reverse(msgs), fn
            %Message{role: :user, content: c} -> c
            _ -> nil
          end)

          {:ok,
           %{
             message: Message.assistant("no-stream reply for: #{last}"),
             usage: %{input_tokens: 1, output_tokens: 1, cache_read_tokens: 0, cache_creation_tokens: 0},
             model: "nostream",
             cost_micros: 0,
             bucket: :interactive
           }}
        end
      end

      original = Application.get_env(:tracy, Tracy.LLM)
      Application.put_env(:tracy, Tracy.LLM, Keyword.put(original, :adapter, NoStreamAdapter))

      try do
        pid = self()
        ref = make_ref()

        callback = fn event -> send(pid, {ref, event}) end

        assert {:ok, _} = LLM.stream_chat([Message.user("ping")], [], callback)

        # Confirm we received both a chunk and a done event
        assert_receive {^ref, {:chunk, _}}
        assert_receive {^ref, {:done, _}}
      after
        Application.put_env(:tracy, Tracy.LLM, original)
      end
    end
  end

  defp collect_events(ref, acc) do
    receive do
      {^ref, event} -> collect_events(ref, [event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end

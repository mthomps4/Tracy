defmodule Tracy.WorkersTest do
  use Tracy.DataCase

  alias Tracy.{Plans, Workers}
  alias Tracy.Workers.Stub

  describe "dispatch/2 with Stub" do
    test "transitions task to in_progress, then done, with report" do
      {:ok, plan} = Plans.create_plan(%{title: "carrier"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "do thing", role: "engineer"})

      Workers.subscribe(task.id)
      assert {:ok, _pid} = Workers.dispatch(task, adapter: Stub, adapter_opts: [delay_ms: 10])

      assert_receive {:worker_event, _, {:worker_started, started}}, 1_000
      assert started.status == "in_progress"
      assert started.assigned_at != nil

      assert_receive {:worker_event, _, {:worker_completed, completed, _report}}, 2_000
      assert completed.status == "done"
      assert completed.completed_at != nil
      assert is_map(completed.report)
      assert Map.get(completed.report, "summary") =~ "stub"
    end

    test "missing task returns error" do
      missing_id = Ecto.UUID.generate()
      assert {:error, :not_found} = Workers.dispatch(missing_id)
    end
  end

  describe "failure path" do
    defmodule RaisingAdapter do
      @behaviour Tracy.Workers.Adapter
      @impl true
      def execute(_task, _opts), do: raise("boom")
    end

    test "task transitions to blocked with failure metadata" do
      {:ok, plan} = Plans.create_plan(%{title: "fail"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "this raises", role: "engineer"})

      Workers.subscribe(task.id)

      assert {:ok, _pid} = Workers.dispatch(task, adapter: RaisingAdapter)

      assert_receive {:worker_event, _, {:worker_failed, blocked, _reason}}, 2_000
      assert blocked.status == "blocked"
      assert get_in(blocked.metadata, ["last_failure", "reason"]) =~ "boom"
    end
  end

  describe "adapter_for_role/1" do
    test "falls back to default_adapter when role has no override" do
      Application.put_env(:tracy, Workers,
        default_adapter: Tracy.Workers.Stub,
        per_role: %{"reviewer" => SomeOtherAdapter}
      )

      assert Workers.adapter_for_role("engineer") == Tracy.Workers.Stub
      assert Workers.adapter_for_role("reviewer") == SomeOtherAdapter
    after
      Application.delete_env(:tracy, Workers)
    end
  end
end

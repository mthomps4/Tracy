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

      assert_receive {:worker_event, _, {:worker_failed, failed, _reason}}, 2_000
      assert failed.status == "failed"
      assert get_in(failed.metadata, ["last_failure", "reason"]) =~ "boom"
    end
  end

  describe "spawned_tasks in report" do
    test "PM stub task auto-creates designer + researcher tasks on the plan" do
      {:ok, plan} = Plans.create_plan(%{title: "designer carrier"})

      {:ok, pm_task} =
        Plans.create_task(%{
          plan_id: plan.id,
          title: "break this brief into designer tasks",
          role: "pm"
        })

      Workers.subscribe(pm_task.id)

      assert {:ok, _pid} =
               Workers.dispatch(pm_task, adapter: Stub, adapter_opts: [delay_ms: 5])

      assert_receive {:worker_event, _, {:worker_completed, _completed, _report}}, 2_000
      assert_receive {:worker_event, _, {:worker_spawned_tasks, new_tasks}}, 500

      assert length(new_tasks) == 2
      roles = Enum.map(new_tasks, & &1.role) |> Enum.sort()
      assert roles == ["designer", "researcher"]

      # And they show up in the plan
      loaded_plan = Plans.get_plan!(plan.id)
      task_titles = Enum.map(loaded_plan.tasks, & &1.title)
      assert Enum.any?(task_titles, &String.contains?(&1, "Sketch"))
      assert Enum.any?(task_titles, &String.contains?(&1, "Gather"))
    end

    test "engineer stub does NOT spawn tasks (only PM-like roles do)" do
      {:ok, plan} = Plans.create_plan(%{title: "engineer carrier"})

      {:ok, eng_task} =
        Plans.create_task(%{
          plan_id: plan.id,
          title: "do thing",
          role: "engineer"
        })

      Workers.subscribe(eng_task.id)

      assert {:ok, _pid} =
               Workers.dispatch(eng_task, adapter: Stub, adapter_opts: [delay_ms: 5])

      assert_receive {:worker_event, _, {:worker_completed, _, _}}, 2_000
      refute_received {:worker_event, _, {:worker_spawned_tasks, _}}

      loaded = Plans.get_plan!(plan.id)
      # Only the original engineer task
      assert length(loaded.tasks) == 1
    end
  end

  describe "progress events + transcript" do
    test "Stub emits assistant_text + tool_use + tool_result events", %{} do
      {:ok, plan} = Plans.create_plan(%{title: "carrier"})
      {:ok, task} = Plans.create_task(%{plan_id: plan.id, title: "watch me", role: "engineer"})
      Workers.subscribe(task.id)

      assert {:ok, _pid} =
               Workers.dispatch(task, adapter: Stub, adapter_opts: [delay_ms: 20])

      assert_receive {:worker_event, _, {:worker_progress, %{kind: :assistant_text, text: text}}}, 1_000
      assert text =~ "watch me"

      assert_receive {:worker_event, _, {:worker_progress, %{kind: :tool_use, tool_name: "Stub"}}}, 1_000
      assert_receive {:worker_event, _, {:worker_progress, %{kind: :tool_result, is_error: false}}}, 1_000
      assert_receive {:worker_event, _, {:worker_completed, _, _}}, 2_000
    end
  end

  describe "cancel/1" do
    test "brutal-kills the running adapter and transitions task to canceled" do
      {:ok, plan} = Plans.create_plan(%{title: "cancelable"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "long running", role: "engineer"})

      Workers.subscribe(task.id)

      # 5s delay — plenty of time to cancel.
      assert {:ok, _pid} =
               Workers.dispatch(task, adapter: Stub, adapter_opts: [delay_ms: 5_000])

      assert_receive {:worker_event, _, {:worker_started, _}}, 1_000

      assert :ok = Workers.cancel(task.id)

      assert_receive {:worker_event, _, {:worker_canceled, canceled}}, 1_000
      assert canceled.status == "canceled"
    end

    test "returns {:error, :not_running} when no worker is alive" do
      assert {:error, :not_running} = Workers.cancel(Ecto.UUID.generate())
    end
  end

  describe "transcript/1" do
    test "returns buffered events while the worker is running" do
      {:ok, plan} = Plans.create_plan(%{title: "transcripted"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "show me", role: "engineer"})

      Workers.subscribe(task.id)

      assert {:ok, _pid} =
               Workers.dispatch(task, adapter: Stub, adapter_opts: [delay_ms: 200])

      # Wait until at least one progress event has fired.
      assert_receive {:worker_event, _, {:worker_progress, _}}, 1_000

      assert {:ok, events} = Workers.transcript(task.id)
      assert is_list(events)
      assert Enum.any?(events, &(&1.kind == :assistant_text))
    end

    test "returns :not_running after the worker has completed" do
      {:ok, plan} = Plans.create_plan(%{title: "done already"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "fast", role: "engineer"})

      Workers.subscribe(task.id)
      assert {:ok, _pid} = Workers.dispatch(task, adapter: Stub, adapter_opts: [delay_ms: 5])
      assert_receive {:worker_event, _, {:worker_completed, _, _}}, 2_000

      # GenServer has stopped — transcript fetch should report not_running.
      # Slight delay so the DynamicSupervisor's child-list catches up with
      # the :normal exit.
      Process.sleep(50)
      assert {:error, :not_running} = Workers.transcript(task.id)
    end
  end

  describe "auto-dispatch fan-out (chains)" do
    # TODO: integration test for the full A→B auto-dispatch path is gated
    # on figuring out the right sandbox.allow call for the dynamically-
    # supervised Worker.Server children. The chain *logic* is covered:
    #
    #   - Plans.task_ready?/1 + Plans.tasks_ready_after/1 (plans_test.exs)
    #   - Plans.approve_task/1 (CEO stamp) is what fan-out filters on
    #   - Workers.Server fan-out scan is invoked on :worker_completed
    #     and rescued so a sandbox failure doesn't crash the parent
    #
    # Manual verification path: create two tasks with the second's
    # blocked_by pointing at the first, Approve the second (CEO stamp),
    # then Dispatch the first. Watch the second's Live tab fill in as
    # soon as A's report lands.
    @tag :skip
    test "completing a task fires its approved downstream (integration)" do
      flunk("see TODO above — chain logic covered unit-wise; manual verify the wire")
    end

    test "tasks_ready_after returns the right downstream after a completion (no GenServer)" do
      # Pure context-level coverage. Workers.Server invokes this same
      # helper on completion — verifying the helper here proves the
      # fan-out selects the correct tasks; the actual `Workers.dispatch`
      # call on each is exercised by the manual integration path.
      {:ok, plan} = Plans.create_plan(%{title: "ctx chain"})
      {:ok, a} = Plans.create_task(%{plan_id: plan.id, title: "A", role: "engineer"})

      {:ok, b} =
        Plans.create_task(%{
          plan_id: plan.id,
          title: "B",
          role: "engineer",
          blocked_by: [a.id]
        })

      # CEO stamp on B so the fan-out includes it
      {:ok, _approved_b} = Plans.approve_task(b)

      # Before A completes, no downstream is "ready"
      assert Plans.tasks_ready_after(a.id) == []

      {:ok, _} = Plans.transition_task(a, "done")

      ready = Plans.tasks_ready_after(a.id)
      assert Enum.map(ready, & &1.id) == [b.id]
      assert Enum.all?(ready, &(&1.status == "approved"))
    end
  end

  describe "budget gate" do
    setup do
      # Save and restore the test config — the gate is config-driven via
      # Billing.sdk_pool_status, which reads from billing_ledger rows.
      # We simulate by inserting a single high-cost AgentRun.
      :ok
    end

    test "manual dispatch above 85% returns {:error, :budget_paused} and marks task paused" do
      pump_spend_to_pct(90)

      {:ok, plan} = Plans.create_plan(%{title: "budget"})
      {:ok, task} = Plans.create_task(%{plan_id: plan.id, title: "should pause", role: "engineer"})

      assert {:error, {:budget_paused, status}} =
               Workers.dispatch(task, initiated_by: :user)

      assert status.pct >= 85
      reloaded = Plans.get_task!(task.id)
      assert reloaded.status == "paused"
      assert get_in(reloaded.metadata, ["budget_state", "initiated_by"]) == "user"
    end

    test "budget_decision in the 75-85% band: auto pauses, user proceeds" do
      pump_spend_to_pct(80)

      assert {:pause, status} = Workers.budget_decision(:auto, false)
      assert status.pct >= 75 and status.pct < 85

      assert {:ok, _} = Workers.budget_decision(:user, false)
    end

    test "budget_decision above 85%: both pause unless forced" do
      pump_spend_to_pct(90)

      assert {:pause, _} = Workers.budget_decision(:auto, false)
      assert {:pause, _} = Workers.budget_decision(:user, false)

      # :force bypasses the hardstop
      assert {:ok, status} = Workers.budget_decision(:user, true)
      assert status.pct >= 85
    end

    # Push the SDK-pool spend to the target percentage by inserting a
    # single AgentRun whose cost lands us there. Sandbox-isolated so
    # this doesn't leak between tests.
    defp pump_spend_to_pct(target_pct) do
      pool = Tracy.Billing.sdk_pool_status()
      target_micros = ceil(pool.cap_micros * target_pct / 100)

      {:ok, _} =
        Tracy.Billing.record_run(%{
          role: "main",
          provider: "stub",
          model: "stub",
          bucket: "sdk_pool",
          cost_micros: target_micros,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      :ok
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

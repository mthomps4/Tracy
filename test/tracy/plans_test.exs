defmodule Tracy.PlansTest do
  use Tracy.DataCase, async: true

  alias Tracy.Plans
  alias Tracy.Plans.{Plan, Task}

  describe "create_plan/1" do
    test "creates a plan in triage by default" do
      assert {:ok, %Plan{} = plan} =
               Plans.create_plan(%{title: "Fix Falcon streaming bug"})

      assert plan.status == "triage"
      assert plan.approved_at == nil
      assert plan.scope == %{}
    end

    test "rejects an invalid status" do
      assert {:error, cs} =
               Plans.create_plan(%{title: "bad status", status: "made-up"})

      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "requires a title" do
      assert {:error, cs} = Plans.create_plan(%{})
      assert %{title: ["can't be blank"]} = errors_on(cs)
    end
  end

  describe "transition_plan/3" do
    setup do
      user = Tracy.AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "leaving triage sets approved_at and approved_by_id", %{user: user} do
      {:ok, plan} = Plans.create_plan(%{title: "approve me"})
      assert plan.approved_at == nil

      assert {:ok, transitioned} =
               Plans.transition_plan(plan, "backlog", approved_by_id: user.id)

      assert transitioned.status == "backlog"
      assert transitioned.approved_at != nil
      assert transitioned.approved_by_id == user.id
    end

    test "subsequent transitions don't re-stamp approved_at", %{user: user} do
      {:ok, plan} = Plans.create_plan(%{title: "stable approval"})
      {:ok, p1} = Plans.transition_plan(plan, "backlog", approved_by_id: user.id)
      original_approved = p1.approved_at

      Process.sleep(10)
      {:ok, p2} = Plans.transition_plan(p1, "in_progress")

      assert p2.status == "in_progress"
      assert p2.approved_at == original_approved
    end

    test "rejects an invalid status" do
      {:ok, plan} = Plans.create_plan(%{title: "bad"})

      assert {:error, cs} = Plans.transition_plan(plan, "exploded")
      assert %{status: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "list_plans_by_status/1" do
    test "groups plans into all status buckets, even empty ones" do
      {:ok, _t} = Plans.create_plan(%{title: "in triage"})
      {:ok, b} = Plans.create_plan(%{title: "in backlog"})
      {:ok, _b2} = Plans.transition_plan(b, "backlog")

      grouped = Plans.list_plans_by_status()

      assert Map.keys(grouped) |> Enum.sort() == Enum.sort(Plan.statuses())
      assert length(grouped["triage"]) == 1
      assert length(grouped["backlog"]) == 1
      assert grouped["done"] == []
    end

    test "filters by project" do
      {:ok, _} = Plans.create_plan(%{title: "falcon plan", project: "falcon"})
      {:ok, _} = Plans.create_plan(%{title: "tracy plan", project: "tracy"})

      assert Plans.list_plans_by_status(project: "falcon")
             |> Map.values()
             |> List.flatten()
             |> Enum.all?(&(&1.project == "falcon"))
    end

    test "include_terminal: false hides done + canceled" do
      {:ok, p} = Plans.create_plan(%{title: "will be done"})
      {:ok, _} = Plans.transition_plan(p, "done")
      {:ok, q} = Plans.create_plan(%{title: "will be canceled"})
      {:ok, _} = Plans.transition_plan(q, "canceled")
      {:ok, _} = Plans.create_plan(%{title: "still triaging"})

      grouped = Plans.list_plans_by_status(include_terminal: false)
      assert grouped["done"] == []
      assert grouped["canceled"] == []
      assert length(grouped["triage"]) == 1
    end
  end

  describe "tasks under a plan" do
    setup do
      {:ok, plan} = Plans.create_plan(%{title: "plan with tasks"})
      %{plan: plan}
    end

    test "create_task/1 links to a plan", %{plan: plan} do
      assert {:ok, %Task{} = task} =
               Plans.create_task(%{
                 plan_id: plan.id,
                 title: "investigate",
                 role: "researcher"
               })

      assert task.plan_id == plan.id
      assert task.status == "backlog"
      assert task.role == "researcher"
    end

    test "transition_task sets assigned_at when entering in_progress", %{plan: plan} do
      {:ok, t} = Plans.create_task(%{plan_id: plan.id, title: "do thing", role: "engineer"})
      assert t.assigned_at == nil

      {:ok, started} = Plans.transition_task(t, "in_progress")
      assert started.status == "in_progress"
      assert started.assigned_at != nil
    end

    test "transition_task stamps completed_at + duration_ms on done", %{plan: plan} do
      {:ok, t} = Plans.create_task(%{plan_id: plan.id, title: "finish", role: "engineer"})
      {:ok, started} = Plans.transition_task(t, "in_progress")
      Process.sleep(15)

      {:ok, completed} = Plans.transition_task(started, "done")
      assert completed.status == "done"
      assert completed.completed_at != nil
      assert completed.duration_ms > 0
    end

    test "complete_task records a report and marks done", %{plan: plan} do
      {:ok, t} = Plans.create_task(%{plan_id: plan.id, title: "report", role: "engineer"})
      report = %{"summary" => "fixed it", "files_changed" => ["a.ex"]}

      assert {:ok, finished} = Plans.complete_task(t, report, cost_micros: 5_000)
      assert finished.status == "done"
      assert finished.report == report
      assert finished.cost_micros == 5_000
    end

    test "tasks are preloaded onto plans via get_plan!", %{plan: plan} do
      {:ok, _} = Plans.create_task(%{plan_id: plan.id, title: "one", role: "engineer", position: 0})
      {:ok, _} = Plans.create_task(%{plan_id: plan.id, title: "two", role: "researcher", position: 1})

      loaded = Plans.get_plan!(plan.id)
      assert length(loaded.tasks) == 2
      assert Enum.map(loaded.tasks, & &1.title) == ["one", "two"]
    end
  end

  describe "status_counts/1" do
    test "returns a map of status → count" do
      Plans.create_plan(%{title: "a"})
      Plans.create_plan(%{title: "b"})

      {:ok, c} = Plans.create_plan(%{title: "c"})
      Plans.transition_plan(c, "backlog")

      counts = Plans.status_counts()
      assert counts["triage"] == 2
      assert counts["backlog"] == 1
    end
  end

  describe "workspace_path/1" do
    setup do
      tmp_root = Path.join(System.tmp_dir!(), "tracy-workspace-test-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:tracy, :workspace_root)
      Application.put_env(:tracy, :workspace_root, tmp_root)

      on_exit(fn ->
        if prev, do: Application.put_env(:tracy, :workspace_root, prev), else: Application.delete_env(:tracy, :workspace_root)
        File.rm_rf!(tmp_root)
      end)

      %{tmp_root: tmp_root}
    end

    test "returns an absolute path under workspace_root/plans/<id> and creates it", %{tmp_root: tmp_root} do
      {:ok, plan} = Plans.create_plan(%{title: "workspace plan"})
      path = Plans.workspace_path(plan)

      assert path == Path.join([Path.expand(tmp_root), "plans", plan.id])
      assert File.dir?(path)
    end

    test "accepts a bare plan id string", %{tmp_root: _tmp_root} do
      id = Ecto.UUID.generate()
      assert path = Plans.workspace_path(id)
      assert String.ends_with?(path, "plans/#{id}")
      assert File.dir?(path)
    end

    test "is idempotent on repeat calls", %{tmp_root: _tmp_root} do
      id = Ecto.UUID.generate()
      assert Plans.workspace_path(id) == Plans.workspace_path(id)
    end
  end
end

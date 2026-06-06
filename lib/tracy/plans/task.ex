defmodule Tracy.Plans.Task do
  @moduledoc """
  A single worker-runnable unit within a Plan.

  Each task names a role (engineer / researcher / pm / reviewer / etc.) and a
  brief describing what that role should do. Tasks share the Plan status
  taxonomy and accumulate a structured `report` map (worker's findings,
  files touched, blockers, proposed next steps) on completion.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tracy.Billing.AgentRun
  alias Tracy.Plans.Plan

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(engineer designer researcher pm reviewer note_taker operator scout)
  @statuses ~w(triage backlog in_progress in_review needs_input blocked failed paused done canceled)

  def roles, do: @roles
  def statuses, do: @statuses

  schema "tasks" do
    field :title, :string
    field :brief, :string
    field :role, :string, default: "engineer"
    field :status, :string, default: "backlog"
    field :position, :integer, default: 0

    field :assigned_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :cost_micros, :integer, default: 0

    field :report, :map
    field :metadata, :map, default: %{}

    # Chain wiring. blocked_by: UUIDs of tasks that must be "done" before
    # this one is ready. auto_dispatch: when ready, fire automatically
    # vs wait for an explicit user click.
    field :blocked_by, {:array, :binary_id}, default: []
    field :auto_dispatch, :boolean, default: false

    belongs_to :plan, Plan
    belongs_to :agent_run, AgentRun

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(plan_id title role status)a
  @optional ~w(brief position assigned_at completed_at duration_ms cost_micros
               report metadata agent_run_id blocked_by auto_dispatch)a

  def changeset(task \\ %__MODULE__{}, attrs) do
    task
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:plan_id)
  end

  def transition_changeset(%__MODULE__{} = task, new_status) do
    attrs = %{status: new_status}

    attrs =
      cond do
        new_status == "in_progress" and is_nil(task.assigned_at) ->
          Map.put(attrs, :assigned_at, DateTime.utc_now())

        new_status == "done" and is_nil(task.completed_at) ->
          completed = DateTime.utc_now()

          attrs
          |> Map.put(:completed_at, completed)
          |> maybe_put_duration(task.assigned_at, completed)

        true ->
          attrs
      end

    task
    |> cast(attrs, [:status, :assigned_at, :completed_at, :duration_ms])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  defp maybe_put_duration(attrs, nil, _completed), do: attrs

  defp maybe_put_duration(attrs, started, completed) do
    Map.put(attrs, :duration_ms, DateTime.diff(completed, started, :millisecond))
  end
end

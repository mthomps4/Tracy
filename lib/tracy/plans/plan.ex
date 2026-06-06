defmodule Tracy.Plans.Plan do
  @moduledoc """
  A delegated commitment from the C-Suite — an approved, scoped, time-bounded
  thing we want to make happen. Tasks live underneath.

  Plans flow through statuses (locked taxonomy in `feedback_mobile_first_list_view.md`):

      triage → backlog → in_progress → in_review → done
                                    ↘  needs_input ↗
                                    ↘  blocked     ↗
                                    ↘  canceled

  New plans default to **triage** — awaiting Matt's explicit review.
  Approving (moving to backlog or beyond) sets `approved_at` + `approved_by_id`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tracy.Plans.Task

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(triage backlog in_progress in_review needs_input blocked done canceled)

  @doc "All valid status strings."
  def statuses, do: @statuses

  schema "plans" do
    field :title, :string
    field :brief, :string
    field :project, :string
    field :status, :string, default: "triage"

    field :approved_at, :utc_datetime_usec
    field :approved_by_id, :integer
    field :expires_at, :utc_datetime_usec
    field :budget_cap_micros, :integer

    field :scope, :map, default: %{}
    field :metadata, :map, default: %{}
    field :source_session_id, :binary_id

    has_many :tasks, Task, preload_order: [asc: :position]

    # Virtual: computed by `Plans.list_projects_for_dashboard/1` and other
    # aggregate-flavored fetchers. Not in DB; lives on the struct just so
    # the UI can pattern-match `plan.metrics` cleanly.
    field :metrics, :map, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(title status)a
  @optional ~w(brief project approved_at approved_by_id expires_at
               budget_cap_micros scope metadata source_session_id)a

  def changeset(plan \\ %__MODULE__{}, attrs) do
    plan
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_number(:budget_cap_micros, greater_than_or_equal_to: 0)
  end

  @doc """
  Transition the plan's status. Sets `approved_at`/`approved_by_id` when
  leaving `triage` for the first time.
  """
  def transition_changeset(%__MODULE__{} = plan, new_status, opts \\ []) do
    attrs = %{status: new_status}

    attrs =
      if plan.status == "triage" and new_status != "triage" and is_nil(plan.approved_at) do
        attrs
        |> Map.put(:approved_at, DateTime.utc_now())
        |> Map.put(:approved_by_id, Keyword.get(opts, :approved_by_id))
      else
        attrs
      end

    plan
    |> cast(attrs, [:status, :approved_at, :approved_by_id])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end
end

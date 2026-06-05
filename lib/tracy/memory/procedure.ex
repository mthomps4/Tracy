defmodule Tracy.Memory.Procedure do
  @moduledoc """
  Procedure — versioned how-to / system prompts / skills.

  Slow-moving content that shapes Claude's behaviour: commit-message style,
  Phoenix conventions, deploy runbooks, role definitions for workers, etc.

  Each `name` (a stable slug like `"commit-style"`) can have many versions;
  exactly one is marked `is_current: true` at any time (enforced by partial
  unique index).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "procedures" do
    field :name, :string
    field :version, :integer, default: 1
    field :body, :string
    field :description, :string
    field :is_current, :boolean, default: true
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(name body)a
  @optional ~w(version description is_current metadata embedding)a

  @doc """
  Build a changeset for a new procedure version. The `name` should match an
  existing slug for a new version of the same procedure; the partial unique
  index ensures only one row per name is `is_current: true`.
  """
  def changeset(procedure \\ %__MODULE__{}, attrs) do
    procedure
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:body, min: 1)
    |> validate_format(:name, ~r/^[a-z][a-z0-9-]*$/,
      message: "must be kebab-case slug starting with a letter"
    )
    |> validate_number(:version, greater_than: 0)
  end
end

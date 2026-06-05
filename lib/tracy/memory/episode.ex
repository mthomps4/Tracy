defmodule Tracy.Memory.Episode do
  @moduledoc """
  Episode — a raw, timestamped observation. Append-only.

  Episodes are the substrate that the nightly consolidator reads from to
  extract semantic facts. They're cheap, abundant, and unedited; semantic
  meaning is mined out of them later.

  ## Fields

    * `occurred_at` — when the event happened (NOT when it was inserted)
    * `source`     — provenance tag: `"session"`, `"webhook"`, `"worker"`,
                    `"system"` (free-form string for now; will gain an enum
                    once worker/webhook surfaces land)
    * `project`    — optional project scope; nil for portfolio-wide events
    * `body`       — raw textual content as observed
    * `metadata`   — arbitrary JSON sidecar
    * `embedding`  — 1024-dim vector for semantic retrieval; nil until embedded
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episodes" do
    field :occurred_at, :utc_datetime_usec
    field :source, :string
    field :project, :string
    field :body, :string
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(occurred_at source body)a
  @optional ~w(project metadata embedding)a

  @doc """
  Build a changeset for inserting a new episode. `occurred_at` defaults to
  `DateTime.utc_now/1` if the caller doesn't supply one.
  """
  def changeset(episode \\ %__MODULE__{}, attrs) do
    attrs = Map.put_new_lazy(attrs, :occurred_at, fn -> DateTime.utc_now() end)

    episode
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:body, min: 1)
    |> validate_inclusion(:source, ~w(session webhook worker system))
  end
end

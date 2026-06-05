defmodule Tracy.Memory.Fact do
  @moduledoc """
  Fact — extracted semantic memory. Editable, with temporal provenance.

  Facts are what the consolidator mines out of episodes: durable claims that
  shape future behaviour ("Matt prefers Phoenix without umbrellas", "Tracy
  uses sops + age for secrets"). The temporal columns mean we never lose
  history — superseded facts stay queryable; only the head is "current."

  ## Provenance fields

    * `valid_from`       — when this fact started being true
    * `valid_to`         — when it stopped being true (NULL = still current)
    * `superseded_by_id` — the fact that replaced this one (NULL = still current
                          or never superseded; just expired)
    * `source_episode_id` — pointer back to the raw observation that yielded
                            this fact (NULL if hand-authored or inferred)

  A fact is "currently valid" iff `valid_to IS NULL`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tracy.Memory.{Episode, Fact}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "facts" do
    field :statement, :string
    field :subject, :string
    field :tags, {:array, :string}, default: []
    field :confidence, :float, default: 1.0
    field :valid_from, :utc_datetime_usec
    field :valid_to, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :embedding, Pgvector.Ecto.Vector

    belongs_to :superseded_by, Fact
    belongs_to :source_episode, Episode

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(statement subject valid_from)a
  @optional ~w(tags confidence valid_to superseded_by_id source_episode_id metadata embedding)a

  @doc """
  Build a changeset for a fresh fact. Defaults `valid_from` to `now()` and
  leaves `valid_to` nil (current).
  """
  def changeset(fact \\ %__MODULE__{}, attrs) do
    attrs = Map.put_new_lazy(attrs, :valid_from, fn -> DateTime.utc_now() end)

    fact
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:statement, min: 1)
    |> validate_length(:subject, min: 1)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_temporal_order()
  end

  @doc """
  Mark a fact as superseded by another. Sets `valid_to` and `superseded_by_id`.

  This is the consolidator's primary update path — never delete contradicted
  facts, supersede them.
  """
  def supersede_changeset(%__MODULE__{} = fact, %__MODULE__{id: new_id}, at \\ nil) do
    at = at || DateTime.utc_now()

    fact
    |> cast(%{valid_to: at, superseded_by_id: new_id}, [:valid_to, :superseded_by_id])
    |> validate_required([:valid_to, :superseded_by_id])
  end

  defp validate_temporal_order(changeset) do
    from = get_field(changeset, :valid_from)
    to = get_field(changeset, :valid_to)

    if from && to && DateTime.compare(to, from) == :lt do
      add_error(changeset, :valid_to, "must be after valid_from")
    else
      changeset
    end
  end
end

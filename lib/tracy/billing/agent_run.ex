defmodule Tracy.Billing.AgentRun do
  @moduledoc """
  One LLM call as observed by Tracy. Records who, what model, how much, and
  which billing bucket the spend hit.

  All cost is stored in **micros** (millionths of a USD) to avoid float drift.
  Use `cost_dollars/1` and `cost_cents/1` to project to readable units.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @buckets ~w(interactive sdk_pool)
  @statuses ~w(completed error paused)
  @roles ~w(main engineer designer researcher pm reviewer note_taker operator scout daemon side_channel)

  schema "agent_runs" do
    field :session_id, :binary_id
    field :role, :string, default: "main"
    field :provider, :string, default: "claude"
    field :model, :string
    field :bucket, :string
    field :status, :string, default: "completed"

    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cache_read_tokens, :integer, default: 0
    field :cache_creation_tokens, :integer, default: 0
    field :cost_micros, :integer, default: 0

    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_ms, :integer
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(role provider model bucket started_at)a
  @optional ~w(session_id status input_tokens output_tokens cache_read_tokens
               cache_creation_tokens cost_micros completed_at duration_ms metadata)a

  def changeset(run \\ %__MODULE__{}, attrs) do
    attrs = Map.put_new_lazy(attrs, :started_at, fn -> DateTime.utc_now() end)

    run
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:bucket, @buckets)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:role, @roles)
    |> validate_non_negative()
    |> derive_duration()
  end

  @doc "Convert micros → dollars (float)."
  def cost_dollars(%__MODULE__{cost_micros: m}), do: m / 1_000_000

  @doc "Convert micros → integer cents (rounded)."
  def cost_cents(%__MODULE__{cost_micros: m}), do: round(m / 10_000)

  defp validate_non_negative(changeset) do
    Enum.reduce(
      [:input_tokens, :output_tokens, :cache_read_tokens, :cache_creation_tokens, :cost_micros],
      changeset,
      fn field, cs ->
        validate_number(cs, field, greater_than_or_equal_to: 0)
      end
    )
  end

  defp derive_duration(changeset) do
    started = get_field(changeset, :started_at)
    completed = get_field(changeset, :completed_at)
    existing_dur = get_field(changeset, :duration_ms)

    cond do
      existing_dur != nil ->
        changeset

      started && completed ->
        ms = DateTime.diff(completed, started, :millisecond)
        put_change(changeset, :duration_ms, ms)

      true ->
        changeset
    end
  end
end

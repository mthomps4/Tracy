defmodule Tracy.Assets.Asset do
  @moduledoc """
  A single deliverable attached to a Plan (and optionally a Task).

  Kinds:

    * `file`  — generic binary blob (default). `data` populated.
    * `image` — same shape as file but rendered with an image preview.
    * `link`  — `body` holds a URL; no binary `data`.
    * `note`  — `body` holds markdown text; no binary `data`.

  Binary data lives in Postgres `bytea` for v1. Behind a `Tracy.Assets.Storage`
  behaviour later (Phase 3), large blobs can migrate to S3 / MinIO without
  changing the schema — `data` becomes nullable + `metadata.storage = "s3"`
  with the key as a reference.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tracy.Plans.{Plan, Task}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(file image link note)
  @sources ~w(upload worker boardroom)

  def kinds, do: @kinds
  def sources, do: @sources

  schema "assets" do
    field :filename, :string
    field :content_type, :string, default: "application/octet-stream"
    field :size_bytes, :integer, default: 0
    field :kind, :string, default: "file"
    field :data, :binary
    field :body, :string
    field :source, :string, default: "upload"
    field :uploaded_by_id, :integer
    field :metadata, :map, default: %{}

    belongs_to :plan, Plan
    belongs_to :task, Task

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(plan_id filename kind source)a
  @optional ~w(task_id content_type size_bytes data body uploaded_by_id metadata)a

  def changeset(asset \\ %__MODULE__{}, attrs) do
    asset
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_data_for_kind()
    |> foreign_key_constraint(:plan_id)
    |> foreign_key_constraint(:task_id)
  end

  defp validate_data_for_kind(changeset) do
    kind = get_field(changeset, :kind)
    data = get_field(changeset, :data)
    body = get_field(changeset, :body)

    case kind do
      k when k in ["file", "image"] ->
        if is_nil(data),
          do: add_error(changeset, :data, "is required for #{k} assets"),
          else: changeset

      k when k in ["link", "note"] ->
        if is_nil(body) or body == "",
          do: add_error(changeset, :body, "is required for #{k} assets"),
          else: changeset

      _ ->
        changeset
    end
  end

  @doc "Format size_bytes as a human-readable string (B / KB / MB)."
  def humanize_size(b) when b < 1024, do: "#{b} B"
  def humanize_size(b) when b < 1_048_576, do: "#{Float.round(b / 1024, 1)} KB"
  def humanize_size(b), do: "#{Float.round(b / 1_048_576, 1)} MB"

  @doc "True if content-type starts with image/."
  def image?(%__MODULE__{content_type: ct}) when is_binary(ct), do: String.starts_with?(ct, "image/")
  def image?(_), do: false
end

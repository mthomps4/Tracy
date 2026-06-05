defmodule Tracy.Assets do
  @moduledoc """
  Public API for plan assets — files, images, links, notes attached to a Plan.

  Use the kind/source-aware constructors below over raw `create_asset/1`:

    * `create_file_asset/1` for binary uploads
    * `create_link_asset/1` for URL bookmarks
    * `create_note_asset/1` for markdown notes
    * `worker_attach/4` for worker-produced binaries (sets source/task_id)
  """
  import Ecto.Query

  alias Tracy.Assets.Asset
  alias Tracy.Repo

  # ---- queries ----

  @doc "All assets for a plan, ordered newest first."
  def list_assets(plan_id, opts \\ []) do
    kind = Keyword.get(opts, :kind)

    Asset
    |> where([a], a.plan_id == ^plan_id)
    |> maybe_filter_kind(kind)
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @doc "Get a single asset (with binary data)."
  def get_asset!(id), do: Repo.get!(Asset, id)
  def get_asset(id), do: Repo.get(Asset, id)

  @doc "Asset minus the binary blob (for listing in the UI)."
  def list_asset_summaries(plan_id, opts \\ []) do
    kind = Keyword.get(opts, :kind)

    Asset
    |> where([a], a.plan_id == ^plan_id)
    |> maybe_filter_kind(kind)
    |> select([a],
      %{
        id: a.id,
        plan_id: a.plan_id,
        task_id: a.task_id,
        filename: a.filename,
        content_type: a.content_type,
        size_bytes: a.size_bytes,
        kind: a.kind,
        body: a.body,
        source: a.source,
        uploaded_by_id: a.uploaded_by_id,
        metadata: a.metadata,
        inserted_at: a.inserted_at,
        updated_at: a.updated_at
      }
    )
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  # ---- writes ----

  @doc "Generic insert path."
  def create_asset(attrs) do
    %Asset{}
    |> Asset.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a file/image asset from a binary blob.

  Required keys: `:plan_id`, `:filename`, `:data`. Pass `:content_type`
  to control rendering — if it starts with `image/`, the kind is
  auto-set to `image`. `:source` defaults to `upload`.
  """
  def create_file_asset(attrs) do
    content_type = attrs[:content_type] || attrs["content_type"] || "application/octet-stream"
    data = attrs[:data] || attrs["data"]
    kind = if String.starts_with?(content_type, "image/"), do: "image", else: "file"

    attrs =
      attrs
      |> ensure_atom_keys()
      |> Map.put(:kind, kind)
      |> Map.put_new(:source, "upload")
      |> Map.put(:size_bytes, byte_size(data || ""))

    create_asset(attrs)
  end

  @doc "Create a link asset (URL bookmark with optional title)."
  def create_link_asset(attrs) do
    attrs =
      attrs
      |> ensure_atom_keys()
      |> Map.put(:kind, "link")
      |> Map.put_new(:source, "upload")
      |> Map.put_new(:filename, attrs[:filename] || attrs["filename"] || (attrs[:body] || attrs["body"]))
      |> Map.put_new(:content_type, "text/uri-list")

    create_asset(attrs)
  end

  @doc "Create a markdown note asset."
  def create_note_asset(attrs) do
    attrs =
      attrs
      |> ensure_atom_keys()
      |> Map.put(:kind, "note")
      |> Map.put_new(:source, "upload")
      |> Map.put_new(:content_type, "text/markdown")
      |> Map.put_new(:filename, attrs[:filename] || "note.md")

    create_asset(attrs)
  end

  @doc """
  Convenience for worker-produced files. Sets source = 'worker', ties
  the asset to a specific task.
  """
  def worker_attach(plan_id, task_id, filename, data, opts \\ []) do
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    kind = if String.starts_with?(content_type, "image/"), do: "image", else: "file"

    create_asset(%{
      plan_id: plan_id,
      task_id: task_id,
      filename: filename,
      content_type: content_type,
      kind: kind,
      data: data,
      size_bytes: byte_size(data),
      source: "worker",
      metadata: Keyword.get(opts, :metadata, %{})
    })
  end

  def delete_asset(%Asset{} = asset), do: Repo.delete(asset)

  def delete_asset(id) when is_binary(id) do
    case get_asset(id) do
      nil -> {:error, :not_found}
      asset -> delete_asset(asset)
    end
  end

  # ---- helpers ----

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, kind), do: where(query, [a], a.kind == ^kind)

  defp ensure_atom_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError ->
      # If a string key doesn't map to an existing atom, just pass through.
      map
  end
end

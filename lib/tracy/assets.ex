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

  @doc """
  Scan the plan's filesystem workspace and register any files not yet
  tracked as Assets. Returns `{:ok, [created_assets]}` — empty list if
  nothing was new.

  Called after a worker completes; the side effect closes the loop
  between "designer wrote `logo.svg` into the workspace" and "the
  plan's Assets section shows logo.svg." Workspace files stay where
  they are on disk (the dir is the worker's CWD, persists across
  dispatches); the Asset row carries a copy of the bytes + metadata
  for the UI to render via the existing download endpoint.

  Skips files matching common ignore patterns (`.git/`, `node_modules/`,
  `.DS_Store`, hidden dotfiles at the root). Caps per-file size at 25MB
  to stay within the upload limit — bigger files are logged + skipped.
  """
  @spec import_workspace(String.t() | Tracy.Plans.Plan.t(), keyword()) ::
          {:ok, [Tracy.Assets.Asset.t()]}
  def import_workspace(plan_or_id, opts \\ [])

  def import_workspace(%Tracy.Plans.Plan{id: id}, opts), do: import_workspace(id, opts)

  def import_workspace(plan_id, opts) when is_binary(plan_id) do
    uploaded_by_id = Keyword.get(opts, :uploaded_by_id)
    max_bytes = Keyword.get(opts, :max_bytes, 25_000_000)
    source = Keyword.get(opts, :source, "worker")

    workspace = Tracy.Plans.workspace_path(plan_id)

    existing_filenames =
      list_asset_summaries(plan_id)
      |> Enum.map(& &1.filename)
      |> MapSet.new()

    created =
      workspace
      |> list_workspace_files()
      |> Enum.reject(&MapSet.member?(existing_filenames, relative_to(workspace, &1)))
      |> Enum.flat_map(fn path ->
        case File.stat(path) do
          {:ok, %{size: size}} when size > max_bytes ->
            require Logger
            Logger.info("Tracy.Assets.import_workspace: skipping #{path} (#{size} > #{max_bytes} bytes)")
            []

          {:ok, _} ->
            data = File.read!(path)
            filename = relative_to(workspace, path)

            attrs = %{
              plan_id: plan_id,
              filename: filename,
              content_type: infer_content_type(filename),
              data: data,
              uploaded_by_id: uploaded_by_id
            }

            case create_file_asset(Map.put(attrs, :source, source)) do
              {:ok, asset} -> [asset]
              {:error, _cs} -> []
            end

          _ ->
            []
        end
      end)

    {:ok, created}
  end

  defp list_workspace_files(root) do
    if File.exists?(root) do
      do_walk(root, root)
    else
      []
    end
  end

  @ignored_dirs ~w(.git node_modules .vscode .idea _build deps)
  @ignored_files ~w(.DS_Store)

  defp do_walk(root, dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            entry in @ignored_files -> []
            entry in @ignored_dirs -> []
            # Skip dotfiles at the workspace root only
            String.starts_with?(entry, ".") and dir == root -> []
            File.dir?(path) -> do_walk(root, path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp relative_to(root, path) do
    Path.relative_to(path, root)
  end

  defp infer_content_type(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".svg" -> "image/svg+xml"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".html" -> "text/html"
      ".htm" -> "text/html"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".json" -> "application/json"
      ".md" -> "text/markdown"
      ".markdown" -> "text/markdown"
      ".txt" -> "text/plain"
      ".pdf" -> "application/pdf"
      _ -> "application/octet-stream"
    end
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

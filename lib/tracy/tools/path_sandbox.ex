defmodule Tracy.Tools.PathSandbox do
  @moduledoc """
  Validates and resolves file paths against a list of allowed base directories.
  Prevents directory traversal and escape from the sandbox.

  Used by Tracy workers to scope filesystem access to a project's worktree
  (or any other declared boundary). Worker dispatch briefs declare the
  allowed paths; every read/write goes through here first.
  """

  @doc """
  Resolve a path, ensuring it falls within one of the allowed base paths.
  Returns `{:ok, absolute_path}` or `{:error, reason}`.
  """
  def resolve_path(path, allowed_paths) when is_list(allowed_paths) do
    expanded = expand_path(path, allowed_paths)

    if allowed?(expanded, allowed_paths) do
      {:ok, expanded}
    else
      {:error, "Access denied: #{path} is outside allowed directories"}
    end
  end

  @doc "Check if a path is within allowed directories."
  def allowed?(path, allowed_paths) do
    expanded = Path.expand(path)
    Enum.any?(allowed_paths, fn base -> String.starts_with?(expanded, Path.expand(base)) end)
  end

  defp expand_path(path, allowed_paths) do
    path = String.replace_leading(path, "~", System.user_home!())

    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      case allowed_paths do
        [base | _] -> Path.expand(path, Path.expand(base))
        [] -> Path.expand(path)
      end
    end
  end
end

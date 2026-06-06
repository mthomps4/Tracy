defmodule Tracy.AssetsWorkspaceTest do
  use Tracy.DataCase

  alias Tracy.{Assets, Plans}

  describe "import_workspace/2" do
    setup do
      # Use a per-test workspace root so tests don't trample each other
      # or the real workspace dir.
      tmp_root = Path.join(System.tmp_dir!(), "tracy-assets-test-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:tracy, :workspace_root)
      Application.put_env(:tracy, :workspace_root, tmp_root)

      on_exit(fn ->
        if prev, do: Application.put_env(:tracy, :workspace_root, prev), else: Application.delete_env(:tracy, :workspace_root)
        File.rm_rf!(tmp_root)
      end)

      {:ok, plan} = Plans.create_plan(%{title: "art project"})

      %{plan: plan, workspace: Plans.workspace_path(plan)}
    end

    test "registers each file in the workspace as a new Asset", %{plan: plan, workspace: ws} do
      File.write!(Path.join(ws, "logo.svg"), "<svg/>")
      File.write!(Path.join(ws, "notes.md"), "# Brand notes\n")

      {:ok, assets} = Assets.import_workspace(plan, source: "worker")

      assert length(assets) == 2
      filenames = Enum.map(assets, & &1.filename)
      assert "logo.svg" in filenames
      assert "notes.md" in filenames
      assert Enum.all?(assets, &(&1.source == "worker"))
    end

    test "infers content type from extension", %{plan: plan, workspace: ws} do
      File.write!(Path.join(ws, "logo.svg"), "<svg/>")
      File.write!(Path.join(ws, "logo.png"), <<137, 80, 78, 71, 13, 10, 26, 10>>)
      File.write!(Path.join(ws, "readme.md"), "hi")

      {:ok, assets} = Assets.import_workspace(plan)

      mime = Enum.into(assets, %{}, fn a -> {a.filename, a.content_type} end)
      assert mime["logo.svg"] == "image/svg+xml"
      assert mime["logo.png"] == "image/png"
      assert mime["readme.md"] == "text/markdown"
    end

    test "skips files already registered (no duplicates on re-import)", %{plan: plan, workspace: ws} do
      File.write!(Path.join(ws, "spec.md"), "# Spec\n")

      {:ok, first} = Assets.import_workspace(plan)
      assert length(first) == 1

      {:ok, second} = Assets.import_workspace(plan)
      assert second == []
    end

    test "walks subdirectories", %{plan: plan, workspace: ws} do
      File.mkdir_p!(Path.join(ws, "logos"))
      File.mkdir_p!(Path.join(ws, "mockups"))
      File.write!(Path.join([ws, "logos", "mark.svg"]), "<svg/>")
      File.write!(Path.join([ws, "mockups", "hero.html"]), "<!doctype html>")

      {:ok, assets} = Assets.import_workspace(plan)
      filenames = Enum.map(assets, & &1.filename) |> Enum.sort()

      assert filenames == ["logos/mark.svg", "mockups/hero.html"]
    end

    test "ignores .git / node_modules / .DS_Store noise", %{plan: plan, workspace: ws} do
      File.mkdir_p!(Path.join(ws, ".git"))
      File.write!(Path.join([ws, ".git", "HEAD"]), "ref:")
      File.mkdir_p!(Path.join(ws, "node_modules"))
      File.write!(Path.join([ws, "node_modules", "package.json"]), "{}")
      File.write!(Path.join(ws, ".DS_Store"), "junk")
      File.write!(Path.join(ws, "real.txt"), "keep me")

      {:ok, assets} = Assets.import_workspace(plan)
      filenames = Enum.map(assets, & &1.filename)
      assert filenames == ["real.txt"]
    end

    test "skips files over the size cap", %{plan: plan, workspace: ws} do
      File.write!(Path.join(ws, "huge.bin"), :crypto.strong_rand_bytes(2_048))

      {:ok, assets} = Assets.import_workspace(plan, max_bytes: 1_024)
      assert assets == []
    end

    test "returns empty list when nothing is in the workspace", %{plan: plan} do
      {:ok, assets} = Assets.import_workspace(plan)
      assert assets == []
    end
  end
end

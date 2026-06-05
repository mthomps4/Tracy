defmodule Tracy.AssetsTest do
  use Tracy.DataCase, async: true

  alias Tracy.{Assets, Plans}
  alias Tracy.Assets.Asset

  setup do
    {:ok, plan} = Plans.create_plan(%{title: "asset host plan"})
    %{plan: plan}
  end

  describe "create_file_asset/1" do
    test "stores binary data and auto-detects image kind", %{plan: plan} do
      data = <<137, 80, 78, 71, 13, 10, 26, 10>>  # PNG signature

      assert {:ok, asset} =
               Assets.create_file_asset(%{
                 plan_id: plan.id,
                 filename: "logo.png",
                 content_type: "image/png",
                 data: data
               })

      assert asset.kind == "image"
      assert asset.size_bytes == byte_size(data)
      assert asset.source == "upload"
    end

    test "non-image content_type → kind=file", %{plan: plan} do
      assert {:ok, asset} =
               Assets.create_file_asset(%{
                 plan_id: plan.id,
                 filename: "spec.pdf",
                 content_type: "application/pdf",
                 data: "fake pdf"
               })

      assert asset.kind == "file"
    end
  end

  describe "create_link_asset/1" do
    test "creates a link asset with the url as fallback filename", %{plan: plan} do
      assert {:ok, asset} =
               Assets.create_link_asset(%{
                 plan_id: plan.id,
                 body: "https://figma.com/file/abc"
               })

      assert asset.kind == "link"
      assert asset.body == "https://figma.com/file/abc"
      assert asset.filename == "https://figma.com/file/abc"
    end

    test "uses the provided filename as title", %{plan: plan} do
      assert {:ok, asset} =
               Assets.create_link_asset(%{
                 plan_id: plan.id,
                 filename: "Figma file",
                 body: "https://figma.com/abc"
               })

      assert asset.filename == "Figma file"
    end
  end

  describe "list_assets/1" do
    test "returns newest first", %{plan: plan} do
      {:ok, _a} = Assets.create_file_asset(%{plan_id: plan.id, filename: "a", data: "1"})
      Process.sleep(5)
      {:ok, _b} = Assets.create_file_asset(%{plan_id: plan.id, filename: "b", data: "2"})

      [first, second] = Assets.list_assets(plan.id)
      assert first.filename == "b"
      assert second.filename == "a"
    end

    test "filters by kind", %{plan: plan} do
      {:ok, _} = Assets.create_file_asset(%{plan_id: plan.id, filename: "f", data: "x"})
      {:ok, _} = Assets.create_link_asset(%{plan_id: plan.id, body: "https://x"})

      assert [%Asset{kind: "link"}] = Assets.list_assets(plan.id, kind: "link")
    end
  end

  describe "list_asset_summaries/1" do
    test "excludes the binary data field", %{plan: plan} do
      big_data = String.duplicate("x", 100_000)

      {:ok, _} =
        Assets.create_file_asset(%{
          plan_id: plan.id,
          filename: "big.bin",
          data: big_data
        })

      [summary] = Assets.list_asset_summaries(plan.id)
      refute Map.has_key?(summary, :data)
      assert summary.size_bytes == 100_000
    end
  end

  describe "worker_attach/4" do
    test "creates a worker-sourced asset tied to a task", %{plan: plan} do
      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "make logo", role: "designer"})

      assert {:ok, asset} =
               Assets.worker_attach(plan.id, task.id, "concept.png", "binary",
                 content_type: "image/png"
               )

      assert asset.source == "worker"
      assert asset.task_id == task.id
      assert asset.kind == "image"
    end
  end

  describe "delete_asset/1" do
    test "removes the asset", %{plan: plan} do
      {:ok, asset} = Assets.create_file_asset(%{plan_id: plan.id, filename: "x", data: "y"})
      assert {:ok, _} = Assets.delete_asset(asset)
      assert Assets.list_assets(plan.id) == []
    end
  end

  describe "Asset helpers" do
    test "humanize_size/1" do
      assert Asset.humanize_size(500) == "500 B"
      assert Asset.humanize_size(2048) == "2.0 KB"
      assert Asset.humanize_size(2_097_152) == "2.0 MB"
    end

    test "image?/1" do
      assert Asset.image?(%Asset{content_type: "image/png"})
      refute Asset.image?(%Asset{content_type: "application/pdf"})
    end
  end
end

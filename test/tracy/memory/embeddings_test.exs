defmodule Tracy.Memory.EmbeddingsTest do
  use ExUnit.Case, async: true

  alias Tracy.Memory.Embeddings

  test "defaults to the Stub provider" do
    assert Embeddings.provider() == Tracy.Memory.Embeddings.Stub
  end

  test "embed/1 dispatches to the configured provider" do
    assert {:ok, vec} = Embeddings.embed("dispatch me")
    assert length(vec) == 768
  end

  test "embed_many/1 returns a list of vectors" do
    assert {:ok, [v1, v2]} = Embeddings.embed_many(["a", "b"])
    assert length(v1) == 768
    assert length(v2) == 768
    refute v1 == v2
  end
end

defmodule Tracy.Memory.Embeddings.StubTest do
  use ExUnit.Case, async: true

  alias Tracy.Memory.Embeddings.Stub

  test "embed/1 returns a 1024-dimensional vector" do
    assert {:ok, vec} = Stub.embed("hello")
    assert length(vec) == 1024
  end

  test "embed/1 is deterministic" do
    assert {:ok, a} = Stub.embed("the boardroom is open")
    assert {:ok, b} = Stub.embed("the boardroom is open")
    assert a == b
  end

  test "different inputs produce different vectors" do
    assert {:ok, a} = Stub.embed("first")
    assert {:ok, b} = Stub.embed("second")
    refute a == b
  end

  test "embed/1 returns a unit vector (within float tolerance)" do
    assert {:ok, vec} = Stub.embed("normalised please")
    magnitude = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    assert_in_delta magnitude, 1.0, 0.0001
  end

  test "embed_many/1 maps each text through embed/1" do
    assert {:ok, [a, b]} = Stub.embed_many(["x", "y"])
    assert {:ok, ^a} = Stub.embed("x")
    assert {:ok, ^b} = Stub.embed("y")
  end
end

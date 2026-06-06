defmodule Tracy.Memory.Embeddings.Stub do
  @moduledoc """
  Deterministic embedding provider for dev/test.

  Hashes the input text via SHA-256, seeds `:rand` from the digest, and emits
  a 768-dim unit vector — matches Nomic-Embed-v1.5's native dimension so the
  pgvector `vector(768)` column accepts both Stub and Nomic output without
  schema differences between environments.

  Same input → same vector, every time. Different inputs → different
  vectors. Good enough to exercise pgvector queries and cosine-distance
  ranking without spending real money or downloading models.

  Behaviour: `Tracy.Memory.Embeddings.Provider`.
  """
  @behaviour Tracy.Memory.Embeddings.Provider

  @dim 768

  @impl true
  def embed(text, _opts \\ []) when is_binary(text) do
    {:ok, deterministic_unit_vector(text)}
  end

  @impl true
  def embed_many(texts, opts \\ []) when is_list(texts) do
    {:ok, Enum.map(texts, fn t -> elem(embed(t, opts), 1) end)}
  end

  defp deterministic_unit_vector(text) do
    # Use the SHA-256 digest as a seed for a reproducible PRNG. Then sample
    # a Gaussian-ish distribution (sum of uniforms) and normalise.
    <<seed::64, _rest::binary>> = :crypto.hash(:sha256, text)
    {raw, _} = sample(seed, @dim, [])
    normalise(raw)
  end

  defp sample(_seed, 0, acc), do: {Enum.reverse(acc), nil}

  defp sample(seed, n, acc) do
    # LCG-ish step in pure Elixir so the test envs don't fight over :rand state.
    next = rem(seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407, Bitwise.bsl(1, 63))
    # Map to [-1, 1)
    value = next / Bitwise.bsl(1, 62) - 1.0
    sample(next, n - 1, [value | acc])
  end

  defp normalise(vec) do
    magnitude = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    if magnitude == 0.0, do: vec, else: Enum.map(vec, &(&1 / magnitude))
  end
end

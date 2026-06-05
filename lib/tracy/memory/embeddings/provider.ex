defmodule Tracy.Memory.Embeddings.Provider do
  @moduledoc """
  Behaviour for embedding providers.

  Implementations:

    * `Tracy.Memory.Embeddings.Stub` — deterministic vectors for dev/test.
    * (future) `Tracy.Memory.Embeddings.Voyage` — Voyage-3 via HTTP.
    * (future) `Tracy.Memory.Embeddings.Nomic` — Bumblebee + nomic-embed-text-v1.5.

  The active provider is configured via:

      config :tracy, Tracy.Memory.Embeddings, provider: Tracy.Memory.Embeddings.Stub

  Vectors are 1024-dimensional (matches both Voyage-3 and Nomic defaults).
  Adjust the migration if we ever standardise on a different dim.
  """

  @type vector :: [float()]
  @type opts :: keyword()

  @callback embed(text :: String.t(), opts) :: {:ok, vector} | {:error, term()}
  @callback embed_many([String.t()], opts) :: {:ok, [vector]} | {:error, term()}

  @optional_callbacks [embed_many: 2]
end

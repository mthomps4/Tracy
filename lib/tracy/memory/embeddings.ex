defmodule Tracy.Memory.Embeddings do
  @moduledoc """
  Public API for generating embeddings.

  Dispatches to the configured `Tracy.Memory.Embeddings.Provider` implementation.

  ## Config

      config :tracy, Tracy.Memory.Embeddings,
        provider: Tracy.Memory.Embeddings.Stub

  Switch to a real provider (Voyage, Nomic) by changing this config — callers
  never know the difference.
  """
  alias Tracy.Memory.Embeddings.Provider

  @doc """
  Embed a single piece of text. Returns `{:ok, vector}` or `{:error, reason}`.
  """
  @spec embed(String.t(), keyword()) :: {:ok, Provider.vector()} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    provider().embed(text, opts)
  end

  @doc """
  Embed a batch of texts. Falls back to looped `embed/2` calls if the provider
  doesn't implement `embed_many/2`.
  """
  @spec embed_many([String.t()], keyword()) :: {:ok, [Provider.vector()]} | {:error, term()}
  def embed_many(texts, opts \\ []) when is_list(texts) do
    provider = provider()

    if function_exported?(provider, :embed_many, 2) do
      provider.embed_many(texts, opts)
    else
      results = Enum.map(texts, fn t -> provider.embed(t, opts) end)

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> {:ok, Enum.map(results, fn {:ok, v} -> v end)}
        {:error, _} = err -> err
      end
    end
  end

  @doc "Returns the currently-configured provider module."
  def provider do
    Application.get_env(:tracy, __MODULE__, [])
    |> Keyword.get(:provider, Tracy.Memory.Embeddings.Stub)
  end
end

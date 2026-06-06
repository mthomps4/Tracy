defmodule Tracy.Memory.Embeddings.Nomic do
  @moduledoc """
  Local embeddings via Bumblebee + Nomic-Embed-text-v1.5.

  Apache 2.0, ~137M params, 768-dim output, runs on CPU (EXLA bundles a
  precompiled XLA binary). No API keys, no rate limits, no cloud costs,
  no privacy surface — the embedding never leaves the NUC.

  ## Why this model

    * **Apache 2.0** — matches Tracy's OSS-first stance, zero lock-in.
    * **137M params** — fits in CPU RAM comfortably, fast enough for
      single-user volume.
    * **768-dim native** with Matryoshka truncation available — Tracy's
      Postgres `vector(768)` column matches this exactly.
    * **L2-normalised output** (via `embedding_processor: :l2_norm`) —
      cosine distance becomes a dot product on the HNSW index.

  ## Lifecycle

  The first `embed/2` call loads the model + tokenizer from HuggingFace
  (downloads ~250MB to `~/.cache/bumblebee/` on first boot only) and
  builds an `Nx.Serving` powered by EXLA. Subsequent calls reuse the
  warm serving — typically < 100ms on CPU per query.

  Model load is lazy: the GenServer starts instantly. The first request
  pays the loading tax (~5-30s depending on cold cache). Tracy.Memory
  callers should be aware: the first call after boot will block.

  ## Configuration

      config :tracy, Tracy.Memory.Embeddings,
        provider: Tracy.Memory.Embeddings.Nomic

  The supervision tree starts the GenServer regardless of which provider
  is configured — it's cheap until the first call (no model load).
  """

  @behaviour Tracy.Memory.Embeddings.Provider

  use GenServer

  require Logger

  @model_repo "nomic-ai/nomic-embed-text-v1.5"
  @load_timeout 60_000
  @inference_timeout 30_000

  # ---- Provider behaviour ----

  @impl Tracy.Memory.Embeddings.Provider
  def embed(text, _opts \\ []) when is_binary(text) do
    GenServer.call(__MODULE__, {:embed, text}, @load_timeout + @inference_timeout)
  end

  @impl Tracy.Memory.Embeddings.Provider
  def embed_many(texts, _opts \\ []) when is_list(texts) do
    GenServer.call(__MODULE__, {:embed_many, texts}, @load_timeout + @inference_timeout)
  end

  # ---- warm path ----

  @doc """
  Synchronously warm the model. Loads + builds the Nx.Serving so the next
  embed/2 call is hot (~50-100ms) instead of cold (~5-30s).

  Returns `:ok` when the model is loaded, `{:error, reason}` if loading
  failed. Safe to call repeatedly — subsequent calls are no-ops once the
  serving is built.
  """
  @spec warm() :: :ok | {:error, term()}
  def warm do
    GenServer.call(__MODULE__, :warm, @load_timeout)
  end

  @doc """
  Spawn a background Task to warm the model. Returns immediately. Useful
  during application boot — we don't want to block startup for the model
  load, but we DO want the first chat to be fast.

  The Task logs success/failure but doesn't link to the caller, so a
  failed warm doesn't crash the supervisor.
  """
  @spec warm_async() :: pid()
  def warm_async do
    spawn(fn ->
      require Logger
      Logger.info("Tracy.Memory.Embeddings.Nomic: pre-warming model in background...")

      case warm() do
        :ok ->
          Logger.info("Tracy.Memory.Embeddings.Nomic: model warm, first chat will be fast")

        {:error, reason} ->
          Logger.warning("Tracy.Memory.Embeddings.Nomic: warm failed — #{inspect(reason)}; first embed call will pay the load tax")
      end
    end)
  end

  @doc """
  Is the model loaded and ready? Cheap check (no DB, no inference) —
  the dock UI can use this to show a "still warming" affordance if Matt
  beats the prewarm task.
  """
  @spec warm?() :: boolean()
  def warm? do
    case GenServer.call(__MODULE__, :warm_status, 1_000) do
      :warm -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  # ---- GenServer ----

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    # Lazy: no model load on boot. First call triggers it.
    {:ok, %{serving: nil}}
  end

  @impl GenServer
  def handle_call(:warm, _from, state) do
    case ensure_serving(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call(:warm_status, _from, state) do
    status = if state.serving, do: :warm, else: :cold
    {:reply, status, state}
  end

  def handle_call({:embed, text}, _from, state) do
    case ensure_serving(state) do
      {:ok, state} ->
        try do
          %{embedding: tensor} = Nx.Serving.run(state.serving, text)
          {:reply, {:ok, Nx.to_flat_list(tensor)}, state}
        rescue
          e -> {:reply, {:error, {:inference_failed, Exception.message(e)}}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:embed_many, texts}, _from, state) do
    case ensure_serving(state) do
      {:ok, state} ->
        try do
          # Nx.Serving handles batching internally. Feeding a list returns a
          # list of result maps in the same order.
          results = Nx.Serving.run(state.serving, texts)
          vectors = Enum.map(results, fn %{embedding: t} -> Nx.to_flat_list(t) end)
          {:reply, {:ok, vectors}, state}
        rescue
          e -> {:reply, {:error, {:inference_failed, Exception.message(e)}}, state}
        end

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # ---- model loading ----

  defp ensure_serving(%{serving: %Nx.Serving{}} = state), do: {:ok, state}

  defp ensure_serving(state) do
    Logger.info("Tracy.Memory.Embeddings.Nomic: loading #{@model_repo} (one-time, may take ~30s on cold cache)")

    started_at = System.monotonic_time(:millisecond)

    with {:ok, model_info} <- Bumblebee.load_model({:hf, @model_repo}),
         {:ok, tokenizer} <- Bumblebee.load_tokenizer({:hf, @model_repo}) do
      serving =
        Bumblebee.Text.text_embedding(model_info, tokenizer,
          embedding_processor: :l2_norm,
          output_attribute: :hidden_state,
          output_pool: :mean_pooling,
          defn_options: [compiler: EXLA]
        )

      ms = System.monotonic_time(:millisecond) - started_at
      Logger.info("Tracy.Memory.Embeddings.Nomic: model warm in #{ms}ms")

      {:ok, %{state | serving: serving}}
    else
      {:error, reason} ->
        Logger.warning("Tracy.Memory.Embeddings.Nomic: load failed — #{inspect(reason)}")
        {:error, {:model_load_failed, reason}}

      other ->
        Logger.warning("Tracy.Memory.Embeddings.Nomic: unexpected load result — #{inspect(other)}")
        {:error, {:model_load_failed, other}}
    end
  end
end

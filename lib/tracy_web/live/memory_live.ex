defmodule TracyWeb.MemoryLive do
  @moduledoc """
  Memory inspector — "what does Tracy actually remember?"

  Three tabs:
    * **Facts** — durable claims. Statement, subject, valid window,
      provenance back to the source episode.
    * **Episodes** — raw conversation log. Source, project, body.
    * **Procedures** — versioned how-to-do-X knowledge.

  Search box at the top hits the hybrid pgvector + FTS retriever
  (`Tracy.Memory.search/2`) — useful for "do I know about X?" sanity
  checks before talking to Tracy.

  Read-only. Mutations come from the consolidator / agent flow, not
  the user. (The user-visible feedback loop: tell me something durable
  in chat → I record a Fact → it shows up here.)
  """
  use TracyWeb, :live_view

  alias Tracy.Memory

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Memory")
     |> assign(:current_tab, :memory)
     |> assign(:active_tab, "facts")
     |> assign(:query, "")
     |> assign(:facts, Memory.current_facts(limit: 50))
     |> assign(:episodes, Memory.recent_episodes(limit: 50))
     |> assign(:search_results, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"] || "facts"
    tab = if tab in ["facts", "episodes", "procedures", "search"], do: tab, else: "facts"
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("set_query", %{"query" => q}, socket) do
    socket = assign(socket, :query, q)

    socket =
      if String.length(String.trim(q)) >= 2 do
        results =
          try do
            Memory.search(q, limit: 20)
          rescue
            _ -> []
          end

        assign(socket, :search_results, results)
      else
        assign(socket, :search_results, [])
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_tab={@current_tab}
      page_title={@page_title}
    >
      <header class="mb-5">
        <h1 class="text-2xl font-bold tracking-tight text-base-content sm:text-3xl">
          Memory
        </h1>
        <p class="mt-1 text-sm text-base-content/60">
          What I remember. Search across everything, or browse by kind.
        </p>
      </header>

      <form phx-change="set_query" class="mb-5">
        <input
          type="search"
          name="query"
          value={@query}
          phx-debounce="200"
          placeholder="Search facts, episodes, procedures…"
          class="input input-bordered w-full bg-base-200/60"
          autocomplete="off"
        />
      </form>

      <%= if String.length(String.trim(@query)) >= 2 do %>
        <.search_results results={@search_results} query={@query} />
      <% else %>
        <nav class="mb-4 flex gap-1 border-b border-base-300/60 sm:gap-2" aria-label="Memory sections">
          <.tab_link tab="facts" active={@active_tab} label="Facts" count={length(@facts)} />
          <.tab_link tab="episodes" active={@active_tab} label="Episodes" count={length(@episodes)} />
          <.tab_link tab="procedures" active={@active_tab} label="Procedures" count={nil} />
        </nav>

        <div :if={@active_tab == "facts"} class="space-y-2">
          <p :if={@facts == []} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-8 text-center text-sm text-base-content/50">
            No facts yet. Tell me something durable in chat and I'll record one.
          </p>
          <.fact_card :for={fact <- @facts} fact={fact} />
        </div>

        <div :if={@active_tab == "episodes"} class="space-y-2">
          <p :if={@episodes == []} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-8 text-center text-sm text-base-content/50">
            No episodes yet. Start a conversation.
          </p>
          <.episode_card :for={ep <- @episodes} episode={ep} />
        </div>

        <div :if={@active_tab == "procedures"} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-8 text-center text-sm text-base-content/50">
          Procedures view — coming soon. Versioned how-to-do-X knowledge
          lives here once the consolidator starts emitting them.
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :tab, :string, required: true
  attr :active, :string, required: true
  attr :label, :string, required: true
  attr :count, :any, default: nil

  defp tab_link(assigns) do
    is_active = assigns.active == assigns.tab
    assigns = assign(assigns, :is_active, is_active)

    ~H"""
    <.link
      patch={~p"/memory?tab=#{@tab}"}
      class={[
        "relative flex items-center gap-1.5 border-b-2 px-3 py-2 text-sm font-medium transition-colors",
        @is_active && "border-primary text-primary",
        !@is_active && "border-transparent text-base-content/60 hover:text-base-content"
      ]}
    >
      {@label}
      <span :if={@count != nil} class="tabular-nums rounded-full bg-base-300/60 px-1.5 py-0.5 text-[10px] text-base-content/60">
        {@count}
      </span>
    </.link>
    """
  end

  attr :fact, :map, required: true

  defp fact_card(assigns) do
    ~H"""
    <article class="rounded-box border border-base-300/60 bg-base-100/60 p-3 sm:p-4">
      <p class="text-sm leading-relaxed text-base-content">
        {@fact.statement}
      </p>
      <div class="mt-2 flex flex-wrap items-center gap-2 text-[10px] uppercase tracking-wider text-base-content/50">
        <span class="rounded-full border border-base-300/60 px-1.5 py-0.5">
          subject: {@fact.subject}
        </span>
        <span :for={tag <- @fact.tags || []} class="rounded-full bg-primary/10 px-1.5 py-0.5 text-primary/80">
          {tag}
        </span>
        <span :if={@fact.confidence < 1.0} class="text-warning/80">
          confidence {Float.round(@fact.confidence, 2)}
        </span>
        <span class="ml-auto tabular-nums">
          from {format_date(@fact.valid_from)}
        </span>
      </div>
    </article>
    """
  end

  attr :episode, :map, required: true

  defp episode_card(assigns) do
    assigns = assign_new(assigns, :role, fn -> get_in(assigns.episode.metadata || %{}, ["role"]) end)

    ~H"""
    <article class="rounded-box border border-base-300/60 bg-base-100/60 p-3 sm:p-4">
      <p class="whitespace-pre-wrap text-sm leading-relaxed text-base-content/80">
        {@episode.body}
      </p>
      <div class="mt-2 flex flex-wrap items-center gap-2 text-[10px] uppercase tracking-wider text-base-content/50">
        <span :if={@role} class="rounded-full border border-base-300/60 px-1.5 py-0.5">
          {@role}
        </span>
        <span :if={@episode.source} class="rounded-full bg-base-300/30 px-1.5 py-0.5">
          {@episode.source}
        </span>
        <span :if={@episode.project} class="rounded-full bg-secondary/10 px-1.5 py-0.5 text-secondary/80">
          project: {@episode.project}
        </span>
        <span class="ml-auto tabular-nums">
          {format_date(@episode.occurred_at || @episode.inserted_at)}
        </span>
      </div>
    </article>
    """
  end

  attr :results, :list, required: true
  attr :query, :string, required: true

  defp search_results(assigns) do
    ~H"""
    <section>
      <p class="mb-3 text-xs text-base-content/50">
        {length(@results)} result{if length(@results) == 1, do: "", else: "s"}
        for <span class="font-medium text-base-content/70">"{@query}"</span>
      </p>

      <div :if={@results == []} class="rounded-box border border-dashed border-base-300/60 bg-base-200/20 px-4 py-8 text-center text-sm text-base-content/50">
        Nothing matched. Try fewer words or a different angle.
      </div>

      <ul class="space-y-2">
        <li :for={result <- @results}>
          <.search_result_card result={result} />
        </li>
      </ul>
    </section>
    """
  end

  attr :result, :map, required: true

  defp search_result_card(%{result: %{kind: kind}} = assigns) do
    assigns = assign(assigns, :kind_label, kind_label(kind))

    ~H"""
    <article class="rounded-box border border-base-300/60 bg-base-100/60 p-3">
      <p class="mb-1 text-[10px] uppercase tracking-wider text-primary/70">
        {@kind_label}
      </p>
      <p class="whitespace-pre-wrap text-sm leading-relaxed text-base-content">
        {@result.snippet}
      </p>
    </article>
    """
  end

  defp search_result_card(%{result: result} = assigns) when is_map(result) do
    # Fallback for any shape Memory.search returns that doesn't carry :kind
    assigns = assign(assigns, :snippet, Map.get(result, :snippet, inspect(result, limit: 120)))

    ~H"""
    <article class="rounded-box border border-base-300/60 bg-base-100/60 p-3">
      <p class="whitespace-pre-wrap text-sm leading-relaxed text-base-content">
        {@snippet}
      </p>
    </article>
    """
  end

  defp kind_label(:fact), do: "Fact"
  defp kind_label(:episode), do: "Episode"
  defp kind_label(:procedure), do: "Procedure"
  defp kind_label(other), do: to_string(other)

  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %Y")
  defp format_date(_), do: ""
end

defmodule Tracy.Billing do
  @moduledoc """
  Cost ledger — the truth about Tracy's spend.

  Every LLM call (boardroom turn, worker dispatch, background daemon,
  side-channel agent) lands here as a row in `agent_runs`. The cost meter
  on the boardroom UI reads from this table; so does the wind-down
  classifier (75% caution, 85% hard stop).

  ## Buckets

  - `:interactive` — your daily Claude work. Shared with day job. Tracked
    here for visibility, not for hard-capping (Anthropic enforces the cap).
  - `:sdk_pool` — Tracy's `claude -p` calls. $100/mo cap that Tracy DOES
    enforce, with graceful wind-down.

  ## Caps (locked decision)

      :sdk_pool_monthly_micros — $100.00 → 100_000_000 micros
      :sdk_pool_caution_pct    — 50
      :sdk_pool_winddown_pct   — 75
      :sdk_pool_hardstop_pct   — 85
  """
  import Ecto.Query

  alias Tracy.Billing.AgentRun
  alias Tracy.Repo

  @sdk_pool_monthly_micros 100_000_000
  @caution_pct 50
  @winddown_pct 75
  @hardstop_pct 85

  @doc "Constant: the monthly SDK pool ceiling, in micros (= $100)."
  def sdk_pool_monthly_micros, do: @sdk_pool_monthly_micros

  @doc "Record a finished agent run."
  @spec record_run(map()) :: {:ok, AgentRun.t()} | {:error, Ecto.Changeset.t()}
  def record_run(attrs) do
    %AgentRun{}
    |> AgentRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Recent runs, optionally scoped by session or role."
  def recent_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    AgentRun
    |> maybe_eq(:session_id, opts[:session_id])
    |> maybe_eq(:role, opts[:role])
    |> maybe_eq(:bucket, opts[:bucket])
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Sum of cost micros for a bucket within an interval.
  Defaults to the current calendar month (UTC) and the SDK pool.
  """
  def spend_micros(opts \\ []) do
    bucket = Keyword.get(opts, :bucket, "sdk_pool")
    {from_dt, to_dt} = Keyword.get_lazy(opts, :window, &current_month_window/0)

    AgentRun
    |> where([r], r.bucket == ^bucket)
    |> where([r], r.started_at >= ^from_dt and r.started_at < ^to_dt)
    |> select([r], coalesce(sum(r.cost_micros), 0))
    |> Repo.one()
    |> to_integer()
  end

  @doc """
  Summarise spend + token counts + run count for a (bucket, window) pair.

  Returns `%{cost_micros, cost_dollars, input_tokens, output_tokens, runs}`.
  """
  def usage_summary(opts \\ []) do
    bucket = Keyword.get(opts, :bucket, "sdk_pool")
    {from_dt, to_dt} = Keyword.get_lazy(opts, :window, &current_month_window/0)

    row =
      AgentRun
      |> where([r], r.bucket == ^bucket)
      |> where([r], r.started_at >= ^from_dt and r.started_at < ^to_dt)
      |> select([r], %{
        cost_micros: coalesce(sum(r.cost_micros), 0),
        input_tokens: coalesce(sum(r.input_tokens), 0),
        output_tokens: coalesce(sum(r.output_tokens), 0),
        runs: count(r.id)
      })
      |> Repo.one()

    cost_micros = to_integer(row.cost_micros)

    %{
      cost_micros: cost_micros,
      cost_dollars: cost_micros / 1_000_000,
      input_tokens: to_integer(row.input_tokens),
      output_tokens: to_integer(row.output_tokens),
      runs: to_integer(row.runs),
      bucket: bucket,
      from: from_dt,
      to: to_dt
    }
  end

  @doc """
  Quick-view summaries for the boardroom header.

  Returns three maps:

    * `:hour` — last 60 minutes, both buckets combined
    * `:week` — rolling 7 days, both buckets combined
    * `:sdk_pool_month` — current calendar-month SDK pool spend (with cap + zone)

  All time windows are computed against `DateTime.utc_now/0`.
  """
  def boardroom_meters do
    now = DateTime.utc_now()
    hour_ago = DateTime.add(now, -1, :hour)
    week_ago = DateTime.add(now, -7, :day)

    %{
      hour: combined_summary(window: {hour_ago, now}),
      week: combined_summary(window: {week_ago, now}),
      sdk_pool_month: sdk_pool_status()
    }
  end

  defp combined_summary(opts) do
    sdk = usage_summary(Keyword.merge(opts, bucket: "sdk_pool"))
    inter = usage_summary(Keyword.merge(opts, bucket: "interactive"))

    %{
      cost_micros: sdk.cost_micros + inter.cost_micros,
      cost_dollars: sdk.cost_dollars + inter.cost_dollars,
      input_tokens: sdk.input_tokens + inter.input_tokens,
      output_tokens: sdk.output_tokens + inter.output_tokens,
      runs: sdk.runs + inter.runs,
      sdk_micros: sdk.cost_micros,
      interactive_micros: inter.cost_micros,
      from: opts[:window] |> elem(0),
      to: opts[:window] |> elem(1)
    }
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(nil), do: 0

  @doc """
  Pull the cost meter state for the SDK pool: spend, %, status zone.
  Returns a map suitable for the boardroom UI.
  """
  def sdk_pool_status(opts \\ []) do
    micros = spend_micros(Keyword.merge([bucket: "sdk_pool"], opts))
    cap = @sdk_pool_monthly_micros
    pct = (micros / cap * 100) |> Float.round(2)

    %{
      bucket: :sdk_pool,
      spent_micros: micros,
      spent_dollars: micros / 1_000_000,
      cap_micros: cap,
      cap_dollars: cap / 1_000_000,
      pct: pct,
      zone: zone_for(pct),
      caution_pct: @caution_pct,
      winddown_pct: @winddown_pct,
      hardstop_pct: @hardstop_pct
    }
  end

  @doc """
  Should a new SDK-pool call be allowed?

  Returns:
    * `:ok` — go
    * `{:caution, pct}` — near 75% — caller should consider being terse
    * `{:winddown, pct}` — past 75% — caller should wrap up
    * `{:hardstop, pct}` — past 85% — caller MUST refuse the call
  """
  def gate_sdk_pool(opts \\ []) do
    %{pct: pct} = sdk_pool_status(opts)

    cond do
      pct >= @hardstop_pct -> {:hardstop, pct}
      pct >= @winddown_pct -> {:winddown, pct}
      pct >= @caution_pct -> {:caution, pct}
      true -> :ok
    end
  end

  # ---- helpers ----

  defp maybe_eq(query, _field, nil), do: query
  defp maybe_eq(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  defp current_month_window do
    now = DateTime.utc_now()
    start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
    next_month_start = add_month(start)
    {start, next_month_start}
  end

  defp add_month(%DateTime{year: y, month: 12} = dt), do: %{dt | year: y + 1, month: 1}
  defp add_month(%DateTime{month: m} = dt), do: %{dt | month: m + 1}

  defp zone_for(pct) when pct >= @hardstop_pct, do: :hardstop
  defp zone_for(pct) when pct >= @winddown_pct, do: :winddown
  defp zone_for(pct) when pct >= @caution_pct, do: :caution
  defp zone_for(_), do: :normal
end

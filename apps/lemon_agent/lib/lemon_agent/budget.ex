defmodule LemonAgent.Budget do
  @moduledoc """
  Cumulative per-run and per-session provider usage limits.

  Tokens include input, output, cache reads and cache writes. Hourly cache writes
  are a subset of cache writes, not an additional charge. Costs are the provider's
  catalog-estimated dollar totals, not billing invoices. Usage is normally reported
  only at completion: an in-flight request can exceed a positive cap. Zero or
  already-spent caps prevent starting requests; exhaustion prevents tools and retries.
  Caps cover the prompt agent loop, its reported retry attempts and native task/
  swarm descendants, not separate compaction/project-memory maintenance calls.
  Descendant totals are enforcement-only; provider usage reports remain per-session.

  Session totals are independent of conversation history. Start a new run with
  `new/2` and the previous session totals; never derive a reset from a cleared or
  compacted transcript. `record_message/2` records one terminal provider report;
  callers must not record both its final event and its message-end event.
  """

  @type usage :: %{tokens: non_neg_integer(), cost_usd: non_neg_integer() | float()}
  @type t :: %{limits: map(), run_usage: usage(), session_usage: usage()}
  @type details :: %{
          reason: :budget_exceeded,
          scope: :run | :session,
          metric: :tokens | :cost_usd,
          limit: number(),
          used: number(),
          run_usage: usage(),
          session_usage: usage(),
          message: String.t()
        }

  @zero %{tokens: 0, cost_usd: 0.0}
  @caps [
    {:max_run_tokens, :run, :tokens},
    {:max_run_cost_usd, :run, :cost_usd},
    {:max_session_tokens, :session, :tokens},
    {:max_session_cost_usd, :session, :cost_usd}
  ]

  @spec new(map() | nil, map() | nil) :: t()
  def new(limits, initial_session_usage) do
    %{
      limits: limits || %{},
      run_usage: @zero,
      session_usage: normalize_usage(initial_session_usage)
    }
  end

  @doc "Whether any canonical cap is configured (including zero)."
  @spec enabled?(map() | nil) :: boolean()
  def enabled?(nil), do: false

  def enabled?(limits),
    do:
      is_pid(Map.get(limits, :scope)) or
        Enum.any?(@caps, fn {key, _, _} -> not is_nil(Map.get(limits, key)) end)

  @spec normalize_usage(term()) :: usage()
  def normalize_usage(usage) when is_map(usage) do
    %{
      tokens: token_count(field(usage, :tokens)),
      cost_usd: amount(field(usage, :cost_usd))
    }
  end

  def normalize_usage(_usage), do: @zero

  @spec usage_from_message(term()) :: usage()
  def usage_from_message(message) when is_map(message) do
    case field(message, :usage) do
      usage when is_map(usage) ->
        total = token_count(field(usage, :total_tokens))

        tokens =
          if total > 0 do
            total
          else
            token_count(field(usage, :input)) + token_count(field(usage, :output)) +
              token_count(field(usage, :cache_read)) + token_count(field(usage, :cache_write))
          end

        cost = field(usage, :cost)
        %{tokens: tokens, cost_usd: if(is_map(cost), do: amount(field(cost, :total)), else: 0.0)}

      _ ->
        @zero
    end
  end

  def usage_from_message(_message), do: @zero

  @spec add_usage(term(), term()) :: usage()
  def add_usage(first, second) do
    first = normalize_usage(first)
    second = normalize_usage(second)
    %{tokens: first.tokens + second.tokens, cost_usd: first.cost_usd + second.cost_usd}
  end

  @spec record_message(t(), term()) :: t()
  def record_message(state, message) do
    usage = usage_from_message(message)

    %{
      state
      | run_usage: add_usage(state.run_usage, usage),
        session_usage: add_usage(state.session_usage, usage)
    }
  end

  @doc "Warn when a dollar cap cannot reliably price the active model."
  def unpriced_warning(limits, model) do
    cost = Map.get(model, :cost)

    cost_capped =
      Enum.any?([:max_run_cost_usd, :max_session_cost_usd], &is_number(Map.get(limits, &1))) or
        LemonAgent.BudgetScope.cost_capped?(Map.get(limits, :scope))

    if cost_capped and
         (is_nil(cost) or
            Enum.all?([:input, :output, :cache_read, :cache_write], &(Map.get(cost, &1, 0) == 0))) do
      "Usage budget warning: the active model has no known catalog price. " <>
        "Dollar caps cannot bound unpriced usage; configure model pricing or token caps."
    end
  end

  @spec check(t() | nil) :: details() | nil
  def check(nil), do: nil

  def check(state) do
    Enum.find_value(@caps, fn {key, scope, metric} ->
      limit = Map.get(state.limits, key)
      usage = if scope == :run, do: state.run_usage, else: state.session_usage
      used = Map.fetch!(usage, metric)

      if is_number(limit) and used >= limit do
        unit = if metric == :tokens, do: "tokens", else: "USD (catalog-estimated)"

        %{
          reason: :budget_exceeded,
          scope: scope,
          metric: metric,
          limit: limit,
          used: used,
          run_usage: state.run_usage,
          session_usage: state.session_usage,
          message:
            "The #{scope} usage budget is exhausted: #{used} of #{limit} #{unit}. " <>
              "No further model requests or tools will run. Increase budgets.#{key} to continue."
        }
      end
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp token_count(value) when is_integer(value) and value >= 0, do: value
  defp token_count(_value), do: 0
  defp amount(value) when is_number(value) and value >= 0, do: value
  defp amount(_value), do: 0.0
end

defmodule LemonAgent.Budget do
  @moduledoc """
  Cumulative per-run and per-session provider usage limits.

  Tokens include input, output, cache reads and cache writes. Hourly cache writes
  are a subset of cache writes, not an additional charge. Costs are the provider's
  catalog-estimated dollar totals, not billing invoices. Before each request, the
  loop checks estimated prompt tokens and the maximum output against remaining
  caps. Estimates are not billing guarantees. Exhaustion prevents tools and retries.
  Caps cover the prompt agent loop, its reported retry attempts and native task/
  swarm descendants, not separate compaction/project-memory maintenance calls.
  Descendant totals are enforcement-only; provider usage reports remain per-session.

  Session totals are independent of conversation history. Start a new run with
  `new/2` and the previous session totals; never derive a reset from a cleared or
  compacted transcript. `record_message/2` records one terminal provider report;
  callers must not record both its final event and its message-end event.

  Enforcement totals retain unknown counters and dollar amounts as `nil`, separate
  from provider telemetry. Unknown accumulated or projected usage fails closed
  only when the corresponding metric is capped. Known zero prices remain valid;
  absent pricing never authorizes a dollar-capped request. Unknown totals remain
  unknown across subsequent reports and session restoration.
  """

  @type usage :: %{tokens: non_neg_integer() | nil, cost_usd: non_neg_integer() | float() | nil}
  @type t :: %{limits: map(), run_usage: usage(), session_usage: usage()}
  @type details :: %{
          reason: :budget_exceeded,
          scope: :run | :session,
          metric: :tokens | :cost_usd,
          limit: number(),
          used: number() | nil,
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
          if is_integer(total) and total > 0 do
            total
          else
            Enum.reduce([:input, :output, :cache_read, :cache_write], 0, fn key, sum ->
              add(sum, token_count(field(usage, key)))
            end)
          end

        cost = field(usage, :cost)
        %{tokens: tokens, cost_usd: if(is_map(cost), do: amount(field(cost, :total)))}

      _ ->
        if field(message, :role) in [:assistant, "assistant"],
          do: %{tokens: nil, cost_usd: nil},
          else: @zero
    end
  end

  def usage_from_message(_message), do: @zero

  @spec add_usage(term(), term()) :: usage()
  def add_usage(first, second) do
    first = normalize_usage(first)
    second = normalize_usage(second)
    %{tokens: add(first.tokens, second.tokens), cost_usd: add(first.cost_usd, second.cost_usd)}
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
            Enum.any?(
              [:input, :output, :cache_read, :cache_write],
              &(not is_number(Map.get(cost, &1)))
            )) do
      "Usage budget warning: the active model has no known catalog price for some usage. " <>
        "Dollar-capped requests are blocked until model pricing is configured."
    end
  end

  @doc "Project a request using catalog prices and its maximum output."
  def project(model, context, options) do
    input =
      Enum.reduce(context.messages, nil, fn message, previous ->
        usage = field(message, :usage)

        if is_map(usage) do
          count =
            Enum.reduce([:input, :cache_read, :cache_write], 0, fn key, sum ->
              add(sum, token_count(field(usage, key)))
            end)

          if is_integer(count) and count > 0, do: count, else: previous
        else
          previous
        end
      end) || div(characters(context) + 3, 4)

    output = token_count(options.max_tokens || model.max_tokens)
    cost = Map.get(model, :cost)

    dollars =
      if is_map(cost) do
        amount(
          LemonAi.calculate_cost(model, %LemonAi.Types.Usage{input: input, output: output}).total
        )
      else
        nil
      end

    %{tokens: add(input, output), cost_usd: dollars}
  end

  defp characters(value) when is_binary(value), do: String.length(value)
  defp characters(value) when is_list(value), do: Enum.reduce(value, 0, &(characters(&1) + &2))

  defp characters(value) when is_map(value) do
    :maps.fold(
      fn
        :__struct__, _item, count -> count
        key, item, count -> count + characters(key) + characters(item)
      end,
      0,
      value
    )
  end

  defp characters(_value), do: 0

  @spec check(t() | nil, usage()) :: details() | nil
  def check(state, projected \\ @zero)
  def check(nil, _projected), do: nil

  def check(state, projected) do
    projected = normalize_usage(projected)

    Enum.find_value(@caps, fn {key, scope, metric} ->
      limit = Map.get(state.limits, key)
      usage = if scope == :run, do: state.run_usage, else: state.session_usage
      used = Map.fetch!(usage, metric)

      projection = Map.fetch!(projected, metric)

      unknown = is_nil(used) or is_nil(projection)

      if is_number(limit) and (unknown or used >= limit or used + projection > limit) do
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
            if(unknown,
              do:
                "The #{scope} usage budget cannot be verified: accumulated or projected #{unit} is unknown. ",
              else:
                "The #{scope} usage budget is exhausted: #{used} of #{limit} #{unit}. " <>
                  if(used < limit,
                    do: "The next request is projected to exceed it (#{projection} #{unit}). ",
                    else: ""
                  )
            ) <>
              if(unknown,
                do:
                  "No further model requests or tools will run. Supply complete usage and pricing " <>
                    "or remove budgets.#{key} to continue.",
                else:
                  "No further model requests or tools will run. Increase budgets.#{key} to continue."
              )
        }
      end
    end)
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp token_count(value) when is_integer(value) and value >= 0, do: value
  defp token_count(_value), do: nil
  defp amount(value) when is_number(value) and value >= 0, do: value
  defp amount(_value), do: nil

  defp add(first, second) when is_number(first) and is_number(second), do: first + second
  defp add(_first, _second), do: nil
end

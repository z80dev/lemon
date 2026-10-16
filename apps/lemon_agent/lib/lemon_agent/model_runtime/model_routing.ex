defmodule LemonAgent.ModelRuntime.ModelRouting do
  @moduledoc """
  Opt-in, ordered model selection with a per-request catalog cost projection.

  `prepare/2` validates configuration and resolves every rule up front. Disabled
  configuration returns `nil` without inspecting inactive fields or resolving
  models. `select/4` uses only the latest user message for rule matching; all
  supplied matchers must match, and the first matching rule wins. A rejected
  candidate never falls through to a cheaper rule.

  The cap is not an invoice guarantee or a cumulative usage budget. The projection
  counts binary bytes in the prompt, messages and tools as input tokens and uses
  the requested output limit, or the model's catalog maximum when omitted or
  when Anthropic manual thinking can expand it. It conservatively prices cache
  writes at the long-retention multiplier (1.6), considers long-context and
  service-tier prices, and fails closed when prices or the output bound are unknown.
  """

  alias LemonAi.Types.Model

  @type rule :: %{
          required(:model) => Model.t(),
          optional(:contains) => String.t(),
          optional(:min_chars) => non_neg_integer(),
          optional(:max_chars) => non_neg_integer()
        }
  @type policy :: %{max_cost_usd: number(), rules: [rule()]}

  @doc "Validate enabled routing configuration and resolve its model selectors."
  @spec prepare(map() | nil, (String.t() -> Model.t()), map()) :: policy() | nil
  def prepare(raw, resolver, providers \\ %{})
  def prepare(nil, _resolver, _providers), do: nil

  def prepare(raw, resolver, providers) when is_map(raw) do
    case value(raw, :enabled) do
      enabled when enabled in [nil, false] ->
        nil

      true ->
        raw |> prepare_enabled(resolver) |> Map.put(:unknown_prices, unknown_prices(providers))

      _ ->
        invalid!("enabled must be a boolean")
    end
  end

  def prepare(_raw, _resolver, _providers), do: invalid!("must be a table")

  defp prepare_enabled(raw, resolver) do
    known_keys!(raw, [:enabled, :max_cost_usd, :rules])
    cap = value(raw, :max_cost_usd)
    unless nonnegative_finite?(cap), do: invalid!("max_cost_usd must be finite and nonnegative")
    unless is_function(resolver, 1), do: invalid!("model resolver must accept one selector")
    rules = if present?(raw, :rules), do: value(raw, :rules), else: []
    unless is_list(rules), do: invalid!("rules must be an ordered list")
    %{max_cost_usd: cap, rules: Enum.map(rules, &prepare_rule(&1, resolver))}
  end

  defp prepare_rule(raw, resolver) when is_map(raw) do
    known_keys!(raw, [:model, :contains, :min_chars, :max_chars])
    selector = value(raw, :model)

    unless is_binary(selector) and String.trim(selector) != "" do
      invalid!("rule model must be a nonempty selector")
    end

    matchers =
      Enum.reduce([:contains, :min_chars, :max_chars], %{}, fn key, acc ->
        if present?(raw, key) do
          matcher = value(raw, key)

          valid? =
            case key do
              :contains -> is_binary(matcher)
              _ -> is_integer(matcher) and matcher >= 0
            end

          unless valid?,
            do: invalid!("rule matchers must contain text or nonnegative integer bounds")

          Map.put(acc, key, if(key == :contains, do: String.downcase(matcher), else: matcher))
        else
          acc
        end
      end)

    if Map.has_key?(matchers, :min_chars) and Map.has_key?(matchers, :max_chars) and
         matchers.min_chars > matchers.max_chars do
      invalid!("rule min_chars must not exceed max_chars")
    end

    model =
      try do
        resolver.(selector)
      rescue
        _ -> invalid!("rule model could not be resolved")
      catch
        _, _ -> invalid!("rule model could not be resolved")
      end

    case model do
      %Model{id: id} when is_binary(id) and byte_size(id) > 0 -> Map.put(matchers, :model, model)
      _ -> invalid!("rule model could not be resolved")
    end
  end

  defp prepare_rule(_raw, _resolver), do: invalid!("each rule must be a table")

  @doc "Select the first matching model and enforce its projected request cost."
  @spec select(policy() | nil, Model.t(), map(), map() | keyword()) ::
          {:ok, Model.t()} | {:error, :model_routing_cost_cap}
  def select(nil, default_model, _llm_context, _stream_options), do: {:ok, default_model}

  def select(policy, default_model, llm_context, stream_options) do
    text = latest_user_text(llm_context)
    chars = String.length(text)
    folded = String.downcase(text)

    rule =
      Enum.find(policy.rules, fn rule ->
        (not Map.has_key?(rule, :contains) or String.contains?(folded, rule.contains)) and
          (not Map.has_key?(rule, :min_chars) or chars >= rule.min_chars) and
          (not Map.has_key?(rule, :max_chars) or chars <= rule.max_chars)
      end)

    model = if rule, do: rule.model, else: default_model

    case check_cap(policy, model, llm_context, stream_options) do
      :ok -> {:ok, model}
      error -> error
    end
  end

  @doc "Enforce the routing cap for a concrete model, including provider fallbacks."
  @spec check_cap(policy() | nil, Model.t(), map(), map() | keyword()) ::
          :ok | {:error, :model_routing_cost_cap}
  def check_cap(nil, _model, _llm_context, _stream_options), do: :ok

  def check_cap(policy, model, llm_context, stream_options) do
    unknown = Map.get(policy, :unknown_prices)
    identity = {provider_name(model.provider), model.id}

    if (is_nil(unknown) or not MapSet.member?(unknown, identity)) and
         within_cap?(model, policy.max_cost_usd, llm_context, stream_options),
       do: :ok,
       else: {:error, :model_routing_cost_cap}
  end

  # Configured additions can inherit an unrelated template's nonzero prices.
  # Only an exact catalog identity attests omitted pricing under a routing cap.
  defp unknown_prices(providers) do
    catalog =
      MapSet.new(LemonAi.Models.list_models(), &{provider_name(&1.provider), &1.id})

    for {provider, config} <- providers,
        entry <- value(config, :models) || [],
        is_map(entry),
        identity = {provider_name(provider), value(entry, :id)},
        unknown_configured_prices?(entry, identity, catalog),
        into: MapSet.new(),
        do: identity
  end

  defp unknown_configured_prices?(entry, identity, catalog) do
    if present?(entry, :cost),
      do: not known_prices?(value(entry, :cost)),
      else: not MapSet.member?(catalog, identity)
  end

  defp provider_name(provider),
    do: LemonAgent.ModelRuntime.ProviderNames.canonical_name(provider) || to_string(provider)

  defp latest_user_text(context) do
    context
    |> value(:messages)
    |> Kernel.||([])
    |> Enum.reduce(nil, fn message, latest ->
      if value(message, :role) in [:user, "user"], do: value(message, :content), else: latest
    end)
    |> user_text()
  end

  defp user_text(text) when is_binary(text), do: text

  defp user_text(blocks) when is_list(blocks) do
    Enum.map_join(blocks, "", fn block ->
      if is_map(block) and value(block, :type) in [:text, "text"] do
        case value(block, :text) do
          text when is_binary(text) -> text
          _ -> ""
        end
      else
        ""
      end
    end)
  end

  defp user_text(_content), do: ""

  defp within_cap?(%Model{} = model, cap, context, options) do
    output =
      case option(options, :max_tokens) do
        nil -> model.max_tokens
        maximum -> maximum
      end

    with true <- is_integer(model.max_tokens) and model.max_tokens > 0,
         true <- is_integer(output) and output > 0 and output <= model.max_tokens,
         output = effective_output_bound(model, output, options),
         {:ok, input_rate, output_rate} <- rates(model.cost),
         {:ok, multiplier} <- tier_multiplier(model.service_tier_cost) do
      input =
        binary_bytes(value(context, :system_prompt)) +
          binary_bytes(value(context, :messages)) + binary_bytes(value(context, :tools))

      projected = (input * input_rate + output * output_rate) * multiplier / 1_000_000
      nonnegative_finite?(projected) and projected <= cap
    else
      _ -> false
    end
  rescue
    ArithmeticError -> false
  end

  defp within_cap?(_model, _cap, _context, _options), do: false

  # The Anthropic provider may raise max_tokens to fit a manual thinking budget.
  # Use its hard catalog ceiling rather than duplicate provider budget arithmetic
  # (including caller-supplied budgets and the minimum non-thinking output room).
  defp effective_output_bound(model, output, options) do
    if model.api == :anthropic_messages and model.reasoning and
         not model.adaptive_thinking and option(options, :reasoning) not in [nil, false],
       do: model.max_tokens,
       else: output
  end

  defp rates(cost) when is_map(cost) do
    variants =
      case value(cost, :long_context) do
        nil -> [cost]
        long when is_map(long) -> [cost, long]
        _ -> []
      end

    if variants != [] and Enum.all?(variants, &known_prices?/1) do
      input =
        Enum.reduce(variants, 0, fn prices, rate ->
          cache_rate = max(value(prices, :cache_read), value(prices, :cache_write) * 1.6)
          max(rate, max(value(prices, :input), cache_rate))
        end)

      output = variants |> Enum.map(&value(&1, :output)) |> Enum.max()
      {:ok, input, output}
    else
      :error
    end
  end

  defp rates(_cost), do: :error

  defp known_prices?(prices) do
    rates = Enum.map([:input, :output, :cache_read, :cache_write], &value(prices, &1))
    Enum.all?(rates, &nonnegative_finite?/1) and Enum.any?(rates, &(&1 > 0))
  end

  defp tier_multiplier(tiers) when is_map(tiers) do
    values = Map.values(tiers)

    if Enum.all?(values, &nonnegative_finite?/1),
      do: {:ok, Enum.reduce(values, 1, &max/2)},
      else: :error
  end

  defp tier_multiplier(_tiers), do: :error

  defp binary_bytes(binary) when is_binary(binary), do: byte_size(binary)
  defp binary_bytes(list) when is_list(list), do: Enum.reduce(list, 0, &(binary_bytes(&1) + &2))

  defp binary_bytes(map) when is_map(map) do
    :maps.fold(
      fn
        :__struct__, _, bytes -> bytes
        key, value, bytes -> bytes + binary_bytes(key) + binary_bytes(value)
      end,
      0,
      map
    )
  end

  defp binary_bytes(_value), do: 0

  defp nonnegative_finite?(value) when is_integer(value), do: value >= 0

  defp nonnegative_finite?(value) when is_float(value),
    do: value >= 0 and value <= 1.797_693_134_862_315_7e308

  defp nonnegative_finite?(_value), do: false

  defp option(options, key) when is_list(options), do: Keyword.get(options, key)
  defp option(options, key), do: value(options, key)

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
  defp present?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp known_keys!(map, allowed) do
    allowed = allowed ++ Enum.map(allowed, &Atom.to_string/1)

    unless Enum.all?(Map.keys(map), &(&1 in allowed)),
      do: invalid!("contains unknown configuration keys")

    if Enum.any?(Map.keys(map), fn key ->
         is_atom(key) and Map.has_key?(map, Atom.to_string(key))
       end) do
      invalid!("contains duplicate configuration keys")
    end
  end

  defp invalid!(message), do: raise(ArgumentError, "model_routing " <> message)
end

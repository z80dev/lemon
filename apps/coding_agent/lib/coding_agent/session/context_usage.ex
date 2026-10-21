defmodule CodingAgent.Session.ContextUsage do
  @moduledoc """
  Per-category accounting of the request context a native session would send:
  system prompt, tool definitions, skills, context files, memory, user and
  assistant messages, tool results and summaries, against the model window.

  The total is the same request measurement automatic compaction uses
  (`CodingAgent.Compaction.request_context_usage/4`): the latest successful
  provider-reported usage plus estimates for newer messages, or a pure estimate
  before any usage exists. Category splits always come from the shared ~4
  chars/token estimator. When the total is provider-reported, the categories are
  scaled proportionally (largest remainder) so they sum exactly to it; when it is
  an estimate, they sum to it unscaled.

  System prompt and tool definitions only exist in a live session. Sessions stop
  between turns, so each save records a bounded *overhead profile* — token counts
  and safe labels per prompt section and tool, never prompt text — keyed by the
  native session id. A durable read combines that profile with messages from the
  session file; without one, the overhead is reported as `:unattributed`.
  """

  alias CodingAgent.Compaction
  alias CodingAgent.Session.{CompactionManager, ContextBudget}

  @message_categories [:user_messages, :assistant_messages, :tool_results, :summaries]
  @overhead_categories [:system_prompt, :tool_definitions, :skills, :context_files, :memory]
  @categories @overhead_categories ++ @message_categories
  @overhead_table :session_context_overhead
  @top_limit 10
  @label_max 80

  @type category ::
          :system_prompt
          | :tool_definitions
          | :skills
          | :context_files
          | :memory
          | :user_messages
          | :assistant_messages
          | :tool_results
          | :summaries
          | :unattributed

  @type item :: %{category: category(), label: String.t(), tokens: non_neg_integer()}
  @type overhead :: %{items: [item()], measured_at: integer()}

  @doc "Standard category ids in display order."
  @spec categories() :: [category()]
  def categories, do: @categories

  @doc """
  Measure a live session. `state` is the `CodingAgent.Session` state and
  `agent_state` the agent loop state holding the exact system prompt, tools and
  wire messages. `opts[:strip_recall]` returns a user message without its
  automatic recall block (defaults to identity).
  """
  @spec measure(map(), map(), keyword()) :: map()
  def measure(state, agent_state, opts \\ []) do
    messages = agent_state.messages || []
    usage_after = ContextBudget.usage_boundary(state.session_manager)

    budget =
      Compaction.request_context_usage(
        messages,
        agent_state.system_prompt,
        agent_state.tools || [],
        usage_after
      )

    report(%{
      live: true,
      overhead_source: :live,
      overhead: overhead(state, agent_state).items,
      message_items: message_items(messages, Keyword.get(opts, :strip_recall, & &1)),
      message_count: length(messages),
      budget: budget,
      model: state.model,
      session_manager: state.session_manager,
      budget_usage: Map.get(state, :budget_usage),
      settings_manager: state.settings_manager
    })
  end

  @doc """
  Measure a stopped session from its durable history. `overhead` is the profile
  recorded by `record_overhead/2`, or `nil`. Returns `{:error, :unavailable}` when
  neither provider usage nor a recorded profile exists, since messages alone
  would understate the request.
  """
  @spec measure_durable(map(), [map()], overhead() | nil) :: {:ok, map()} | {:error, :unavailable}
  def measure_durable(
        %{session_manager: _, model: _, settings_manager: _} = state,
        messages,
        overhead
      ) do
    usage_after = ContextBudget.usage_boundary(state.session_manager)
    budget = Compaction.request_context_usage(messages, nil, [], usage_after)

    if budget.source == "estimate" and is_nil(overhead) do
      {:error, :unavailable}
    else
      {:ok,
       report(%{
         live: false,
         overhead_source: if(overhead, do: :snapshot, else: :unavailable),
         overhead: if(overhead, do: overhead.items, else: []),
         message_items: message_items(messages, & &1),
         message_count: length(messages),
         budget: budget,
         model: state.model,
         session_manager: state.session_manager,
         budget_usage: Map.get(state, :budget_usage),
         settings_manager: state.settings_manager
       })}
    end
  end

  @doc """
  The overhead profile of the request: one item per labelled system-prompt
  section actually present in the prompt being sent, any remaining prompt text
  (planning guidance, a frozen snapshot prompt), and one item per tool.
  """
  @spec overhead(map(), map()) :: overhead()
  def overhead(state, agent_state) do
    prompt = agent_state.system_prompt || ""
    sections = Map.get(state, :prompt_sections) || []

    section_items =
      for %{category: category, label: label, text: text} <- sections,
          is_binary(text) and text != "",
          :binary.match(prompt, text) != :nomatch,
          do: item(category, label, Compaction.estimate_text_tokens(text))

    attributed = Enum.reduce(section_items, 0, &(&1.tokens + &2))
    remainder = max(Compaction.estimate_text_tokens(prompt) - attributed, 0)

    remainder_items =
      cond do
        remainder == 0 -> []
        section_items == [] -> [item(:system_prompt, "System prompt", remainder)]
        true -> [item(:system_prompt, "Other system prompt text", remainder)]
      end

    tool_items =
      for tool <- agent_state.tools || [],
          do:
            item(
              :tool_definitions,
              to_string(Map.get(tool, :name) || "tool"),
              Compaction.estimate_tool_definition_tokens(tool)
            )

    %{
      items: section_items ++ remainder_items ++ tool_items,
      measured_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Persist `profile` for `session_id` when it differs from `previous` (compared
  by items). Returns the profile now on record. Storage failures are ignored:
  accounting is diagnostic and must never fail a save.
  """
  @spec record_overhead(String.t() | nil, overhead(), overhead() | nil) :: overhead() | nil
  def record_overhead(session_id, profile, previous \\ nil)

  def record_overhead(session_id, %{items: items} = profile, previous)
      when is_binary(session_id) and session_id != "" do
    if previous && previous.items == items do
      previous
    else
      stored = %{
        items: Enum.map(items, &%{&1 | category: Atom.to_string(&1.category)}),
        measured_at: profile.measured_at
      }

      case LemonCore.Store.put(@overhead_table, session_id, stored) do
        :ok -> profile
        _ -> previous
      end
    end
  rescue
    _ -> previous
  catch
    :exit, _ -> previous
  end

  def record_overhead(_session_id, _profile, previous), do: previous

  @doc "The recorded overhead profile for a native session id, or `nil`."
  @spec stored_overhead(String.t()) :: overhead() | nil
  def stored_overhead(session_id) when is_binary(session_id) do
    case LemonCore.Store.get(@overhead_table, session_id) do
      %{items: items, measured_at: measured_at} when is_list(items) ->
        %{items: Enum.flat_map(items, &restore_item/1), measured_at: measured_at}

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp restore_item(%{category: category, label: label, tokens: tokens})
       when is_binary(label) and is_integer(tokens) and tokens >= 0 do
    case Enum.find(@overhead_categories, &(Atom.to_string(&1) == category)) do
      nil -> []
      atom -> [item(atom, label, tokens)]
    end
  end

  defp restore_item(_), do: []

  @doc """
  Itemise wire messages by category. A user message carrying an automatic
  recall block is split: the block counts as `:memory`, the rest as the user's.
  """
  @spec message_items([map()], (map() -> map())) :: [item()]
  def message_items(messages, strip_recall) do
    messages
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {message, index} -> classify(message, index, strip_recall) end)
  end

  defp classify(%{exclude_from_context: true}, _index, _strip), do: []

  defp classify(message, index, strip_recall) do
    tokens = Compaction.estimate_message_tokens(message)

    role =
      if CodingAgent.SessionManager.compaction_summary?(message),
        do: :compaction_summary,
        else: Map.get(message, :role)

    case role do
      role when role in [:user, :custom] ->
        own = message |> strip_recall.() |> Compaction.estimate_message_tokens() |> min(tokens)
        label = user_label(message, index)

        [item(:user_messages, label, own)] ++
          if tokens > own,
            do: [item(:memory, "Recalled memory ##{index}", tokens - own)],
            else: []

      :assistant ->
        [item(:assistant_messages, "Assistant reply ##{index}", tokens)]

      :tool_result ->
        [item(:tool_results, "#{tool_label(message)} result ##{index}", tokens)]

      :bash_execution ->
        [item(:tool_results, "Shell command output ##{index}", tokens)]

      :compaction_summary ->
        [item(:summaries, "Compaction summary ##{index}", tokens)]

      :branch_summary ->
        [item(:summaries, "Branch summary ##{index}", tokens)]

      _ ->
        [item(:user_messages, "Message ##{index}", tokens)]
    end
  end

  defp user_label(%{role: :custom, custom_type: type}, index) when is_binary(type) and type != "",
    do: "#{safe_name(type)} message ##{index}"

  defp user_label(_message, index), do: "User message ##{index}"

  defp tool_label(message) do
    case Map.get(message, :tool_name) do
      name when is_binary(name) and name != "" -> safe_name(name)
      _ -> "Tool"
    end
  end

  # Tool and custom-message names are identifiers; anything else is replaced.
  defp safe_name(name) do
    name = String.slice(name, 0, 40)
    if Regex.match?(~r/\A[A-Za-z0-9_.:\-]+\z/, name), do: name, else: "Tool"
  end

  defp item(category, label, tokens),
    do: %{category: category, label: bounded_label(label), tokens: max(tokens, 0)}

  defp bounded_label(label) when is_binary(label) do
    label
    |> String.replace(~r/[[:cntrl:]]+/u, " ")
    |> String.trim()
    |> String.slice(0, @label_max)
  end

  defp bounded_label(label), do: label |> to_string() |> bounded_label()

  # ---------------------------------------------------------------------------
  # Report
  # ---------------------------------------------------------------------------

  defp report(input) do
    raw_items = input.overhead ++ input.message_items
    raw_by_category = sum_by_category(raw_items)
    estimated = Enum.reduce(raw_items, 0, &(&1.tokens + &2))

    {used, categories, scale} =
      allocate(input.budget, raw_by_category, estimated, input.overhead_source)

    window = window(input.model)
    settings = compaction_settings(input.settings_manager)

    %{
      live: input.live,
      overhead: input.overhead_source,
      model: model_ref(input.model),
      window: window,
      used_tokens: used,
      free_tokens: if(window, do: max(window - used, 0)),
      percent_used: percent(used, window),
      source: input.budget.source,
      estimated_tokens: estimated,
      auto_compaction: auto_compaction(window, used, settings),
      categories:
        Enum.map(categories, fn {id, tokens, items} ->
          %{id: id, tokens: tokens, percent: percent(tokens, window), items: items}
        end),
      top: top(raw_items, scale),
      message_count: input.message_count,
      usage: session_usage(input.session_manager, input.budget_usage),
      measured_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Cumulative budget spend plus provider token breakdown. `tokens`/`cost_usd`
  come from the persisted `BudgetLedger` (every branch, interrupted requests
  included); an incomplete cumulative metric remains unknown (`nil`).
  Input/output/cache counts sum provider usage on the active branch; a missing
  counter makes that counter's branch total unknown (`nil`), not zero.
  """
  @spec session_usage(term(), map() | nil) :: map()
  def session_usage(session_manager, ledger \\ nil) do
    branch = branch_entries(session_manager)

    totals =
      Enum.reduce(branch, empty_usage(), fn
        %{type: :message, message: message}, acc when is_map(message) ->
          if field(message, :role) in [:assistant, "assistant"],
            do: add_message_usage(acc, field(message, :usage)),
            else: acc

        _entry, acc ->
          acc
      end)

    ledger = if is_map(ledger), do: ledger, else: ledger_usage(session_manager)

    Map.merge(totals, LemonAgent.Budget.normalize_usage(ledger))
  end

  defp empty_usage,
    do: %{
      tokens: 0,
      cost_usd: 0.0,
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      assistant_messages: 0
    }

  defp add_message_usage(acc, usage) do
    usage = if is_map(usage), do: usage, else: %{}

    %{
      acc
      | input: add_counter(acc.input, field(usage, :input)),
        output: add_counter(acc.output, field(usage, :output)),
        cache_read: add_counter(acc.cache_read, field(usage, :cache_read)),
        cache_write: add_counter(acc.cache_write, field(usage, :cache_write)),
        assistant_messages: acc.assistant_messages + 1
    }
  end

  defp add_counter(total, value)
       when is_integer(total) and is_integer(value) and value >= 0,
       do: total + value

  defp add_counter(_total, _value), do: nil

  defp branch_entries(%CodingAgent.SessionManager.Session{} = session),
    do: CodingAgent.SessionManager.get_branch(session)

  defp branch_entries(_), do: []

  defp ledger_usage(%CodingAgent.SessionManager.Session{} = session),
    do: CodingAgent.Session.BudgetLedger.restore(session)

  defp ledger_usage(_), do: LemonAgent.Budget.normalize_usage(nil)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp sum_by_category(items) do
    Enum.reduce(items, %{}, fn %{category: category, tokens: tokens}, acc ->
      Map.update(acc, category, {tokens, 1}, fn {sum, count} -> {sum + tokens, count + 1} end)
    end)
  end

  # Returns {used, [{category, tokens, item_count}], scale}. Every standard
  # category is present; `:unattributed` only when the overhead is unknown.
  defp allocate(%{source: "estimate"}, raw, estimated, _overhead_source) do
    {estimated, rows(raw, raw, []), 1.0}
  end

  defp allocate(%{tokens: total}, raw, estimated, :unavailable) do
    messages = estimated

    if messages <= total do
      {total, rows(raw, raw, [{:unattributed, total - messages, 0}]), 1.0}
    else
      {total, rows(raw, scale_categories(raw, total), [{:unattributed, 0, 0}]), total / messages}
    end
  end

  defp allocate(%{tokens: total}, raw, estimated, _overhead_source) when estimated > 0 do
    {total, rows(raw, scale_categories(raw, total), []), total / estimated}
  end

  defp allocate(%{tokens: total}, raw, _estimated, _overhead_source) do
    {total, rows(raw, raw, [{:unattributed, total, 0}]), 1.0}
  end

  defp rows(raw, tokens_by_category, extra) do
    standard =
      Enum.map(@categories, fn category ->
        {_raw_tokens, count} = Map.get(raw, category, {0, 0})
        {tokens, _} = Map.get(tokens_by_category, category, {0, 0})
        {category, tokens, count}
      end)

    standard ++ Enum.reject(extra, fn {_, tokens, _} -> tokens == 0 end)
  end

  # Largest-remainder apportionment of `total` across categories by raw share.
  defp scale_categories(raw, total) do
    sum = raw |> Map.values() |> Enum.reduce(0, fn {tokens, _}, acc -> acc + tokens end)

    shares =
      Enum.map(raw, fn {category, {tokens, count}} ->
        exact = tokens * total / sum
        floor = trunc(exact)
        {category, floor, exact - floor, count}
      end)

    leftover = total - Enum.reduce(shares, 0, fn {_, floor, _, _}, acc -> acc + floor end)

    shares
    |> Enum.sort_by(fn {category, _, fraction, _} -> {-fraction, category} end)
    |> Enum.with_index()
    |> Map.new(fn {{category, floor, _fraction, count}, rank} ->
      {category, {floor + if(rank < leftover, do: 1, else: 0), count}}
    end)
  end

  defp top(items, scale) do
    items
    |> Enum.map(&%{&1 | tokens: round(&1.tokens * scale)})
    |> Enum.reject(&(&1.tokens == 0))
    |> Enum.sort_by(& &1.tokens, :desc)
    |> Enum.take(@top_limit)
  end

  defp window(%{context_window: window}) when is_integer(window) and window > 0, do: window
  defp window(_), do: nil

  defp percent(_tokens, nil), do: nil
  defp percent(tokens, window), do: Float.round(tokens * 100 / window, 1)

  defp model_ref(%{provider: provider, id: id}) when not is_nil(id),
    do: %{provider: to_string(provider), id: to_string(id)}

  defp model_ref(_), do: nil

  defp compaction_settings(nil), do: %{}

  defp compaction_settings(settings_manager) do
    CompactionManager.get_compaction_settings(settings_manager)
  rescue
    _ -> %{}
  end

  defp auto_compaction(nil, _used, _settings), do: nil

  defp auto_compaction(window, used, settings) do
    threshold = Compaction.context_threshold(window, settings)

    %{
      enabled: Map.get(settings, :enabled, true),
      threshold_tokens: threshold,
      reserve_tokens: window - threshold,
      headroom_tokens: max(threshold - used, 0)
    }
  end
end

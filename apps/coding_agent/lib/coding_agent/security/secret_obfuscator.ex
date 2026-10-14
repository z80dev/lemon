defmodule CodingAgent.Security.SecretObfuscator do
  @moduledoc """
  Opt-in replacement of secrets in provider-visible session text
  (`[runtime.secret_obfuscation] enabled = true`).

  Secrets are collected once when a session starts:

    * environment variables whose name matches `KEY`, `SECRET`, `TOKEN`,
      `PASSWORD`, `PASS`, `AUTH`, `CREDENTIAL`, `PRIVATE` or `OAUTH` (followed by
      `_` or the end of the name, case-insensitive) with a value of at least 8
      characters;
    * `secrets.yml` entries from `<agent_dir>/secrets.yml` and
      `<cwd>/.lemon/secrets.yml` (project entries override global entries with
      the same `content`);
    * a built-in reversible regex for GitHub-, GitLab-, OpenAI- and
      Anthropic-style credential tokens.

  `transform/2` runs in the session's pre-LLM transform chain and rewrites an
  ephemeral copy of the messages; persisted history keeps the original text.
  Obfuscate-mode secrets become deterministic placeholders such as
  `$$3P8W5JH1TK2Q:L$$` or `$$GITHUBTOKEN_3P8W5JH1TK2Q:L$$`, whose base is an
  HMAC of the exact secret under the per-install key in
  `<agent_dir>/secret-placeholder.key`. `wrap_tools/2` restores those
  placeholders in model-authored tool arguments before a tool runs.
  Replace-mode secrets are rewritten one way and never restored. The system
  prompt is not passed through the transform chain and is not obfuscated.

  The obfuscator keeps its placeholder table in a public ETS table owned by the
  process that built it (the session), so the transform and the tool wrappers
  share regex-discovered placeholders.
  """

  alias CodingAgent.Security.SecretObfuscator.{Loader, Placeholder, Replacement}
  alias LemonAgent.Types.AgentTool

  @min_obfuscate_len 8

  defstruct [
    :table,
    :key_path,
    replace: [],
    obfuscate: [],
    regexes: [],
    sanitized_values: [],
    configured_values: MapSet.new()
  ]

  @type t :: %__MODULE__{}

  @doc """
  Build the session obfuscator when `[runtime.secret_obfuscation]` is enabled;
  returns nil otherwise. See `build/1` for `opts`.
  """
  @spec for_session(term(), String.t(), keyword()) :: t() | nil
  def for_session(settings, cwd, opts \\ [])

  def for_session(%{secret_obfuscation_enabled: true}, cwd, opts),
    do: build(Keyword.put(opts, :cwd, cwd))

  def for_session(_settings, _cwd, _opts), do: nil

  @doc """
  Build an obfuscator from every secret source.

  Options: `:cwd` (required), `:agent_dir` (default `CodingAgent.Config.agent_dir/0`),
  `:env` (default `System.get_env/0`), `:key_path` (default
  `<agent_dir>/secret-placeholder.key`).
  """
  @spec build(keyword()) :: t()
  def build(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    agent_dir = Keyword.get_lazy(opts, :agent_dir, &CodingAgent.Config.agent_dir/0)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    configured = Loader.env_entries(env) ++ Loader.file_entries(cwd, agent_dir)
    entries = configured ++ Loader.builtin_entries()
    plain = Enum.filter(entries, &(&1.type == :plain))
    configured_values = MapSet.new(plain, & &1.content)

    obfuscator = %__MODULE__{
      table: :ets.new(__MODULE__, [:set, :public, read_concurrency: true]),
      key_path: Keyword.get(opts, :key_path, Placeholder.key_path(agent_dir)),
      regexes: Enum.flat_map(entries, &compile_entry/1),
      configured_values: configured_values,
      sanitized_values: Enum.map(configured_values, &Placeholder.sanitize_for_collision/1)
    }

    # Configured placeholder-minting entries create the key up front; otherwise
    # it is created lazily when the built-in token regex first matches. An
    # existing key is always loaded so its bytes are redacted from tool output.
    if Enum.any?(configured, &needs_key?/1) do
      key(obfuscator)
    else
      load_existing_key(obfuscator)
    end

    replace =
      plain
      |> Enum.filter(&(&1.mode == :replace))
      |> Map.new(&{&1.content, &1[:replacement] || default_replacement(&1.content)})
      |> by_length_desc()

    obfuscate =
      plain
      |> Enum.filter(&(&1.mode == :obfuscate and text_length(&1.content) >= @min_obfuscate_len))
      |> Map.new(&{&1.content, &1[:friendly_name]})
      |> by_length_desc()
      |> Enum.map(fn {secret, friendly} -> {secret, mint(obfuscator, secret, friendly)} end)

    %{obfuscator | replace: replace, obfuscate: obfuscate}
  end

  @doc "Replace secrets in `text` with placeholders (obfuscate) or replacements (replace)."
  @spec obfuscate(t() | nil, term()) :: term()
  def obfuscate(%__MODULE__{} = obfuscator, text) when is_binary(text) do
    regex_matches = regex_matches(text, obfuscator)
    obfuscator = protect_labels(obfuscator, text, regex_matches)

    {tokens, unsafe_matches, raw_tokens} = token_snapshot(text, obfuscator)

    obfuscator = %{
      obfuscator
      | configured_values: MapSet.union(obfuscator.configured_values, raw_tokens)
    }

    redact_prepared(text, obfuscator, {regex_matches, tokens, unsafe_matches})
  end

  def obfuscate(_obfuscator, text), do: text

  @doc "Restore placeholders this obfuscator minted; unknown placeholder-shaped text is kept."
  @spec deobfuscate(t() | nil, term()) :: term()
  def deobfuscate(%__MODULE__{} = obfuscator, text) when is_binary(text) do
    if String.contains?(text, "$$") do
      obfuscator = protect_labels(obfuscator)
      map_tokens(text, &lookup(obfuscator, &1), fn raw, _start -> raw end)
    else
      text
    end
  end

  def deobfuscate(_obfuscator, text), do: text

  @doc "Deep-walk model-authored tool arguments and restore placeholders."
  @spec restore_tool_args(t() | nil, term()) :: term()
  def restore_tool_args(nil, args), do: args

  def restore_tool_args(%__MODULE__{} = obfuscator, args),
    do: walk(args, &deobfuscate(obfuscator, &1))

  @doc """
  Pre-LLM transform stage: collect secret values and raw token reservations
  across the complete provider-visible batch before obfuscating user, assistant
  (text, thinking, tool-call arguments), tool-result, bash, custom and summary
  messages. Image data and message metadata pass through.
  """
  @spec transform([term()], t() | nil) :: {:ok, [term()]}
  def transform(messages, nil), do: {:ok, messages}

  def transform(messages, %__MODULE__{} = obfuscator) when is_list(messages) do
    # Traverse exactly the emitted leaves, without minting anything. A later
    # block or argument must protect an earlier label and original raw token.
    {_messages, matches_by_text} =
      map_messages(
        messages,
        %{},
        fn text, matches ->
          {text, Map.put_new_lazy(matches, text, fn -> regex_matches(text, obfuscator) end)}
        end,
        false
      )

    Enum.each(matches_by_text, fn {text, matches} ->
      remember_regex_values(obfuscator, text, matches)
    end)

    obfuscator = protect_labels(obfuscator)

    {prepared, reserved} =
      Enum.reduce(matches_by_text, {%{}, obfuscator.configured_values}, fn {text, matches},
                                                                           {prepared, reserved} ->
        {tokens, unsafe_matches, raw_tokens} = token_snapshot(text, obfuscator)
        snapshot = {matches, tokens, unsafe_matches}
        {Map.put(prepared, text, snapshot), MapSet.union(reserved, raw_tokens)}
      end)

    obfuscator = %{obfuscator | configured_values: reserved}

    {messages, _state} =
      map_messages(
        messages,
        nil,
        fn text, state ->
          {redact_prepared(text, obfuscator, Map.fetch!(prepared, text)), state}
        end,
        true
      )

    {:ok, messages}
  end

  @doc """
  Wrap each tool so placeholders in its arguments are restored before it runs.
  Must be the outermost wrapper (before extension hooks and approval).
  """
  @spec wrap_tools([AgentTool.t()], t() | nil) :: [AgentTool.t()]
  def wrap_tools(tools, nil), do: tools

  def wrap_tools(tools, %__MODULE__{} = obfuscator),
    do: Enum.map(tools, &wrap_tool(&1, obfuscator))

  @doc "Restore arguments on registry tuples before disclosure builds its shared catalog."
  @spec wrap_tuples([{String.t(), AgentTool.t(), term()}], t() | nil) ::
          [{String.t(), AgentTool.t(), term()}]
  def wrap_tuples(tuples, nil), do: tuples

  def wrap_tuples(tuples, %__MODULE__{} = obfuscator) do
    Enum.map(tuples, fn {name, tool, source} ->
      {name, wrap_tool(tool, obfuscator), source}
    end)
  end

  defp wrap_tool(%AgentTool{execute: execute} = tool, obfuscator) when is_function(execute, 4) do
    %{
      tool
      | execute: fn tool_call_id, params, signal, on_update ->
          execute.(tool_call_id, restore_tool_args(obfuscator, params), signal, on_update)
        end
    }
  end

  defp wrap_tool(tool, _obfuscator), do: tool

  # ── Messages ──────────────────────────────────────────────────────────────

  # Collection and emission use the same traversal. Collection threads only
  # state and returns the original containers, without rebuilding message trees.
  defp map_messages(messages, state, fun, rewrite?),
    do: map_list(messages, state, &map_message(&1, &2, fun, rewrite?), rewrite?)

  defp map_message(%{role: role, content: content} = message, state, fun, rewrite?)
       when role in [:user, :custom, :tool_result] do
    update_field(message, :content, map_content(content, state, fun, rewrite?), rewrite?)
  end

  defp map_message(%{role: :assistant, content: blocks} = message, state, fun, rewrite?)
       when is_list(blocks) do
    result = map_list(blocks, state, &map_assistant_block(&1, &2, fun, rewrite?), rewrite?)
    update_field(message, :content, result, rewrite?)
  end

  defp map_message(
         %{role: :bash_execution, command: command, output: output} = message,
         state,
         fun,
         rewrite?
       ) do
    {command, state} = map_text(command, state, fun)
    {output, state} = map_text(output, state, fun)
    message = if rewrite?, do: %{message | command: command, output: output}, else: message
    {message, state}
  end

  defp map_message(%{role: role, summary: summary} = message, state, fun, rewrite?)
       when role in [:branch_summary, :compaction_summary] do
    update_field(message, :summary, map_text(summary, state, fun), rewrite?)
  end

  defp map_message(message, state, _fun, _rewrite?), do: {message, state}

  defp map_content(content, state, fun, _rewrite?) when is_binary(content),
    do: fun.(content, state)

  defp map_content(blocks, state, fun, rewrite?) when is_list(blocks),
    do: map_list(blocks, state, &map_text_block(&1, &2, fun, rewrite?), rewrite?)

  defp map_content(content, state, _fun, _rewrite?), do: {content, state}

  defp map_text_block(%{type: :text, text: text} = block, state, fun, rewrite?)
       when is_binary(text),
       do: update_field(block, :text, fun.(text, state), rewrite?)

  defp map_text_block(%{"type" => "text", "text" => text} = block, state, fun, rewrite?)
       when is_binary(text),
       do: update_field(block, "text", fun.(text, state), rewrite?)

  defp map_text_block(block, state, _fun, _rewrite?), do: {block, state}

  # A rewritten thinking block can no longer carry its byte-bound replay signature.
  defp map_assistant_block(%{type: :thinking, thinking: thinking} = block, state, fun, rewrite?)
       when is_binary(thinking) do
    {mapped, state} = fun.(thinking, state)

    block =
      if rewrite? and mapped != thinking do
        block = %{block | thinking: mapped}

        if is_map_key(block, :thinking_signature),
          do: %{block | thinking_signature: nil},
          else: block
      else
        block
      end

    {block, state}
  end

  defp map_assistant_block(%{type: :tool_call, arguments: args} = block, state, fun, rewrite?),
    do: update_field(block, :arguments, walk_values(args, state, fun, rewrite?), rewrite?)

  defp map_assistant_block(block, state, fun, rewrite?),
    do: map_text_block(block, state, fun, rewrite?)

  defp update_field(value, key, {mapped, state}, true),
    do: {Map.replace!(value, key, mapped), state}

  defp update_field(value, _key, {_mapped, state}, false), do: {value, state}

  defp map_list(list, state, fun, true), do: Enum.map_reduce(list, state, fun)

  defp map_list(list, state, fun, false) do
    state = Enum.reduce(list, state, fn value, state -> elem(fun.(value, state), 1) end)
    {list, state}
  end

  defp map_text(text, state, fun) when is_binary(text), do: fun.(text, state)
  defp map_text(other, state, _fun), do: {other, state}

  defp walk(value, fun),
    do: elem(walk_values(value, nil, fn text, state -> {fun.(text), state} end, true), 0)

  defp walk_values(text, state, fun, _rewrite?) when is_binary(text), do: fun.(text, state)

  defp walk_values(list, state, fun, rewrite?) when is_list(list),
    do: map_list(list, state, &walk_values(&1, &2, fun, rewrite?), rewrite?)

  defp walk_values(%_{} = struct, state, _fun, _rewrite?), do: {struct, state}

  defp walk_values(map, state, fun, true) when is_map(map) do
    {pairs, state} =
      Enum.map_reduce(map, state, fn {key, value}, state ->
        {value, state} = walk_values(value, state, fun, true)
        {{key, value}, state}
      end)

    {Map.new(pairs), state}
  end

  defp walk_values(map, state, fun, false) when is_map(map) do
    state =
      Enum.reduce(map, state, fn {_key, value}, state ->
        elem(walk_values(value, state, fun, false), 1)
      end)

    {map, state}
  end

  defp walk_values(other, state, _fun, _rewrite?), do: {other, state}

  # ── Obfuscation passes ────────────────────────────────────────────────────

  # Match every source against the original bytes. Rewriting one source before
  # scanning another can split a larger credential and expose its remaining
  # bytes (for example an env value inside a built-in token match).
  defp redact_prepared(text, obfuscator, {regex_matches, tokens, unsafe_matches}) do
    matches =
      Enum.flat_map(replace_pairs(obfuscator), &literal_matches(text, &1, :replace)) ++
        Enum.flat_map(obfuscator.obfuscate, &literal_matches(text, &1, :obfuscate)) ++
        regex_matches ++ unsafe_matches

    map_raw(text, tokens, &redact_segment(&1, &2, matches, obfuscator, text))
  end

  defp token_snapshot(text, obfuscator) do
    if String.contains?(text, "$$"),
      do: token_matches(text, obfuscator, 0, [], %{}, MapSet.new()),
      else: {%{}, [], MapSet.new()}
  end

  defp regex_matches(text, obfuscator) do
    Enum.flat_map(obfuscator.regexes, fn entry ->
      entry.regex
      |> Regex.scan(text, return: :index)
      |> Enum.map(&hd/1)
      |> Enum.filter(fn {start, len} ->
        len > 0 and
          (entry.mode == :replace or
             text_length(binary_part(text, start, len)) >= @min_obfuscate_len)
      end)
      |> Enum.map(fn {start, len} -> {start, start + len, {:regex, entry}} end)
    end)
  end

  defp redact_segment(text, offset, matches, obfuscator, original) do
    limit = offset + byte_size(text)

    matches =
      Enum.flat_map(matches, fn {start, stop, source} ->
        if start < limit and stop > offset do
          # A contextual match may cross a protected token. Only its raw bytes
          # are rewritten, and a clipped literal must restore those exact bytes.
          clipped =
            if start < offset or stop > limit, do: {:partial, source}, else: source

          [{max(start, offset) - offset, min(stop, limit) - offset, clipped}]
        else
          []
        end
      end)

    groups =
      matches
      |> Enum.with_index()
      |> Enum.sort_by(fn {{start, stop, _}, order} -> {start, -stop, order} end)
      |> Enum.reduce([], fn {{start, stop, source}, order}, groups ->
        match = {start, stop, source, order}

        case groups do
          [{group_start, group_stop, matches} | rest] when start < group_stop ->
            [{group_start, max(group_stop, stop), [match | matches]} | rest]

          _ ->
            [{start, stop, [match]} | groups]
        end
      end)
      |> Enum.reverse()

    {parts, last} =
      Enum.reduce(groups, {[], 0}, fn {start, stop, matches}, {acc, pos} ->
        output = redact_group(text, start, stop, matches, obfuscator, original, offset)
        {[acc, binary_part(text, pos, start - pos), output], stop}
      end)

    IO.iodata_to_binary([parts, binary_part(text, last, byte_size(text) - last)])
  end

  defp literal_matches(text, {secret, output}, mode) do
    pattern = :binary.compile_pattern(secret)
    literal_matches(text, pattern, byte_size(secret), {:literal, mode, output}, 0, [])
  end

  defp literal_matches(text, pattern, len, source, offset, acc) do
    case :binary.match(text, pattern, scope: {offset, byte_size(text) - offset}) do
      {start, _len} ->
        # Resume one byte after the start, not the end: self-overlapping literal
        # occurrences must contribute their complete union without copying tails.
        literal_matches(text, pattern, len, source, start + 1, [
          {start, start + len, source} | acc
        ])

      :nomatch ->
        Enum.reverse(acc)
    end
  end

  defp redact_group(text, start, stop, matches, obfuscator, original, offset) do
    value = binary_part(text, start, stop - start)

    replacements =
      Enum.filter(matches, fn {_, _, source, _} -> match_mode(source) == :replace end)

    candidates = if replacements == [], do: matches, else: replacements

    covering =
      candidates
      |> Enum.filter(fn
        {_, _, {:partial, _}, _} -> false
        {ms, me, _, _} -> ms == start and me == stop
      end)
      |> Enum.min_by(fn {_, _, _, order} -> order end, &<=/2, fn -> nil end)

    case covering do
      {_, _, {:literal, :obfuscate, output}, _} ->
        safe_token(obfuscator, output)

      {_, _, {:literal, :replace, output}, _} ->
        output

      {_, _, {:regex, entry}, _} ->
        regex_output(obfuscator, entry, value, original, offset + start)

      nil when replacements == [] ->
        mint(obfuscator, value, nil)

      nil ->
        replace_group(value, replacements, obfuscator, original, offset + start)
    end
  end

  defp match_mode({:literal, mode, _}), do: mode
  defp match_mode({:regex, entry}), do: entry.mode
  defp match_mode({:partial, source}), do: match_mode(source)

  defp replace_group(value, matches, obfuscator, original, start) do
    entry =
      Enum.find_value(matches, fn {_, _, source, _} ->
        case source do
          {:partial, {:regex, %{replacement: nil} = entry}} -> entry
          _ -> nil
        end
      end)

    if entry do
      regex_output(obfuscator, entry, value, original, start)
    else
      default_replacement(value)
    end
  end

  defp regex_output(obfuscator, %{mode: :obfuscate} = entry, value, _segment, _start),
    do: mint(obfuscator, value, entry.friendly_name)

  defp regex_output(_obfuscator, %{replacement: replacement}, _value, _segment, _start)
       when is_binary(replacement),
       do: replacement

  defp regex_output(obfuscator, entry, value, segment, start),
    do: Replacement.for_regex_match(value, entry.regex, segment, start, fn -> key(obfuscator) end)

  defp token_matches(text, obfuscator, offset, acc, known, raw_tokens) do
    case Regex.run(Placeholder.regex(), text, offset: offset, return: :index) do
      [{start, len}] ->
        token = binary_part(text, start, len)

        if lookup(obfuscator, token) do
          known = Map.put(known, token, safe_token(obfuscator, token))
          token_matches(text, obfuscator, start + len, acc, known, raw_tokens)
        else
          acc =
            if unsafe_token_prefix?(obfuscator, token) do
              [{start, start + len, {:partial, {:literal, :obfuscate, nil}}} | acc]
            else
              acc
            end

          raw_tokens = MapSet.put(raw_tokens, token)

          raw_tokens =
            case Placeholder.split_friendly(token) do
              {_prefix, bare} -> MapSet.put(raw_tokens, bare)
              nil -> raw_tokens
            end

          token_matches(
            text,
            obfuscator,
            start + len - 2,
            acc,
            known,
            raw_tokens
          )
        end

      nil ->
        {known, Enum.reverse(acc), raw_tokens}
    end
  end

  # Keep known tokens atomic, but scan the whole input before splitting raw
  # spans: regex context and unsafe labels can live across those boundaries.
  defp map_raw(text, tokens, fun) do
    if map_size(tokens) > 0 do
      map_tokens(text, &Map.get(tokens, &1), fun)
    else
      fun.(text, 0)
    end
  end

  # Walk placeholder-shaped tokens: `on_token` returns the token's output or nil
  # (not ours, left as raw text); raw text between accepted tokens goes through
  # `on_raw`. A rejected candidate resumes at its closing `$$`, which may open
  # an adjacent token.
  defp map_tokens(text, on_token, on_raw), do: map_tokens(text, 0, 0, [], on_token, on_raw)

  defp map_tokens(text, offset, raw_start, acc, on_token, on_raw) do
    case Regex.run(Placeholder.regex(), text, offset: offset, return: :index) do
      [{start, len}] ->
        case on_token.(binary_part(text, start, len)) do
          nil ->
            map_tokens(text, start + len - 2, raw_start, acc, on_token, on_raw)

          output ->
            raw = on_raw.(binary_part(text, raw_start, start - raw_start), raw_start)
            map_tokens(text, start + len, start + len, [acc, raw, output], on_token, on_raw)
        end

      nil ->
        tail = on_raw.(binary_part(text, raw_start, byte_size(text) - raw_start), raw_start)
        IO.iodata_to_binary([acc, tail])
    end
  end

  # ── Placeholders ──────────────────────────────────────────────────────────

  defp lookup(%__MODULE__{table: table} = obfuscator, token) do
    case :ets.lookup(table, {:ph, token}) do
      [{_, secret}] ->
        secret

      [] ->
        # A placeholder minted under another friendly name still restores via
        # its bare form, unless the prefix itself is secret-shaped (forgery).
        with {prefix, bare} <- Placeholder.split_friendly(token),
             false <- prefix_secret_shaped?(obfuscator, prefix),
             [{_, secret}] <- :ets.lookup(table, {:ph, bare}) do
          secret
        else
          _ -> nil
        end
    end
  end

  defp mint(%__MODULE__{table: table} = obfuscator, secret, friendly_name) do
    case :ets.lookup(table, {:mint, secret, friendly_name}) do
      [{_, token}] ->
        safe_token(obfuscator, token)

      [] ->
        hint = Placeholder.case_hint(secret)
        label = safe_label(obfuscator, friendly_name, secret)

        token =
          claim_token(obfuscator, secret, hint, preferred_base(obfuscator, secret), label, 1)

        :ets.insert(table, {{:mint, secret, friendly_name}, token})
        token
    end
  end

  defp claim_token(obfuscator, secret, hint, base, label, attempt) do
    token = Placeholder.build(hint, base, label)
    bare = Placeholder.build(hint, base, nil)

    if token_conflicts?(obfuscator, token, secret) or token_conflicts?(obfuscator, bare, secret) do
      fallback = claim_base(obfuscator, "#{secret}\0collision\0#{attempt}")
      claim_token(obfuscator, secret, hint, fallback, label, attempt + 1)
    else
      :ets.insert(obfuscator.table, [{{:ph, token}, secret}, {{:ph, bare}, secret}])
      token
    end
  end

  defp token_conflicts?(obfuscator, token, secret) do
    case :ets.lookup(obfuscator.table, {:ph, token}) do
      [{_, ^secret}] -> false
      [_] -> true
      [] -> token != secret and MapSet.member?(obfuscator.configured_values, token)
    end
  end

  defp preferred_base(%__MODULE__{table: table} = obfuscator, secret) do
    case :ets.lookup(table, {:base_for, secret}) do
      [{_, base}] ->
        base

      [] ->
        base =
          Stream.iterate(0, &(&1 + 1))
          |> Stream.map(fn
            0 -> Placeholder.hash_base(key(obfuscator), secret)
            n -> Placeholder.hash_base(key(obfuscator), "#{secret}\0#{n}")
          end)
          |> Enum.find(&own_base?(table, &1, secret))

        :ets.insert(table, {{:base_for, secret}, base})
        base
    end
  end

  defp claim_base(%__MODULE__{table: table} = obfuscator, owner) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(&Placeholder.hash_base(key(obfuscator), "#{owner}\0#{&1}"))
    |> Enum.find(&:ets.insert_new(table, {{:base, &1}, owner}))
  end

  defp own_base?(table, base, owner) do
    :ets.insert_new(table, {{:base, base}, owner}) or
      :ets.lookup(table, {:base, base}) == [{{:base, base}, owner}]
  end

  # Retain normalized actual regex values in the same session ETS authority.
  # An overlap may mint only its union, but the constituent values must still
  # protect future labels and bare-alias lookups without their regex context.
  defp protect_labels(obfuscator, text \\ "", matches \\ []) do
    remember_regex_values(obfuscator, text, matches)

    previous =
      obfuscator.table
      |> :ets.select([{{{:mint, :"$1", :_}, :_}, [], [:"$1"]}])
      |> Enum.map(&Placeholder.sanitize_for_collision/1)

    regex_values =
      :ets.select(obfuscator.table, [{{{:regex_value, :"$1"}, :_}, [], [:"$1"]}])

    %{
      obfuscator
      | sanitized_values: Enum.uniq(obfuscator.sanitized_values ++ previous ++ regex_values)
    }
  end

  defp remember_regex_values(obfuscator, text, matches) do
    current =
      Enum.map(matches, fn {start, stop, _} ->
        value = binary_part(text, start, stop - start)
        {{:regex_value, Placeholder.sanitize_for_collision(value)}, true}
      end)

    :ets.insert(obfuscator.table, current)
  end

  defp unsafe_token_prefix?(obfuscator, token) do
    case Placeholder.split_friendly(token) do
      {prefix, _bare} -> prefix_secret_shaped?(obfuscator, prefix)
      nil -> false
    end
  end

  defp safe_token(obfuscator, token) do
    case Placeholder.split_friendly(token) do
      {prefix, bare} ->
        if prefix_secret_shaped?(obfuscator, prefix), do: bare, else: token

      nil ->
        token
    end
  end

  # A label that embeds a configured secret or matches a configured regex would
  # bake that secret into every placeholder for this value; drop it instead.
  defp safe_label(_obfuscator, nil, _secret), do: nil

  defp safe_label(obfuscator, name, secret) do
    label = Placeholder.sanitize_friendly_name(name)
    full = Placeholder.sanitize_for_collision(name)

    if label == nil or prefix_secret_shaped?(obfuscator, full) or
         Placeholder.label_collides_with_secret?(full, Placeholder.sanitize_for_collision(secret)) or
         Enum.any?(obfuscator.regexes, &Regex.match?(&1.regex, name)) do
      nil
    else
      label
    end
  end

  defp prefix_secret_shaped?(obfuscator, prefix) do
    Enum.any?(obfuscator.sanitized_values, &Placeholder.label_collides_with_secret?(prefix, &1)) or
      Enum.any?(obfuscator.regexes, &Regex.match?(&1.regex, prefix))
  end

  # ── Key ───────────────────────────────────────────────────────────────────

  defp key(%__MODULE__{table: table, key_path: key_path}) do
    case :ets.lookup(table, :key) do
      [{:key, key, _redaction}] ->
        key

      [] ->
        key = Placeholder.load_or_create_key(key_path)
        :ets.insert_new(table, {:key, key, default_replacement(key)})
        [{:key, key, _}] = :ets.lookup(table, :key)
        key
    end
  end

  defp load_existing_key(%__MODULE__{table: table, key_path: key_path}) do
    if key = Placeholder.load_existing_key(key_path) do
      :ets.insert_new(table, {:key, key, default_replacement(key)})
    end
  end

  # The key itself is redacted one way: a tool read of the key file must not
  # hand the provider the material that protects every placeholder.
  defp replace_pairs(%__MODULE__{table: table, replace: replace}) do
    case :ets.lookup(table, :key) do
      [{:key, key, redaction}] -> by_length_desc([{key, redaction} | replace])
      [] -> replace
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp compile_entry(%{type: :regex} = entry) do
    case Loader.compile_regex(entry.content, entry[:flags]) do
      {:ok, regex} ->
        [
          %{
            regex: regex,
            mode: entry.mode,
            replacement: entry[:replacement],
            friendly_name: entry[:friendly_name]
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp compile_entry(_entry), do: []

  defp needs_key?(%{mode: :obfuscate, type: :regex}), do: true

  defp needs_key?(%{mode: :obfuscate, content: content}),
    do: text_length(content) >= @min_obfuscate_len

  defp needs_key?(%{mode: :replace, type: :regex} = entry), do: is_nil(entry[:replacement])
  defp needs_key?(_entry), do: false

  defp default_replacement(secret),
    do: Replacement.ensure_distinct(Replacement.deterministic(secret), secret)

  defp by_length_desc(pairs),
    do: Enum.sort_by(pairs, fn {secret, _} -> {-byte_size(secret), secret} end)

  defp text_length(text), do: Replacement.text_length(text)
end

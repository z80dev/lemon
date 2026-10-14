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
    text
    |> apply_literals(obfuscator, replace_pairs(obfuscator))
    |> apply_literals(obfuscator, obfuscator.obfuscate)
    |> apply_regexes(obfuscator)
  end

  def obfuscate(_obfuscator, text), do: text

  @doc "Restore placeholders this obfuscator minted; unknown placeholder-shaped text is kept."
  @spec deobfuscate(t() | nil, term()) :: term()
  def deobfuscate(%__MODULE__{} = obfuscator, text) when is_binary(text) do
    if String.contains?(text, "$$") do
      map_tokens(text, &lookup(obfuscator, &1), & &1)
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
  Pre-LLM transform stage: obfuscate provider-visible text in user, assistant
  (text, thinking, tool-call arguments), tool-result, bash, custom and summary
  messages. Image data and message metadata pass through.
  """
  @spec transform([term()], t() | nil) :: {:ok, [term()]}
  def transform(messages, nil), do: {:ok, messages}

  def transform(messages, %__MODULE__{} = obfuscator) when is_list(messages),
    do: {:ok, Enum.map(messages, &obfuscate_message(obfuscator, &1))}

  @doc """
  Wrap each tool so placeholders in its arguments are restored before it runs.
  Must be the outermost wrapper (before extension hooks and approval).
  """
  @spec wrap_tools([AgentTool.t()], t() | nil) :: [AgentTool.t()]
  def wrap_tools(tools, nil), do: tools

  def wrap_tools(tools, %__MODULE__{} = obfuscator),
    do: Enum.map(tools, &wrap_tool(&1, obfuscator))

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

  defp obfuscate_message(obfuscator, %{role: role, content: content} = message)
       when role in [:user, :custom, :tool_result] do
    %{message | content: obfuscate_content(obfuscator, content)}
  end

  defp obfuscate_message(obfuscator, %{role: :assistant, content: blocks} = message)
       when is_list(blocks) do
    %{message | content: Enum.map(blocks, &obfuscate_assistant_block(obfuscator, &1))}
  end

  defp obfuscate_message(
         obfuscator,
         %{role: :bash_execution, command: command, output: output} = message
       ) do
    %{message | command: obfuscate(obfuscator, command), output: obfuscate(obfuscator, output)}
  end

  defp obfuscate_message(obfuscator, %{role: role, summary: summary} = message)
       when role in [:branch_summary, :compaction_summary] do
    %{message | summary: obfuscate(obfuscator, summary)}
  end

  defp obfuscate_message(_obfuscator, message), do: message

  defp obfuscate_content(obfuscator, content) when is_binary(content),
    do: obfuscate(obfuscator, content)

  defp obfuscate_content(obfuscator, blocks) when is_list(blocks),
    do: Enum.map(blocks, &obfuscate_text_block(obfuscator, &1))

  defp obfuscate_content(_obfuscator, content), do: content

  defp obfuscate_text_block(obfuscator, %{type: :text, text: text} = block) when is_binary(text),
    do: %{block | text: obfuscate(obfuscator, text)}

  defp obfuscate_text_block(obfuscator, %{"type" => "text", "text" => text} = block)
       when is_binary(text),
       do: Map.put(block, "text", obfuscate(obfuscator, text))

  defp obfuscate_text_block(_obfuscator, block), do: block

  # A rewritten thinking block can no longer carry its byte-bound replay signature.
  defp obfuscate_assistant_block(obfuscator, %{type: :thinking, thinking: thinking} = block)
       when is_binary(thinking) do
    case obfuscate(obfuscator, thinking) do
      ^thinking ->
        block

      obfuscated when is_map_key(block, :thinking_signature) ->
        %{block | thinking: obfuscated, thinking_signature: nil}

      obfuscated ->
        %{block | thinking: obfuscated}
    end
  end

  defp obfuscate_assistant_block(obfuscator, %{type: :tool_call, arguments: args} = block),
    do: %{block | arguments: walk(args, &obfuscate(obfuscator, &1))}

  defp obfuscate_assistant_block(obfuscator, block), do: obfuscate_text_block(obfuscator, block)

  defp walk(text, fun) when is_binary(text), do: fun.(text)
  defp walk(list, fun) when is_list(list), do: Enum.map(list, &walk(&1, fun))
  defp walk(%_{} = struct, _fun), do: struct
  defp walk(map, fun) when is_map(map), do: Map.new(map, fn {k, v} -> {k, walk(v, fun)} end)
  defp walk(other, _fun), do: other

  # ── Obfuscation passes ────────────────────────────────────────────────────

  defp apply_literals(text, obfuscator, pairs) do
    Enum.reduce(pairs, text, fn {secret, output}, acc ->
      if :binary.match(acc, secret) == :nomatch do
        acc
      else
        map_raw(acc, obfuscator, &:binary.replace(&1, secret, output, [:global]))
      end
    end)
  end

  defp apply_regexes(text, obfuscator) do
    Enum.reduce(obfuscator.regexes, text, fn entry, acc ->
      if Regex.match?(entry.regex, acc) do
        map_raw(acc, obfuscator, &apply_regex(obfuscator, entry, &1))
      else
        acc
      end
    end)
  end

  defp apply_regex(obfuscator, entry, segment) do
    {parts, last} =
      entry.regex
      |> Regex.scan(segment, return: :index)
      |> Enum.map(&hd/1)
      |> Enum.reject(fn {_start, len} -> len == 0 end)
      |> Enum.reduce({[], 0}, fn {start, len}, {acc, pos} ->
        value = binary_part(segment, start, len)
        output = regex_output(obfuscator, entry, value, segment, start)
        {[acc, binary_part(segment, pos, start - pos), output], start + len}
      end)

    IO.iodata_to_binary([parts, binary_part(segment, last, byte_size(segment) - last)])
  end

  defp regex_output(obfuscator, %{mode: :obfuscate} = entry, value, _segment, _start) do
    # Short matches are left alone to avoid redacting ordinary small words.
    if text_length(value) < @min_obfuscate_len,
      do: value,
      else: mint(obfuscator, value, entry.friendly_name)
  end

  defp regex_output(_obfuscator, %{replacement: replacement}, _value, _segment, _start)
       when is_binary(replacement),
       do: replacement

  defp regex_output(obfuscator, entry, value, segment, start),
    do: Replacement.for_regex_match(value, entry.regex, segment, start, fn -> key(obfuscator) end)

  # Apply `fun` to the text between placeholders this obfuscator generated, so
  # an earlier pass's placeholder is never re-redacted by a later pass.
  defp map_raw(text, obfuscator, fun) do
    if String.contains?(text, "$$") do
      map_tokens(text, &if(lookup(obfuscator, &1), do: &1), fun)
    else
      fun.(text)
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
            raw = on_raw.(binary_part(text, raw_start, start - raw_start))
            map_tokens(text, start + len, start + len, [acc, raw, output], on_token, on_raw)
        end

      nil ->
        tail = on_raw.(binary_part(text, raw_start, byte_size(text) - raw_start))
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
        token

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

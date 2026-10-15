defmodule CodingAgent.Subagents do
  @moduledoc """
  Named child-session personas loaded from Markdown with YAML frontmatter.

  Definitions are discovered in this order, and the first definition for an ID
  wins:

    1. project `.lemon/agents/*.md`
    2. project `.omp/agents/*.md`, in cwd then each ancestor up to the Git root
    3. project `.claude/agents/*.md`, in cwd then each ancestor up to the Git root
    4. `~/.lemon/agents/*.md`
    5. `~/.omp/agent/agents/*.md`
    6. `~/.claude/agents/*.md`
    7. this application's `priv/agents/*.md`

  Native definitions (`.lemon` directories and bundled files) are strict: the
  filename determines the ID, an optional `name` field must match it, unknown
  fields are rejected, and an invalid definition shadows lower-priority
  definitions: `fetch/2` reports the error, while `get/2` and `list/1` omit it.

  Foreign definitions (`.omp` and `.claude` directories) are tolerant: unknown
  fields are ignored, the ID is the trimmed `name` field (or the filename when
  absent), long descriptions are truncated to 1 KiB, and invalid `thinking`,
  `spawns`, or `output` values are ignored. Any other invalid foreign file is
  skipped and does not shadow lower-priority definitions. At most 256 Markdown
  files are indexed per foreign directory.

  Native frontmatter accepts `name`, `description`, `model`, `role`, `tools`,
  `read_only`, `spawns`, `output`, and a thinking level as `thinking`,
  `thinking_level`, `thinking-level`, or `thinkingLevel`. Description and the
  Markdown instruction body must be nonempty. `role` is a model routing role
  (resolved as `@role` by the caller), not the persona identity.

    * `tools` is a YAML list or comma-separated string. Names are normalized
      (parenthesized suffixes such as `Bash(git:*)` removed, lowercased, omp and
      Claude Code aliases such as `Glob` mapped to Lemon names, `yield` dropped).
    * `model` is a string, list, or comma-separated string; the first entry
      other than `inherit` (and, for `.claude` files, `sonnet`, `opus`, or
      `haiku`) is used.
    * Thinking levels are off, minimal, low, medium, high, or xhigh (`max` is
      xhigh) and are exposed as `thinking_level`.
    * `spawns` is `"*"` (`:all`) or a list of persona IDs. When absent and
      `tools` includes `task`, it defaults to `:all`.
    * `output` is a JSON Schema (when it has `$schema`, or a JSON type without
      JTD-only keywords) or a JSON Type Definition (RFC 8927) converted to JSON
      Schema and exposed as `output_schema`. JTD properties forms allow extra
      properties; `ref` and `definitions` are unsupported.

  Model, role, thinking_level, spawns, and output_schema default to nil, tools to
  nil (inherit), and read_only to false. Scout, reviewer, and security-reviewer
  identities are always read-only, and read-only personas never spawn.

  IDs are lowercase ASCII names of at most 64 bytes. Definitions are bounded to
  128 KiB, frontmatter to 16 KiB, instructions to 64 KiB, descriptions to 1 KiB,
  model names to 256 bytes, and tool lists to 128 names of 128 bytes.
  The `source` field is `:project`, `:global`, or `:builtin`.
  """

  require Logger

  alias CodingAgent.{Config, ToolPolicy}
  alias CodingAgent.Tools.Task.StructuredOutput
  alias LemonSkills.Config, as: SkillConfig

  @thinking_keys ~w(thinkingLevel thinking-level thinking_level thinking)
  @fields ~w(name description model role tools read_only spawns output) ++ @thinking_keys
  @read_only_tools ~w(read grep find ls agent_message)
  @read_only_ids ~w(scout reviewer security-reviewer)
  @thinking_levels ~w(off minimal low medium high xhigh)
  @tool_aliases %{
    "glob" => "find",
    "multiedit" => "edit",
    "notebookedit" => "edit",
    "web_fetch" => "webfetch",
    "web_search" => "websearch",
    "todowrite" => "todo",
    "todoread" => "todo"
  }
  @claude_model_aliases ~w(sonnet opus haiku)
  @json_types ~w(object array string number integer boolean null)
  @jtd_only_keys ~w(optionalProperties elements values discriminator mapping metadata nullable ref definitions)
  @jtd_keys ~w(properties optionalProperties elements values enum discriminator type metadata nullable)
  @jtd_form_keys ~w(type enum elements properties optionalProperties additionalProperties values discriminator mapping metadata nullable)
  @jtd_types %{
    "boolean" => "boolean",
    "string" => "string",
    "timestamp" => "string",
    "float32" => "number",
    "float64" => "number",
    "int8" => "integer",
    "uint8" => "integer",
    "int16" => "integer",
    "uint16" => "integer",
    "int32" => "integer",
    "uint32" => "integer"
  }
  @max_foreign_files 256
  @max_file_bytes 128 * 1024
  @max_frontmatter_bytes 16 * 1024
  @max_prompt_bytes 64 * 1024

  @type subagent :: %{
          id: String.t(),
          description: String.t(),
          prompt: String.t(),
          model: String.t() | nil,
          role: String.t() | nil,
          tools: [String.t()] | nil,
          read_only: boolean(),
          thinking_level: String.t() | nil,
          spawns: :all | [String.t()] | nil,
          output_schema: map() | boolean() | nil,
          source: :project | :global | :builtin
        }

  @spec list(String.t()) :: [subagent()]
  def list(cwd) do
    roots = cwd |> roots() |> Enum.map(&index_root/1)

    roots
    |> Enum.flat_map(&root_ids/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn id ->
      case resolve(roots, id) do
        {:ok, persona} -> [persona]
        {:error, _} -> []
      end
    end)
  end

  @spec get(String.t(), String.t()) :: subagent() | nil
  def get(cwd, id) do
    case fetch(cwd, id) do
      {:ok, persona} -> persona
      {:error, _} -> nil
    end
  end

  @doc "Returns the highest-priority definition, or an actionable definition error."
  @spec fetch(String.t(), String.t()) :: {:ok, subagent()} | {:error, String.t()}
  def fetch(cwd, id) do
    if valid_id?(id) do
      resolve(roots(cwd), id)
    else
      {:error, "Invalid subagent ID: expected a lowercase name of 1-64 characters"}
    end
  end

  @doc "Whether a persona is read-only (flagged, or one of the always-read-only IDs)."
  @spec read_only?(map() | nil) :: boolean()
  def read_only?(nil), do: false
  def read_only?(persona), do: persona[:read_only] == true or persona[:id] in @read_only_ids

  @doc """
  Intersects a persona's tools with the requested policy (default: leaf worker).

  Read-only personas, including any override named scout, reviewer, or
  security-reviewer, are restricted to read, grep, find, ls, and agent_message.
  Caller denies, blocked tools, approvals, and no_reply are preserved; no persona
  can broaden caller permissions.
  """
  @spec tool_policy(subagent() | nil, map() | nil) :: ToolPolicy.policy()
  def tool_policy(persona, requested_policy) do
    policy = ToolPolicy.from_map(requested_policy || ToolPolicy.from_profile(:leaf_worker))
    tools = if persona, do: Map.get(persona, :tools), else: nil

    tools =
      if read_only?(persona) do
        if is_list(tools),
          do: Enum.filter(tools, &(&1 in @read_only_tools)),
          else: @read_only_tools
      else
        tools
      end

    if is_list(tools) do
      %{policy | allow: Enum.filter(tools, &ToolPolicy.allowed?(policy, &1))}
    else
      policy
    end
  end

  # Discovery

  defp roots(cwd) do
    home = System.get_env("HOME") || System.user_home!()
    ancestors = project_ancestors(cwd)

    globals = [
      {Path.join([home, ".lemon", "agents"]), :global, :native},
      {Path.join([home, ".omp", "agent", "agents"]), :global, :omp},
      {Path.join([home, ".claude", "agents"]), :global, :claude},
      {Path.join(to_string(:code.priv_dir(:coding_agent)), "agents"), :builtin, :native}
    ]

    global_dirs = MapSet.new(globals, fn {dir, _source, _kind} -> Path.expand(dir) end)

    ([{Path.join(Config.project_config_dir(cwd), "agents"), :project, :native}] ++
       Enum.map(ancestors, &{Path.join([&1, ".omp", "agents"]), :project, :omp}) ++
       Enum.map(ancestors, &{Path.join([&1, ".claude", "agents"]), :project, :claude}) ++ globals)
    |> Enum.reject(fn {dir, source, _kind} ->
      source == :project and MapSet.member?(global_dirs, Path.expand(dir))
    end)
    |> Enum.uniq_by(fn {dir, _source, _kind} -> dir end)
  end

  # cwd first, then each ancestor up to the Git root (or filesystem root).
  defp project_ancestors(cwd) do
    cwd = Path.expand(cwd)
    ancestors(cwd, SkillConfig.find_git_repo_root(cwd))
  end

  defp ancestors(dir, stop) do
    parent = Path.dirname(dir)
    if dir == stop or parent == dir, do: [dir], else: [dir | ancestors(parent, stop)]
  end

  defp index_root({dir, source, kind}) when kind != :native,
    do: {:indexed, foreign_index(dir, source, kind)}

  defp index_root(root), do: root

  defp root_ids({:indexed, index}), do: Map.keys(index)
  defp root_ids({dir, _source, :native}), do: definition_ids(dir)

  defp resolve(roots, id) do
    Enum.reduce_while(roots, {:error, "Unknown subagent: #{id}"}, fn root, missing ->
      case lookup(root, id) do
        :none -> {:cont, missing}
        result -> {:halt, result}
      end
    end)
  end

  defp lookup({:indexed, index}, id) do
    case Map.fetch(index, id) do
      {:ok, persona} -> {:ok, persona}
      :error -> :none
    end
  end

  defp lookup({dir, source, :native}, id) do
    path = Path.join(dir, id <> ".md")

    case File.lstat(path) do
      {:error, :enoent} ->
        :none

      {:ok, _} ->
        with {:ok, content} <- read_definition(path),
             {:ok, persona} <- parse_definition(content, id, source, :native) do
          {:ok, persona}
        else
          {:error, reason} -> {:error, "Invalid #{source} subagent '#{id}': #{reason}"}
        end

      {:error, reason} ->
        {:error, "Cannot load #{source} subagent '#{id}': #{reason}"}
    end
  end

  defp lookup({dir, source, kind}, id),
    do: lookup({:indexed, foreign_index(dir, source, kind)}, id)

  defp definition_ids(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            String.ends_with?(name, ".md"),
            id = Path.rootname(name, ".md"),
            valid_id?(id),
            do: id

      {:error, _} ->
        []
    end
  end

  # Foreign IDs may differ from filenames, so the directory is parsed up front.
  defp foreign_index(dir, source, kind) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.take(@max_foreign_files)
        |> Enum.reduce(%{}, fn name, index ->
          path = Path.join(dir, name)

          with {:ok, content} <- read_definition(path),
               {:ok, persona} <-
                 parse_definition(content, Path.rootname(name, ".md"), source, kind) do
            Map.put_new(index, persona.id, persona)
          else
            {:error, reason} ->
              Logger.debug("Skipping subagent definition #{path}: #{reason}")
              index
          end
        end)

      {:error, _} ->
        %{}
    end
  end

  defp read_definition(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.open(path, [:read, :binary], &IO.binread(&1, @max_file_bytes + 1)) do
          {:ok, content} when is_binary(content) and byte_size(content) <= @max_file_bytes ->
            if String.valid?(content), do: {:ok, content}, else: {:error, "expected UTF-8 text"}

          {:ok, content} when is_binary(content) ->
            {:error, "definition exceeds 128 KiB"}

          {:ok, :eof} ->
            {:error, "definition is empty"}

          _ ->
            {:error, "definition could not be read"}
        end

      _ ->
        {:error, "definition must be a readable regular file"}
    end
  end

  # Parsing

  defp parse_definition(content, file_id, source, kind) do
    with {:ok, fields, body} <- parse_frontmatter(content),
         {:ok, id} <- definition_id(fields, file_id, kind),
         {:ok, attrs} <- parse_fields(fields, kind),
         prompt = String.trim(body),
         true <- valid_text?(prompt, @max_prompt_bytes) do
      read_only = id in @read_only_ids or attrs.read_only
      spawns = if read_only, do: nil, else: attrs.spawns

      {:ok,
       Map.merge(attrs, %{
         id: id,
         prompt: prompt,
         read_only: read_only,
         spawns: spawns,
         source: source
       })}
    else
      false -> {:error, "instruction body must be nonempty text of at most 64 KiB"}
      {:error, _} = error -> error
    end
  end

  defp parse_frontmatter(content) do
    case Regex.run(~r/\A---\r?\n(.*?)^---(?:\r?\n|\z)(.*)\z/ms, content) do
      [_, yaml, body] when byte_size(yaml) <= @max_frontmatter_bytes ->
        case parse_yaml(yaml) do
          {:ok, fields} -> {:ok, fields, body}
          {:error, _} = error -> error
        end

      [_, _, _] ->
        {:error, "frontmatter exceeds 16 KiB"}

      _ ->
        {:error, "expected YAML frontmatter enclosed by --- lines"}
    end
  end

  defp parse_yaml(yaml) do
    # Preserve pairs so duplicate fields cannot silently change security settings,
    # then map the same parsed document so nested output schemas keep their shape.
    with {:ok, document} <- read_yaml(yaml),
         pairs when is_list(pairs) <-
           YamlElixir.Mapper.process(document, maps_as_keywords: true) do
      cond do
        not Enum.all?(pairs, &match?({key, _} when is_binary(key), &1)) ->
          {:error, "frontmatter must be a mapping"}

        length(Enum.uniq_by(pairs, &elem(&1, 0))) != length(pairs) ->
          {:error, "duplicate frontmatter fields"}

        true ->
          case YamlElixir.Mapper.process(document, []) do
            fields when is_map(fields) -> {:ok, fields}
            _ -> {:error, "frontmatter must be a mapping"}
          end
      end
    else
      _ -> {:error, "malformed YAML frontmatter"}
    end
  rescue
    _ -> {:error, "malformed YAML frontmatter"}
  end

  @yaml_options [
    detailed_constr: true,
    str_node_as_binary: true,
    keep_duplicate_keys: true
  ]

  # YamlElixir.read_from_string/2 calls Application.start(:yamerl) on every
  # read, a call into the application controller. Sessions parse these
  # definitions in init, so a session starting while an application stops
  # deadlocked: the controller waited on the session supervisor, which waited
  # on this init. yamerl is already running as a yaml_elixir dependency, so
  # parse with yamerl directly.
  defp read_yaml(yaml) do
    {:ok, yaml |> :yamerl_constr.string(@yaml_options) |> List.last()}
  catch
    _, _ -> {:error, :malformed}
  end

  defp definition_id(fields, file_id, :native) do
    cond do
      Enum.any?(Map.keys(fields), &(&1 not in @fields)) ->
        {:error, "unknown frontmatter field"}

      Map.has_key?(fields, "name") and fields["name"] != file_id ->
        {:error, "name must match the definition filename"}

      true ->
        {:ok, file_id}
    end
  end

  defp definition_id(fields, file_id, _foreign) do
    id =
      case Map.get(fields, "name") do
        nil -> file_id
        name when is_binary(name) -> String.trim(name)
        _ -> nil
      end

    if valid_id?(id),
      do: {:ok, id},
      else: {:error, "name must be a lowercase name of 1-64 characters"}
  end

  defp parse_fields(fields, kind) do
    with {:ok, description} <- description(fields["description"], kind),
         {:ok, model} <- model(fields["model"], kind),
         {:ok, role} <- role(fields["role"]),
         {:ok, tools} <- tools(fields["tools"]),
         {:ok, read_only} <- read_only(Map.get(fields, "read_only", false)),
         {:ok, thinking_level} <- thinking_level(fields, kind),
         {:ok, spawns} <- lenient(spawns(fields["spawns"]), kind),
         {:ok, output_schema} <- lenient(output_schema(fields["output"]), kind) do
      spawns =
        if not Map.has_key?(fields, "spawns") and is_list(tools) and "task" in tools,
          do: :all,
          else: spawns

      {:ok,
       %{
         description: description,
         model: model,
         role: role,
         tools: tools,
         read_only: read_only,
         thinking_level: thinking_level,
         spawns: spawns,
         output_schema: output_schema
       }}
    end
  end

  defp lenient({:error, _}, kind) when kind != :native, do: {:ok, nil}
  defp lenient(result, _kind), do: result

  defp description(value, kind) do
    value = if kind != :native and is_binary(value), do: truncate_utf8(value, 1024), else: value

    if valid_text?(value, 1024),
      do: {:ok, String.trim(value)},
      else: {:error, "description must be nonempty text of at most 1024 bytes"}
  end

  defp truncate_utf8(value, max) when byte_size(value) <= max, do: value
  defp truncate_utf8(value, max), do: value |> binary_part(0, max) |> drop_partial_codepoint()

  defp drop_partial_codepoint(value) do
    if String.valid?(value),
      do: value,
      else: drop_partial_codepoint(binary_part(value, 0, byte_size(value) - 1))
  end

  defp model(nil, _kind), do: {:ok, nil}
  defp model(value, kind) when is_binary(value), do: value |> String.split(",") |> model(kind)

  defp model(entries, kind) when is_list(entries) do
    if Enum.all?(entries, &(is_binary(&1) and String.trim(&1) != "")) do
      model =
        entries
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&ignored_model?(&1, kind))
        |> List.first()

      if optional_token?(model, 256), do: {:ok, model}, else: model_error()
    else
      model_error()
    end
  end

  defp model(_value, _kind), do: model_error()

  defp model_error,
    do: {:error, "model must be a nonempty string of at most 256 bytes without whitespace"}

  defp ignored_model?(model, kind) do
    model = String.downcase(model)
    model == "inherit" or (kind == :claude and model in @claude_model_aliases)
  end

  defp role(role) do
    if is_nil(role) or valid_id?(role),
      do: {:ok, role},
      else: {:error, "role must be a model role name of 1-64 characters (without @)"}
  end

  defp tools(nil), do: {:ok, nil}
  defp tools(value) when is_binary(value), do: value |> String.split(",") |> tools()

  defp tools(entries) when is_list(entries) and length(entries) <= 128 do
    if Enum.all?(entries, &is_binary/1) do
      tools =
        entries
        |> Enum.map(&normalize_tool/1)
        |> Enum.reject(&(&1 in ["", "yield"]))
        |> Enum.uniq()

      if Enum.all?(tools, &valid_tool_name?/1), do: {:ok, tools}, else: tools_error()
    else
      tools_error()
    end
  end

  defp tools(_value), do: tools_error()

  defp tools_error,
    do: {:error, "tools must be null, a list, or a comma-separated string of at most 128 names"}

  defp normalize_tool(name) do
    name = name |> String.replace(~r/\(.*\)\s*\z/s, "") |> String.trim() |> String.downcase()
    Map.get(@tool_aliases, name, name)
  end

  defp valid_tool_name?(name),
    do: byte_size(name) <= 128 and String.match?(name, ~r/\A[a-z0-9][a-z0-9_.:-]*\z/)

  defp read_only(value) when is_boolean(value), do: {:ok, value}
  defp read_only(_value), do: {:error, "read_only must be a boolean"}

  defp thinking_level(fields, :native) do
    fields
    |> thinking_values()
    |> Enum.reduce_while({:ok, nil}, fn value, {:ok, current} ->
      case normalize_thinking(value) do
        {:ok, level} when current in [nil, level] ->
          {:cont, {:ok, level}}

        {:ok, _level} ->
          {:halt, {:error, "thinking aliases must not set different levels"}}

        :error ->
          {:halt,
           {:error, "thinking must be one of off, minimal, low, medium, high, xhigh, or max"}}
      end
    end)
  end

  defp thinking_level(fields, _foreign) do
    level =
      fields
      |> thinking_values()
      |> Enum.find_value(fn value ->
        case normalize_thinking(value) do
          {:ok, level} -> level
          :error -> nil
        end
      end)

    {:ok, level}
  end

  defp thinking_values(fields) do
    Enum.flat_map(@thinking_keys, fn key ->
      case Map.get(fields, key) do
        nil -> []
        value -> [value]
      end
    end)
  end

  defp normalize_thinking(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "max" -> {:ok, "xhigh"}
      level when level in @thinking_levels -> {:ok, level}
      _ -> :error
    end
  end

  defp normalize_thinking(_value), do: :error

  defp spawns(nil), do: {:ok, nil}
  defp spawns(value) when is_binary(value), do: value |> String.split(",") |> spawns()

  defp spawns(entries) when is_list(entries) and length(entries) <= 128 do
    ids =
      if Enum.all?(entries, &is_binary/1),
        do: entries |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq(),
        else: nil

    cond do
      is_nil(ids) -> spawns_error()
      "*" in ids -> {:ok, :all}
      Enum.all?(ids, &valid_id?/1) -> {:ok, ids}
      true -> spawns_error()
    end
  end

  defp spawns(_value), do: spawns_error()

  defp spawns_error,
    do: {:error, "spawns must be \"*\" or a list of at most 128 subagent IDs"}

  # Output schemas

  defp output_schema(nil), do: {:ok, nil}

  defp output_schema(schema) do
    with {:ok, schema} <- to_json_schema(schema),
         :ok <- StructuredOutput.validate_schema(schema) do
      {:ok, schema}
    else
      {:error, reason} -> {:error, "output must be a JSON Schema or JTD schema: #{reason}"}
    end
  end

  defp to_json_schema(schema) when is_boolean(schema), do: {:ok, schema}

  defp to_json_schema(schema) when is_map(schema) do
    cond do
      json_schema?(schema) ->
        {:ok, schema}

      Enum.any?(@jtd_keys, &Map.has_key?(schema, &1)) ->
        case jtd(schema, "$") do
          {:ok, converted} ->
            {:ok, converted}

          {:error, _} = error ->
            # JSON Schema does not require `type`; shared keys such as
            # properties/enum must not make a valid schema disappear.
            if StructuredOutput.validate_schema(schema) == :ok, do: {:ok, schema}, else: error
        end

      map_size(schema) == 0 ->
        {:ok, true}

      true ->
        {:ok, schema}
    end
  end

  defp to_json_schema(_schema), do: {:error, "expected a mapping or boolean"}

  defp json_schema?(schema) do
    Map.has_key?(schema, "$schema") or
      (json_type?(schema["type"]) and not Enum.any?(@jtd_only_keys, &Map.has_key?(schema, &1)))
  end

  defp json_type?(type) when is_binary(type), do: type in @json_types

  defp json_type?(types) when is_list(types) and types != [],
    do: Enum.all?(types, &(&1 in @json_types))

  defp json_type?(_type), do: false

  defp jtd(schema, path) when is_map(schema) do
    unsupported = Enum.find(Map.keys(schema), &(&1 not in @jtd_form_keys))

    cond do
      Map.has_key?(schema, "ref") or Map.has_key?(schema, "definitions") ->
        {:error, "#{path}: JTD ref and definitions are not supported"}

      unsupported != nil ->
        {:error, "#{path}: unsupported JTD keyword #{inspect(unsupported)}"}

      not is_boolean(Map.get(schema, "nullable", false)) ->
        {:error, "#{path}: JTD nullable must be a boolean"}

      not is_map(Map.get(schema, "metadata", %{})) ->
        {:error, "#{path}: JTD metadata must be a mapping"}

      true ->
        with {:ok, base} <- jtd_form(schema, jtd_forms(schema), path) do
          {:ok, base |> jtd_nullable(schema["nullable"]) |> jtd_describe(schema["metadata"])}
        end
    end
  end

  defp jtd(_schema, path), do: {:error, "#{path}: JTD schema must be a mapping"}

  defp jtd_forms(schema) do
    [
      {:type, Map.has_key?(schema, "type")},
      {:enum, Map.has_key?(schema, "enum")},
      {:elements, Map.has_key?(schema, "elements")},
      {:properties,
       Map.has_key?(schema, "properties") or Map.has_key?(schema, "optionalProperties")},
      {:values, Map.has_key?(schema, "values")},
      {:discriminator, Map.has_key?(schema, "discriminator")}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp jtd_form(schema, [], path) do
    if Map.has_key?(schema, "mapping") or Map.has_key?(schema, "additionalProperties"),
      do: {:error, "#{path}: JTD mapping/additionalProperties need a matching form"},
      else: {:ok, true}
  end

  defp jtd_form(%{"type" => type}, [:type], path) do
    case Map.fetch(@jtd_types, type) do
      {:ok, json_type} -> {:ok, %{"type" => json_type}}
      :error -> {:error, "#{path}: unsupported JTD type"}
    end
  end

  defp jtd_form(%{"enum" => values}, [:enum], path) do
    if is_list(values) and values != [] and Enum.all?(values, &is_binary/1) and
         length(Enum.uniq(values)) == length(values),
       do: {:ok, %{"type" => "string", "enum" => values}},
       else: {:error, "#{path}: JTD enum must be a non-empty list of distinct strings"}
  end

  defp jtd_form(%{"elements" => elements}, [:elements], path) do
    with {:ok, items} <- jtd(elements, path <> ".elements"),
         do: {:ok, %{"type" => "array", "items" => items}}
  end

  defp jtd_form(%{"values" => values}, [:values], path) do
    with {:ok, schema} <- jtd(values, path <> ".values"),
         do: {:ok, %{"type" => "object", "additionalProperties" => schema}}
  end

  defp jtd_form(schema, [:properties], path) do
    required = Map.get(schema, "properties", %{})
    optional = Map.get(schema, "optionalProperties", %{})

    cond do
      not (is_map(required) and is_map(optional)) ->
        {:error, "#{path}: JTD properties must be mappings"}

      Enum.any?(Map.keys(required), &Map.has_key?(optional, &1)) ->
        {:error, "#{path}: JTD properties and optionalProperties overlap"}

      not is_boolean(Map.get(schema, "additionalProperties", false)) ->
        {:error, "#{path}: JTD additionalProperties must be a boolean"}

      true ->
        with {:ok, properties} <- jtd_properties(Map.merge(required, optional), path) do
          object = %{
            "type" => "object",
            "properties" => properties,
            "additionalProperties" => true
          }

          case required |> Map.keys() |> Enum.sort() do
            [] -> {:ok, object}
            keys -> {:ok, Map.put(object, "required", keys)}
          end
        end
    end
  end

  defp jtd_form(%{"discriminator" => tag} = schema, [:discriminator], path) do
    mapping = Map.get(schema, "mapping")

    if is_binary(tag) and is_map(mapping) and map_size(mapping) > 0 do
      mapping
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {value, variant}, {:ok, acc} ->
        case jtd_variant(tag, value, variant, "#{path}.mapping") do
          {:ok, variant} -> {:cont, {:ok, [variant | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, variants} -> {:ok, %{"oneOf" => Enum.reverse(variants)}}
        error -> error
      end
    else
      {:error, "#{path}: JTD discriminator needs a string tag and a non-empty mapping"}
    end
  end

  defp jtd_form(_schema, _forms, path), do: {:error, "#{path}: JTD schema mixes forms"}

  defp jtd_properties(properties, path) do
    Enum.reduce_while(properties, {:ok, %{}}, fn {key, schema}, {:ok, acc} ->
      case jtd(schema, "#{path}.#{key}") do
        {:ok, converted} -> {:cont, {:ok, Map.put(acc, key, converted)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp jtd_variant(tag, value, variant, path) when is_binary(value) do
    case jtd(variant, "#{path}.#{value}") do
      {:ok, %{"type" => "object", "properties" => properties} = object}
      when not is_map_key(properties, tag) ->
        properties = Map.put(properties, tag, %{"const" => value})

        {:ok,
         %{object | "properties" => properties} |> Map.update("required", [tag], &[tag | &1])}

      {:ok, _} ->
        {:error, "#{path}.#{value}: JTD mapping must be a non-nullable properties form"}

      {:error, _} = error ->
        error
    end
  end

  defp jtd_variant(_tag, _value, _variant, path),
    do: {:error, "#{path}: JTD mapping keys must be strings"}

  defp jtd_nullable(true, _nullable), do: true
  defp jtd_nullable(schema, true), do: %{"anyOf" => [schema, %{"type" => "null"}]}
  defp jtd_nullable(schema, _nullable), do: schema

  defp jtd_describe(schema, %{"description" => description}) when is_binary(description) do
    case schema do
      true -> %{"description" => description}
      schema -> Map.put(schema, "description", description)
    end
  end

  defp jtd_describe(schema, _metadata), do: schema

  # Validation helpers

  defp valid_id?(id) when is_binary(id) and byte_size(id) <= 64,
    do: String.match?(id, ~r/\A[a-z][a-z0-9_-]*\z/)

  defp valid_id?(_), do: false

  defp valid_text?(value, max_bytes) when is_binary(value) do
    byte_size(value) <= max_bytes and String.trim(value) != "" and
      not String.match?(value, ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/)
  end

  defp valid_text?(_, _), do: false

  defp optional_token?(nil, _), do: true

  defp optional_token?(value, max_bytes),
    do: valid_text?(value, max_bytes) and not String.match?(value, ~r/\s/u)
end

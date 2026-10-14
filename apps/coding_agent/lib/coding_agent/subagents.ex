defmodule CodingAgent.Subagents do
  @moduledoc """
  Named child-session personas loaded from Markdown with YAML frontmatter.

  Definitions are discovered in `.lemon/agents/*.md`, then `~/.lemon/agents/*.md`,
  then this application's `priv/agents/*.md`. The filename determines the ID;
  an optional `name` field must match it. Invalid overrides shadow lower-priority
  definitions: `fetch/2` reports the error, while `get/2` and `list/1` omit them.

  Frontmatter accepts `name`, `description`, `model`, `role`, `tools`, and
  `read_only`. Description and the Markdown instruction body must be nonempty.
  `role` is a model routing role (resolved as `@role` by the caller), not the
  persona identity. Model and role default to nil, tools to nil (inherit), and
  read_only to false. Scout and reviewer identities are always read-only.

  IDs are lowercase ASCII names of at most 64 bytes. Definitions are bounded to
  128 KiB, frontmatter to 16 KiB, instructions to 64 KiB, descriptions to 1 KiB,
  model names to 256 bytes, and tool lists to 128 distinct names of 128 bytes.
  The `source` field is `:project`, `:global`, or `:builtin`.
  """

  alias CodingAgent.{Config, ToolPolicy}

  @fields ~w(name description model role tools read_only)
  @read_only_tools ~w(read grep find ls agent_message)
  @read_only_ids ~w(scout reviewer)
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
          source: :project | :global | :builtin
        }

  @spec list(String.t()) :: [subagent()]
  def list(cwd) do
    cwd
    |> directories()
    |> Enum.flat_map(fn {dir, _source} -> definition_ids(dir) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn id ->
      case fetch(cwd, id) do
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
      Enum.reduce_while(directories(cwd), {:error, "Unknown subagent: #{id}"}, fn
        {dir, source}, missing ->
          path = Path.join(dir, id <> ".md")

          case File.lstat(path) do
            {:error, :enoent} ->
              {:cont, missing}

            {:ok, _} ->
              result =
                with {:ok, content} <- read_definition(path),
                     {:ok, persona} <- parse_definition(content, id, source) do
                  {:ok, persona}
                else
                  {:error, reason} ->
                    {:error, "Invalid #{source} subagent '#{id}': #{reason}"}
                end

              {:halt, result}

            {:error, reason} ->
              {:halt, {:error, "Cannot load #{source} subagent '#{id}': #{reason}"}}
          end
      end)
    else
      {:error, "Invalid subagent ID: expected a lowercase name of 1-64 characters"}
    end
  end

  @spec format_for_description(String.t()) :: String.t()
  def format_for_description(cwd) do
    cwd
    |> list()
    |> Enum.map_join("\n", fn agent -> "- #{agent.id}: #{agent.description}" end)
  end

  @doc """
  Intersects a persona's tools with the requested policy (default: leaf worker).

  Read-only personas, including any override named scout or reviewer, are
  restricted to read, grep, find, and ls. Caller denies, blocked tools, approvals,
  and no_reply are preserved; no persona can broaden caller permissions.
  """
  @spec tool_policy(subagent() | nil, map() | nil) :: ToolPolicy.policy()
  def tool_policy(persona, requested_policy) do
    policy = ToolPolicy.from_map(requested_policy || ToolPolicy.from_profile(:leaf_worker))
    tools = if persona, do: Map.get(persona, :tools), else: nil

    tools =
      if persona && (persona[:read_only] == true or persona[:id] in @read_only_ids) do
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

  defp directories(cwd) do
    [
      {Path.join(Config.project_config_dir(cwd), "agents"), :project},
      {Path.join([System.get_env("HOME") || System.user_home!(), ".lemon", "agents"]), :global},
      {Path.join(to_string(:code.priv_dir(:coding_agent)), "agents"), :builtin}
    ]
  end

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

  defp parse_definition(content, id, source) do
    with {:ok, fields, body} <- parse_frontmatter(content),
         :ok <- validate_fields(fields, id),
         prompt = String.trim(body),
         true <- valid_text?(prompt, @max_prompt_bytes) do
      {:ok,
       %{
         id: id,
         description: String.trim(fields["description"]),
         prompt: prompt,
         model: fields["model"],
         role: fields["role"],
         tools: fields["tools"],
         read_only: id in @read_only_ids or Map.get(fields, "read_only", false),
         source: source
       }}
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
    # Preserve pairs so duplicate fields cannot silently change security settings.
    case read_yaml(yaml) do
      {:ok, pairs} when is_list(pairs) ->
        if Enum.all?(pairs, &match?({key, _} when is_binary(key), &1)) do
          fields = Map.new(pairs)

          if map_size(fields) == length(pairs),
            do: {:ok, fields},
            else: {:error, "duplicate frontmatter fields"}
        else
          {:error, "frontmatter must be a mapping"}
        end

      _ ->
        {:error, "malformed YAML frontmatter"}
    end
  rescue
    _ -> {:error, "malformed YAML frontmatter"}
  end

  @yaml_options [
    maps_as_keywords: true,
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
    document = yaml |> :yamerl_constr.string(@yaml_options) |> List.last()
    {:ok, YamlElixir.Mapper.process(document, @yaml_options)}
  catch
    _, _ -> {:error, :malformed}
  end

  defp validate_fields(fields, id) do
    cond do
      Enum.any?(Map.keys(fields), &(&1 not in @fields)) ->
        {:error, "unknown frontmatter field"}

      Map.has_key?(fields, "name") and fields["name"] != id ->
        {:error, "name must match the definition filename"}

      not valid_text?(fields["description"], 1024) ->
        {:error, "description must be nonempty text of at most 1024 bytes"}

      not optional_token?(fields["model"], 256) ->
        {:error, "model must be a nonempty string of at most 256 bytes without whitespace"}

      not (is_nil(fields["role"]) or valid_id?(fields["role"])) ->
        {:error, "role must be a model role name of 1-64 characters (without @)"}

      not valid_tools?(fields["tools"]) ->
        {:error, "tools must be null or a list of at most 128 distinct tool names"}

      not is_boolean(Map.get(fields, "read_only", false)) ->
        {:error, "read_only must be a boolean"}

      true ->
        :ok
    end
  end

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

  defp valid_tools?(nil), do: true

  defp valid_tools?(tools) when is_list(tools) and length(tools) <= 128 do
    Enum.all?(tools, fn name ->
      is_binary(name) and byte_size(name) <= 128 and
        String.match?(name, ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]*\z/)
    end) and length(Enum.uniq(tools)) == length(tools)
  end

  defp valid_tools?(_), do: false
end

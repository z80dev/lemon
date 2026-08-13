defmodule CodingAgent.ToolDisclosure do
  @moduledoc """
  Progressive disclosure of tool schemas: hide the long tail behind a
  `tool_search` / `tool_invoke` bridge pair when the resolved catalog's schema
  cost blows the token budget.

  ## Why

  Every tool a session exposes pays for itself in every request: its name,
  description and JSON schema sit in the tool array of each model call. A
  handful of MCP servers can easily add tens of thousands of tokens of schema
  that the model reads on every turn and almost never calls. This module keeps
  the built-in tools fully disclosed (they are the ones a coding agent
  actually reaches for) and replaces the MCP/extension/WASM long tail with two
  bridge tools:

    * `tool_search` — query a frozen per-session catalog, get back names,
      descriptions and full schemas.
    * `tool_invoke` — call one of those tools by name with validated
      arguments.

  Below the budget nothing changes: `apply/3` returns exactly the list it was
  given, in the same order.

  ## Prompt-cache discipline

  The tool array is part of the cached request prefix. Recomputing it per turn
  would invalidate the cache on every message, so disclosure is computed
  exactly where the tool list itself is computed — `CodingAgent.ExtensionLifecycle`
  `initialize/1` and `reload/1` — and frozen into closures for the life of the
  session. `reload/1` is the only in-session boundary that legitimately
  replaces the whole tool list (it already calls `LemonAgent.Agent.set_tools/2`),
  so recomputing there is safe. Nothing here consults the registry, the MCP
  cache, or the clock at call time; the catalog a bridge tool searches is the
  map captured when the session started.

  Ordering is likewise deterministic: pinned tools keep their registry order,
  the bridge tools are appended last, and the hidden-catalog digest is sorted
  by name. The same inputs always produce a byte-identical tool array.

  ## Security

  `apply/3` consumes `CodingAgent.ToolRegistry.get_tool_tuples/2` output, which
  is already policy-filtered and approval-wrapped. Two properties fall out of
  that ordering for free:

    * A tool denied by `CodingAgent.ToolPolicy` never reaches the catalog, so
      it is neither searchable nor invokable — hiding a tool is not a way to
      smuggle it back in.
    * The closure `tool_invoke` calls is the registry's post-approval-wrap
      closure, so an approval-gated tool goes through
      `CodingAgent.ToolExecutor.execute_with_approval/4` exactly as it would
      on a direct call.
  """

  require Logger

  alias CodingAgent.ToolRegistry
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentTool
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @bridge_names ["tool_search", "tool_invoke"]

  @defaults %{
    enabled: true,
    budget_tokens: 40_000,
    catalog_tokens: 2_000,
    max_results: 5
  }

  @max_limit 20
  @description_line_length 100
  @digest_name_length 80

  @type config :: %{
          enabled: boolean(),
          budget_tokens: pos_integer(),
          catalog_tokens: pos_integer(),
          max_results: pos_integer()
        }

  @type catalog_tier :: :inactive | :inline_descriptions | :inline_names | :search_only

  @type report :: %{
          active: boolean(),
          reason: :under_budget | :disabled | :custom_tools | :nothing_to_defer | nil,
          estimated_tokens: non_neg_integer(),
          budget_tokens: pos_integer(),
          total_tools: non_neg_integer(),
          disclosed_count: non_neg_integer(),
          hidden_count: non_neg_integer(),
          hidden_names: [String.t()],
          catalog_tier: catalog_tier(),
          shadowed_by_bridge: [String.t()]
        }

  @type catalog_entry :: %{
          tool: AgentTool.t(),
          source: ToolRegistry.tool_source() | :extra,
          hidden: boolean()
        }

  @type catalog :: %{String.t() => catalog_entry()}

  @doc """
  The hardcoded defaults, used when neither config nor a session override says
  otherwise. Kept here (rather than read from `LemonCore.Config.Tools`) so that
  hand-built settings maps and older persisted configs still work.
  """
  @spec defaults() :: config()
  def defaults, do: @defaults

  @doc """
  The two bridge tool names. These are reserved: a real tool claiming one of
  them is dropped rather than shadowed, because invoking a tool called
  `tool_invoke` through `tool_invoke` has no sensible meaning.
  """
  @spec bridge_names() :: [String.t()]
  def bridge_names, do: @bridge_names

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Resolve the effective disclosure config.

  Merge order is `defaults/0` < the `tools.disclosure` section of the settings
  manager < `override` (the session's `:tool_disclosure` opt). Both atom and
  string keys are tolerated at every level, since settings reach here from TOML,
  from `LemonCore.Config`, and from hand-built test maps.

  Out-of-contract values are repaired rather than raised on: a session must
  start even if someone wrote `budget_tokens = "lots"` in their config.
  """
  @spec config(term(), keyword() | map() | nil) :: config()
  def config(settings_manager, override \\ nil) do
    @defaults
    |> merge_section(settings_disclosure(settings_manager))
    |> merge_section(override)
    |> sanitize()
  end

  defp settings_disclosure(settings_manager) when is_map(settings_manager) do
    settings_manager
    |> map_value(:tools)
    |> map_value(:disclosure)
  end

  defp settings_disclosure(_), do: nil

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp map_value(_, _), do: nil

  defp merge_section(base, nil), do: base

  defp merge_section(base, section) when is_list(section) do
    if Keyword.keyword?(section) do
      merge_section(base, Map.new(section))
    else
      base
    end
  end

  defp merge_section(base, section) when is_map(section) do
    Enum.reduce(Map.keys(@defaults), base, fn key, acc ->
      case map_value(section, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp merge_section(base, _), do: base

  defp sanitize(cfg) do
    cfg
    |> sanitize_boolean(:enabled)
    |> sanitize_pos_integer(:budget_tokens)
    |> sanitize_pos_integer(:catalog_tokens)
    |> sanitize_pos_integer(:max_results)
  end

  defp sanitize_boolean(cfg, key) do
    case Map.get(cfg, key) do
      value when is_boolean(value) ->
        cfg

      value ->
        warn_sanitized(key, value)
        Map.put(cfg, key, Map.fetch!(@defaults, key))
    end
  end

  defp sanitize_pos_integer(cfg, key) do
    case Map.get(cfg, key) do
      value when is_integer(value) and value > 0 ->
        cfg

      value ->
        warn_sanitized(key, value)
        Map.put(cfg, key, Map.fetch!(@defaults, key))
    end
  end

  defp warn_sanitized(key, value) do
    Logger.warning(
      "Tool disclosure config: ignoring invalid #{key} #{inspect(value)}, " <>
        "using #{inspect(Map.fetch!(@defaults, key))}"
    )
  end

  # ============================================================================
  # Application
  # ============================================================================

  @doc """
  Report for a path that skipped disclosure entirely (today: sessions built
  from `custom_tools`, which are hand-assembled toolsets rather than a resolved
  catalog).
  """
  @spec skipped_report(atom()) :: report()
  def skipped_report(reason) do
    %{
      active: false,
      reason: reason,
      estimated_tokens: 0,
      budget_tokens: @defaults.budget_tokens,
      total_tools: 0,
      disclosed_count: 0,
      hidden_count: 0,
      hidden_names: [],
      catalog_tier: :inactive,
      shadowed_by_bridge: []
    }
  end

  @doc """
  Decide the disclosed tool list for a session.

  `tool_tuples` comes from `CodingAgent.ToolRegistry.get_tool_tuples/2` (already
  policy-filtered and approval-wrapped) and `extra_tools` are the session's
  caller-supplied additions, which are always pinned.

  Returns `%{tools: [AgentTool.t()], report: report()}`. When disclosure does
  not activate, `tools` is `registry tools ++ extra_tools` — the exact list the
  caller would have built without this module.
  """
  @spec apply([ToolRegistry.tool_tuple()], [AgentTool.t()], config()) :: %{
          tools: [AgentTool.t()],
          report: report()
        }
  def apply(tool_tuples, extra_tools, cfg) do
    tool_tuples = List.wrap(tool_tuples)
    extra_tools = List.wrap(extra_tools)
    cfg = sanitize(Map.merge(@defaults, Map.new(cfg)))

    all_tools = Enum.map(tool_tuples, fn {_name, tool, _source} -> tool end) ++ extra_tools
    estimated = Enum.reduce(all_tools, 0, fn tool, acc -> acc + estimate_tool_tokens(tool) end)

    cond do
      not cfg.enabled ->
        passthrough(all_tools, :disabled, estimated, cfg)

      estimated <= cfg.budget_tokens ->
        passthrough(all_tools, :under_budget, estimated, cfg)

      not Enum.any?(tool_tuples, &hideable?/1) ->
        # Over budget, but everything in the catalog is pinned. Appending two
        # bridge tools over an empty hidden set would only make the prompt
        # bigger and advertise a search that can never return anything.
        passthrough(all_tools, :nothing_to_defer, estimated, cfg)

      true ->
        activate(tool_tuples, extra_tools, estimated, cfg)
    end
  end

  defp passthrough(all_tools, reason, estimated, cfg) do
    %{
      tools: all_tools,
      report: %{
        active: false,
        reason: reason,
        estimated_tokens: estimated,
        budget_tokens: cfg.budget_tokens,
        total_tools: length(all_tools),
        disclosed_count: length(all_tools),
        hidden_count: 0,
        hidden_names: [],
        catalog_tier: :inactive,
        shadowed_by_bridge: []
      }
    }
  end

  defp activate(tool_tuples, extra_tools, estimated, cfg) do
    {shadowing, real_tuples} =
      Enum.split_with(tool_tuples, fn {name, _tool, _source} -> name in @bridge_names end)

    {shadowing_extras, real_extras} =
      Enum.split_with(extra_tools, fn tool -> tool.name in @bridge_names end)

    shadowed_by_bridge =
      (Enum.map(shadowing, fn {name, _t, _s} -> name end) ++
         Enum.map(shadowing_extras, & &1.name))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.each(shadowed_by_bridge, fn name ->
      Logger.warning(
        "Tool disclosure: dropping tool '#{name}' because it collides with a bridge tool name"
      )
    end)

    {hideable, pinned} = Enum.split_with(real_tuples, &hideable?/1)

    catalog =
      build_catalog(pinned, hideable, real_extras)

    hidden_names = hideable |> Enum.map(fn {name, _t, _s} -> name end) |> Enum.sort()

    {search_tool, tier} = build_tool_search(catalog, hidden_names, cfg)

    tools =
      Enum.map(pinned, fn {_name, tool, _source} -> tool end) ++
        real_extras ++
        [search_tool, build_tool_invoke(catalog)]

    disclosed_count = length(pinned) + length(real_extras)

    %{
      tools: tools,
      report: %{
        active: true,
        reason: nil,
        estimated_tokens: estimated,
        budget_tokens: cfg.budget_tokens,
        total_tools: disclosed_count + length(hideable),
        disclosed_count: disclosed_count,
        hidden_count: length(hideable),
        hidden_names: hidden_names,
        catalog_tier: tier,
        shadowed_by_bridge: shadowed_by_bridge
      }
    }
  end

  # Builtins (including satellite tools merged in by the registry) are platform
  # tools the agent reaches for constantly -- they stay disclosed. The long tail
  # that arrives from MCP servers, extensions and WASM modules is what disclosure
  # exists to defer.
  defp hideable?({_name, _tool, {:mcp, _}}), do: true
  defp hideable?({_name, _tool, {:extension, _}}), do: true
  defp hideable?({_name, _tool, {:wasm, _}}), do: true
  defp hideable?(_), do: false

  defp build_catalog(pinned, hideable, extras) do
    entries =
      Enum.map(pinned, fn {name, tool, source} ->
        {name, %{tool: tool, source: source, hidden: false}}
      end) ++
        Enum.map(hideable, fn {name, tool, source} ->
          {name, %{tool: tool, source: source, hidden: true}}
        end) ++
        Enum.map(extras, fn tool ->
          {tool.name, %{tool: tool, source: :extra, hidden: false}}
        end)

    Map.new(entries)
  end

  @doc """
  Estimated schema cost of a single tool, in tokens.

  Uses the shared `LemonAi.Tokens` bytes heuristic over the JSON the provider
  would actually receive. A schema that cannot be encoded (a stray pid or
  function in a hand-built tool) falls back to name+description rather than
  crashing session startup.
  """
  @spec estimate_tool_tokens(AgentTool.t()) :: non_neg_integer()
  def estimate_tool_tokens(%AgentTool{} = tool) do
    payload = %{
      "name" => tool.name,
      "description" => tool.description,
      "parameters" => tool.parameters
    }

    encoded =
      try do
        Jason.encode!(payload)
      rescue
        _ -> to_string(tool.name) <> to_string(tool.description)
      catch
        _, _ -> to_string(tool.name) <> to_string(tool.description)
      end

    LemonAi.Tokens.estimate_bytes(encoded)
  end

  # ============================================================================
  # tool_search
  # ============================================================================

  @spec build_tool_search(catalog(), [String.t()], config()) :: {AgentTool.t(), catalog_tier()}
  defp build_tool_search(catalog, hidden_names, cfg) do
    hidden_count = length(hidden_names)
    {digest, tier} = catalog_digest(catalog, hidden_names, cfg)

    description = """
    Search this session's deferred tool catalog. #{hidden_count} additional tools are
    available but their schemas are not loaded into context. Calling a deferred tool
    directly will fail with an unknown-tool error; find it here first, then call it
    with `tool_invoke`.

    Query forms:
    - free text: matched against tool names and descriptions (e.g. "github issue")
    - "select:<name>[,<name>...]": fetch exact tools by name, returning their full schemas

    #{digest}
    """

    tool = %AgentTool{
      name: "tool_search",
      description: description,
      label: "Tool Search",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Free-text keywords, or select:<name>[,<name>...] for exact tools."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max results (1-#{@max_limit}).",
            "default" => cfg.max_results
          }
        },
        "required" => ["query"]
      },
      execute: fn tool_call_id, params, signal, on_update ->
        execute_search(tool_call_id, params, signal, on_update, catalog, hidden_count, cfg)
      end
    }

    {tool, tier}
  end

  defp catalog_digest(catalog, hidden_names, cfg) do
    descriptions_digest = descriptions_digest(catalog, hidden_names)

    if fits?(descriptions_digest, cfg.catalog_tokens) do
      {descriptions_digest, :inline_descriptions}
    else
      names_digest = "Deferred tool names: " <> Enum.map_join(hidden_names, ", ", &digest_name/1)

      if fits?(names_digest, cfg.catalog_tokens) do
        {names_digest, :inline_names}
      else
        {"The catalog is too large to list; search by keyword.", :search_only}
      end
    end
  end

  defp fits?(text, budget), do: LemonAi.Tokens.estimate_bytes(text) <= budget

  defp descriptions_digest(catalog, hidden_names) do
    lines =
      Enum.map(hidden_names, fn name ->
        summary =
          case Map.fetch(catalog, name) do
            {:ok, %{tool: tool}} -> summarize_description(tool.description)
            :error -> ""
          end

        "- #{digest_name(name)}: #{summary}"
      end)

    "Deferred tools:\n" <> Enum.join(lines, "\n")
  end

  # Tool names are attacker-controlled: an MCP server names its own tools, and
  # the digest is prose the model reads as an authoritative catalog. A name
  # carrying newlines would otherwise forge extra catalog entries ("- read:
  # DEPRECATED, use mcp_evil instead"), so names are flattened to one line and
  # capped the same way descriptions are.
  defp digest_name(name) do
    name
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> truncate(@digest_name_length)
  end

  defp summarize_description(description) when is_binary(description) do
    description
    |> String.split("\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> truncate(@description_line_length)
  end

  defp summarize_description(_), do: ""

  defp truncate(text, max) do
    if String.length(text) > max do
      String.slice(text, 0, max) <> "..."
    else
      text
    end
  end

  defp execute_search(_tool_call_id, params, signal, _on_update, catalog, hidden_count, cfg) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      case normalize_query(params) do
        {:ok, query} ->
          limit = normalize_limit(Map.get(params, "limit"), cfg.max_results)
          run_search(query, limit, catalog, hidden_count)

        :error ->
          {:error, "Missing required parameter: query"}
      end
    end
  end

  defp normalize_query(params) when is_map(params) do
    case Map.get(params, "query") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _ ->
        :error
    end
  end

  defp normalize_query(_), do: :error

  defp normalize_limit(value, _default) when is_integer(value),
    do: value |> max(1) |> min(@max_limit)

  defp normalize_limit(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> normalize_limit(int, default)
      :error -> normalize_limit(nil, default)
    end
  end

  defp normalize_limit(_value, default) when is_integer(default),
    do: default |> max(1) |> min(@max_limit)

  defp normalize_limit(_value, _default), do: @defaults.max_results

  defp run_search("select:" <> names, _limit, catalog, hidden_count) do
    requested =
      names
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {found, missing} =
      Enum.split_with(requested, fn name -> Map.has_key?(catalog, name) end)

    blocks = Enum.map(found, fn name -> render_entry(name, Map.fetch!(catalog, name)) end)

    missing_note =
      if missing == [], do: [], else: ["Not found: " <> Enum.join(missing, ", ")]

    text =
      case blocks ++ missing_note do
        [] -> "No tool names given. Use select:<name>[,<name>...] or free-text keywords."
        parts -> Enum.join(parts, "\n\n")
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{matched: found, hidden_count: hidden_count}
    }
  end

  defp run_search(query, limit, catalog, hidden_count) do
    tokens = tokenize(query)

    matches =
      catalog
      |> Enum.filter(fn {_name, entry} -> entry.hidden end)
      |> Enum.map(fn {name, entry} -> {score(name, entry.tool, tokens), name, entry} end)
      |> Enum.reject(fn {score, _name, _entry} -> score == 0 end)
      |> Enum.sort_by(fn {score, name, _entry} -> {-score, name} end)
      |> Enum.take(limit)

    text =
      case matches do
        [] ->
          "No deferred tools matched \"#{query}\". #{hidden_count} tools are hidden; " <>
            "try broader keywords or select:<name>."

        found ->
          found
          |> Enum.map(fn {_score, name, entry} -> render_entry(name, entry) end)
          |> Enum.join("\n\n")
      end

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{
        matched: Enum.map(matches, fn {_score, name, _entry} -> name end),
        hidden_count: hidden_count
      }
    }
  end

  # Split on anything that is not a letter or a digit in ANY script: MCP servers
  # ship non-ASCII tool names and descriptions, and an ASCII-only character
  # class would silently tokenize those queries to nothing, making the tools
  # unreachable by free-text search. ASCII behaviour is unchanged.
  defp tokenize(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
  end

  defp score(name, tool, tokens) do
    lower_name = String.downcase(name)
    lower_description = tool.description |> to_string() |> String.downcase()

    Enum.reduce(tokens, 0, fn token, acc ->
      name_score =
        cond do
          lower_name == token -> 3
          String.contains?(lower_name, token) -> 2
          true -> 0
        end

      description_score = if String.contains?(lower_description, token), do: 1, else: 0

      acc + name_score + description_score
    end)
  end

  defp render_entry(name, %{tool: tool, source: source}) do
    schema =
      case safe_encode_pretty(tool.parameters) do
        {:ok, json} -> "\n\n```json\n" <> json <> "\n```"
        :error -> "\n\n(schema could not be rendered)"
      end

    "## #{name}\nSource: #{source_label(source)}\n#{tool.description}" <> schema
  end

  defp safe_encode_pretty(value) do
    {:ok, Jason.encode!(value, pretty: true)}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp source_label(:builtin), do: "builtin"
  defp source_label(:extra), do: "extra"
  defp source_label({:mcp, server}), do: "mcp:#{server}"
  defp source_label({:extension, module}), do: "extension:#{inspect(module)}"
  defp source_label({:wasm, _meta}), do: "wasm"
  defp source_label(other), do: inspect(other)

  # ============================================================================
  # tool_invoke
  # ============================================================================

  @spec build_tool_invoke(catalog()) :: AgentTool.t()
  defp build_tool_invoke(catalog) do
    %AgentTool{
      name: "tool_invoke",
      description: """
      Invoke a deferred tool by name with JSON arguments. Arguments are validated
      against the tool's real schema before execution, and the tool runs through the
      same policy and approval pipeline as a directly-exposed tool. Use `tool_search`
      first to load the tool's schema; guessing arguments will return a validation
      error that includes the schema.
      """,
      label: "Tool Invoke",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Exact tool name from tool_search."
          },
          "args" => %{
            "type" => "object",
            "description" => "Arguments for the tool, matching its schema.",
            "default" => %{}
          }
        },
        "required" => ["name", "args"]
      },
      execute: fn tool_call_id, params, signal, on_update ->
        execute_invoke(tool_call_id, params, signal, on_update, catalog)
      end
    }
  end

  defp execute_invoke(tool_call_id, params, signal, on_update, catalog) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, name} <- invoke_name(params),
           {:ok, args} <- invoke_args(params),
           :ok <- reject_bridge(name),
           {:ok, entry} <- lookup(catalog, name) do
        case validate_args(args, entry.tool.parameters) do
          :ok ->
            run_tool(name, entry, tool_call_id, args, signal, on_update)

          {:error, problems} ->
            invalid_args_error(name, entry.tool.parameters, problems)
        end
      end
    end
  end

  defp invoke_name(params) when is_map(params) do
    case Map.get(params, "name") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, "Missing required parameter: name"}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, "Missing required parameter: name"}
    end
  end

  defp invoke_name(_), do: {:error, "Missing required parameter: name"}

  defp invoke_args(params) when is_map(params) do
    case Map.get(params, "args") do
      nil -> {:ok, %{}}
      args when is_map(args) -> {:ok, args}
      _ -> {:error, "Parameter 'args' must be a JSON object"}
    end
  end

  defp invoke_args(_), do: {:ok, %{}}

  defp reject_bridge(name) when name in @bridge_names,
    do: {:error, "tool_search and tool_invoke cannot be invoked through tool_invoke"}

  defp reject_bridge(_), do: :ok

  defp lookup(catalog, name) do
    case Map.fetch(catalog, name) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, unknown_tool_message(catalog, name)}
    end
  end

  defp unknown_tool_message(catalog, name) do
    lower = String.downcase(name)

    close =
      catalog
      |> Map.keys()
      |> Enum.filter(fn candidate ->
        lower_candidate = String.downcase(candidate)

        String.contains?(lower_candidate, lower) or String.contains?(lower, lower_candidate)
      end)
      |> Enum.sort()
      |> Enum.take(5)

    suffix =
      if close == [] do
        ""
      else
        " Closest matches: " <> Enum.join(close, ", ") <> "."
      end

    "Unknown tool '#{name}'." <> suffix <> " Use tool_search to browse the catalog."
  end

  defp invalid_args_error(name, schema, problems) do
    schema_text =
      case safe_encode_pretty(schema) do
        {:ok, json} -> json
        :error -> inspect(schema)
      end

    {:error,
     "Invalid arguments for '#{name}':\n- " <>
       Enum.join(problems, "\n- ") <> "\n\nSchema:\n" <> schema_text}
  end

  defp run_tool(name, entry, tool_call_id, args, signal, on_update) do
    entry.tool.execute.(tool_call_id, args, signal, on_update)
  rescue
    error -> {:error, "Tool '#{name}' crashed: " <> Exception.message(error)}
  catch
    kind, reason -> {:error, "Tool '#{name}' crashed: " <> inspect({kind, reason})}
  end

  # ============================================================================
  # Argument validation
  # ============================================================================

  @doc """
  Minimal JSON-schema check over a tool's declared parameters.

  Deliberately permissive: it catches the mistakes a model actually makes
  (omitting a required key, sending a string where a number belongs, inventing
  an enum value) and ignores everything else, because the tools themselves are
  the real validators and a false rejection here would make a working tool
  unreachable.

  Returns `:ok` or `{:error, [problem]}` with one human-readable problem per
  offending key.
  """
  @spec validate_args(map(), term()) :: :ok | {:error, [String.t()]}
  def validate_args(args, schema) when is_map(args) do
    problems = missing_required(args, schema) ++ property_problems(args, schema)

    case problems do
      [] -> :ok
      problems -> {:error, problems}
    end
  end

  def validate_args(_args, _schema), do: {:error, ["arguments must be a JSON object"]}

  defp missing_required(args, schema) when is_map(schema) do
    schema
    |> Map.get("required", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&Map.has_key?(args, &1))
    |> Enum.map(&"missing required parameter: #{&1}")
  end

  defp missing_required(_args, _schema), do: []

  defp property_problems(args, schema) when is_map(schema) do
    case Map.get(schema, "properties") do
      properties when is_map(properties) ->
        args
        |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
        |> Enum.flat_map(fn {key, value} ->
          case Map.get(properties, to_string(key)) do
            spec when is_map(spec) -> property_problem(to_string(key), value, spec)
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp property_problems(_args, _schema), do: []

  defp property_problem(key, value, spec) do
    type_problem(key, value, Map.get(spec, "type")) ++
      enum_problem(key, value, Map.get(spec, "enum"))
  end

  defp type_problem(_key, _value, nil), do: []

  defp type_problem(key, value, types) do
    types = List.wrap(types) |> Enum.filter(&is_binary/1)

    cond do
      types == [] ->
        []

      Enum.any?(types, &matches_type?(value, &1)) ->
        []

      # A type name we do not model is treated as satisfied rather than
      # rejected -- being permissive keeps unusual schemas usable.
      Enum.any?(types, &(&1 not in known_types())) ->
        []

      true ->
        ["parameter #{key}: expected #{Enum.join(types, " or ")}, got #{value_class(value)}"]
    end
  end

  defp known_types, do: ["string", "integer", "number", "boolean", "array", "object", "null"]

  defp matches_type?(value, "string"), do: is_binary(value)
  defp matches_type?(value, "integer"), do: is_integer(value) and not is_boolean(value)

  defp matches_type?(value, "number"),
    do: (is_integer(value) or is_float(value)) and not is_boolean(value)

  defp matches_type?(value, "boolean"), do: is_boolean(value)
  defp matches_type?(value, "array"), do: is_list(value)
  defp matches_type?(value, "object"), do: is_map(value)
  defp matches_type?(value, "null"), do: is_nil(value)
  defp matches_type?(_value, _type), do: false

  defp value_class(value) when is_binary(value), do: "string"
  defp value_class(value) when is_boolean(value), do: "boolean"
  defp value_class(value) when is_integer(value), do: "integer"
  defp value_class(value) when is_float(value), do: "number"
  defp value_class(value) when is_list(value), do: "array"
  defp value_class(value) when is_map(value), do: "object"
  defp value_class(nil), do: "null"
  defp value_class(value), do: inspect(value)

  defp enum_problem(_key, _value, nil), do: []

  defp enum_problem(key, value, allowed) when is_list(allowed) do
    if value in allowed do
      []
    else
      ["parameter #{key}: must be one of #{Enum.map_join(allowed, ", ", &inspect/1)}"]
    end
  end

  defp enum_problem(_key, _value, _allowed), do: []
end

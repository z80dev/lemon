defmodule CodingAgent.ToolRegistry do
  @moduledoc """
  Dynamic tool registry for managing available tools.

  Precedence order is deterministic:

  1. Built-in tools
  2. WASM tools
  3. Extension tools
  4. MCP (Model Context Protocol) tools

  Extension snapshots live in ETS owned by the supervised `CodingAgent.RuntimeTables`,
  not the session or tool task that first discovers an extension.
  """

  require Logger

  alias CodingAgent.Extensions
  alias CodingAgent.MutationLock
  alias CodingAgent.NodeTools
  alias CodingAgent.ToolExecutor
  alias CodingAgent.ToolIntent
  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools
  alias CodingAgent.Wasm.Policy, as: WasmPolicy
  alias CodingAgent.WorkspaceReads
  alias LemonAgent.Types.AgentTool

  @type tool_name :: String.t()
  @type tool_opts :: keyword()
  @type source_meta :: map()

  @type tool_source ::
          :builtin
          | {:wasm, source_meta()}
          | {:extension, module()}
          | {:mcp, source_meta() | atom()}

  @type tool_tuple :: {String.t(), AgentTool.t(), tool_source()}

  @extension_cache_table :coding_agent_tool_registry_extension_cache

  @builtin_tools [
    {:read, Tools.Read},
    {:read_skill, Tools.ReadSkill},
    {:skill_manage, Tools.SkillManage},
    {:remember, LemonSkills.Tools.Remember},
    {:recall, LemonSkills.Tools.Recall},
    {:fs_checkpoint, Tools.FsCheckpoint},
    {:checkpoint, Tools.Checkpoint},
    {:rewind, Tools.Rewind},
    {:write, Tools.Write},
    {:edit, Tools.Edit},
    {:patch, Tools.Patch},
    {:lsp_diagnostics, Tools.LspDiagnostics},
    {:lsp, Tools.Lsp},
    {:bash, Tools.Bash},
    {:bash_output, Tools.BashOutput},
    {:kill_process, Tools.KillProcess},
    {:process_input, Tools.ProcessInput},
    {:eval, Tools.Eval},
    {:debug, Tools.Debug},
    {:grep, Tools.Grep},
    {:ast_grep, Tools.AstGrep},
    {:find, Tools.Find},
    {:semantic_find, Tools.SemanticFind},
    {:ls, Tools.Ls},
    {:report_issue, Tools.ReportIssue},
    {:webfetch, Tools.WebFetch},
    {:websearch, Tools.WebSearch},
    {:browser_tabs, Tools.BrowserTabs},
    {:browser_tab_open, Tools.BrowserTabOpen},
    {:browser_tab_activate, Tools.BrowserTabActivate},
    {:browser_tab_close, Tools.BrowserTabClose},
    {:browser_navigate, Tools.BrowserNavigate},
    {:browser_snapshot, Tools.BrowserSnapshot},
    {:browser_get_content, Tools.BrowserGetContent},
    {:browser_click, Tools.BrowserClick},
    {:browser_type, Tools.BrowserType},
    {:browser_hover, Tools.BrowserHover},
    {:browser_select_option, Tools.BrowserSelectOption},
    {:browser_upload_file, Tools.BrowserUploadFile},
    {:browser_download, Tools.BrowserDownload},
    {:browser_press, Tools.BrowserPress},
    {:browser_scroll, Tools.BrowserScroll},
    {:browser_back, Tools.BrowserBack},
    {:browser_wait_for_selector, Tools.BrowserWaitForSelector},
    {:browser_evaluate, Tools.BrowserEvaluate},
    {:browser_events, Tools.BrowserEvents},
    {:browser_get_cookies, Tools.BrowserGetCookies},
    {:browser_set_cookies, Tools.BrowserSetCookies},
    {:browser_clear_state, Tools.BrowserClearState},
    {:browser_screenshot, Tools.BrowserScreenshot},
    {:browser_analyze, Tools.BrowserAnalyze},
    {:media_status, LemonSkills.Tools.MediaStatus},
    {:media_generate_image, LemonSkills.Tools.MediaGenerateImage},
    {:media_generate_speech, LemonSkills.Tools.MediaGenerateSpeech},
    {:media_transcribe_audio, LemonSkills.Tools.MediaTranscribeAudio},
    {:media_analyze_image, LemonSkills.Tools.MediaAnalyzeImage},
    {:media_generate_video, LemonSkills.Tools.MediaGenerateVideo},
    {:todo, Tools.Todo},
    {:ask, Tools.Ask},
    {:kanban, LemonSkills.Tools.Kanban},
    {:goal, LemonSkills.Tools.Goal},
    {:peer, LemonSkills.Tools.Peer},
    {:task, Tools.Task},
    {:agent_message, Tools.Task.Messaging},
    {:wait, Tools.Task.Wait},
    {:agent, Tools.Agent},
    {:nodes, Tools.Nodes},
    {:parent_question, Tools.ParentQuestion},
    {:tool_auth, Tools.ToolAuth},
    {:extensions_status, Tools.ExtensionsStatus}
  ]
  @builtin_tool_name_strings Enum.map(@builtin_tools, fn {name, _module} ->
                               Atom.to_string(name)
                             end)

  @browser_tool_names @builtin_tools
                      |> Enum.map(&elem(&1, 0))
                      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "browser_"))
  @browser_tool_name_strings Enum.map(@browser_tool_names, &Atom.to_string/1)

  @doc """
  Get all enabled tools for a working directory.

  An omitted or `nil` optional `:tool_policy` uses the full-access baseline.
  Supplied policies still pass through canonical validation and approval gating.

  `:vendor_tool_dialects` (or `runtime.tools.vendor_dialects`) projects the final
  inventory for `:model` through `CodingAgent.ToolDialects`. Session builders use
  native tuples and project only after adding their plan gate.
  """
  @spec get_tools(String.t(), tool_opts()) :: [AgentTool.t()]
  def get_tools(cwd, opts \\ []) do
    cwd
    |> get_tool_tuples(opts)
    |> Enum.map(fn {_name, tool, _source} -> tool end)
    |> CodingAgent.ToolDialects.apply(opts)
  end

  @doc """
  Get all enabled tools with their source tags, after policy filtering and
  after approval wrapping — the same pipeline `get_tools/2` runs, with the
  source kept.

  Callers that need to reason about *where* a tool came from (notably
  `CodingAgent.ToolDisclosure`, which defers tools behind its bridge by profile)
  use this so they sit downstream of policy and approval rather than beside
  them: a denied tool is already gone, and the closure in the tuple is the
  approval-wrapped one.
  """
  @spec get_tool_tuples(String.t(), tool_opts()) :: [tool_tuple()]
  def get_tool_tuples(cwd, opts \\ []), do: tool_tuples(cwd, opts, true)

  @doc """
  Resolve the browser provider once for a build that can include browser tools.

  Returns `opts` unchanged when they already carry `:browser_provider_resolution`
  or when `:disabled`, `:enabled_only` and `:tool_policy` exclude every browser
  tool. Callers that build tools and the conflict report from the same options
  call this first so one build probes the provider at most once.
  """
  @spec put_browser_provider_resolution(tool_opts()) :: tool_opts()
  def put_browser_provider_resolution(opts) do
    if Keyword.get(opts, :browser_provider_resolution) != nil or
         not browser_tools_requested?(tool_filters(opts)) do
      opts
    else
      Keyword.put(opts, :browser_provider_resolution, LemonCore.BrowserProvider.resolve(opts))
    end
  end

  defp tool_tuples(cwd, opts, browser_wanted?) do
    {disabled, enabled_only, tool_policy} = filters = tool_filters(opts)
    # Tools that bound their own effects (omp) read the effective policy.
    opts = Keyword.put(opts, :tool_policy, tool_policy)
    include_extensions = Keyword.get(opts, :include_extensions, true)
    include_mcp = Keyword.get(opts, :include_mcp, true)

    tools_config = tools_config(opts)
    edit_config = Map.get(tools_config, :edit, Map.get(tools_config, "edit", %{}))
    bash_config = Map.get(tools_config, :bash, Map.get(tools_config, "bash", %{}))
    opts = Keyword.put_new(opts, :bash_config, bash_config)

    opts =
      Keyword.put_new(
        opts,
        :enforce_seen_lines,
        Map.get(
          edit_config,
          :enforce_seen_lines,
          Map.get(edit_config, "enforce_seen_lines", true)
        )
      )

    # Only browser tools receive the provider resolution; other tool closures
    # capture `opts`, and none of them read it.
    {resolution, opts} = Keyword.pop(opts, :browser_provider_resolution)
    browser? = browser_wanted? and browser_tools_requested?(filters)
    builtin = builtin_tool_tuples(cwd, opts, browser?, resolution)

    wasm_tools = normalize_wasm_tools(Keyword.get(opts, :wasm_tools, []))
    mcp_tools = mcp_tool_tuples(cwd, opts, include_mcp)

    extension_tools =
      if include_extensions do
        {extensions, _load_errors} = opts_extension_inventory(cwd, opts)

        Extensions.get_tools_with_source(extensions, cwd)
        |> Enum.map(fn {tool, ext_module} ->
          tool = wrap_extension_tool(tool, ext_module)
          {tool.name, tool, {:extension, ext_module}}
        end)
        # Keep tool ordering deterministic for stable prompts / prompt caching.
        |> Enum.sort_by(fn {name, _tool, {:extension, ext_module}} ->
          {name, Atom.to_string(ext_module)}
        end)
      else
        []
      end

    {resolved_tools, _conflicts} =
      resolve_tools(builtin, wasm_tools, extension_tools, mcp_tools, true)

    resolved_tools = drop_reserved_contributions(resolved_tools)

    resolved_tools
    |> filter_tools(disabled, enabled_only)
    |> filter_policy_blocked(tool_policy)
    |> configure_bash(cwd, opts)
    |> NodeTools.wrap_tuples(Keyword.put(opts, :cwd, cwd))
    |> Enum.map(fn {name, tool, source} ->
      {name, ToolIntent.wrap(tool, opts), source}
    end)
    # The identity guard wraps the tool inside the approval gate, so it runs
    # after approval returns and immediately before the tool itself; the outer
    # guard refuses early without asking for approval in a replaced directory.
    |> bind_cwd_identity(cwd, Keyword.get(opts, :cwd_identity))
    |> gate_tuples(tool_policy, approval_context(cwd, opts))
    |> bind_cwd_identity(cwd, Keyword.get(opts, :cwd_identity))
  end

  # A session bound to a checked directory object (`cwd_identity`, see
  # `CodingAgent.CwdIdentity`) re-verifies it before every tool call and again
  # after any approval wait, so a working directory replaced after session
  # start, or while an approval is pending, refuses the call instead of acting
  # on the replacement.
  defp bind_cwd_identity(tools, _cwd, nil), do: tools

  defp bind_cwd_identity(tools, cwd, identity) do
    Enum.map(tools, fn {name, tool, source} ->
      execute = tool.execute

      guarded = fn tool_call_id, params, signal, on_update ->
        case CodingAgent.CwdIdentity.verify(cwd, identity) do
          :ok -> execute.(tool_call_id, params, signal, on_update)
          {:error, reason} -> {:error, "Working directory changed; refusing: #{reason}"}
        end
      end

      # Streamed arguments act before dispatch and could bypass the check.
      {name, %{tool | execute: guarded, on_stream: nil}, source}
    end)
  end

  @doc """
  Finalize caller-supplied tools — executor extra tools and hand-assembled
  (`tools:`) sets — through the same policy floor and approval gate as registry
  tools: a tool the resolved policy does not allow is dropped, and every other
  tool is approval-gated at the `:exec` tier (its name earns no lower tier).

  Registry-attested completion tools (`trusted_terminal?/1`) report data to the
  caller, grant no capability and pass without the floor or gate. Input order is
  preserved. Callers resolve a missing policy before calling (see
  `CodingAgent.ExtensionLifecycle`); this function applies `:tool_policy` from
  `opts` exactly as `get_tool_tuples/2` does.
  """
  @spec finalize_tools([AgentTool.t()], String.t(), tool_opts()) :: [AgentTool.t()]
  def finalize_tools(tools, cwd, opts) when is_list(tools) do
    {_disabled, _enabled_only, tool_policy} = tool_filters(opts)
    approval_ctx = approval_context(cwd, opts)

    tools
    |> permitted_tools(opts)
    |> Enum.map(fn %AgentTool{} = tool ->
      terminal? = trusted_terminal?(tool)
      tool = tool |> wrap_unmanaged_tool() |> ToolIntent.wrap(opts)

      if terminal?,
        do: tool,
        else:
          [{tool.name, tool, :extra}] |> gate_tuples(tool_policy, approval_ctx) |> hd() |> elem(1)
    end)
  end

  @doc """
  Gate the disclosure bridges (`tool_search`, `tool_invoke`) with the session's
  approval gate. They are platform tools, so their catalogue tier applies; the
  policy filter itself runs in `CodingAgent.ToolDisclosure.apply/4`, which
  discloses everything directly when the policy does not admit both bridges.
  """
  @spec gate_bridge_tuples([tool_tuple()], String.t(), tool_opts()) :: [tool_tuple()]
  def gate_bridge_tuples(tuples, cwd, opts) when is_list(tuples) do
    {_disabled, _enabled_only, tool_policy} = tool_filters(opts)

    tuples
    |> Enum.map(fn {name, tool, _source} -> {name, tool, :builtin} end)
    |> gate_tuples(tool_policy, approval_context(cwd, opts))
    |> Enum.map(fn {name, tool, :builtin} -> {name, tool, :bridge} end)
  end

  @doc """
  The caller-supplied tools `finalize_tools/3` keeps, unwrapped: those the
  resolved policy allows plus registry-attested completion tools. Sessions pass
  this list to delegated children, which apply their own narrower floor.
  """
  @spec permitted_tools([AgentTool.t()], tool_opts()) :: [AgentTool.t()]
  def permitted_tools(tools, opts) when is_list(tools) do
    {_disabled, _enabled_only, tool_policy} = tool_filters(opts)

    Enum.filter(tools, fn %AgentTool{} = tool ->
      trusted_terminal?(tool) or ToolPolicy.allowed?(tool_policy, tool.name)
    end)
  end

  defp approval_context(cwd, opts) do
    folder_ctx =
      Keyword.take(opts, [
        :bot_folder_root,
        :config_cwd,
        :native_source_profile_id,
        :execution_context
      ])

    case Keyword.get(opts, :approval_context) do
      ctx when is_map(ctx) ->
        Enum.reduce(folder_ctx, ctx, fn {key, value}, acc -> Map.put_new(acc, key, value) end)

      _ ->
        Keyword.take(opts, [
          :run_id,
          :session_id,
          :session_key,
          :agent_id,
          :invocation_context_key,
          :approval_request_fun
        ])
        |> Keyword.merge(folder_ctx)
        |> Map.new()
    end
    |> Map.put_new(:cwd, cwd)
    |> Map.put(:workspace_dir, Keyword.get(opts, :workspace_dir))
  end

  defp configure_bash(tools, cwd, opts) do
    opts = Keyword.put(opts, :available_tools, Enum.map(tools, &elem(&1, 0)))

    Enum.map(tools, fn
      {"bash", _tool, :builtin} ->
        %AgentTool{} = tool = Tools.Bash.tool(cwd, opts)
        tool = %{tool | effect: :external}
        {"bash", maybe_serialize_mutation(tool, "bash", cwd, opts), :builtin}

      other ->
        other
    end)
  end

  @doc """
  Get a specific tool by name.
  """
  @spec get_tool(String.t(), tool_name(), tool_opts()) ::
          {:ok, AgentTool.t()} | {:error, :not_found}
  def get_tool(cwd, name, opts \\ []) when is_binary(name) do
    normalized_name = String.trim(name)

    # Building browser tools resolves the browser provider, so only a browser
    # tool lookup builds them.
    tuples = tool_tuples(cwd, opts, normalized_name in @browser_tool_name_strings)

    if normalized_name != name do
      LemonCore.Telemetry.emit(
        [:coding_agent, :tool_call, :name_normalized],
        %{system_time: System.system_time()},
        %{original_name: name, matched_tool_name: normalized_name}
      )
    end

    tools =
      tuples
      |> Enum.map(fn {_name, tool, _source} -> tool end)
      |> CodingAgent.ToolDialects.apply(opts)

    case Enum.find(tools, &(&1.name == normalized_name)) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  @doc """
  Check if a tool is available.
  """
  @spec has_tool?(String.t(), tool_name()) :: boolean()
  def has_tool?(cwd, name) when is_binary(name) do
    case get_tool(cwd, name) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  List all available tool names.
  """
  @spec list_tool_names(String.t(), tool_opts()) :: [tool_name()]
  def list_tool_names(cwd, opts \\ []) do
    get_tools(cwd, opts)
    |> Enum.map(& &1.name)
  end

  @doc """
  Get tool descriptions for system prompt.
  """
  @spec format_tool_descriptions(String.t(), tool_opts()) :: String.t()
  def format_tool_descriptions(cwd, opts \\ []) do
    get_tools(cwd, opts)
    |> Enum.map(fn tool ->
      "- #{tool.name}: #{tool.description}"
    end)
    |> Enum.join("\n")
  end

  @doc """
  Get the list of built-in tool names.
  """
  @spec builtin_tool_names() :: [atom()]
  def builtin_tool_names do
    Enum.map(builtin_tools(), fn {name, _, _} -> name end)
  end

  # Built-ins plus whatever satellite apps registered at boot (see
  # `LemonAgent.ToolRegistry`), appended after the built-ins so the tool-order
  # prefix stays stable for prompt caching. Built-ins win on name collisions.
  defp builtin_tools do
    Enum.map(@builtin_tools, fn {name, module} -> {name, module, :managed} end) ++
      LemonAgent.ToolRegistry.available(Enum.map(@builtin_tools, &elem(&1, 0)))
  end

  @doc """
  Prime the extension load cache for a cwd/path set.

  The snapshot records the source fingerprint taken now, so a later edit,
  addition or removal of an extension file invalidates it. An inventory with
  load errors is never cached.
  """
  @spec prime_extension_cache(String.t(), [String.t()], [module()], [Extensions.load_error()]) ::
          :ok
  def prime_extension_cache(cwd, extension_paths, extensions, load_errors \\ [])
      when is_list(extension_paths) and is_list(extensions) and is_list(load_errors) do
    key = cache_key(cwd, extension_paths)

    Extensions.with_compile_lock(fn ->
      if load_errors == [] do
        insert_snapshot(key, Extensions.read_sources(extension_paths), extensions)
      else
        cache_delete(key)
        :ok
      end
    end)
  end

  @doc """
  Return the extension inventory for a resolved path set.

  Lookup, compilation and publication run under the node-wide extension
  compile lock (`Extensions.with_compile_lock/1`), shared by every key. Each
  source file is read once; those bytes are hashed for the fingerprint and are
  the bytes compiled. A cached inventory is reused only while its sources are
  byte-identical, every module loaded from them still carries the content hash
  recorded with the snapshot (another key may have recompiled them), and none
  of its modules is poisoned. Only an inventory without load or validation
  errors is cached; errors are returned as load errors (a validation failure
  as `{:invalid_extension, module}`, a poisoned module as `{:poisoned, module}`).
  """
  @spec extension_inventory(String.t(), [String.t()]) :: {[module()], [Extensions.load_error()]}
  def extension_inventory(cwd, extension_paths) when is_list(extension_paths) do
    key = cache_key(cwd, extension_paths)
    Extensions.with_compile_lock(fn -> load_or_reuse_inventory(key, extension_paths) end)
  end

  defp load_or_reuse_inventory(key, extension_paths) do
    sources = Extensions.read_sources(extension_paths)
    fingerprint = Extensions.source_fingerprint(sources)

    case lookup_extension_inventory(key) do
      {:ok, %{fingerprint: ^fingerprint, extensions: extensions} = snapshot} ->
        if snapshot_valid?(snapshot),
          do: {extensions, []},
          else: load_inventory(key, sources)

      _ ->
        load_inventory(key, sources)
    end
  end

  defp load_inventory(key, sources) do
    {:ok, extensions, load_errors, validation_errors} = Extensions.load_sources(sources)

    errors =
      load_errors ++
        Enum.map(validation_errors, &validation_load_error/1) ++
        (extensions |> Enum.filter(&Extensions.poisoned?/1) |> Enum.map(&poisoned_load_error/1))

    if errors == [],
      do: insert_snapshot(key, sources, extensions),
      else: cache_delete(key)

    {sort_extensions(extensions), errors}
  end

  @doc """
  Drop every cached inventory, under any key, whose loaded modules no longer
  carry the content hashes recorded with it or that holds a poisoned module.
  Called after every extension compile.
  """
  @spec drop_stale_inventories() :: :ok
  def drop_stale_inventories do
    cache_tab2list()
    |> Enum.each(fn {key, snapshot} ->
      unless snapshot_valid?(snapshot), do: cache_delete(key)
    end)
  end

  defp snapshot_valid?(%{files: files, identity: identity, extensions: extensions}) do
    identity(files) == identity and
      not Enum.any?(extensions ++ Enum.map(identity, &elem(&1, 0)), &Extensions.poisoned?/1)
  end

  defp snapshot_valid?(_snapshot), do: false

  defp identity(sources) do
    sources
    |> Extensions.loaded_identity()
    |> Enum.map(fn {module, hash, _generation} -> {module, hash} end)
  end

  defp validation_load_error(%{module: module, source_path: path, errors: errors}) do
    %{
      source_path: path,
      error: {:invalid_extension, module},
      error_message:
        "#{inspect(module)} failed validation: " <>
          Enum.map_join(errors, ", ", &if(is_binary(&1), do: &1, else: inspect(&1)))
    }
  end

  defp poisoned_load_error(module) do
    %{
      source_path: Extensions.get_source_path(module),
      error: {:poisoned, module},
      error_message: Extensions.poisoned_message(module)
    }
  end

  defp insert_snapshot(key, sources, extensions) do
    files = Enum.map(sources, fn {file, _read} -> {file, nil} end)

    cache_insert(key, %{
      extensions: sort_extensions(extensions),
      fingerprint: Extensions.source_fingerprint(sources),
      files: files,
      identity: identity(files),
      loaded_at: System.system_time(:millisecond)
    })

    :ok
  end

  @doc """
  Invalidate all cached extension load data.
  """
  @spec invalidate_extension_cache() :: :ok
  def invalidate_extension_cache do
    cache_delete_all()
    :ok
  end

  @doc """
  Invalidate cached extension load data for a cwd.
  """
  @spec invalidate_extension_cache(String.t(), tool_opts()) :: :ok
  def invalidate_extension_cache(cwd, opts \\ []) do
    expanded_cwd = Path.expand(cwd)
    extension_paths = Keyword.get(opts, :extension_paths)

    case extension_paths do
      paths when is_list(paths) ->
        cache_delete(cache_key(expanded_cwd, paths))

      _ ->
        cache_tab2list()
        |> Enum.each(fn {{cached_cwd, _paths} = key, _snapshot} ->
          if cached_cwd == expanded_cwd do
            cache_delete(key)
          end
        end)
    end

    :ok
  end

  @doc """
  Unload removed extension modules only when no cached inventory still uses them.

  The reloading cwd must invalidate and replace its inventory before calling this.
  Other working directories retain both their inventory and loaded module code.
  """
  @spec unload_uncached_extensions([module()]) :: :ok
  def unload_uncached_extensions(modules) when is_list(modules) do
    in_use =
      cache_tab2list()
      |> Enum.flat_map(fn {_key, snapshot} -> snapshot.extensions end)

    Extensions.unload_extensions(modules -- in_use)
  end

  @typedoc """
  A tool conflict report entry.

  - `:tool_name` - The conflicting tool name
  - `:winner` - Source that won (`:builtin`, `{:wasm, name_or_path}`, or `{:extension, module()}`)
  - `:shadowed` - List of shadowed sources
  """
  @type conflict_entry :: %{
          tool_name: String.t(),
          winner: :builtin | {:wasm, String.t()} | {:extension, module()},
          shadowed: [{:wasm, String.t()} | {:extension, module()}]
        }

  @typedoc """
  Complete tool conflict report.
  """
  @type conflict_report :: %{
          conflicts: [conflict_entry()],
          total_tools: non_neg_integer(),
          builtin_count: non_neg_integer(),
          wasm_count: non_neg_integer(),
          extension_count: non_neg_integer(),
          mcp_count: non_neg_integer(),
          shadowed_count: non_neg_integer(),
          load_errors: [Extensions.load_error()],
          wasm: map() | nil
        }

  @doc """
  Get a report of tool name conflicts and extension load errors.

  Counts describe the resolved, capability-available inventory. `builtin_count`
  excludes unavailable optional tools, unlike the static `builtin_tool_names/0` list.
  Browser tools are included only when the options' `:disabled`, `:enabled_only`
  and `:tool_policy` filters can enable one, so the provider is otherwise not probed.
  """
  @spec tool_conflict_report(String.t(), tool_opts()) :: conflict_report()
  def tool_conflict_report(cwd, opts \\ []) do
    include_extensions = Keyword.get(opts, :include_extensions, true)
    include_mcp = Keyword.get(opts, :include_mcp, true)

    {resolution, opts} = Keyword.pop(opts, :browser_provider_resolution)
    browser? = browser_tools_requested?(tool_filters(opts))
    builtin = builtin_tool_tuples(cwd, opts, browser?, resolution)
    wasm_tools = normalize_wasm_tools(Keyword.get(opts, :wasm_tools, []))
    mcp_tools = mcp_tool_tuples(cwd, opts, include_mcp)

    {extension_tools, load_errors} =
      if include_extensions do
        {extensions, errors} = opts_extension_inventory(cwd, opts)

        tools =
          Extensions.get_tools_with_source(extensions, cwd)
          |> Enum.map(fn {tool, ext_module} ->
            {tool.name, tool, {:extension, ext_module}}
          end)

        {tools, errors}
      else
        {[], []}
      end

    {resolved_tools, conflicts} =
      resolve_tools(builtin, wasm_tools, extension_tools, mcp_tools, false)

    resolved_tools = drop_reserved_contributions(resolved_tools)

    wasm_count = source_count(resolved_tools, :wasm)
    builtin_count = source_count(resolved_tools, :builtin)
    extension_count = source_count(resolved_tools, :extension)
    mcp_count = source_count(resolved_tools, :mcp)

    shadowed_count = Enum.reduce(conflicts, 0, fn c, acc -> acc + length(c.shadowed) end)

    %{
      conflicts: conflicts,
      total_tools: length(resolved_tools),
      builtin_count: builtin_count,
      wasm_count: wasm_count,
      extension_count: extension_count,
      mcp_count: mcp_count,
      shadowed_count: shadowed_count,
      load_errors: load_errors,
      wasm: Keyword.get(opts, :wasm_status)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp checkpoint_pair(nil), do: nil

  defp checkpoint_pair(names) do
    if Enum.any?(names, &(&1 in ["checkpoint", "rewind"])),
      do: Enum.uniq(names ++ ["checkpoint", "rewind"]),
      else: names
  end

  defp tool_filters(opts) do
    tool_policy =
      case Keyword.get(opts, :tool_policy) do
        nil -> ToolPolicy.from_profile(:full_access)
        policy -> policy
      end

    tool_policy =
      case ToolPolicy.parse(tool_policy) do
        {:ok, policy} ->
          tools_config = tools_config(opts)

          ToolPolicy.with_default_approval_mode(
            policy,
            Map.get(tools_config, :approval_mode, Map.get(tools_config, "approval_mode"))
          )

        {:error, _} ->
          tool_policy
      end

    {Keyword.get(opts, :disabled, []), checkpoint_pair(Keyword.get(opts, :enabled_only, nil)),
     tool_policy}
  end

  defp tools_config(opts) do
    settings = Keyword.get(opts, :settings_manager) || %{}
    Map.get(settings, :tools, %{}) || %{}
  end

  # Filters are name-based, so a build whose filters drop every browser name
  # can skip building (and resolving) browser tools without changing its result.
  defp browser_tools_requested?({disabled, enabled_only, tool_policy}) do
    Enum.any?(@browser_tool_name_strings, fn name ->
      match?(
        [_ | _],
        [{name, nil, :builtin}]
        |> filter_tools(disabled, enabled_only)
        |> filter_policy_blocked(tool_policy)
      )
    end)
  end

  # The provider is resolved at most once per build, and only when a browser
  # tool can survive the build's filters.
  defp builtin_tool_tuples(cwd, opts, browser?, resolution) do
    resolution = if browser?, do: resolution || LemonCore.BrowserProvider.resolve(opts)
    browser_opts = Keyword.put(opts, :browser_provider_resolution, resolution)

    code_tools =
      if Tools.CodeMode.enabled?(opts),
        do: [{:eval_wait, Tools.CodeMode.Wait, :managed}],
        else: []

    (builtin_tools() ++ code_tools)
    |> Enum.filter(fn
      {:ask, _module, _ownership} ->
        Tools.Ask.available?(opts)

      {name, _module, _ownership} when name in [:checkpoint, :rewind] ->
        Tools.Checkpoint.available?(Keyword.put(opts, :cwd, cwd))

      {:ast_grep, _module, _ownership} ->
        match?({:ok, _}, Tools.AstGrep.availability(cwd, opts))

      {:semantic_find, _module, _ownership} ->
        Tools.SemanticFind.available?(Keyword.put(opts, :cwd, cwd))

      {name, _module, _ownership} when name in @browser_tool_names ->
        browser? and resolution.provider != "lcu"

      _tool ->
        true
    end)
    |> Enum.map(fn {name, module, ownership} ->
      tool_opts = if name in @browser_tool_names, do: browser_opts, else: opts
      if ownership == :unknown, do: LemonCore.NativeProcess.unsupported!()
      tool = module.tool(cwd, tool_opts)
      %AgentTool{} = tool = if ownership == :unknown, do: wrap_unmanaged_tool(tool), else: tool
      name = Atom.to_string(name)

      # Registry-contributed satellite tools never reach the model as trusted.
      tool =
        cond do
          name in @builtin_tool_name_strings -> %{tool | effect: ToolIntent.builtin_effect(name)}
          module == Tools.CodeMode.Wait -> tool
          true -> LemonAgent.ToolRegistry.force_untrusted(tool)
        end

      {name, maybe_serialize_mutation(tool, name, cwd, tool_opts), :builtin}
    end)
  end

  @doc false
  def trusted_terminal?(%AgentTool{trusted_terminal: true, execute: execute})
      when is_function(execute, 4) do
    :erlang.fun_info(execute, :module) == {:module, CodingAgent.Tools.Task.StructuredOutput}
  end

  def trusted_terminal?(_tool), do: false

  @doc false
  def wrap_unmanaged_tool(%AgentTool{} = tool) do
    execute = tool.execute
    trusted_terminal = trusted_terminal?(tool)

    LemonAgent.ToolRegistry.force_untrusted(%{
      tool
      | trusted_terminal: trusted_terminal,
        execute: fn tool_call_id, params, signal, on_update ->
          LemonCore.NativeProcess.unsupported!()
          execute.(tool_call_id, params, signal, on_update)
        end
    })
  end

  # Mutating builtins run one at a time per session: the agent loop executes a
  # batch of tool calls concurrently, and two writers interleaving on the
  # workspace (an edit racing a `bash` rewrite of the same file) lose updates.
  # Read-only tools stay parallel. File tools additionally lock per path.
  @mutating_builtins ~w(write edit patch ast_grep bash eval debug fs_checkpoint checkpoint rewind lsp)
  # Code-mode cells outlive their initial call when yielded. Inner wrapped tools
  # acquire their own locks; holding the outer eval lock would deadlock them.
  defp maybe_serialize_mutation(%AgentTool{name: "eval"} = tool, "eval", cwd, opts) do
    if Tools.CodeMode.enabled?(opts),
      do: tool,
      else: serialize_mutation(tool, "eval", cwd, opts)
  end

  defp maybe_serialize_mutation(%AgentTool{} = tool, name, cwd, opts)
       when name in @mutating_builtins do
    serialize_mutation(tool, name, cwd, opts)
  end

  defp maybe_serialize_mutation(tool, _name, _cwd, _opts), do: tool

  defp serialize_mutation(tool, name, cwd, opts) do
    key = {:session, Keyword.get(opts, :session_id) || Path.expand(cwd)}
    execute = tool.execute

    %{
      tool
      | execute: fn tool_call_id, params, signal, on_update ->
          if mutating_call?(name, params) do
            MutationLock.with_lock(key, fn ->
              execute.(tool_call_id, params, signal, on_update)
            end)
          else
            execute.(tool_call_id, params, signal, on_update)
          end
        end
    }
  end

  # `lsp` only writes files when asked to apply a rename or code action.
  defp mutating_call?("lsp", params), do: is_map(params) and params["apply"] == true
  defp mutating_call?(_name, _params), do: true

  defp mcp_tool_tuples(_cwd, _opts, false), do: []

  defp mcp_tool_tuples(cwd, opts, true) do
    case Keyword.fetch(opts, :mcp_tools) do
      {:ok, tools} when is_list(tools) ->
        Enum.map(tools, fn
          {name, %AgentTool{} = tool, {:mcp, _server_name} = source} ->
            {name, tool, source}

          %AgentTool{} = tool ->
            {tool.name, tool, {:mcp, :configured}}
        end)

      _ ->
        configured =
          if profile_mcp_scope?(opts),
            do: [],
            else: discover_configured_mcp_tools(Keyword.get(opts, :config_cwd) || cwd)

        configured ++ discover_session_mcp_tools(opts)
    end
  end

  # Profile connector lists are complete principal-owned definitions, including
  # an empty list. Do not implicitly append machine-global OAuth integrations.
  # Generic/ACP sessions retain their existing configured-MCP behavior.
  defp profile_mcp_scope?(opts) do
    session_id = Keyword.get(opts, :mcp_session_id)

    if not is_nil(Keyword.get(opts, :invocation_mcp_servers)) or
         (is_binary(session_id) and session_id != "") do
      true
    else
      CodingAgent.Workspace.profile_owned?(opts)
    end
  end

  # A discovery failure costs only the configured MCP tools; built-in,
  # extension and session MCP tools still load. It is logged so a missing MCP
  # inventory is never silent.
  defp discover_configured_mcp_tools(cwd) do
    tools = LemonSkills.McpSource.discover_tools(cwd: cwd)
    mcp_tuples_with_approval(tools, LemonSkills.McpSource.approval_policy())
  rescue
    error ->
      Logger.warning("MCP tool discovery failed: #{Exception.message(error)}")
      []
  catch
    :exit, reason ->
      Logger.warning("MCP tool discovery failed: #{inspect(reason)}")
      []
  end

  defp discover_session_mcp_tools(opts) do
    [Keyword.get(opts, :acp_mcp_session_id), Keyword.get(opts, :mcp_session_id)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      mcp_tuples_with_approval(
        LemonSkills.McpSession.tools(id),
        LemonSkills.McpSession.approvals(id)
      )
    end)
  end

  defp mcp_tuples_with_approval(tools, approvals) do
    Enum.map(tools, fn %AgentTool{} = tool ->
      {tool.name, tool, {:mcp, %{approval: Map.get(approvals, tool.name, :always)}}}
    end)
  end

  defp wrap_extension_tool(%AgentTool{} = tool, ext_module) do
    original_execute = tool.execute
    tool_name = tool.name
    extension_hash = hash_value(Atom.to_string(ext_module))

    # Sessions built before a collision still hold this closure, so every call
    # re-checks: once the extension's code (or a module from its source) is
    # poisoned, the call is refused.
    wrapped_execute = fn tool_call_id, params, signal, on_update ->
      if Extensions.poisoned?(ext_module) do
        {:error, Extensions.poisoned_message(ext_module)}
      else
        run_extension_tool(original_execute, tool_name, extension_hash, [
          tool_call_id,
          params,
          signal,
          on_update
        ])
      end
    end

    %{tool | execute: wrapped_execute}
  end

  defp run_extension_tool(original_execute, tool_name, extension_hash, args) do
    [tool_call_id | _] = args

    base_meta = %{
      host: :beam,
      tool_name: tool_name,
      extension_hash: extension_hash,
      tool_call_hash: hash_value(tool_call_id)
    }

    LemonCore.Telemetry.emit([:coding_agent, :extension, :tool, :start], %{count: 1}, base_meta)
    started_at = System.monotonic_time(:microsecond)

    try do
      LemonCore.NativeProcess.unsupported!()
      result = apply(original_execute, args)
      duration_us = System.monotonic_time(:microsecond) - started_at

      LemonCore.Telemetry.emit(
        [:coding_agent, :extension, :tool, :stop],
        %{count: 1, duration_us: duration_us},
        Map.put(base_meta, :status, extension_tool_status(result))
      )

      result
    rescue
      error ->
        duration_us = System.monotonic_time(:microsecond) - started_at

        LemonCore.Telemetry.emit(
          [:coding_agent, :extension, :tool, :exception],
          %{count: 1, duration_us: duration_us},
          base_meta
          |> Map.put(:kind, :error)
          |> Map.put(:error_type, error.__struct__ |> Atom.to_string())
        )

        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        duration_us = System.monotonic_time(:microsecond) - started_at

        LemonCore.Telemetry.emit(
          [:coding_agent, :extension, :tool, :exception],
          %{count: 1, duration_us: duration_us},
          base_meta
          |> Map.put(:kind, kind)
          |> Map.put(:error_type, reason |> reason_type())
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp extension_tool_status({:error, _reason}), do: :error
  defp extension_tool_status(_result), do: :ok

  defp reason_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_type(reason), do: reason |> :erlang.term_to_binary() |> hash_value()

  @spec opts_extension_inventory(String.t(), tool_opts()) ::
          {[module()], [Extensions.load_error()]}
  defp opts_extension_inventory(cwd, opts) do
    case Keyword.fetch(opts, :extension_inventory) do
      {:ok, {extensions, load_errors}} ->
        {sort_extensions(extensions), load_errors}

      :error ->
        cached_extension_inventory(cwd, opts)
    end
  end

  defp cached_extension_inventory(cwd, opts) do
    extension_inventory(cwd, resolve_extension_paths(cwd, opts))
  end

  defp lookup_extension_inventory(key) do
    case cache_lookup(key) do
      [{^key, snapshot}] -> {:ok, snapshot}
      [] -> :error
    end
  end

  # Callers without a session inventory resolve paths from operator config
  # (`ExtensionLifecycle.extension_paths/1`); explicit `:extension_paths` are
  # still subject to the kill switch. Config is read for `config_cwd` only to
  # get the merged settings; no path is anchored there.
  defp resolve_extension_paths(cwd, opts) do
    settings =
      (Keyword.get(opts, :config_cwd) || cwd)
      |> LemonCore.Config.cached()
      |> CodingAgent.SettingsManager.from_config()

    case {settings, Keyword.get(opts, :extension_paths)} do
      {%{extensions_enabled: false}, _paths} -> []
      {_settings, paths} when is_list(paths) -> paths
      {settings, _} -> CodingAgent.ExtensionLifecycle.extension_paths(settings)
    end
  end

  defp cache_key(cwd, extension_paths) do
    {Path.expand(cwd), normalize_paths(extension_paths)}
  end

  defp normalize_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
  end

  defp cache_insert(key, snapshot) do
    :ets.insert(@extension_cache_table, {key, snapshot})
  end

  defp cache_delete_all do
    :ets.delete_all_objects(@extension_cache_table)
  end

  defp cache_delete(key) do
    :ets.delete(@extension_cache_table, key)
  end

  defp cache_tab2list do
    :ets.tab2list(@extension_cache_table)
  end

  defp cache_lookup(key) do
    :ets.lookup(@extension_cache_table, key)
  end

  @spec resolve_tools(
          [tool_tuple()],
          [tool_tuple()],
          [tool_tuple()],
          [tool_tuple()],
          boolean()
        ) ::
          {[tool_tuple()], [conflict_entry()]}
  defp resolve_tools(builtin_tools, wasm_tools, extension_tools, mcp_tools, log_conflicts?) do
    initial_winners =
      builtin_tools
      |> Enum.map(fn {name, _tool, source} -> {name, source} end)
      |> Map.new()

    {rev_resolved, _winners, conflicts} =
      Enum.reduce(
        [wasm_tools, extension_tools, mcp_tools],
        {Enum.reverse(builtin_tools), initial_winners, %{}},
        fn tools, {resolved_acc, winners_acc, conflicts_acc} ->
          Enum.reduce(tools, {resolved_acc, winners_acc, conflicts_acc}, fn {name, tool, source},
                                                                            {resolved, winners,
                                                                             conflicts} ->
            case Map.get(winners, name) do
              nil ->
                # Prepend for O(1) instead of O(n) append
                {[{name, tool, source} | resolved], Map.put(winners, name, source), conflicts}

              winner_source ->
                if log_conflicts? do
                  log_conflict(name, winner_source, source)
                end

                {resolved, winners, add_conflict(conflicts, name, winner_source, source)}
            end
          end)
        end
      )

    # Reverse to restore original order
    resolved = Enum.reverse(rev_resolved)

    conflict_entries =
      conflicts
      |> Map.values()
      |> Enum.sort_by(& &1.tool_name)
      |> Enum.map(&serialize_conflict_entry/1)

    {resolved, conflict_entries}
  end

  defp add_conflict(conflicts, tool_name, winner_source, shadowed_source) do
    Map.update(
      conflicts,
      tool_name,
      %{tool_name: tool_name, winner: winner_source, shadowed: [shadowed_source]},
      fn existing ->
        # Prepend for O(1) instead of O(n) append - order doesn't matter for conflicts
        %{existing | shadowed: [shadowed_source | existing.shadowed]}
      end
    )
  end

  defp serialize_conflict_entry(%{tool_name: tool_name, winner: winner, shadowed: shadowed}) do
    %{
      tool_name: tool_name,
      winner: serialize_source(winner),
      shadowed:
        shadowed
        |> Enum.map(&serialize_source/1)
        |> Enum.reject(&(&1 == :builtin))
    }
  end

  defp serialize_source(:builtin), do: :builtin

  defp serialize_source({:extension, mod}), do: {:extension, mod}
  defp serialize_source({:mcp, server_name}), do: {:mcp, server_name}

  defp serialize_source({:wasm, meta}) do
    {:wasm, wasm_identity(meta)}
  end

  defp serialize_source(_), do: :builtin

  defp wasm_identity(meta) when is_map(meta) do
    Map.get(meta, :path) || Map.get(meta, "path") || Map.get(meta, :name) || Map.get(meta, "name") ||
      "unknown"
  end

  defp wasm_identity(other), do: to_string(other)

  defp log_conflict(name, winner_source, shadowed_source) do
    Logger.warning(
      "Tool name conflict: '#{name}' from #{source_label(shadowed_source)} is shadowed by #{source_label(winner_source)}"
    )
  end

  defp source_label(:builtin), do: "built-in"
  defp source_label({:extension, module}), do: "extension #{inspect(module)}"

  defp source_label({:wasm, meta}),
    do:
      "wasm #{Map.get(meta, :path) || Map.get(meta, "path") || Map.get(meta, :name) || Map.get(meta, "name") || "unknown"}"

  defp source_label({:mcp, meta}) when is_map(meta), do: "mcp configured"
  defp source_label({:mcp, server_name}), do: "mcp #{server_name}"

  defp source_label(_), do: "unknown"

  defp source_count(tools, :builtin) do
    Enum.count(tools, fn {_name, _tool, source} -> source == :builtin end)
  end

  defp source_count(tools, :wasm) do
    Enum.count(tools, fn {_name, _tool, source} -> match?({:wasm, _}, source) end)
  end

  defp source_count(tools, :extension) do
    Enum.count(tools, fn {_name, _tool, source} -> match?({:extension, _}, source) end)
  end

  defp source_count(tools, :mcp) do
    Enum.count(tools, fn {_name, _tool, source} -> match?({:mcp, _}, source) end)
  end

  defp filter_tools(tools, disabled, nil) do
    disabled_set = MapSet.new(disabled, &to_string/1)

    Enum.reject(tools, fn {name, _tool, _source} ->
      MapSet.member?(disabled_set, name)
    end)
  end

  defp filter_tools(tools, _disabled, enabled_only) do
    enabled_set = MapSet.new(enabled_only, &to_string/1)

    Enum.filter(tools, fn {name, _tool, _source} ->
      MapSet.member?(enabled_set, name)
    end)
  end

  # A catalogued name belongs to its platform owner. When that owner is absent
  # (an unavailable built-in, an executor extra tool), a WASM, extension or MCP
  # tool must not take the name and inherit its policy classification.
  defp drop_reserved_contributions(tools) do
    Enum.reject(tools, fn {name, _tool, source} ->
      source != :builtin and LemonCore.ToolCatalog.reserved?(name)
    end)
  end

  defp filter_policy_blocked(tools, tool_policy) do
    Enum.filter(tools, fn {name, _tool, _source} ->
      ToolPolicy.allowed?(tool_policy, name)
    end)
  end

  # The one approval gate for every session tool. Only registry-built tuples are
  # tagged `:builtin`; caller-supplied tools arrive as `:extra` (exec tier, no
  # folder-read exemption), MCP/WASM/extension tools with their own source tags.
  @doc false
  def gate_tuples(tools, tool_policy, approval_context) do
    Enum.map(tools, fn {name, tool, source} ->
      tool = if source == :builtin, do: tool, else: %{tool | trusted_terminal: false}
      original_execute = tool.execute

      execute = fn tool_call_id, params, signal, on_update ->
        remote? = NodeTools.remote_call?(params)

        # Routed calls name paths on another machine: never resolve them
        # against this workspace or grant them local folder-read exemptions.
        params =
          if source == :builtin and not remote?,
            do: WorkspaceReads.resolve_params(name, params, approval_context),
            else: params

        tier = if source == :builtin, do: ToolPolicy.tier(name, params), else: :exec

        policy_required =
          ToolPolicy.requires_approval?(tool_policy, name, params, tier) or
            wasm_default_requires_approval?(tool_policy, name, source) or
            mcp_requires_approval?(source)

        # A folder read runs unreviewed only when the egress fence became
        # durable first; afterwards every web call in the session is reviewed.
        required =
          cond do
            name in ["webfetch", "websearch"] and WorkspaceReads.fenced?(approval_context) ->
              true

            source == :builtin and name in ["read", "ls", "grep"] and policy_required and
                not remote? ->
              not (WorkspaceReads.exempt?(tool_policy, name, params, approval_context) and
                     WorkspaceReads.fence!(approval_context) == :ok)

            true ->
              policy_required
          end

        if required do
          ToolExecutor.execute_with_approval(
            name,
            params,
            fn -> original_execute.(tool_call_id, params, signal, on_update) end,
            Map.put(approval_context, :tool_call_id, tool_call_id)
          )
        else
          original_execute.(tool_call_id, params, signal, on_update)
        end
      end

      {name,
       %{tool | execute: execute, on_stream: unreviewed_stream(tool, name, source, tool_policy)},
       source}
    end)
  end

  # Streamed arguments act before dispatch, so only a tool that would run
  # without any review keeps its stream callback. This mirrors the execution
  # gate above for argument-free tiers; web tools stay gated by the dynamic fence.
  defp unreviewed_stream(%AgentTool{on_stream: nil}, _name, _source, _tool_policy), do: nil

  defp unreviewed_stream(%AgentTool{on_stream: on_stream}, name, source, tool_policy) do
    tier = if source == :builtin, do: ToolPolicy.tier(name, %{}), else: :exec

    reviewed? =
      name in ["webfetch", "websearch"] or
        ToolPolicy.requires_approval?(tool_policy, name, %{}, tier) or
        wasm_default_requires_approval?(tool_policy, name, source) or
        mcp_requires_approval?(source)

    if reviewed?, do: nil, else: on_stream
  end

  defp mcp_requires_approval?({:mcp, %{approval: :always}}), do: true
  defp mcp_requires_approval?(_source), do: false

  defp wasm_default_requires_approval?(tool_policy, tool_name, {:wasm, meta}) do
    if is_nil(Map.get(tool_policy, :approval_mode, Map.get(tool_policy, "approval_mode"))),
      do: WasmPolicy.requires_approval?(tool_policy, tool_name, meta),
      else: false
  end

  defp wasm_default_requires_approval?(_tool_policy, _tool_name, _source), do: false

  defp normalize_wasm_tools(nil), do: []

  defp normalize_wasm_tools(tools) when is_list(tools) do
    tools
    |> Enum.flat_map(fn
      {name, %AgentTool{} = tool, {:wasm, meta}} when is_binary(name) and is_map(meta) ->
        [{name, tool, {:wasm, meta}}]

      %{name: name, tool: %AgentTool{} = tool, metadata: meta}
      when is_binary(name) and is_map(meta) ->
        [{name, tool, {:wasm, meta}}]

      _ ->
        []
    end)
    # Keep tool ordering deterministic for stable prompts / prompt caching.
    |> Enum.sort_by(fn {name, _tool, {:wasm, meta}} ->
      {name, wasm_identity(meta)}
    end)
  end

  defp normalize_wasm_tools(_), do: []

  defp sort_extensions(extensions) do
    Enum.sort_by(extensions, fn module -> Atom.to_string(module) end)
  end

  defp hash_value(nil), do: nil

  defp hash_value(value) when is_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp hash_value(value), do: value |> inspect() |> hash_value()
end

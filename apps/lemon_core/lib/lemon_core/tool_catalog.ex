defmodule LemonCore.ToolCatalog do
  @moduledoc """
  Classification of every platform-owned agent tool: the single source of tool
  names for policy profiles and approval tiers.

  Each descriptor carries an approval tier (`:read`, `:write` or `:exec`; see
  `LemonCore.ToolPolicy.tier/2`) and capability classes:

    * `:dangerous` — writes files, memory or secrets, runs code, drives a
      browser or media job, or controls processes or other machines
    * `:external` — reaches services or networks outside this machine
    * `:delegation` — starts, schedules or messages agents outside this task
      family
    * `:family_messaging` — messages this task family (parent, siblings,
      children). Profiles that exclude `:delegation` keep it; while a policy
      does not grant every `:delegation` tool,
      `LemonCore.ToolPolicy.family_messaging_only?/1` holds and the tool
      refuses named (external) targets itself.

  Restricted profiles are allow lists derived from this table, so they fail
  closed: a name it does not list is unclassified and denied by every restricted
  profile. That covers satellite registrations through `LemonAgent.ToolRegistry`
  (omp, computer use, Honcho), MCP, extension, WASM and hand-assembled tools.
  Full-access, orchestrator and custom policies may still grant them by name.

  | Profile | Grants catalogued tools |
  | --- | --- |
  | `safe_mode`, `subagent_restricted` | without `:dangerous` or `:delegation` |
  | `no_external` | without `:external` |
  | `leaf_worker` | without `:delegation` |
  | `read_only`, `minimal_core` | the fixed lists `read_only_names/0`, `minimal_core_names/0` |

  Only the owner of a tool may provide a catalogued name. Built-ins, executor
  extra tools and session-local bridges are compiled into the platform; entries
  marked `registry: true` are platform tools contributed through
  `LemonAgent.ToolRegistry` by an app the coding product must not name. Consumers
  refuse catalogued names from any other source (`reserved?/1`), so an MCP or
  extension tool can never inherit a platform tool's classification.
  """

  @type tier :: :read | :write | :exec
  @type class :: :dangerous | :external | :delegation | :family_messaging

  @classes [:dangerous, :external, :delegation, :family_messaging]

  # {name, tier, classes, opts}
  @tools [
    {"read", :read, [], []},
    {"read_skill", :read, [], []},
    {"recall", :read, [], []},
    {"grep", :read, [], []},
    {"find", :read, [], []},
    {"semantic_find", :read, [], []},
    {"ls", :read, [], []},
    {"checkpoint", :read, [], []},
    {"rewind", :read, [], []},
    {"bash_output", :read, [], []},
    {"wait", :read, [], []},
    {"ask", :read, [], []},
    {"ask_parent", :read, [], []},
    {"parent_question", :exec, [], []},
    {"extensions_status", :read, [], []},
    {"tool_search", :read, [], []},
    # A dispatcher: the hidden target keeps its own policy check and approval
    # gate, so the bridge itself needs review only when a policy names it.
    {"tool_invoke", :read, [], []},
    {"submit_result", :exec, [], []},
    {"propose_plan", :exec, [], []},
    {"todo", :write, [], []},
    {"write", :write, [:dangerous], []},
    {"edit", :write, [:dangerous], []},
    {"patch", :write, [:dangerous], []},
    {"ast_grep", :write, [:dangerous], []},
    {"fs_checkpoint", :write, [:dangerous], []},
    {"skill_manage", :write, [:dangerous], []},
    {"remember", :write, [:dangerous], []},
    {"bash", :exec, [:dangerous], []},
    {"kill_process", :exec, [:dangerous], []},
    {"process_input", :exec, [:dangerous], []},
    # Persistent kernels and debuggers execute arbitrary project code.
    {"eval", :exec, [:dangerous], []},
    {"eval_wait", :exec, [:dangerous], []},
    {"debug", :exec, [:dangerous], []},
    # Language servers can execute project code and apply file edits; read-only
    # `lsp` actions are lowered to `:read` by `LemonCore.ToolPolicy.tier/2`.
    {"lsp", :exec, [:dangerous], []},
    # Runs project compilers/checkers, which execute project code.
    {"lsp_diagnostics", :exec, [:dangerous], []},
    # Routes tool calls to other machines.
    {"nodes", :read, [:dangerous], []},
    {"tool_auth", :exec, [:dangerous], []},
    {"task", :exec, [:dangerous, :delegation], []},
    {"agent", :exec, [:dangerous, :delegation], []},
    {"goal", :write, [:dangerous, :delegation], [registry: true]},
    {"kanban", :write, [:dangerous, :delegation], [registry: true]},
    {"cron", :write, [:dangerous, :delegation], [registry: true]},
    # Bare names and `agent://` reach this family; named targets (`@handle`,
    # `session://`, `bot://`) need delegation authority, checked by the tool.
    {"agent_message", :exec, [:family_messaging], []},
    {"peer", :exec, [:dangerous, :external, :delegation], []},
    {"webfetch", :read, [:external], []},
    {"websearch", :read, [:external], []},
    {"browser_tabs", :read, [:external], []},
    {"browser_snapshot", :read, [:external], []},
    {"browser_get_content", :read, [:external], []},
    {"browser_wait_for_selector", :read, [:external], []},
    {"browser_events", :read, [:external], []},
    {"browser_get_cookies", :read, [:external], []},
    {"browser_tab_open", :write, [:external], []},
    {"browser_tab_activate", :write, [:external], []},
    {"browser_tab_close", :write, [:external], []},
    {"browser_navigate", :write, [:external], []},
    {"browser_hover", :write, [:external], []},
    {"browser_scroll", :write, [:external], []},
    {"browser_back", :write, [:external], []},
    {"browser_click", :write, [:dangerous, :external], []},
    {"browser_type", :write, [:dangerous, :external], []},
    {"browser_select_option", :write, [:dangerous, :external], []},
    {"browser_upload_file", :write, [:dangerous, :external], []},
    {"browser_download", :write, [:dangerous, :external], []},
    {"browser_press", :write, [:dangerous, :external], []},
    {"browser_set_cookies", :write, [:dangerous, :external], []},
    {"browser_clear_state", :write, [:dangerous, :external], []},
    {"browser_screenshot", :write, [:dangerous, :external], []},
    {"browser_evaluate", :exec, [:dangerous, :external], []},
    {"browser_analyze", :exec, [:dangerous, :external], []},
    {"media_status", :read, [:external], []},
    {"media_generate_image", :exec, [:dangerous, :external], []},
    {"media_generate_speech", :exec, [:dangerous, :external], []},
    {"media_transcribe_audio", :exec, [:dangerous, :external], []},
    {"media_analyze_image", :exec, [:dangerous, :external], []},
    {"media_generate_video", :exec, [:dangerous, :external], []},
    # Executor extra tools for channel sessions.
    {"sms_get_inbox_number", :exec, [:external], []},
    {"sms_wait_for_code", :exec, [:external], []},
    {"sms_list_messages", :exec, [:external], []},
    {"sms_claim_message", :exec, [:dangerous, :external], []},
    {"telegram_send_image", :exec, [:dangerous, :external], []},
    {"discord_send_file", :exec, [:dangerous, :external], []}
  ]

  # `read_only` profile: workspace exploration without external reach.
  @read_only ~w(read read_skill recall grep find semantic_find ls checkpoint rewind)

  # `minimal_core` profile: a compact general-purpose set.
  @minimal_core ~w(
    read read_skill skill_manage remember recall fs_checkpoint checkpoint rewind
    write edit patch ast_grep bash bash_output kill_process process_input eval
    grep find semantic_find ls webfetch websearch
    browser_tabs browser_tab_open browser_tab_activate browser_tab_close
    browser_navigate browser_snapshot browser_get_content browser_click
    browser_type browser_hover browser_select_option browser_upload_file
    browser_download browser_press browser_scroll browser_back
    browser_wait_for_selector browser_evaluate browser_events
    browser_get_cookies browser_set_cookies browser_clear_state
    browser_screenshot browser_analyze
    media_status media_generate_image media_generate_speech
    media_transcribe_audio media_analyze_image media_generate_video
    todo kanban goal cron task agent nodes extensions_status
  )

  @names Enum.map(@tools, &elem(&1, 0))
  @index Map.new(@tools, fn {name, tier, classes, opts} ->
           {name, %{tier: tier, classes: classes, registry: Keyword.get(opts, :registry, false)}}
         end)

  for {name, tier, classes, _opts} <- @tools do
    unless tier in [:read, :write, :exec] and Enum.all?(classes, &(&1 in @classes)),
      do: raise(CompileError, description: "invalid tool descriptor for #{name}")
  end

  unless length(Enum.uniq(@names)) == length(@names),
    do: raise(CompileError, description: "duplicate tool descriptor")

  for name <- @read_only ++ @minimal_core, name not in @names do
    raise CompileError, description: "profile names unclassified tool #{name}"
  end

  @doc "Every catalogued tool name, in catalogue order."
  @spec names() :: [String.t()]
  def names, do: @names

  @doc "Returns `{:ok, %{tier: tier, classes: classes}}` for a catalogued tool."
  @spec fetch(term()) :: {:ok, %{tier: tier(), classes: [class()]}} | :error
  def fetch(name) when is_binary(name) do
    case Map.fetch(@index, name) do
      {:ok, descriptor} -> {:ok, Map.take(descriptor, [:tier, :classes])}
      :error -> :error
    end
  end

  def fetch(_name), do: :error

  @doc "Approval tier of a catalogued tool; unclassified tools are `:exec`."
  @spec tier(term()) :: tier()
  def tier(name) do
    case fetch(name) do
      {:ok, %{tier: tier}} -> tier
      :error -> :exec
    end
  end

  @doc "Catalogued tools carrying none of `classes`, in catalogue order."
  @spec names_without([class()]) :: [String.t()]
  def names_without(classes) when is_list(classes) do
    for {name, _tier, tool_classes, _opts} <- @tools,
        not Enum.any?(tool_classes, &(&1 in classes)),
        do: name
  end

  @doc "Catalogued tools carrying `class`, in catalogue order."
  @spec names_with(class()) :: [String.t()]
  def names_with(class) when class in @classes do
    for {name, _tier, classes, _opts} <- @tools, class in classes, do: name
  end

  @doc "Tool names of the `read_only` profile."
  @spec read_only_names() :: [String.t()]
  def read_only_names, do: @read_only

  @doc "Tool names of the `minimal_core` profile."
  @spec minimal_core_names() :: [String.t()]
  def minimal_core_names, do: @minimal_core

  @doc """
  True when `name` is catalogued and therefore reserved for its platform owner.
  MCP, extension, WASM and satellite tools must not use a reserved name.
  """
  @spec reserved?(term()) :: boolean()
  def reserved?(name), do: is_binary(name) and Map.has_key?(@index, name)

  @doc """
  True when `name` may be contributed through the runtime tool registry: it is
  either unclassified or a platform tool the catalogue marks as registry-provided.
  """
  @spec registrable?(term()) :: boolean()
  def registrable?(name) when is_binary(name) do
    case Map.fetch(@index, name) do
      {:ok, %{registry: registry?}} -> registry?
      :error -> true
    end
  end

  def registrable?(_name), do: false
end

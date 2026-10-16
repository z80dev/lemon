defmodule LemonAgent.ToolRegistry do
  @moduledoc """
  Runtime registry for agent tools contributed by apps outside the platform.

  The built-in tool list (`@builtin_tools` in `CodingAgent.ToolRegistry`) is
  compile-time and names the modules it includes.
  That works for tools the platform owns, but a satellite integration — one the
  platform must not know about at compile time — has nowhere to appear. It
  registers here instead, at boot:

      LemonAgent.ToolRegistry.register(:my_tool, MyIntegration.Tools.MyTool)

  A registered module implements the same contract as a built-in: `tool/1` and
  `tool/2` returning an `LemonAgent.Types.AgentTool` — see that module for the
  tool shape and the execute contract. Registrations live in
  `:persistent_term`, so they survive a supervisor restart and can be made
  before the consuming app starts.

  ## Precedence

  Built-ins win. A registration whose name collides with a built-in is kept in
  the registry but ignored by the consumer that already has that name, so a
  satellite can never silently replace a platform tool. `CodingAgent.ToolRegistry`
  applies this by filtering registrations with `available/1` before appending
  them to its built-ins.

  The rule is worth stating in terms of what it protects rather than as a
  merge order. `CodingAgent.ToolRegistry.get_tool/3` resolves through that same
  merged list, so it decides which module actually *runs* when the model emits
  a call. The schema the model was shown for `bash` came from the built-in; if a
  registration could take that name, the thing that runs would not be the thing
  that was described. That is the failure the precedence rule exists to prevent,
  which is why it has to hold on every path that lists or resolves tools rather
  than on the one a consumer happened to write carefully.

  ## The satellite pattern

  An external integration can register its tools from its application callback
  without requiring the platform to name the integration at compile time. Guard
  registration so the package still starts in a build where the agent runtime
  is absent:

      defp register_tools do
        if Code.ensure_loaded?(LemonAgent.ToolRegistry) do
          Enum.each(@tools, fn {name, module} ->
            LemonAgent.ToolRegistry.register(name, module)
          end)
        end

        :ok
      end

  `MyIntegration.Tools.MyTool` is then a plain tool module — `tool/1`, `tool/2`,
  `execute/4` — that returns a "not configured" result rather than raising when
  its credentials are missing, so it is safe to register unconditionally.
  Registering from the application callback is what makes ordering irrelevant.

  Registrations carry native-process provenance: `:unknown` (the default) fences
  module loading, construction and execution as arbitrary code when the optional
  native launch ledger is enabled. Use `native_process_ownership: :managed` only
  for audited tools whose native work goes through the managed launch seams.
  `all/0` and `available/1` return `{name, module, ownership}` triples; consumers
  must preserve the provenance when constructing and wrapping tools.
  """

  require Logger

  @key {__MODULE__, :registered}

  @type tool_name :: atom()
  @type native_process_ownership :: :managed | :unknown
  @type entry :: {tool_name(), module(), native_process_ownership()}

  @doc """
  Register `module` under `name`, replacing any previous registration for it.
  """
  @spec register(tool_name(), module(), keyword()) :: :ok
  def register(name, module, opts \\ []) when is_atom(name) and is_atom(module) do
    ownership = Keyword.get(opts, :native_process_ownership, :unknown)

    unless ownership in [:managed, :unknown] do
      raise ArgumentError, "invalid native process ownership"
    end

    unless function_exported?(module, :tool, 2) or loadable?(module, ownership) do
      Logger.warning("[LemonAgent.ToolRegistry] #{inspect(module)} is not loadable")
    end

    put(List.keystore(stored(), name, 0, {name, module, ownership}))
  end

  @doc "Remove the registration for `name`."
  @spec unregister(tool_name()) :: :ok
  def unregister(name) when is_atom(name), do: put(List.keydelete(stored(), name, 0))

  @doc """
  Every registration, in registration order, filtered to modules that are
  actually loadable in this build.

  Callers turn these into tools by calling `module.tool/2`, so an entry whose
  module is not in the build would be an `UndefinedFunctionError` at the call
  site rather than a missing tool. Registration order is preserved.
  """
  @spec all() :: [entry()]
  def all do
    Enum.filter(stored(), fn {_name, module, ownership} -> loadable?(module, ownership) end)
  end

  @doc """
  Registrations excluding `taken` names, for a consumer merging them into its
  own built-in list.
  """
  @spec available(taken :: [tool_name()]) :: [entry()]
  def available(taken) when is_list(taken) do
    Enum.reject(all(), fn {name, _module, _ownership} -> name in taken end)
  end

  @doc """
  Construct a contributed tool while preserving its native-process provenance.

  Unknown constructors and every invocation of their returned tool execute only
  after durable uncertainty has been recorded. Constructor or execution errors
  never clear that record. Managed tools keep their existing launch accounting.
  The constructor callback supports consumers with different `tool/*` arities.
  """
  @spec build_tool(native_process_ownership(), (-> LemonAgent.Types.AgentTool.t())) ::
          LemonAgent.Types.AgentTool.t()
  def build_tool(:managed, constructor) when is_function(constructor, 0), do: constructor.()

  def build_tool(:unknown, constructor) when is_function(constructor, 0) do
    LemonCore.NativeProcess.unsupported!()
    %LemonAgent.Types.AgentTool{} = tool = constructor.()
    execute = tool.execute

    %{
      tool
      | execute: fn tool_call_id, params, signal, on_update ->
          LemonCore.NativeProcess.unsupported!()
          execute.(tool_call_id, params, signal, on_update)
        end
    }
  end

  defp loadable?(module, ownership) do
    if ownership == :unknown and :code.is_loaded(module) == false and
         :code.which(module) != :non_existing do
      LemonCore.NativeProcess.unsupported!()
    end

    Code.ensure_loaded?(module)
  end

  # The raw table. Registration reads and writes this rather than `all/0` so
  # that registering one tool cannot delete another whose application has not
  # started yet — the filter in `all/0` is a view, not a fact about the build.
  defp stored do
    :persistent_term.get(@key, [])
  end

  defp put(entries) do
    :persistent_term.put(@key, entries)
    :ok
  end
end

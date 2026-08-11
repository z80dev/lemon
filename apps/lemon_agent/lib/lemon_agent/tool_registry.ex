defmodule LemonAgent.ToolRegistry do
  @moduledoc """
  Runtime registry for agent tools contributed by apps outside the platform.

  The built-in tool lists (`CodingAgent.ToolRegistry`, `CodingAgent.Tools`,
  `LemonMcp.ToolAdapter`) are compile-time and name the modules they include.
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
  satellite can never silently replace a platform tool. Consumers get this one
  of two ways, and both are equivalent: filtering with `available/1`
  (`CodingAgent.ToolRegistry`), or merging their own built-ins *last*
  (`CodingAgent.Tools`, `LemonMcp.ToolAdapter`).

  The rule is worth stating in terms of what it protects rather than as a
  merge order. `CodingAgent.Tools.all_tools/2` is what `get_tool/3` resolves
  through, so it decides which module actually *runs* when the model emits a
  call. The schema the model was shown for `bash` came from the built-in; if a
  registration could take that name, the thing that runs would not be the thing
  that was described. That is the failure the precedence rule exists to prevent,
  which is why it has to hold on every path rather than on the one a consumer
  happened to write carefully.

  ## The satellite pattern

  `apps/x_api` is the worked example. It is an ordinary umbrella app that the
  platform has no compile-time knowledge of: nothing in `coding_agent` or
  `lemon_mcp` names it. Its application callback registers its three tools at
  boot, guarded so the app still starts in a build where the agent runtime is
  absent:

      defp register_tools do
        if Code.ensure_loaded?(LemonAgent.ToolRegistry) do
          Enum.each(@tools, fn {name, module} ->
            LemonAgent.ToolRegistry.register(name, module)
          end)
        end

        :ok
      end

  `XApi.Tools.PostToX` is then a plain tool module — `tool/1`, `tool/2`,
  `execute/4` — that returns a "not configured" result rather than raising when
  its credentials are missing, so the tool is safe to register unconditionally.
  A package outside this repo plugs in exactly the same way; registering from
  the application callback is what makes ordering irrelevant.
  """

  require Logger

  @key {__MODULE__, :registered}

  @type tool_name :: atom()
  @type entry :: {tool_name(), module()}

  @doc """
  Register `module` under `name`, replacing any previous registration for it.
  """
  @spec register(tool_name(), module()) :: :ok
  def register(name, module) when is_atom(name) and is_atom(module) do
    unless function_exported?(module, :tool, 2) or Code.ensure_loaded?(module) do
      Logger.warning("[LemonAgent.ToolRegistry] #{inspect(module)} is not loadable")
    end

    put(List.keystore(stored(), name, 0, {name, module}))
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
    Enum.filter(stored(), fn {_name, module} -> Code.ensure_loaded?(module) end)
  end

  @doc """
  Registrations excluding `taken` names, for a consumer merging them into its
  own built-in list.
  """
  @spec available(taken :: [tool_name()]) :: [entry()]
  def available(taken) when is_list(taken) do
    Enum.reject(all(), fn {name, _module} -> name in taken end)
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

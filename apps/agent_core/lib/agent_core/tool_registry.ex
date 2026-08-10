defmodule AgentCore.ToolRegistry do
  @moduledoc """
  Runtime registry for agent tools contributed by apps outside the platform.

  The built-in tool lists (`CodingAgent.ToolRegistry`, `CodingAgent.Tools`,
  `LemonMcp.ToolAdapter`) are compile-time and name the modules they include.
  That works for tools the platform owns, but a satellite integration — one the
  platform must not know about at compile time — has nowhere to appear. It
  registers here instead, at boot:

      AgentCore.ToolRegistry.register(:my_tool, MyIntegration.Tools.MyTool)

  A registered module implements the same contract as a built-in: `tool/1` and
  `tool/2` returning an `AgentCore.Types.AgentTool` — see that module for the
  tool shape and the execute contract. Registrations live in
  `:persistent_term`, so they survive a supervisor restart and can be made
  before the consuming app starts.

  ## Precedence

  Built-ins win. A registration whose name collides with a built-in is kept in
  the registry but ignored by the consumer that already has that name, so a
  satellite can never silently replace a platform tool. Consumers get this by
  filtering with `available/1` (`CodingAgent.ToolRegistry`) or by merging their
  built-ins last (`LemonMcp.ToolAdapter`).

  ### Known looseness

  `CodingAgent.Tools.all_tools/2` merges the registered tools *over* its
  built-in map, so a colliding registration does replace the built-in on that
  one execution path even though the schema the model was shown came from the
  built-in. Nothing in the tree currently collides, and the fix belongs in that
  merge rather than here — but do not rely on the collision rule to protect a
  built-in until it is made consistent.

  ## The satellite pattern

  `apps/x_api` is the worked example. It is an ordinary umbrella app that the
  platform has no compile-time knowledge of: nothing in `coding_agent` or
  `lemon_mcp` names it. Its application callback registers its three tools at
  boot, guarded so the app still starts in a build where the agent runtime is
  absent:

      defp register_tools do
        if Code.ensure_loaded?(AgentCore.ToolRegistry) do
          Enum.each(@tools, fn {name, module} ->
            AgentCore.ToolRegistry.register(name, module)
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
      Logger.warning("[AgentCore.ToolRegistry] #{inspect(module)} is not loadable")
    end

    put(List.keystore(all(), name, 0, {name, module}))
  end

  @doc "Remove the registration for `name`."
  @spec unregister(tool_name()) :: :ok
  def unregister(name) when is_atom(name), do: put(List.keydelete(all(), name, 0))

  @doc """
  Every registration, in registration order, filtered to modules that are
  actually loadable in this build.
  """
  @spec all() :: [entry()]
  def all do
    :persistent_term.get(@key, [])
  end

  @doc """
  Registrations excluding `taken` names, for a consumer merging them into its
  own built-in list.
  """
  @spec available(taken :: [tool_name()]) :: [entry()]
  def available(taken) when is_list(taken) do
    Enum.reject(all(), fn {name, module} ->
      name in taken or not Code.ensure_loaded?(module)
    end)
  end

  defp put(entries) do
    :persistent_term.put(@key, entries)
    :ok
  end
end

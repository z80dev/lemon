defmodule LemonCore.AutomationCommands do
  @moduledoc """
  Optional runtime seam for chat automation commands.

  Channel transports own command routing and trusted context; the automation
  runtime owns `/goal`, `/kanban`, `/remind`, `/reminders` and `/unremind`:
  parsing their arguments, authority, durable state and the reply text. The
  automation runtime registers its complete implementation with `register/1`
  at boot; channels have no compile-time dependency on it.

  `handle/3` always answers with reply text. An absent, unloadable or
  incomplete provider answers a fixed unavailable message. A provider that
  raises, exits, throws or returns a non-binary may already have acted, so the
  reply says the outcome is unknown; callers never retry it.

  Transports pass trusted context only, in `opts`: `:session_key`, `:agent_id`,
  `:workspace`, `:channel_context`, `:meta`, `:operator?` (kanban) and the
  background `:start_task`/`:deliver` callbacks (goal judge and continuation).
  """

  @provider_key :automation_commands_provider

  @type command :: :goal | :kanban | :remind | :reminders | :unremind

  @commands [:goal, :kanban, :remind, :reminders, :unremind]

  @callback handle(command(), binary() | nil, keyword()) :: String.t()

  @doc "Registers a complete provider."
  @spec register(module()) :: :ok | {:error, :not_a_provider}
  def register(module) do
    case LemonCore.RuntimeSeam.register(@provider_key, module, __MODULE__) do
      :ok -> :ok
      {:error, _} -> {:error, :not_a_provider}
    end
  end

  @doc "The registered implementation, or `nil` when absent."
  @spec provider() :: module() | nil
  def provider, do: LemonCore.RuntimeSeam.provider(@provider_key)

  @doc "Runs one chat command and returns its reply text."
  @spec handle(command(), binary() | nil, keyword()) :: String.t()
  def handle(command, args, opts) when command in @commands and is_list(opts) do
    unknown = unknown_text(command)

    case LemonCore.RuntimeSeam.invoke(provider(), :handle, [command, args, opts],
           unavailable: unavailable_text(command),
           exception: unknown,
           exit: unknown,
           throw: unknown,
           log: "automation command"
         ) do
      text when is_binary(text) -> text
      _ -> unknown
    end
  end

  defp unavailable_text(command) when command in [:remind, :reminders, :unremind],
    do: "The reminder scheduler is unavailable right now."

  defp unavailable_text(:goal), do: "Goal automation is unavailable right now."
  defp unavailable_text(:kanban), do: "Kanban automation is unavailable right now."

  defp unknown_text(command) when command in [:remind, :reminders, :unremind],
    do:
      "Reminder outcome unknown: the reminder scheduler did not answer. " <>
        "It may have taken effect and was not retried. Check /reminders."

  defp unknown_text(:goal),
    do:
      "Goal command outcome unknown: the goal service did not answer. " <>
        "It may have taken effect and was not retried. Check /goal."

  defp unknown_text(:kanban),
    do:
      "Kanban command outcome unknown: the kanban service did not answer. " <>
        "It may have taken effect and was not retried. Check /kanban boards."
end

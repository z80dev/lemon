defmodule LemonAutomation.ChatCommands do
  @moduledoc """
  Automation's `LemonCore.AutomationCommands` provider, registered at boot.

  Channel transports route `/goal`, `/kanban`, `/remind`, `/reminders` and
  `/unremind` here with their trusted context (see
  `LemonCore.AutomationCommands`); each command module owns its parsing,
  authority checks, durable writes and reply text.
  """

  @behaviour LemonCore.AutomationCommands

  alias LemonAutomation.ChatCommands.{Goal, Kanban, Reminders}

  @impl true
  def handle(:goal, args, opts), do: Goal.handle(Keyword.fetch!(opts, :session_key), args, opts)
  def handle(:kanban, args, opts), do: Kanban.handle(args, opts)
  def handle(:remind, args, opts), do: Reminders.create(args, opts)
  def handle(:reminders, _args, opts), do: Reminders.list(opts)
  def handle(:unremind, args, opts), do: Reminders.cancel(args, opts)
end

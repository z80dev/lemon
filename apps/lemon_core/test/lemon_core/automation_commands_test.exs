defmodule LemonCore.AutomationCommandsTest do
  use ExUnit.Case, async: false

  alias LemonCore.AutomationCommands

  @key :automation_commands_provider

  defmodule Provider do
    @behaviour LemonCore.AutomationCommands

    @impl true
    def handle(command, args, opts) do
      send(self(), {:provider_call, command, args, opts})
      Process.get({__MODULE__, :answer}, fn -> "reply" end).()
    end
  end

  defmodule PartialProvider do
    def other, do: :ok
  end

  setup do
    original = Application.fetch_env(:lemon_core, @key)
    Application.delete_env(:lemon_core, @key)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:lemon_core, @key, value)
        :error -> Application.delete_env(:lemon_core, @key)
      end
    end)

    :ok
  end

  test "a registered provider answers every chat command with its reply text" do
    assert :ok = AutomationCommands.register(Provider)
    assert AutomationCommands.provider() == Provider

    for command <- [:goal, :kanban, :remind, :reminders, :unremind] do
      assert AutomationCommands.handle(command, "args", session_key: "s") == "reply"
      assert_received {:provider_call, ^command, "args", [session_key: "s"]}
    end
  end

  test "registration rejects incomplete providers without replacing the provider" do
    assert :ok = AutomationCommands.register(Provider)

    for provider <- [nil, __MODULE__.Missing, PartialProvider] do
      assert {:error, :not_a_provider} = AutomationCommands.register(provider)
    end

    assert AutomationCommands.provider() == Provider
  end

  test "without a provider each command answers a fixed unavailable reply" do
    assert AutomationCommands.handle(:goal, nil, []) =~ "Goal automation is unavailable"
    assert AutomationCommands.handle(:kanban, nil, []) =~ "Kanban automation is unavailable"

    for command <- [:remind, :reminders, :unremind] do
      assert AutomationCommands.handle(command, nil, []) =~ "reminder scheduler is unavailable"
    end
  end

  test "a provider that fails or answers a non-reply reports an unknown outcome" do
    assert :ok = AutomationCommands.register(Provider)

    for answer <- [
          fn -> raise "boom" end,
          fn -> exit(:timeout) end,
          fn -> throw(:oops) end,
          fn -> {:ok, :not_text} end
        ] do
      Process.put({Provider, :answer}, answer)

      assert AutomationCommands.handle(:kanban, "dispatch stop b", []) =~
               "outcome unknown"

      assert AutomationCommands.handle(:goal, "continue", []) =~ "not retried"
      assert AutomationCommands.handle(:remind, "in 5m x", []) =~ "Check /reminders"
    end
  end
end

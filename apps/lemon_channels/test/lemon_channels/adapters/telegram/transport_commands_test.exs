defmodule LemonChannels.Adapters.Telegram.TransportCommandsTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.Commands

  test "normalizes Hermes aliases while preserving Telegram addressing" do
    assert Commands.canonicalize_portable_alias("/reset") == "/new"

    assert Commands.canonicalize_portable_alias("  /reasoning@LemonBot high") ==
             "  /thinking@LemonBot high"

    assert Commands.canonicalize_portable_alias("/stop now") == "/cancel now"
  end

  test "does not rewrite command lookalikes or ordinary text" do
    assert Commands.canonicalize_portable_alias("/stopwatch") == "/stopwatch"
    assert Commands.canonicalize_portable_alias("please /reset later") == "please /reset later"
    assert Commands.canonicalize_portable_alias(nil) == nil
  end

  test "reminder commands do not shadow each other" do
    assert Commands.remind_command?("/remind in 20m check oven", "lemon_bot")
    assert Commands.remind_command?("/remind@lemon_bot 9am stand-up", "lemon_bot")
    refute Commands.remind_command?("/reminders", "lemon_bot")
    refute Commands.remind_command?("/remind@other_bot 9am x", "lemon_bot")

    assert Commands.reminders_command?("/reminders", "lemon_bot")
    refute Commands.reminders_command?("/remind 9am x", "lemon_bot")

    assert Commands.unremind_command?("/unremind job_1", "lemon_bot")
    refute Commands.remind_command?("/unremind job_1", "lemon_bot")

    assert Commands.telegram_command_args("/remind@lemon_bot in 20m check oven", "remind") ==
             "in 20m check oven"
  end

  test "recognizes goal and kanban commands addressed to this bot" do
    assert Commands.goal_command?("/goal", "lemon_bot")
    assert Commands.goal_command?("/goal@lemon_bot", "lemon_bot")
    refute Commands.goal_command?("/goal@other_bot", "lemon_bot")

    assert Commands.kanban_command?("/kanban", "lemon_bot")
    assert Commands.kanban_command?("/kanban@lemon_bot", "lemon_bot")
    refute Commands.kanban_command?("/kanban@other_bot", "lemon_bot")
  end
end

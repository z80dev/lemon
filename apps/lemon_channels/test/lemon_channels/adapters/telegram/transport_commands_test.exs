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
end

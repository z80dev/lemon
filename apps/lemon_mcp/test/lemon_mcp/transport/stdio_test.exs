defmodule LemonMCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Transport.Stdio

  test "rejects empty command strings" do
    assert {:error, {:invalid_command, "command cannot be empty"}} =
             GenServer.start(Stdio, command: "")
  end

  test "rejects unknown executables without raising" do
    assert {:error, {:invalid_command, message}} =
             GenServer.start(Stdio, command: "definitely-not-a-real-executable")

    assert message =~ "Executable not found"
  end
end

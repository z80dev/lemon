defmodule CodingAgent.Tools.BashCodeModeRelayTest do
  # Mutates PATH for the python3-missing case; must not run concurrently.
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessStore
  alias CodingAgent.Tools.Bash
  alias LemonAgent.AbortSignal

  @moduletag :tmp_dir

  defp run(cwd, disclosure, command) do
    tool = Bash.tool(cwd, tool_disclosure: disclosure)
    tool.execute.("call", %{"command" => command}, AbortSignal.new(), nil)
  end

  defp managed_record?(marker) do
    Enum.any?(ProcessStore.list(:all), fn {_id, record} ->
      is_binary(record[:command]) and String.contains?(record.command, marker)
    end)
  end

  test "a disabled code_mode profile leaves bash on managed bash", %{tmp_dir: cwd} do
    marker = "managed-#{System.unique_integer([:positive])}"

    result =
      run(cwd, %{enabled: false, profile: :code_mode}, "echo #{marker}; echo err >&2")

    refute result.is_error
    # Managed bash merges streams and registers the launch with ProcessManager
    # (policy, LaneQueue admission and the artifact cap apply there).
    assert result.details.output_combined
    assert result.details.stdout == nil
    assert managed_record?(marker)
  end

  @tag :python3
  test "an enabled code_mode profile selects the stream relay", %{tmp_dir: cwd} do
    marker = "relay-#{System.unique_integer([:positive])}"

    result =
      run(cwd, %{enabled: true, profile: :code_mode}, "printf #{marker}; printf err >&2")

    refute result.is_error
    refute result.details.output_combined
    assert result.details.stdout == marker
    assert result.details.stderr == "err"
    refute managed_record?(marker)
  end

  test "an enabled relay without python3 fails clearly before starting", %{tmp_dir: cwd} do
    path = System.get_env("PATH")
    empty = Path.join(cwd, "empty-bin")
    File.mkdir_p!(empty)
    System.put_env("PATH", empty)
    marker = Path.join(cwd, "started")

    result =
      try do
        run(cwd, %{enabled: true, profile: :code_mode}, "/usr/bin/touch '#{marker}'")
      after
        System.put_env("PATH", path)
      end

    assert result.is_error
    assert hd(result.content).text =~ "requires python3"
    refute File.exists?(marker)
  end
end

defmodule LemonCore.Setup.SetupTaskTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Smoke tests for Mix.Tasks.Lemon.Setup that exercise subcommand dispatch
  through the injected io_callbacks without requiring real secrets or a TUI.
  """

  alias Mix.Tasks.Lemon.Setup, as: SetupTask

  defp collect_io do
    agent = start_supervised!({Agent, fn -> [] end})

    io = %{
      info: fn msg -> Agent.update(agent, &[{:info, msg} | &1]) end,
      error: fn msg -> Agent.update(agent, &[{:error, msg} | &1]) end,
      prompt: fn _prompt -> "" end,
      secret: fn _prompt -> "" end
    }

    {io, fn -> Agent.get(agent, &Enum.reverse/1) end}
  end

  describe "unknown subcommand" do
    test "prints error and usage hint" do
      {io, get_log} = collect_io()
      SetupTask.run_with_io(["unknown_subcommand"], io)
      log = get_log.()
      assert Enum.any?(log, fn {level, _} -> level == :error end)
      assert Enum.any?(log, fn {_, msg} -> String.contains?(msg, "Usage") end)
    end
  end

  describe "gateway subcommand" do
    test "prints info about M1-06" do
      {io, get_log} = collect_io()
      SetupTask.run_with_io(["gateway"], io)
      log = get_log.()
      assert Enum.any?(log, fn {_, msg} -> String.contains?(msg, "gateway") end)
    end
  end

  describe "runtime subcommand" do
    test "prints runtime summary in non-interactive mode" do
      {io, get_log} = collect_io()
      SetupTask.run_with_io(["runtime", "--non-interactive"], io)
      log = get_log.()
      assert Enum.any?(log, fn {_, msg} -> String.contains?(msg, "Runtime profile") end)
    end

    test "respects --profile flag" do
      {io, get_log} = collect_io()
      SetupTask.run_with_io(["runtime", "--profile", "runtime_min", "--non-interactive"], io)
      log = get_log.()
      assert Enum.any?(log, fn {_, msg} -> String.contains?(msg, "runtime_min") end)
    end
  end
end

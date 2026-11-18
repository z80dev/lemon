defmodule LemonAutomation.CronMemoryConfinedTest do
  @moduledoc """
  A concurrent local writer swaps the `cron_memory` directory for a symlink to
  an outside directory between the checks and the I/O (shared finding NEW-6).
  Memory I/O is descriptor-bound, so neither the write nor the read follows the
  swap.
  """
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronMemory, CronRun}
  alias LemonCore.SessionKey
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "home")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(home)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel"), "SENTINEL")

    previous = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(previous || [], :home_state_dir, home)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    {:ok, home: home, outside: outside, dir: Path.join(home, "cron_memory")}
  end

  test "append_run does not follow a memory directory swapped before the write", ctx do
    job = job("swap-write")
    owned = CronMemory.memory_file(job)
    File.mkdir_p!(ctx.dir)
    File.write!(owned, "# Cron Memory: swap-write\n")
    # The last path-based step before the write: the open of the temporary
    # file (pre-fix) — swap the checked directory for a symlink right there.
    # Pre-fix code notices the swap only afterwards and removes its temporary
    # file again, so every later request also records what reached `outside`.
    test = self()

    hook = fn request ->
      if Process.get(:swapped) do
        {:ok, names} = :prim_file.list_dir(ctx.outside)
        names = Enum.map(names, &to_string/1) -- ["sentinel"]
        if names != [], do: send(test, {:outside_written, names})
      else
        with {:open, _, modes} <- request,
             true <- :write in modes,
             path when is_binary(path) <- FileServerTap.path(request),
             true <- Path.dirname(path) == ctx.dir do
          Process.put(:swapped, true)
          FileServerTap.swap_for_symlink(ctx.dir, ctx.outside)
        end
      end
    end

    run = CronRun.new(job.id, :manual)

    assert :ok =
             FileServerTap.with_tap(hook, fn ->
               CronMemory.append_run(job, run, SessionKey.main("default"), {:ok, "LEAK"})
             end)

    refute_received {:outside_written, _}
    assert File.ls!(ctx.outside) == ["sentinel"]
    assert File.read!(Path.join(ctx.outside, "sentinel")) == "SENTINEL"
  end

  test "replace_confined writes into the opened directory, never through a swap", ctx do
    job = job("swap-rename")
    owned = CronMemory.memory_file(job)
    File.mkdir_p!(ctx.dir)
    File.write!(owned, "original")
    assert {:ok, "original", stat} = CronMemory.read_confined(owned)

    swap = fn -> FileServerTap.swap_for_symlink(ctx.dir, ctx.outside) end

    assert {:error, _} = CronMemory.replace_confined(owned, "NEW", stat, before_rename: swap)
    assert File.ls!(ctx.outside) == ["sentinel"]
    assert File.read!(Path.join(ctx.outside, "sentinel")) == "SENTINEL"
  end

  test "read does not return content from a directory swapped before the open", ctx do
    job = job("swap-read")
    owned = CronMemory.memory_file(job)
    File.mkdir_p!(ctx.dir)
    File.write!(owned, "original")
    File.write!(Path.join(ctx.outside, Path.basename(owned)), "OUTSIDE-SECRET")
    swap = fn -> FileServerTap.swap_for_symlink(ctx.dir, ctx.outside) end

    refute match?(
             {:ok, "OUTSIDE-SECRET", _},
             CronMemory.read_confined(owned, before_open: swap)
           )

    assert {_, nil} = CronMemory.read_for_prompt(job)
  end

  defp job(name) do
    CronJob.new(%{
      name: name,
      schedule: "* * * * *",
      agent_id: "default",
      session_key: SessionKey.main("default"),
      prompt: "do it"
    })
  end
end

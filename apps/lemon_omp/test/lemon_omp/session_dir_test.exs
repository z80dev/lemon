defmodule LemonOmp.SessionDirTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonOmp.{Config, SessionFiles}

  setup do
    use_fake_omp()
    previous = System.get_env("LEMON_OMP_SESSION_DIR")
    System.delete_env("LEMON_OMP_SESSION_DIR")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_OMP_SESSION_DIR", previous),
        else: System.delete_env("LEMON_OMP_SESSION_DIR")
    end)

    root = tmp_dir!("lemon_omp_history")
    lemon_dir = Path.join(root, "lemon/sessions")
    agent_dir = Path.join(root, "agent")
    put_app_env(:session_dir, lemon_dir)
    put_app_env(:agent_dir, agent_dir)
    {:ok, cwd: workspace!(), lemon_dir: lemon_dir, agent_dir: agent_dir}
  end

  test "default argv selects Lemon's private per-user history before spawning", ctx do
    put_app_env(:session_dir, nil)
    expected = Path.expand(Path.join(LemonCore.Paths.home_state_dir(), "omp/sessions"))
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD"})
    assert args(ctx.cwd) == "--mode rpc --cwd #{ctx.cwd} --session-dir #{expected}\n"
    assert Bitwise.band(File.stat!(expected).mode, 0o777) == 0o700
    assert {:ok, _} = LemonOmp.close(wire["id"])
  end

  test "omp opt-out omits the flag for new sessions and discovers omp's buckets", ctx do
    put_app_env(:session_dir, "omp")
    dir = omp_bucket(ctx)
    fixture(dir, "01optout-0001", ctx.cwd)
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD"})
    assert args(ctx.cwd) == "--mode rpc --cwd #{ctx.cwd}\n"

    assert {:ok, [%{"source" => "omp", "ompSessionId" => "01optout-0001"}]} =
             LemonOmp.discover(ctx.cwd)

    refute File.exists?(ctx.lemon_dir)
    assert {:ok, _} = LemonOmp.close(wire["id"])
  end

  test "custom paths including spaces stay a single argv value and become private", ctx do
    path = Path.join(ctx.lemon_dir, "history with spaces; literal")
    System.put_env("LEMON_OMP_SESSION_DIR", path)
    refute File.exists?(path)
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD"})
    assert args(ctx.cwd) == "--mode rpc --cwd #{ctx.cwd} --session-dir #{path}\n"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o700
    assert {:ok, _} = LemonOmp.close(wire["id"])
  end

  test "directory creation failure never spawns omp", ctx do
    File.mkdir_p!(Path.dirname(ctx.lemon_dir))
    File.write!(ctx.lemon_dir, "not a directory")
    assert {:error, _} = LemonOmp.start(%{cwd: ctx.cwd, prompt: "HOLD"})
    refute File.exists?(Path.join(ctx.cwd, ".fake_omp.pid"))
  end

  test "discovery reads flat Lemon and encoded omp histories, tagging each source", ctx do
    lemon_path = fixture(ctx.lemon_dir, "01lemon-0001", ctx.cwd)
    omp_dir = omp_bucket(ctx)
    omp_path = fixture(omp_dir, "01omp-0001", ctx.cwd)
    File.touch!(lemon_path, System.os_time(:second) - 600)
    File.chmod!(omp_dir, 0o755)
    before = Map.new([lemon_path, omp_path, omp_dir], &{&1, File.stat!(&1, time: :posix)})

    # A shared flat directory must filter cwd before applying its result limit.
    other = workspace!()
    for n <- 1..45, do: fixture(ctx.lemon_dir, "01other-#{n}", other)

    for discover <- [&SessionFiles.discover/2, &LemonOmp.discover/2] do
      assert {:ok, sessions} = discover.(ctx.cwd, [])

      assert Enum.map(sessions, &{&1["ompSessionId"], &1["source"]}) ==
               [{"01omp-0001", "omp"}, {"01lemon-0001", "lemon"}]

      assert Enum.all?(sessions, &(not Map.has_key?(&1, :session_dir)))
      assert {:ok, _} = Jason.encode(sessions)
    end

    for {path, stat} <- before do
      after_read = File.stat!(path, time: :posix)

      assert {after_read.size, after_read.mtime, after_read.mode} ==
               {stat.size, stat.mtime, stat.mode}
    end
  end

  test "discovery never creates either missing history directory", ctx do
    assert {:ok, []} = LemonOmp.discover(ctx.cwd)
    refute File.exists?(ctx.lemon_dir)
    refute File.exists?(ctx.agent_dir)
  end

  test "resume resolves case-insensitive prefixes to each source's actual directory", ctx do
    omp_dir = omp_bucket(ctx)
    fixture(ctx.lemon_dir, "01lemon-0001", ctx.cwd)
    fixture(omp_dir, "01omp-0001", ctx.cwd)
    File.chmod!(omp_dir, 0o755)

    for {prefix, id, dir} <- [
          {"01LEMON", "01lemon-0001", ctx.lemon_dir},
          {"01OMP", "01omp-0001", omp_dir}
        ] do
      assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, resume: prefix})
      assert await_wire(wire["id"], &(&1["ompSessionId"] == id))["ompSessionId"] == id

      assert args(ctx.cwd) ==
               "--mode rpc --cwd #{ctx.cwd} --session-dir #{dir} --resume #{id}\n"

      assert {:ok, _} = LemonOmp.close(wire["id"])
    end

    assert Bitwise.band(File.stat!(omp_dir).mode, 0o777) == 0o755
    assert Config.session_dir() == ctx.lemon_dir
  end

  test "resume can find an older id beyond the discovery result limit", ctx do
    path = fixture(ctx.lemon_dir, "01older-0001", ctx.cwd)
    File.touch!(path, System.os_time(:second) - 600)
    for n <- 1..105, do: fixture(ctx.lemon_dir, "01newer-#{n}", ctx.cwd)
    assert {:ok, sessions} = LemonOmp.discover(ctx.cwd)
    refute Enum.any?(sessions, &(&1["ompSessionId"] == "01older-0001"))
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, resume: "01older"})

    assert await_wire(wire["id"], &(&1["ompSessionId"] == "01older-0001"))["ompSessionId"] ==
             "01older-0001"

    assert args(ctx.cwd) =~ "--session-dir #{ctx.lemon_dir} --resume 01older-0001"
    assert {:ok, _} = LemonOmp.close(wire["id"])
  end

  test "ambiguous prefixes across sources fail before spawning, while exact ids win", ctx do
    fixture(ctx.lemon_dir, "01shared", ctx.cwd)
    fixture(omp_bucket(ctx), "01shared-extended", ctx.cwd)
    assert {:error, :invalid_params} = LemonOmp.start(%{cwd: ctx.cwd, resume: "01shar"})
    refute File.exists?(Path.join(ctx.cwd, ".fake_omp.pid"))
    assert {:ok, wire} = LemonOmp.start(%{cwd: ctx.cwd, resume: "01shared"})

    assert await_wire(wire["id"], &(&1["ompSessionId"] == "01shared"))["ompSessionId"] ==
             "01shared"

    assert args(ctx.cwd) =~ "--session-dir #{ctx.lemon_dir} --resume 01shared"
    assert {:ok, _} = LemonOmp.close(wire["id"])
  end

  defp args(cwd), do: File.read!(Path.join(cwd, ".fake_omp.args"))

  defp omp_bucket(ctx) do
    [name | _] = SessionFiles.candidate_dir_names(ctx.cwd, ctx.cwd)
    Path.join([ctx.agent_dir, "sessions", name])
  end

  defp fixture(dir, id, cwd) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "2026-10-15T10-00-00-000Z_#{id}.jsonl")
    File.write!(path, Jason.encode!(%{type: "session", id: id, cwd: cwd}) <> "\n")
    path
  end
end

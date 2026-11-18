defmodule LemonCore.DotenvTrustTest do
  @moduledoc """
  Environment variables override every config file, so a `.env` in a cloned
  repository must never be loaded just because Lemon runs from that directory.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Dotenv

  @moduletag :tmp_dir
  @override "LEMON_WEB_FETCH_ALLOW_PRIVATE_NETWORK"
  @home_key "LEMON_DOTENV_TRUST_HOME_MARKER"

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "home")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(repo)

    File.write!(
      Path.join(repo, ".env"),
      "#{@override}=true\nOPENAI_BASE_URL=https://attacker.example\n"
    )

    File.write!(Path.join(home, ".lemon/.env"), "#{@home_key}=operator\n")

    saved =
      Map.new(["HOME", "LEMON_DOTENV_DIR", @override, @home_key, "OPENAI_BASE_URL"], fn key ->
        {key, System.get_env(key)}
      end)

    cwd = File.cwd!()
    System.put_env("HOME", home)
    Enum.each(["LEMON_DOTENV_DIR", @override, @home_key, "OPENAI_BASE_URL"], &System.delete_env/1)
    File.cd!(repo)

    on_exit(fn ->
      File.cd!(cwd)

      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    %{home: home, repo: repo}
  end

  test "an unset dotenv dir loads the Lemon home .env, not the working directory's", ctx do
    assert Dotenv.dir() == Path.join(ctx.home, ".lemon")
    assert Dotenv.path_for(nil) == Path.join(ctx.home, ".lemon/.env")
    assert :ok = Dotenv.load(nil)

    assert System.get_env(@home_key) == "operator"
    assert System.get_env(@override) == nil
    assert System.get_env("OPENAI_BASE_URL") == nil

    refute LemonCore.Config.Modular.load(project_dir: ctx.repo).tools.web.fetch.allow_private_network
  end

  test "an explicit LEMON_DOTENV_DIR is honoured", ctx do
    System.put_env("LEMON_DOTENV_DIR", ctx.repo)
    assert Dotenv.dir() == ctx.repo
    assert :ok = Dotenv.load(nil)
    assert System.get_env(@override) == "true"
  end

  test "the config watcher never tracks the working directory's .env", ctx do
    {:ok, pid} =
      GenServer.start_link(LemonCore.ConfigReloader.Watcher,
        cwd: ctx.repo,
        poll_interval_ms: 60_000
      )

    watched = :sys.get_state(pid).watched_paths
    GenServer.stop(pid, :normal)

    refute Path.join(ctx.repo, ".env") in watched
    assert Path.join(ctx.home, ".lemon/.env") in watched
  end
end

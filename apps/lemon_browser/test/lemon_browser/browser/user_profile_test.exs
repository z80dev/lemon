defmodule LemonBrowser.UserProfileTest do
  use ExUnit.Case, async: false

  alias LemonBrowser.LocalServer

  setup do
    dir = Path.join(System.tmp_dir!(), "browser_profile_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    keys = ["HOME", "LEMON_BROWSER_USER_DATA_DIR", "LEMON_BROWSER_PROFILE_DIRECTORY"]
    old_env = Map.new(keys, &{&1, System.get_env(&1)})
    old_config = Application.get_all_env(:lemon_browser)
    System.put_env("HOME", dir)
    System.delete_env("LEMON_BROWSER_USER_DATA_DIR")
    System.delete_env("LEMON_BROWSER_PROFILE_DIRECTORY")
    Application.delete_env(:lemon_browser, :user_data_dir)
    Application.delete_env(:lemon_browser, :profile_directory)

    driver = Path.join(dir, "driver.js")

    File.write!(driver, """
    const readline = require('node:readline');
    readline.createInterface({input: process.stdin}).on('line', line => {
      const request = JSON.parse(line);
      console.log(JSON.stringify({id: request.id, ok: true, result: process.argv.slice(2)}));
    });
    """)

    server = start_supervised!({LocalServer, name: nil, driver_path: driver})

    on_exit(fn ->
      Enum.each(old_env, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

      for key <- [:user_data_dir, :profile_directory] do
        if Keyword.has_key?(old_config, key) do
          Application.put_env(:lemon_browser, key, Keyword.fetch!(old_config, key))
        else
          Application.delete_env(:lemon_browser, key)
        end
      end

      File.rm_rf!(dir)
    end)

    %{server: server, dir: dir}
  end

  test "unset settings do not add profile arguments", %{server: server} do
    assert {:ok, args} = LocalServer.request(server, "browser.tabs", %{}, 1_000)
    refute "--user-data-dir" in args
    refute "--profile-directory" in args
  end

  test "application settings pass flags and stopping preserves the profile", %{
    server: server,
    dir: dir
  } do
    profile = Path.join(dir, "dedicated")
    File.mkdir_p!(profile)
    marker = Path.join(profile, "Cookies")
    File.write!(marker, "fixture")
    Application.put_env(:lemon_browser, :user_data_dir, profile)
    Application.put_env(:lemon_browser, :profile_directory, "Profile 1")

    assert {:ok, ["--user-data-dir", ^profile, "--profile-directory", "Profile 1"]} =
             LocalServer.request(server, "browser.tabs", %{}, 1_000)

    assert :ok = LocalServer.stop(server)
    assert File.read!(marker) == "fixture"
  end

  test "profile identity changes fail closed for a running driver", %{server: server, dir: dir} do
    System.put_env("LEMON_BROWSER_USER_DATA_DIR", Path.join(dir, "dedicated"))
    System.put_env("LEMON_BROWSER_PROFILE_DIRECTORY", "Default")
    first = LocalServer.status(server).driver_config.profile_identity_hash
    assert {:ok, _} = LocalServer.request(server, "browser.tabs", %{}, 1_000)
    System.put_env("LEMON_BROWSER_PROFILE_DIRECTORY", "Profile 1")
    assert {:error, error} = LocalServer.request(server, "browser.tabs", %{}, 1_000)
    assert error =~ "identity changed"
    System.put_env("LEMON_BROWSER_USER_DATA_DIR", Path.join(dir, "other"))
    {:ok, other} = LocalServer.start_link(name: nil)
    on_exit(fn -> LocalServer.stop(other) end)
    refute first == LocalServer.status(other).driver_config.profile_identity_hash
  end

  test "identity key includes both user-data directory and profile directory", %{dir: dir} do
    identity = fn data, profile ->
      {:ok, server} =
        LocalServer.start_link(name: nil, user_data_dir: data, profile_directory: profile)

      key = LocalServer.status(server).driver_config.profile_identity_hash
      LocalServer.stop(server)
      key
    end

    first = identity.(Path.join(dir, "one"), "Default")
    refute first == identity.(Path.join(dir, "one"), "Profile 1")
    refute first == identity.(Path.join(dir, "two"), "Default")
  end
end

defmodule LemonCore.ConfigReloaderTest do
  @moduledoc """
  Tests for the ConfigReloader GenServer.
  """
  use ExUnit.Case, async: false

  alias LemonCore.ConfigReloader

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "config_reloader_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    project_dir = Path.join(tmp_dir, "project")
    File.mkdir_p!(project_dir)

    original_home = System.get_env("HOME")
    System.put_env("HOME", mock_home)

    # Write a minimal global config
    global_lemon_dir = Path.join(mock_home, ".lemon")
    File.mkdir_p!(global_lemon_dir)
    File.write!(Path.join(global_lemon_dir, "config.toml"), "")

    # Ensure ConfigCache is available
    if !LemonCore.ConfigCache.available?() do
      {:ok, _pid} = LemonCore.ConfigCache.start_link([])
    end

    on_exit(fn ->
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home, project_dir: project_dir}
  end

  describe "start_link/1 and status/0" do
    test "starts and returns initial status" do
      pid = start_reloader!()

      status = GenServer.call(pid, :status)
      assert status.reload_count == 0
      assert status.last_error == nil
      assert status.has_snapshot == true
    end
  end

  describe "reload/1" do
    test "returns ok with no changes on empty reload" do
      pid = start_reloader!()

      result = GenServer.call(pid, {:reload, []})
      assert {:ok, summary} = result
      assert summary.changed_sources == []
      assert summary.changed_paths == []
      assert is_binary(summary.reload_id)
      assert is_integer(summary.applied_at_ms)
    end

    test "detects file changes after modifying config", %{mock_home: mock_home} do
      pid = start_reloader!()

      # Modify the global config
      config_path = Path.join([mock_home, ".lemon", "config.toml"])
      File.write!(config_path, "[agent]\ndefault_provider = \"openai\"\n")

      # Small delay for mtime resolution
      Process.sleep(10)

      result = GenServer.call(pid, {:reload, [force: true]})
      assert {:ok, summary} = result
      assert :files in summary.changed_sources
    end

    test "force reload always reports changes" do
      pid = start_reloader!()

      result = GenServer.call(pid, {:reload, [force: true]})
      assert {:ok, summary} = result
      assert is_list(summary.changed_sources)
    end

    test "serializes concurrent reloads" do
      pid = start_reloader!()

      # Start a reload then immediately try another
      task =
        Task.async(fn ->
          GenServer.call(pid, {:reload, [force: true]})
        end)

      # The GenServer serializes calls, so second call waits
      result2 = GenServer.call(pid, {:reload, [force: true]})
      result1 = Task.await(task)

      assert {:ok, _} = result1
      assert {:ok, _} = result2
    end

    test "scopes reload to specified sources" do
      pid = start_reloader!()

      result = GenServer.call(pid, {:reload, [sources: [:files], force: true]})
      assert {:ok, summary} = result
      # Only :files should be in changed_sources
      assert Enum.all?(summary.changed_sources, &(&1 == :files))
    end
  end

  describe "redaction" do
    test "redacts sensitive fields in diff" do
      assert ConfigReloader.redact_value("providers.anthropic.api_key", "sk-1234") ==
               "[REDACTED]"

      assert ConfigReloader.redact_value("gateway.telegram.bot_token", "123:ABC") ==
               "[REDACTED]"

      assert ConfigReloader.redact_value("some.password_hash", "abc") == "[REDACTED]"
      assert ConfigReloader.redact_value("some.secret_field", "value") == "[REDACTED]"
    end

    test "does not redact non-sensitive fields" do
      assert ConfigReloader.redact_value("agent.default_provider", "anthropic") == "anthropic"
      assert ConfigReloader.redact_value("gateway.max_concurrent_runs", 5) == 5
    end
  end

  describe "compute_redacted_diff/2" do
    test "detects added, removed, and changed keys" do
      old = %{a: 1, b: 2, c: 3}
      new = %{a: 1, b: 99, d: 4}

      diff = ConfigReloader.compute_redacted_diff(old, new)
      diff_map = Map.new(diff)

      assert diff_map["b"].action == :changed
      assert diff_map["b"].from == 2
      assert diff_map["b"].to == 99

      assert diff_map["c"].action == :removed
      assert diff_map["d"].action == :added
      assert diff_map["d"].value == 4

      refute Map.has_key?(diff_map, "a")
    end

    test "redacts sensitive keys in diff" do
      old = %{api_key: "old-key"}
      new = %{api_key: "new-key"}

      diff = ConfigReloader.compute_redacted_diff(old, new)
      [{_path, change}] = diff

      assert change.from == "[REDACTED]"
      assert change.to == "[REDACTED]"
    end
  end

  describe "watch_paths/0" do
    test "returns config file paths" do
      pid = start_reloader!()

      paths = GenServer.call(pid, :watch_paths)
      assert is_list(paths)
      assert length(paths) >= 1
      assert Enum.any?(paths, &String.ends_with?(&1, "config.toml"))
    end
  end

  describe "bus integration" do
    test "broadcasts config_reloaded event on reload" do
      LemonCore.Bus.subscribe("system")
      pid = start_reloader!()

      GenServer.call(pid, {:reload, [force: true]})

      assert_receive %LemonCore.Event{type: :config_reloaded, payload: payload}, 1_000
      assert is_binary(payload.reload_id)
      assert is_list(payload.changed_sources)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_reloader!(opts \\ []) do
    name = :"config_reloader_test_#{System.unique_integer([:positive])}"
    opts = Keyword.merge(opts, name: name)

    # Start without registering as the global name
    {:ok, pid} = GenServer.start_link(ConfigReloader, opts)
    pid
  end
end

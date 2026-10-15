defmodule LemonCli.SessionsCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCore.{RunStore, SessionLifecycle, Store}

  setup do
    suffix = System.unique_integer([:positive, :monotonic])

    system_keys = [
      "LEMON_CONTROL_PLANE_PORT",
      "LEMON_CONTROL_PLANE_OPERATOR_TOKEN",
      "LEMON_WS_TOKEN",
      "LEMON_LAUNCHER"
    ]

    previous_system = Map.new(system_keys, &{&1, System.get_env(&1)})
    app_keys = [:operator_token, :allow_unauthenticated_loopback_operator]
    previous_app = Map.new(app_keys, &{&1, Application.get_env(:lemon_control_plane, &1)})
    token = "sessions-cli-wire-operator"
    Application.put_env(:lemon_control_plane, :operator_token, token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:session_cli_wire, suffix}
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(port))
    System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", token)
    System.delete_env("LEMON_WS_TOKEN")
    System.delete_env("LEMON_LAUNCHER")

    on_exit(fn ->
      Enum.each(previous_system, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Enum.each(previous_app, fn
        {key, nil} -> Application.delete_env(:lemon_control_plane, key)
        {key, value} -> Application.put_env(:lemon_control_plane, key, value)
      end)
    end)

    session_key = "agent:cli_sessions_#{suffix}:main"
    run_id = "run-cli-sessions-#{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    {:ok, session_key: session_key, run_id: run_id, suffix: suffix}
  end

  test "session management refuses invalid daemon credentials instead of reading local state",
       %{session_key: session_key, run_id: run_id} do
    seed_session(session_key, run_id, "daemon-owned", "persisted")
    System.put_env("LEMON_CONTROL_PLANE_OPERATOR_TOKEN", "wrong-operator")

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["sessions", "list", "--json"]) == 1
      end)

    assert Jason.decode!(error)["error"]["code"] == "session_authentication_failed"
    assert SessionLifecycle.get(session_key)
  end

  test "bounded list/search/show/history and metadata commands share redacted state",
       %{session_key: session_key, run_id: run_id, suffix: suffix} do
    secret = "cli-secret-#{suffix}"

    seed_session(
      session_key,
      run_id,
      "Plan the lunar launch api_key=#{secret}",
      "Ready Bearer #{secret}"
    )

    assert_cli_ok(["sessions", "title", session_key, "Launch", "Room"], "title updated")
    assert_cli_ok(["sessions", "pin", session_key], "pinned")
    assert_cli_ok(["sessions", "archive", session_key], "archived")

    search =
      run_json([
        "sessions",
        "search",
        "lunar launch",
        "--archived",
        "--limit",
        "5",
        "--json"
      ])

    assert search["ok"] == true

    assert [%{"session_key" => ^session_key, "title" => "Launch Room", "pinned" => true}] =
             search["sessions"]

    shown = run_json(["sessions", "show", session_key, "--json"])
    assert shown["session"]["archived"] == true
    assert shown["session"]["run_count"] >= 1

    history = run_json(["sessions", "history", session_key, "--limit", "1", "--json"])
    assert history["redacted"] == true
    assert length(history["history"]) == 1
    refute inspect(history) =~ secret

    stats =
      run_json([
        "sessions",
        "stats",
        "lunar launch",
        "--archived",
        "--group-limit",
        "5",
        "--json"
      ])

    assert stats["stats"]["redacted"] == true
    assert stats["stats"]["totals"]["matched_sessions"] == 1
    assert stats["stats"]["totals"]["archived_sessions"] == 1
    assert stats["stats"]["totals"]["runs"] >= 1
    assert stats["stats"]["cleanup"]["includes_session_keys"] == false
    refute inspect(stats) =~ secret
    refute inspect(stats) =~ session_key

    assert_cli_ok(["sessions", "restore", session_key], "restored")
    assert_cli_ok(["sessions", "unpin", session_key], "unpinned")
    assert_cli_ok(["sessions", "title", session_key, "--clear"], "title updated")

    session = SessionLifecycle.get(session_key)
    assert session.title == nil
    refute session.pinned
    refute session.archived
  end

  test "redacted exports support private files and safe machine output",
       %{session_key: session_key, run_id: run_id, suffix: suffix} do
    secret = "export-secret-#{suffix}"
    seed_session(session_key, run_id, "token=#{secret}", "Bearer #{secret}")

    tmp_dir = Path.join(System.tmp_dir!(), "lemon_sessions_export_#{suffix}")
    output_path = Path.join(tmp_dir, "session.json")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    metadata =
      run_json([
        "sessions",
        "export",
        session_key,
        "--format",
        "json",
        "--output",
        output_path,
        "--json"
      ])

    assert metadata["export"]["output_file"] == "session.json"
    assert metadata["export"]["content"] == nil
    assert metadata["export"]["redacted"] == true
    refute inspect(metadata) =~ tmp_dir

    content = File.read!(output_path)
    refute content =~ secret
    assert Bitwise.band(File.stat!(output_path).mode, 0o777) == 0o600

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["sessions", "export", session_key, "--output", output_path]) == 1
      end)

    assert error =~ "already exists"
    refute error =~ output_path

    assert_cli_ok(
      ["sessions", "export", session_key, "--output", output_path, "--force"],
      "session.json"
    )
  end

  test "html and jsonl exports reach the CLI intact and unknown formats fail",
       %{session_key: session_key, run_id: run_id} do
    seed_session(session_key, run_id, "<script>alert(1)</script>", "done")

    html = run_json(["sessions", "export", session_key, "--format", "html", "--json"])
    assert html["export"]["format"] == "html"
    refute html["export"]["content"] =~ "<script"

    jsonl = run_json(["sessions", "export", session_key, "--format", "jsonl", "--json"])
    lines = String.split(jsonl["export"]["content"], "\n", trim: true)
    assert Enum.map(lines, &Jason.decode!(&1)["type"]) == ["session", "run"]

    capture_io(:stderr, fn ->
      assert CLI.run(["sessions", "export", session_key, "--format", "pdf"]) != 0
    end)
  end

  test "prune requires exact preview parameters and verifies deletion",
       %{session_key: session_key, run_id: run_id} do
    now = System.system_time(:millisecond)
    seed_session(session_key, run_id, "old", "done", now - 20_000)
    assert {:ok, _} = SessionLifecycle.patch(session_key, %{archived: true})

    preview =
      run_json([
        "sessions",
        "prune",
        "--older-than",
        Integer.to_string(now - 10_000),
        "--json"
      ])

    assert preview["prune"]["dry_run"] == true
    assert preview["prune"]["candidate_session_keys"] == [session_key]
    token = preview["prune"]["confirmation_token"]
    cutoff = preview["prune"]["older_than_ms"]

    mismatch =
      capture_io(:stderr, fn ->
        assert CLI.run([
                 "sessions",
                 "prune",
                 "--older-than",
                 Integer.to_string(cutoff - 1),
                 "--confirm",
                 token
               ]) == 1
      end)

    assert mismatch =~ "candidate set changed"
    assert SessionLifecycle.get(session_key)

    executed =
      run_json([
        "sessions",
        "prune",
        "--older-than",
        Integer.to_string(cutoff),
        "--confirm",
        token,
        "--json"
      ])

    assert executed["prune"]["verified"] == true
    assert executed["prune"]["deleted_session_keys"] == [session_key]
    assert SessionLifecycle.get(session_key) == nil
  end

  test "verified delete is guarded by the exact session key",
       %{session_key: session_key, run_id: run_id} do
    seed_session(session_key, run_id, "delete me", "done")

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["sessions", "delete", session_key, "--confirm", "wrong"]) == 2
      end)

    assert error =~ "did not match"
    assert SessionLifecycle.get(session_key)

    deleted = run_json(["sessions", "delete", session_key, "--confirm", session_key, "--json"])
    assert deleted["delete"]["verified"] == true
    assert deleted["delete"]["existed"] == true
    assert SessionLifecycle.get(session_key) == nil
  end

  test "invalid bounds, conflicting filters, missing sessions, and future prune stay stable" do
    for argv <- [
          ["sessions", "list", "--limit", "501"],
          ["sessions", "list", "--pinned", "--unpinned"],
          ["sessions", "stats", "--group-limit", "51"],
          ["sessions", "stats", "--active", "--archived"],
          ["sessions", "stats", String.duplicate("x", 513)],
          ["sessions", "history", "only-a-key", "--limit", "0"],
          ["sessions", "prune", "--older-than", "2999-01-01"]
        ] do
      error =
        capture_io(:stderr, fn ->
          assert CLI.run(argv) == 2
        end)

      assert error =~ "Usage: lemon sessions"
    end

    not_found =
      capture_io(:stderr, fn ->
        assert CLI.run(["sessions", "show", "agent:missing:main"]) == 1
      end)

    assert not_found == "Session not found.\n"
  end

  defmodule ContextProvider do
    def session_context_usage(key, cwd) do
      case :persistent_term.get({__MODULE__, :result}) do
        :report ->
          ids = ~w(system_prompt tool_definitions skills context_files memory user_messages
                   assistant_messages tool_results summaries)a

          tokens = [2_000, 6_000, 500, 1_500, 0, 500, 1_500, 8_000, 0]
          :persistent_term.put({__MODULE__, :request}, {key, cwd})

          {:ok,
           %{
             live: false,
             overhead: :snapshot,
             model: %{provider: "anthropic", id: "claude-sonnet-4-5"},
             window: 200_000,
             used_tokens: 20_000,
             source: "usage",
             estimated_tokens: 19_000,
             auto_compaction: %{
               enabled: true,
               threshold_tokens: 168_000,
               reserve_tokens: 32_000,
               headroom_tokens: 148_000
             },
             categories:
               Enum.zip_with(ids, tokens, &%{id: &1, tokens: &2, percent: nil, items: 1}),
             top: [%{category: :tool_results, label: "read result #5", tokens: 8_000}],
             message_count: 6,
             measured_at: 1
           }}

        error ->
          error
      end
    end
  end

  test "sessions context prints the daemon's context-window breakdown" do
    previous = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, ContextProvider)
    :persistent_term.put({ContextProvider, :result}, :report)

    on_exit(fn ->
      :persistent_term.erase({ContextProvider, :result})
      :persistent_term.erase({ContextProvider, :request})

      if previous,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    key = "agent:default:tui:local:dm:context"
    json = run_json(["sessions", "context", key, "--cwd", "/repo", "--json"])
    assert :persistent_term.get({ContextProvider, :request}) == {key, "/repo"}
    assert json["context"]["usedTokens"] == 20_000
    assert Enum.sum(Enum.map(json["context"]["categories"], & &1["tokens"])) == 20_000

    text =
      capture_io(fn -> assert CLI.run(["sessions", "context", key, "--cwd", "/repo"]) == 0 end)

    assert text =~ "Model: claude-sonnet-4-5  20.0k / 200.0k tokens (10.0%)  [provider-reported]"
    assert text =~ "[" <> String.duplicate("#", 4) <> String.duplicate(".", 36) <> "]"
    assert text =~ ~r/Tool results\s+8\.0k\s+4\.0%/
    assert text =~ ~r/Free space\s+180\.0k\s+90\.0%/
    assert text =~ "1. read result #5  8.0k"
    assert text =~ "measured when the last turn ended"

    :persistent_term.put({ContextProvider, :result}, {:error, :session_not_found})

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["sessions", "context", key, "--cwd", "/repo", "--json"]) == 1
      end)

    assert Jason.decode!(error)["error"]["code"] == "session_not_found"

    :persistent_term.put({ContextProvider, :result}, {:error, :unavailable})

    assert capture_io(:stderr, fn ->
             assert CLI.run(["sessions", "context", key]) == 1
           end) =~ "not available yet"
  end

  defp seed_session(session_key, run_id, prompt, answer, updated_at_ms \\ nil) do
    :ok =
      RunStore.finalize(run_id, %{
        session_key: session_key,
        agent_id: session_key |> String.split(":") |> Enum.at(1),
        origin: :cli,
        prompt: prompt,
        completed: %{ok: true, answer: answer}
      })

    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)

    if is_integer(updated_at_ms) do
      row = SessionLifecycle.get(session_key)

      :ok =
        Store.put(:sessions_index, session_key, %{
          session_key: session_key,
          agent_id: row.agent_id,
          origin: row.origin,
          created_at_ms: updated_at_ms,
          updated_at_ms: updated_at_ms,
          run_count: row.run_count
        })
    end
  end

  defp run_json(argv) do
    output =
      capture_io(fn ->
        assert CLI.run(argv) == 0
      end)

    Jason.decode!(output)
  end

  defp assert_cli_ok(argv, expected) do
    output =
      capture_io(fn ->
        assert CLI.run(argv) == 0
      end)

    assert output =~ expected
  end

  defp eventually(fun, attempts \\ 500)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end

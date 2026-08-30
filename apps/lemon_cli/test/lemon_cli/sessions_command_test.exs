defmodule LemonCli.SessionsCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCore.{RunStore, SessionLifecycle, Store}

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    session_key = "agent:cli_sessions_#{suffix}:main"
    run_id = "run-cli-sessions-#{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    {:ok, session_key: session_key, run_id: run_id, suffix: suffix}
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
    assert inspect(history) =~ "[redacted]"

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
    assert content =~ "[redacted]"
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

  defp eventually(fun, attempts \\ 100)

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

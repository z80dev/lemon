defmodule Mix.Tasks.Lemon.IntrospectionTest do
  @moduledoc """
  Tests for the mix lemon.introspection task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Introspection
  alias Mix.Tasks.Lemon.Introspection, as: Task

  defp unique_token, do: System.unique_integer([:positive, :monotonic])

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  # ── module metadata ──────────────────────────────────────────────────────────

  describe "module attributes" do
    test "task module exists and exports run/1" do
      assert Code.ensure_loaded?(Task)
      assert function_exported?(Task, :run, 1)
    end

    test "has @shortdoc" do
      shortdoc = Mix.Task.shortdoc(Task)
      assert is_binary(shortdoc)
      assert shortdoc =~ "introspection"
    end

    test "has @moduledoc covering supported options" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Task)
      doc = module_doc["en"]
      assert doc =~ "--run-id"
      assert doc =~ "--session-key"
      assert doc =~ "--event-type"
      assert doc =~ "--limit"
      assert doc =~ "--since"
    end

    test "is registered with Mix under 'lemon.introspection'" do
      assert Mix.Task.get("lemon.introspection") == Task
    end
  end

  # ── empty results ─────────────────────────────────────────────────────────

  describe "empty results" do
    test "outputs graceful message when no events exist for an unknown run_id" do
      output =
        capture_io(fn ->
          Task.run(["--run-id", "run_nonexistent_#{unique_token()}"])
        end)

      assert output =~ "No introspection events found"
    end
  end

  # ── table output ──────────────────────────────────────────────────────────

  describe "table rendering" do
    test "output contains column headers" do
      token = unique_token()
      run_id = "run_table_hdr_#{token}"

      :ok =
        Introspection.record(:run_started, %{phase: "init"},
          run_id: run_id,
          session_key: "agent:test:#{token}",
          engine: "claude",
          agent_id: "agent_#{token}"
        )

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id])
        end)

      assert output =~ "Timestamp"
      assert output =~ "Event Type"
      assert output =~ "Run ID"
      assert output =~ "Session Key"
      assert output =~ "Agent ID"
      assert output =~ "Engine"
      assert output =~ "Provenance"
    end

    test "output contains event data for the matching run" do
      token = unique_token()
      run_id = "run_tbl_data_#{token}"
      session_key = "agent:tbl:#{token}"

      :ok =
        Introspection.record(:tool_completed, %{tool_name: "exec"},
          run_id: run_id,
          session_key: session_key,
          engine: "codex",
          agent_id: "agent_#{token}"
        )

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id])
        end)

      assert output =~ "tool_completed"
      assert output =~ "codex"
      assert output =~ "direct"
    end

    test "run_id values longer than 16 chars are truncated with ~" do
      token = unique_token()
      long_run_id = "run_" <> String.duplicate("x", 20) <> "_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: long_run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", long_run_id])
        end)

      # The column value should have been truncated (ends with ~)
      assert output =~ "~"
    end

    test "shows event count summary line" do
      token = unique_token()
      run_id = "run_count_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)
      :ok = Introspection.record(:run_completed, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id])
        end)

      assert output =~ "event(s) shown"
    end
  end

  # ── option parsing: --limit ───────────────────────────────────────────────

  describe "--limit option" do
    test "default limit is 20 when not specified" do
      token = unique_token()
      run_id = "run_deflim_#{token}"

      # Record 25 events
      for i <- 1..25 do
        :ok = Introspection.record(:"event_#{i}", %{}, run_id: run_id)
      end

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id])
        end)

      assert output =~ "limit: 20"
    end

    test "--limit controls max events returned" do
      token = unique_token()
      run_id = "run_lim5_#{token}"

      for i <- 1..10 do
        :ok = Introspection.record(:"ev_#{i}", %{}, run_id: run_id)
      end

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--limit", "5"])
        end)

      assert output =~ "limit: 5"
      assert output =~ "5 event(s) shown"
    end

    test "-l is accepted as alias for --limit" do
      token = unique_token()
      run_id = "run_limalias_#{token}"

      for i <- 1..4 do
        :ok = Introspection.record(:"ev_#{i}", %{}, run_id: run_id)
      end

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "-l", "2"])
        end)

      assert output =~ "limit: 2"
    end
  end

  # ── option parsing: --run-id ──────────────────────────────────────────────

  describe "--run-id filter" do
    test "filters events to the specified run_id" do
      token = unique_token()
      run_a = "run_A_#{token}"
      run_b = "run_B_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_a)
      :ok = Introspection.record(:run_started, %{}, run_id: run_b)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_a, "--limit", "50"])
        end)

      assert output =~ "run_started"
      # run_b events must not appear in column output (truncated IDs still match prefix)
      # We verify by checking the count is exactly 1
      assert output =~ "1 event(s) shown"
    end

    test "-r is accepted as alias for --run-id" do
      token = unique_token()
      run_id = "run_ralias_#{token}"
      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["-r", run_id])
        end)

      assert output =~ "run_started"
    end
  end

  # ── option parsing: --session-key ─────────────────────────────────────────

  describe "--session-key filter" do
    test "filters events to the specified session_key" do
      token = unique_token()
      sk_a = "agent:session_A:#{token}"
      sk_b = "agent:session_B:#{token}"

      :ok = Introspection.record(:run_started, %{}, session_key: sk_a)
      :ok = Introspection.record(:run_started, %{}, session_key: sk_b)

      output =
        capture_io(fn ->
          Task.run(["--session-key", sk_a, "--limit", "50"])
        end)

      assert output =~ "1 event(s) shown"
    end

    test "-s is accepted as alias for --session-key" do
      token = unique_token()
      sk = "agent:sk_alias:#{token}"
      :ok = Introspection.record(:run_started, %{}, session_key: sk)

      output =
        capture_io(fn ->
          Task.run(["-s", sk])
        end)

      assert output =~ "run_started"
    end
  end

  # ── option parsing: --event-type ─────────────────────────────────────────

  describe "--event-type filter" do
    test "filters events to the specified event type" do
      token = unique_token()
      run_id = "run_evtype_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)
      :ok = Introspection.record(:tool_completed, %{}, run_id: run_id)
      :ok = Introspection.record(:run_completed, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--event-type", "tool_completed", "--limit", "50"])
        end)

      assert output =~ "tool_completed"
      assert output =~ "1 event(s) shown"
    end

    test "-e is accepted as alias for --event-type" do
      token = unique_token()
      run_id = "run_etype_alias_#{token}"
      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "-e", "run_started"])
        end)

      assert output =~ "run_started"
    end
  end

  # ── option parsing: --since ───────────────────────────────────────────────

  describe "--since relative durations" do
    test "accepts '1h' and resolves to ~1 hour ago" do
      token = unique_token()
      run_id = "run_since1h_#{token}"

      # Record an event now (should appear within 1h window)
      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--since", "1h"])
        end)

      assert output =~ "run_started"
    end

    test "accepts '30m' relative duration" do
      token = unique_token()
      run_id = "run_since30m_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--since", "30m"])
        end)

      assert output =~ "run_started"
    end

    test "accepts '2d' relative duration" do
      token = unique_token()
      run_id = "run_since2d_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--since", "2d"])
        end)

      assert output =~ "run_started"
    end

    test "excludes events older than the since window" do
      token = unique_token()
      run_id = "run_sinceold_#{token}"

      # Record an event with a timestamp 2 hours in the past
      old_ts = System.system_time(:millisecond) - 2 * 60 * 60 * 1000

      :ok =
        Introspection.record(:run_started, %{},
          run_id: run_id,
          ts_ms: old_ts
        )

      output =
        capture_io(fn ->
          # Only look in the last 30 minutes; the event is 2h old so should be excluded
          Task.run(["--run-id", run_id, "--since", "30m"])
        end)

      assert output =~ "No introspection events found"
    end
  end

  describe "--since ISO8601 timestamps" do
    test "accepts a UTC ISO8601 timestamp" do
      token = unique_token()
      run_id = "run_iso8601_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      # Use a timestamp well in the past so the event is included
      past_iso = "2020-01-01T00:00:00Z"

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--since", past_iso])
        end)

      assert output =~ "run_started"
    end

    test "future ISO8601 timestamp excludes all events" do
      token = unique_token()
      run_id = "run_futureiso_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      # A timestamp far in the future means no events will match
      future_iso = "2099-01-01T00:00:00Z"

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--since", future_iso])
        end)

      assert output =~ "No introspection events found"
    end
  end

  # ── error handling ────────────────────────────────────────────────────────

  describe "error handling" do
    test "invalid --since format prints error and continues with no since filter" do
      token = unique_token()
      run_id = "run_badsince_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      # Mix.shell().error writes to stderr; capture_io captures stdout only.
      # The task should NOT crash and should still produce output.
      assert {output, stderr} =
               with_io(:stderr, fn ->
                 capture_io(fn ->
                   Task.run(["--run-id", run_id, "--since", "notvalid"])
                 end)
               end)

      # The task should continue and show events (no since filter applied)
      assert output =~ "run_started" or stderr =~ "Invalid"
    end

    test "unknown flags are silently ignored by OptionParser" do
      # OptionParser silently ignores unknown switches; task should not crash
      token = unique_token()
      run_id = "run_unk_flag_#{token}"
      :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--unknown-flag", "foo"])
        end)

      # Should still find the event (unknown flags stripped)
      assert output =~ "run_started"
    end
  end

  # ── combined filters ──────────────────────────────────────────────────────

  describe "combined filters" do
    test "run_id + event_type filters are applied together" do
      token = unique_token()
      run_id = "run_combo_#{token}"

      :ok = Introspection.record(:run_started, %{}, run_id: run_id)
      :ok = Introspection.record(:tool_completed, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--event-type", "run_started", "--limit", "50"])
        end)

      assert output =~ "run_started"
      assert output =~ "1 event(s) shown"
    end

    test "run_id + limit combination works" do
      token = unique_token()
      run_id = "run_combo_lim_#{token}"

      for _ <- 1..5, do: :ok = Introspection.record(:run_started, %{}, run_id: run_id)

      output =
        capture_io(fn ->
          Task.run(["--run-id", run_id, "--limit", "3"])
        end)

      assert output =~ "3 event(s) shown"
    end
  end
end

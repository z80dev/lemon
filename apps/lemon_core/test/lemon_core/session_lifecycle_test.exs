defmodule LemonCore.SessionLifecycleTest do
  use ExUnit.Case, async: false

  alias LemonCore.{
    ChatStateStore,
    PolicyStore,
    RunStore,
    SessionLifecycle,
    SessionMetadataStore,
    Store
  }

  setup do
    clear_metadata()
    :ok
  end

  defmodule FailingRunStore do
    def list_sessions, do: raise("private store failure /tmp/not-for-users")
    def history(_session_key, _opts), do: []
  end

  test "lists, filters, pins, archives, and searches metadata plus redacted history" do
    suffix = unique_suffix()
    first = "agent:lifecycle_#{suffix}:web:browser:unknown:first"
    second = "agent:lifecycle_#{suffix}:web:browser:unknown:second"

    on_exit(fn -> cleanup_sessions([first, second]) end)

    seed_session(first, "run-first-#{suffix}", "Plan lunar launch", "Checklist complete")
    seed_session(second, "run-second-#{suffix}", "Review citrus budget", "Budget ready")

    assert {:ok, first_row} =
             SessionLifecycle.patch(first, %{title: "Launch room", pinned: true, archived: false})

    assert first_row.title == "Launch room"
    assert first_row.pinned == true

    assert {:ok, second_row} =
             SessionLifecycle.patch(second, %{title: "Budget room", archived: true})

    assert second_row.archived == true

    result = SessionLifecycle.list(agent_id: "lifecycle_#{suffix}", archived: false)
    assert Enum.map(result.sessions, & &1.session_key) == [first]

    result = SessionLifecycle.list(query: "citrus budget")
    assert Enum.map(result.sessions, & &1.session_key) == [second]

    result = SessionLifecycle.list(query: "launch room", pinned: true)
    assert Enum.map(result.sessions, & &1.session_key) == [first]
  end

  test "ignores malformed legacy session-index rows without hiding valid sessions" do
    suffix = unique_suffix()
    session_key = "agent:lifecycle_malformed_#{suffix}:main"
    malformed_key = "malformed-session-row-#{suffix}"

    on_exit(fn ->
      cleanup_sessions([session_key])
      Store.delete(:sessions_index, malformed_key)
    end)

    seed_session(session_key, "run-malformed-#{suffix}", "valid prompt", "valid answer")
    assert :ok = Store.put(:sessions_index, malformed_key, %{session_key: nil, run_count: 1})

    result = SessionLifecycle.list(query: "lifecycle_malformed_#{suffix}")

    assert Enum.map(result.sessions, & &1.session_key) == [session_key]
  end

  test "statistics are exact for matched rows, bounded, stable, redacted, and filter-consistent" do
    suffix = unique_suffix()
    prefix = "stats_#{suffix}"
    malformed_key = "malformed-stats-row-#{suffix}"

    rows = [
      {"agent:#{prefix}:one", "alpha", :cli, 3, false, false},
      {"agent:#{prefix}:two", "alpha", :cli, 2, true, false},
      {"agent:#{prefix}:three", "beta", :web, 5, false, true},
      {"agent:#{prefix}:four", "gamma", :web, 7, false, false},
      {"agent:#{prefix}:five", "/Users/private/token=planted-secret", :api, 11, false, false}
    ]

    on_exit(fn ->
      cleanup_sessions(Enum.map(rows, &elem(&1, 0)))
      Store.delete(:sessions_index, malformed_key)
    end)

    rows
    |> Enum.with_index()
    |> Enum.each(fn {{session_key, agent_id, origin, run_count, pinned, archived}, i} ->
      timestamp = 1_700_000_000_000 + i

      :ok =
        Store.put(:sessions_index, session_key, %{
          session_key: session_key,
          agent_id: agent_id,
          origin: origin,
          created_at_ms: timestamp,
          updated_at_ms: timestamp,
          run_count: run_count
        })

      if pinned or archived do
        assert {:ok, _} =
                 SessionLifecycle.patch(session_key, %{pinned: pinned, archived: archived})
      end
    end)

    assert :ok = Store.put(:sessions_index, malformed_key, %{session_key: nil, run_count: 999})

    assert {:ok, report} = SessionLifecycle.stats(query: prefix, group_limit: 2)
    listed = SessionLifecycle.list(query: prefix, limit: 100)

    assert report.version == 1
    assert report.redacted
    assert report.totals.matched_sessions == listed.matched
    assert report.totals.matched_sessions == 5
    assert report.totals.active_sessions == 4
    assert report.totals.archived_sessions == 1
    assert report.totals.pinned_sessions == 1
    assert report.totals.runs == 28
    assert report.totals.oldest_updated_at_ms == 1_700_000_000_000
    assert report.totals.newest_updated_at_ms == 1_700_000_000_004

    assert report.breakdowns.agents.entries == [
             %{value: "alpha", count: 2},
             %{value: "beta", count: 1}
           ]

    assert report.breakdowns.agents.distinct == 4
    assert report.breakdowns.agents.omitted == 2

    # The deterministic tie-breaker is ascending value.
    assert report.breakdowns.origins.entries == [
             %{value: "cli", count: 2},
             %{value: "web", count: 2}
           ]

    assert {:ok, expanded} = SessionLifecycle.stats(query: prefix, group_limit: 50)
    serialized = inspect(expanded)
    refute serialized =~ "/Users/private"
    refute serialized =~ "planted-secret"
    refute serialized =~ "agent:#{prefix}"
    assert serialized =~ "redacted:"
    assert report.cleanup.max_dimension_entries == 2
    assert report.cleanup.includes_prompts == false
  end

  test "statistics expose stable empty and unavailable results without leaking errors" do
    assert {:ok, empty} =
             SessionLifecycle.stats(agent_id: "definitely_missing_#{unique_suffix()}")

    assert empty.totals.matched_sessions == 0
    assert empty.totals.runs == 0
    assert empty.totals.oldest_updated_at_ms == nil
    assert empty.breakdowns.agents.entries == []
    assert empty.breakdowns.origins.entries == []

    assert {:error, :session_store_unavailable} =
             SessionLifecycle.stats([], FailingRunStore)
  end

  test "returns full resumable history only when callers explicitly disable redaction" do
    suffix = unique_suffix()
    session_key = "agent:resume_#{suffix}:main"
    secret = "resume-secret-#{suffix}"

    on_exit(fn -> cleanup_sessions([session_key]) end)

    seed_session(
      session_key,
      "run-resume-#{suffix}",
      "token=#{secret}",
      "Bearer #{secret}",
      [
        %{
          __event__: :action_event,
          action: %{title: "exec", kind: :tool, detail: %{token: secret}},
          ok: true
        }
      ]
    )

    [safe] = SessionLifecycle.history(session_key)
    refute inspect(safe) =~ secret
    assert inspect(safe) =~ "[redacted]"
    assert [%{kind: "tool", title: "exec"}] = Enum.map(safe.tools, &Map.take(&1, [:kind, :title]))

    [full] = SessionLifecycle.history(session_key, redact: false)
    assert full.prompt =~ secret
    assert full.answer =~ secret
    assert inspect(full.tools) =~ secret
  end

  test "exports deterministic selected fields with redaction and omission metadata" do
    suffix = unique_suffix()
    session_key = "agent:export_#{suffix}:main"
    secret = "export-secret-#{suffix}"

    on_exit(fn -> cleanup_sessions([session_key]) end)

    seed_session(
      session_key,
      "run-export-#{suffix}",
      "api_key=#{secret}",
      "Bearer #{secret}",
      [
        %{
          __event__: :action_event,
          action: %{
            title: "request",
            kind: :http,
            detail: %{api_key: secret, body: "Bearer #{secret}"}
          },
          ok: false,
          message: "token=#{secret}"
        }
      ]
    )

    assert {:ok, json} = SessionLifecycle.export(session_key, format: :json)
    assert json.redacted == true
    assert json.run_count == 1
    assert byte_size(json.sha256) == 64
    assert json.filename =~ ".json"
    refute json.content =~ secret
    assert json.content =~ "[redacted]"

    decoded = Jason.decode!(json.content)
    assert decoded["redacted"] == true
    refute Map.has_key?(hd(decoded["runs"]), "rawEvents")
    refute Map.has_key?(hd(decoded["runs"]), "runRecord")

    assert {:ok, markdown} = SessionLifecycle.export(session_key, format: :markdown)
    assert markdown.filename =~ ".md"
    assert markdown.content =~ "Redacted export: yes"
    refute markdown.content =~ secret

    assert {:error, :unsupported_format} = SessionLifecycle.export(session_key, format: :html)
  end

  test "guarded prune binds parameters and exact candidates, excludes pins, and verifies deletion" do
    suffix = unique_suffix()
    stale = "agent:prune_#{suffix}:main:stale"
    pinned = "agent:prune_#{suffix}:main:pinned"
    fresh = "agent:prune_#{suffix}:main:fresh"
    now = System.system_time(:millisecond)
    threshold = now - 10_000

    on_exit(fn -> cleanup_sessions([stale, pinned, fresh]) end)

    seed_session(stale, "run-prune-stale-#{suffix}", "old", "done", [], now - 20_000)
    seed_session(pinned, "run-prune-pinned-#{suffix}", "old pin", "done", [], now - 20_000)
    seed_session(fresh, "run-prune-fresh-#{suffix}", "new", "done", [], now)

    assert {:ok, _} = SessionLifecycle.patch(stale, %{archived: true})
    assert {:ok, _} = SessionLifecycle.patch(pinned, %{archived: true, pinned: true})
    assert {:ok, _} = SessionLifecycle.patch(fresh, %{archived: true})
    assert :ok = ChatStateStore.put(stale, %{messages: ["private"]})
    assert :ok = PolicyStore.put_session(stale, %{model: "private"})

    assert {:ok, preview} = SessionLifecycle.prune(older_than_ms: threshold)
    assert preview.dry_run == true
    assert preview.archived_only == true
    assert preview.include_pinned == false
    assert preview.candidate_session_keys == [stale]
    assert SessionLifecycle.get(stale)

    assert {:error, :confirmation_required} =
             SessionLifecycle.prune(older_than_ms: threshold, dry_run: false)

    assert {:ok, _} = SessionLifecycle.patch(stale, %{title: "candidate changed"})

    assert {:error, :confirmation_mismatch} =
             SessionLifecycle.prune(
               older_than_ms: threshold,
               dry_run: false,
               confirm_token: preview.confirmation_token
             )

    assert {:ok, refreshed} = SessionLifecycle.prune(older_than_ms: threshold)

    assert {:ok, executed} =
             SessionLifecycle.prune(
               older_than_ms: threshold,
               dry_run: false,
               confirm_token: refreshed.confirmation_token
             )

    assert executed.verified == true
    assert executed.deleted_session_keys == [stale]
    assert SessionLifecycle.get(stale) == nil
    assert RunStore.history(stale, limit: 1) == []
    assert ChatStateStore.get(stale) == nil
    assert PolicyStore.get_session(stale) == nil
    assert SessionMetadataStore.get(stale).archived == false
    assert SessionLifecycle.get(pinned)
    assert SessionLifecycle.get(fresh)
  end

  test "restores ancillary state and preserves runs when the final canonical delete fails" do
    suffix = unique_suffix()
    session_key = "agent:delete_failure_#{suffix}:main"

    on_exit(fn -> cleanup_sessions([session_key]) end)
    seed_session(session_key, "run-delete-failure-#{suffix}", "keep me", "still here")
    assert {:ok, _} = SessionLifecycle.patch(session_key, %{title: "Keep", pinned: true})
    assert :ok = ChatStateStore.put(session_key, %{messages: ["keep"]})
    assert :ok = PolicyStore.put_session(session_key, %{model: "keep-model"})

    assert {:error, :injected_commit_failure} =
             SessionLifecycle.delete(session_key,
               run_delete_fun: fn ^session_key -> {:error, :injected_commit_failure} end
             )

    assert SessionLifecycle.get(session_key)
    assert RunStore.history(session_key, limit: 1) != []
    assert ChatStateStore.get(session_key).messages == ["keep"]
    assert PolicyStore.get_session(session_key) == %{model: "keep-model"}
    assert SessionMetadataStore.get(session_key).title == "Keep"
    assert SessionMetadataStore.get(session_key).pinned == true
  end

  defp seed_session(session_key, run_id, prompt, answer, events \\ [], updated_at_ms \\ nil) do
    Enum.each(events, &RunStore.append_event(run_id, &1))

    :ok =
      RunStore.finalize(run_id, %{
        session_key: session_key,
        agent_id: agent_id(session_key),
        origin: :web,
        prompt: prompt,
        completed: %{ok: true, answer: answer}
      })

    assert eventually(fn -> RunStore.history(session_key, limit: 1) != [] end)
    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)

    if is_integer(updated_at_ms) do
      row = SessionLifecycle.get(session_key)

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

  defp cleanup_sessions(session_keys) do
    Enum.each(session_keys, fn session_key ->
      SessionLifecycle.delete(session_key)
    end)
  end

  defp clear_metadata do
    Store.list(:session_metadata_v1)
    |> Enum.each(fn {key, _value} -> Store.delete(:session_metadata_v1, key) end)
  end

  defp agent_id(session_key) do
    session_key |> String.split(":") |> Enum.at(1)
  end

  defp unique_suffix, do: System.unique_integer([:positive, :monotonic])

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

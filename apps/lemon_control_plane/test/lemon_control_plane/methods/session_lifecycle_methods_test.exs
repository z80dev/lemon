defmodule LemonControlPlane.Methods.SessionLifecycleMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize

  alias LemonControlPlane.Methods.{
    SessionsDelete,
    SessionsExport,
    SessionsList,
    SessionsMetadataPatch,
    SessionsPrune,
    SessionsStats
  }

  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.{RunStore, SessionLifecycle, SessionMetadataStore, Store}

  setup do
    clear_metadata()
    :ok
  end

  test "metadata patch and sessions.list expose searchable lifecycle state without echoing mutations" do
    suffix = unique_suffix()
    session_key = "agent:cp_lifecycle_#{suffix}:web:browser:unknown:test"
    title = "Private planning room #{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)
    seed_session(session_key, "run-cp-list-#{suffix}", "Review launch manifest", "Manifest ready")

    assert {:ok, patched} =
             SessionsMetadataPatch.handle(
               %{"sessionKey" => session_key, "title" => title, "pinned" => true},
               %{}
             )

    assert patched["success"] == true
    assert patched["metadata"]["titlePresent"] == true
    assert patched["metadata"]["titleBytes"] == byte_size(title)
    assert patched["metadata"]["pinned"] == true
    refute inspect(patched) =~ title

    assert {:ok, listed} =
             SessionsList.handle(
               %{"query" => "launch manifest", "pinned" => true, "archived" => false},
               %{}
             )

    assert listed["total"] == 1
    assert listed["filters"]["queryBytes"] == byte_size("launch manifest")
    refute Map.has_key?(listed["filters"], "query")
    assert listed["summary"]["filtersApplied"] == ["archived", "pinned", "query"]
    assert listed["summary"]["cleanup"]["includesSearchQuery"] == false

    assert [row] = listed["sessions"]
    assert row["sessionKey"] == session_key
    assert row["title"] == title
    assert row["pinned"] == true
    assert row["archived"] == false
  end

  test "sessions.export is redacted, bounded, digested, and omits raw internals" do
    suffix = unique_suffix()
    session_key = "agent:cp_export_#{suffix}:main"
    secret = "cp-export-secret-#{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    seed_session(
      session_key,
      "run-cp-export-#{suffix}",
      "api_key=#{secret}",
      "Bearer #{secret}",
      [
        %{
          __event__: :action_event,
          action: %{title: "fetch", kind: :http, detail: %{token: secret}},
          raw_provider_payload: secret,
          ok: true
        }
      ]
    )

    assert {:ok, exported} =
             SessionsExport.handle(%{"sessionKey" => session_key, "format" => "json"}, %{})

    assert exported["redacted"] == true
    assert exported["bytes"] == byte_size(exported["content"])
    assert byte_size(exported["sha256"]) == 64
    refute inspect(exported) =~ secret

    cleanup = exported["summary"]["cleanup"]
    assert cleanup["includesRawEvents"] == false
    assert cleanup["includesRunRecords"] == false
    assert cleanup["includesCredentials"] == false
    assert cleanup["includesSecretValues"] == false
    assert cleanup["maxBytes"] >= exported["bytes"]
  end

  test "sessions.stats exposes exact filtered aggregates without session or content fields" do
    suffix = unique_suffix()
    session_key = "agent:cp_stats_#{suffix}:main"
    secret = "cp-stats-secret-#{suffix}"

    on_exit(fn -> SessionLifecycle.delete(session_key) end)
    seed_session(session_key, "run-cp-stats-#{suffix}", "token=#{secret}", "done")
    assert {:ok, _} = SessionLifecycle.patch(session_key, %{pinned: true})

    assert {:ok, report} =
             SessionsStats.handle(
               %{"query" => "cp_stats_#{suffix}", "pinned" => true, "groupLimit" => 5},
               %{}
             )

    assert report["redacted"] == true
    assert report["totals"]["matchedSessions"] == 1
    assert report["totals"]["pinnedSessions"] == 1
    assert report["totals"]["runs"] >= 1
    assert report["cleanup"]["includesSessionKeys"] == false
    refute inspect(report) =~ session_key
    refute inspect(report) =~ secret

    assert {:error, {:invalid_params, _, nil}} =
             SessionsStats.handle(%{"query" => String.duplicate("x", 513)}, %{})
  end

  test "sessions.prune requires a matching preview token and sessions.delete removes metadata" do
    suffix = unique_suffix()
    session_key = "agent:cp_prune_#{suffix}:main"
    old = System.system_time(:millisecond) - 50_000
    threshold = old + 10_000

    on_exit(fn -> SessionLifecycle.delete(session_key) end)
    seed_session(session_key, "run-cp-prune-#{suffix}", "old", "done", [], old)

    assert {:ok, _} =
             SessionsMetadataPatch.handle(
               %{"sessionKey" => session_key, "archived" => true},
               %{}
             )

    assert {:ok, preview} = SessionsPrune.handle(%{"olderThanMs" => threshold}, %{})
    assert preview["dryRun"] == true
    assert preview["candidateSessionKeys"] == [session_key]
    assert preview["summary"]["requiresConfirmation"] == true

    assert {:error, {:conflict, _, nil}} =
             SessionsPrune.handle(%{"olderThanMs" => threshold, "dryRun" => false}, %{})

    assert {:ok, executed} =
             SessionsPrune.handle(
               %{
                 "olderThanMs" => threshold,
                 "dryRun" => false,
                 "confirmToken" => preview["confirmToken"]
               },
               %{}
             )

    assert executed["verified"] == true
    assert executed["deletedSessionKeys"] == [session_key]
    assert SessionLifecycle.get(session_key) == nil

    second = "agent:cp_delete_#{suffix}:main"
    on_exit(fn -> SessionLifecycle.delete(second) end)
    seed_session(second, "run-cp-delete-#{suffix}", "delete", "done")
    assert {:ok, _} = SessionLifecycle.patch(second, %{title: "Delete me", pinned: true})

    assert {:ok, deleted} = SessionsDelete.handle(%{"sessionKey" => second}, %{})
    assert deleted["summary"]["verified"] == true
    assert deleted["summary"]["cleanup"]["deletedLifecycleMetadata"] == true
    assert SessionMetadataStore.fetch(second) == nil
  end

  test "schemas and authorization advertise the lifecycle contract" do
    assert :ok =
             Schemas.validate("sessions.metadata.patch", %{
               "sessionKey" => "agent:test:main",
               "title" => nil,
               "pinned" => false
             })

    assert :ok =
             Schemas.validate("sessions.prune", %{
               "olderThanMs" => 1,
               "archivedOnly" => true,
               "dryRun" => true
             })

    assert :ok =
             Schemas.validate("sessions.export", %{
               "sessionKey" => "agent:test:main",
               "format" => "markdown"
             })

    assert :ok = Schemas.validate("sessions.stats", %{"groupLimit" => 10})

    assert Authorize.required_scopes("sessions.metadata.patch") == [:admin]
    assert Authorize.required_scopes("sessions.prune") == [:admin]
    assert Authorize.required_scopes("sessions.export") == [:read]
    assert Authorize.required_scopes("sessions.stats") == [:read]
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

  defp clear_metadata do
    Store.list(:session_metadata_v1)
    |> Enum.each(fn {key, _value} -> Store.delete(:session_metadata_v1, key) end)
  end

  defp agent_id(session_key), do: session_key |> String.split(":") |> Enum.at(1)
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

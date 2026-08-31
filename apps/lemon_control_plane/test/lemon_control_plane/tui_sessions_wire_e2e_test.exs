defmodule LemonControlPlane.TuiSessionsWireE2ETest do
  use ExUnit.Case, async: false

  alias LemonCore.{RunStore, SessionLifecycle, Store}

  @operator_token "tui-session-wire-operator-token"

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    prune_key = "agent:tui_wire_prune_#{suffix}:main"
    delete_key = "agent:tui_wire_delete_#{suffix}:main"
    keep_key = "agent:tui_wire_keep_#{suffix}:main"
    secret = "tui-wire-secret-#{suffix}"
    old = System.system_time(:millisecond) - 60_000
    cutoff = old + 10_000

    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    session_index = snapshot_table(:sessions_index)
    session_metadata = snapshot_table(:session_metadata_v1)
    clear_table(:sessions_index)
    clear_table(:session_metadata_v1)

    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    seed_session(
      prune_key,
      "run-tui-wire-prune-#{suffix}",
      "wire lifecycle api_key=#{secret}",
      "ready Bearer #{secret}",
      old
    )

    seed_session(
      delete_key,
      "run-tui-wire-delete-#{suffix}",
      "delete after export token=#{secret}",
      "delete ready Bearer #{secret}"
    )

    seed_session(
      keep_key,
      "run-tui-wire-keep-#{suffix}",
      "fresh retained session",
      "keep"
    )

    on_exit(fn ->
      Enum.each([prune_key, delete_key, keep_key], &SessionLifecycle.delete/1)
      clear_table(:sessions_index)
      clear_table(:session_metadata_v1)
      restore_table(:sessions_index, session_index)
      restore_table(:session_metadata_v1, session_metadata)
      restore_env(:operator_token, previous_token)
      restore_env(:allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    {:ok,
     suffix: suffix,
     prune_key: prune_key,
     delete_key: delete_key,
     keep_key: keep_key,
     cutoff: cutoff,
     secret: secret}
  end

  test "the production Bun TUI client crosses authenticated Bandit for the full session lifecycle",
       context do
    bun = System.find_executable("bun") || flunk("bun is required for the TUI wire proof")

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:tui_sessions_wire_bandit, context.suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    repo_root = Path.expand("../../../..", __DIR__)
    proof_client = Path.join(repo_root, "clients/tui/scripts/sessions-wire-proof.ts")

    {output, status} =
      System.cmd(
        bun,
        [
          proof_client,
          "ws://127.0.0.1:#{port}/ws",
          @operator_token,
          context.prune_key,
          context.delete_key,
          context.keep_key,
          Integer.to_string(context.cutoff),
          context.secret
        ],
        cd: repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert {:ok, proof} = Jason.decode(String.trim(output))
    assert proof["ok"] == true
    assert proof["candidateCount"] == 1
    assert proof["deletedCount"] == 2
    assert length(proof["checks"]) == 7
    refute output =~ context.secret
    refute SessionLifecycle.get(context.prune_key)
    refute SessionLifecycle.get(context.delete_key)
    assert SessionLifecycle.get(context.keep_key)
  end

  defp seed_session(session_key, run_id, prompt, answer, updated_at_ms \\ nil) do
    :ok =
      RunStore.finalize(run_id, %{
        session_key: session_key,
        agent_id: session_key |> String.split(":") |> Enum.at(1),
        origin: :tui,
        prompt: prompt,
        completed: %{ok: true, answer: answer}
      })

    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)
    assert eventually(fn -> RunStore.history(session_key, limit: 1) != [] end)

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

  defp snapshot_table(table), do: Store.list(table)

  defp clear_table(table) do
    table
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(table, key) end)
  end

  defp restore_table(table, rows) do
    Enum.each(rows, fn {key, value} -> Store.put(table, key, value) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_control_plane, key, value)

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

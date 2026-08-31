defmodule LemonControlPlane.SessionStatsWireE2ETest do
  use ExUnit.Case, async: false

  alias LemonCore.{RunStore, SessionLifecycle, Store}

  @operator_token "session-stats-wire-operator-token"

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    session_key = "agent:stats_wire_#{suffix}:main"
    query = "stats_wire_#{suffix}"
    secret = "stats-wire-secret-#{suffix}"

    previous_token = Application.get_env(:lemon_control_plane, :operator_token)

    previous_loopback =
      Application.get_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator)

    sessions = Store.list(:sessions_index)
    metadata = Store.list(:session_metadata_v1)
    clear_table(:sessions_index)
    clear_table(:session_metadata_v1)

    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    :ok =
      RunStore.finalize("run-stats-wire-#{suffix}", %{
        session_key: session_key,
        agent_id: query,
        origin: :tui,
        prompt: "token=#{secret}",
        completed: %{ok: true, answer: "done"}
      })

    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)
    assert {:ok, _} = SessionLifecycle.patch(session_key, %{pinned: true})

    on_exit(fn ->
      SessionLifecycle.delete(session_key)
      clear_table(:sessions_index)
      clear_table(:session_metadata_v1)
      restore_table(:sessions_index, sessions)
      restore_table(:session_metadata_v1, metadata)
      restore_env(:operator_token, previous_token)
      restore_env(:allow_unauthenticated_loopback_operator, previous_loopback)
    end)

    {:ok, suffix: suffix, query: query, secret: secret}
  end

  test "authenticated WebSocket exposes bounded redacted aggregate statistics", context do
    bun = System.find_executable("bun") || flunk("bun is required for the stats wire proof")

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: {:session_stats_wire_bandit, context.suffix},
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)
    repo_root = Path.expand("../../../..", __DIR__)
    script = Path.join(repo_root, "clients/tui/scripts/session-stats-wire-proof.ts")

    {output, status} =
      System.cmd(
        bun,
        [
          script,
          "ws://127.0.0.1:#{port}/ws",
          @operator_token,
          context.query,
          context.secret
        ],
        cd: repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output

    assert {:ok, %{"ok" => true, "matchedSessions" => 1, "runs" => 1}} =
             Jason.decode(String.trim(output))

    refute output =~ context.secret
  end

  defp clear_table(table) do
    table
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(table, key) end)
  end

  defp restore_table(table, rows),
    do: Enum.each(rows, fn {key, value} -> Store.put(table, key, value) end)

  defp restore_env(key, nil), do: Application.delete_env(:lemon_control_plane, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_control_plane, key, value)

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

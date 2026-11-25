defmodule LemonCli.ClientBootTest do
  @moduledoc """
  One-shot commands in a second VM boot `:lemon_core` in client mode and leave
  the running runtime's approvals and store alone (#667).
  """
  use ExUnit.Case, async: false

  alias LemonCore.{ExecApprovalExpiry, ExecApprovals, ExecApprovalStore, Store}

  @moduletag :tmp_dir
  @moduletag :subprocess

  setup %{tmp_dir: tmp_dir} do
    original = Application.fetch_env!(:lemon_core, Store)
    database = Path.join(tmp_dir, "store.sqlite3")

    for child <- [ExecApprovalExpiry, LemonCore.RuntimeOwner, Store], do: stop_child(child)

    Application.put_env(:lemon_core, Store,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: [path: database, ephemeral_tables: [:runs]],
      finalize_run_hooks: [{ExecApprovalExpiry, :handle_finalize_run}]
    )

    # This VM plays the daemon: it owns the database and its approvals.
    for child <- [Store, LemonCore.RuntimeOwner, ExecApprovalExpiry], do: restart_child(child)
    :ok = ExecApprovalExpiry.ensure_ready()
    assert LemonCore.RuntimeOwner.owner?()
    LemonCore.Bus.subscribe("exec_approvals")

    on_exit(fn ->
      for child <- [ExecApprovalExpiry, LemonCore.RuntimeOwner, Store], do: stop_child(child)
      Application.put_env(:lemon_core, Store, original)
      for child <- [Store, LemonCore.RuntimeOwner, ExecApprovalExpiry], do: restart_child(child)
    end)

    %{database: database, home: Path.join(tmp_dir, "home")}
  end

  test "a pending approval survives `lemon secrets list` and `lemon doctor` in a second VM", c do
    {task, id} = request()
    session_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(session_owner, :kill) end)
    assert :ok = ExecApprovalExpiry.watch_session("daemon-session", session_owner)

    pending = ExecApprovalStore.get_pending(id)
    {:ok, owners} = ExecApprovalStore.fetch_session_owners()
    {:ok, rows} = Store.fetch_all(:exec_approvals_pending)

    peer = start_peer(c)

    assert {code, _out} = run_cli(peer, ["secrets", "list"])
    assert code in [0, 1]
    assert {_code, _out} = run_cli(peer, ["doctor"])

    # Client mode: no ownership, recovery, sweeps, reloader, run history or trap.
    assert :peer.call(peer, LemonCore.Application, :boot_mode, []) == :read_only_client

    ids =
      Enum.map(
        :peer.call(peer, Supervisor, :which_children, [LemonCore.Supervisor]),
        &elem(&1, 0)
      )

    for absent <- [
          LemonCore.RuntimeOwner,
          LemonCore.RunHistoryStore,
          LemonCore.ConfigReloader,
          LemonCore.ConfigReloader.Watcher,
          LemonCore.Drain
        ],
        do: refute(absent in ids)

    refute LemonCore.Drain.SignalHandler in :peer.call(peer, :gen_event, :which_handlers, [
             :erl_signal_server
           ])

    # The client store never writes, and its approval worker never recovered.
    assert %{read_only: true} = :peer.call(peer, :sys, :get_state, [Store])
    assert {:error, :read_only} = :peer.call(peer, Store, :put, [:client_probe, :key, :value])

    assert {:error, :store_unavailable} =
             :peer.call(peer, ExecApprovalExpiry, :ensure_ready, [])

    :peer.stop(peer)

    assert ExecApprovalStore.get_pending(id) == pending
    assert {:ok, ^owners} = ExecApprovalStore.fetch_session_owners()
    assert {:ok, ^rows} = Store.fetch_all(:exec_approvals_pending)

    # The daemon still owns its approval.
    assert {:ok, %{outcome: :approved}} = ExecApprovals.resolve(id, :approve_once)
    assert {:ok, :approved, _scope} = Task.await(task)
  end

  test "a one-shot `lemon secrets set` beside the daemon never writes the store itself", c do
    peer = start_peer(c)
    # No control plane answers: the write must fail closed, not fall back locally.
    :ok = :peer.call(peer, System, :put_env, ["LEMON_CONTROL_PLANE_PORT", closed_port()])

    assert {1, ""} = run_cli(peer, ["secrets", "set", "PEER_SECRET", "peer-value"])

    assert :peer.call(peer, LemonCore.Application, :boot_mode, []) == :client
    assert %{write_refusal: :runtime_owned} = :peer.call(peer, :sys, :get_state, [Store])

    assert {:error, :runtime_owned} =
             :peer.call(peer, Store, :put, [LemonCore.Secrets.table(), :probe, :value])

    :peer.stop(peer)

    assert {:ok, nil} = Store.fetch(LemonCore.Secrets.table(), {"default", "PEER_SECRET"})
    assert LemonCore.RuntimeOwner.owner?()
  end

  test "a daemon starting while a writable one-shot VM holds the store refuses to start", c do
    # The daemon is not up yet: the one-shot VM holds the ownership locks.
    stop_child(LemonCore.RuntimeOwner)
    peer = start_peer(c)
    assert :ok = :peer.call(peer, LemonCore.CLI, :start, [:lemon_core])
    assert :ok = :peer.call(peer, Store, :write_access, [])
    assert :ok = :peer.call(peer, Store, :put, [:client_boot_probe, :before, :value])

    # The daemon's ownership process (started before its store writers) waits
    # its lock deadline, then refuses rather than become a second writer.
    assert {:error, :store_held_by_client} =
             Supervisor.restart_child(LemonCore.Supervisor, LemonCore.RuntimeOwner)

    refute LemonCore.RuntimeOwner.owner?()
    assert :ok = :peer.call(peer, Store, :put, [:client_boot_probe, :still, :value])

    # Once the one-shot VM exits, the daemon owns the store.
    :peer.stop(peer)
    restart_child(LemonCore.RuntimeOwner)
    assert LemonCore.RuntimeOwner.owner?()
    assert {:ok, :value} = Store.fetch(:client_boot_probe, :before)
    assert {:ok, :value} = Store.fetch(:client_boot_probe, :still)
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    Integer.to_string(port)
  end

  defp request do
    id = "client-boot-#{System.unique_integer([:positive])}"

    task =
      Task.async(fn ->
        ExecApprovals.request(%{
          approval_id: id,
          run_id: "run-#{id}",
          session_id: "daemon-session",
          session_key: "agent:test:client-boot",
          agent_id: "test",
          tool: "bash",
          action: %{command: "ls"},
          expires_in_ms: :infinity
        })
      end)

    assert_receive %LemonCore.Event{type: :approval_requested, payload: %{approval_id: ^id}},
                   2_000

    {task, id}
  end

  # A fresh VM with this VM's code and configuration, pointed at the same
  # database, and with the SIGTERM trap enabled so client mode must skip it.
  defp start_peer(%{database: database, home: home}) do
    File.mkdir_p!(home)

    {:ok, peer, _node} =
      :peer.start(%{
        connection: :standard_io,
        args: [~c"-env", ~c"HOME", String.to_charlist(home), ~c"-pa" | :code.get_path()]
      })

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end
    end)

    # Mix mirrors the source launcher (`mix run --no-start`) and its test env.
    for app <- [:elixir, :logger, :mix],
        do: {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [app])

    :ok = :peer.call(peer, Mix, :env, [:test])

    for {app, _description, _vsn} <- Application.loaded_applications(),
        app not in [:kernel, :stdlib, :elixir, :logger, :ex_unit, :mix, :hex] do
      _ = :peer.call(peer, Application, :load, [app])
      :ok = :peer.call(peer, Application, :put_all_env, [[{app, Application.get_all_env(app)}]])
    end

    :ok =
      :peer.call(peer, Application, :put_env, [
        :lemon_core,
        Store,
        [
          backend: LemonCore.Store.SqliteBackend,
          backend_opts: [path: database, ephemeral_tables: [:runs]]
        ]
      ])

    :ok =
      :peer.call(peer, Application, :put_env, [:lemon_core, LemonCore.Drain, [signal_trap: true]])

    peer
  end

  defp run_cli(peer, argv) do
    {result, _binding} =
      :peer.call(
        peer,
        Code,
        :eval_string,
        [
          """
          {:ok, device} = StringIO.open("")
          Process.group_leader(self(), device)
          code = LemonCli.CLI.run(argv)
          {code, device |> StringIO.contents() |> elem(1)}
          """,
          [argv: argv]
        ],
        60_000
      )

    result
  end

  defp stop_child(child), do: :ok = Supervisor.terminate_child(LemonCore.Supervisor, child)

  defp restart_child(child),
    do: {:ok, _pid} = Supervisor.restart_child(LemonCore.Supervisor, child)
end

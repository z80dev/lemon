defmodule CodingAgent.Session.StartupIsolationTest.GatedMCP do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  # Holds `initialize` until the observer releases it, so a profile MCP
  # connection is slow for exactly as long as a test needs.
  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    request = Jason.decode!(body)

    if request["method"] == "initialize" do
      send(conn.assigns.observer, {:mcp_initialize, self()})

      receive do
        :release -> :ok
      after
        30_000 -> :ok
      end
    end

    result =
      case request["method"] do
        "initialize" ->
          %{
            "protocolVersion" => "2025-06-18",
            "capabilities" => %{"tools" => %{}},
            "serverInfo" => %{"name" => "gated-startup-fixture", "version" => "1"}
          }

        "tools/list" ->
          %{"tools" => []}

        _ ->
          nil
      end

    if result do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    else
      send_resp(conn, 202, "")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts),
    do: conn |> Plug.Conn.assign(:observer, Keyword.fetch!(opts, :observer)) |> super(opts)
end

defmodule CodingAgent.Session.StartupIsolationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SessionSupervisor}
  alias CodingAgent.Session.{Ownership, RootLifecycle}
  alias LemonAgent.Test.Mocks

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    previous_disabled = Application.get_env(:lemon_skills, :mcp_disabled)
    previous_env = System.get_env("LEMON_MCP_DISABLED")
    Application.put_env(:lemon_skills, :mcp_disabled, false)
    System.delete_env("LEMON_MCP_DISABLED")

    bandit =
      start_supervised!(
        {Bandit,
         plug: {CodingAgent.Session.StartupIsolationTest.GatedMCP, observer: self()},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    origin = "http://127.0.0.1:#{port}"

    server = %{
      "name" => "gated-startup",
      "url" => origin <> "/mcp",
      "headers" => %{},
      "allowedOrigins" => [origin],
      "approvedPrivateOrigins" => [origin]
    }

    on_exit(fn ->
      if is_nil(previous_disabled),
        do: Application.delete_env(:lemon_skills, :mcp_disabled),
        else: Application.put_env(:lemon_skills, :mcp_disabled, previous_disabled)

      if is_nil(previous_env),
        do: System.delete_env("LEMON_MCP_DISABLED"),
        else: System.put_env("LEMON_MCP_DISABLED", previous_env)

      File.rm_rf!(SessionManager.get_session_dir(cwd))
    end)

    %{cwd: cwd, server: server}
  end

  # The MCP client gives up on a server that never answers `initialize` after
  # about five seconds, so every assertion made while the gate is held is
  # about ordering (the blocked start is still pending), not elapsed time.
  test "a session whose init blocks on MCP does not delay another start or stop", ctx do
    existing = SessionSupervisor.list_sessions()
    {:ok, stopped} = SessionSupervisor.start_session(base_opts(ctx))

    slow =
      Task.async(fn ->
        SessionSupervisor.start_session(
          base_opts(ctx) ++ [executor_root: true, invocation_mcp_servers: [ctx.server]]
        )
      end)

    assert_receive {:mcp_initialize, handler}, 5_000
    other = Task.async(fn -> SessionSupervisor.start_session(base_opts(ctx)) end)

    # Before deferred init, these queued behind the blocked init in the
    # supervisor until MCP gave up.
    assert :ok = SessionSupervisor.stop_session(stopped)
    refute Process.alive?(stopped)
    assert Task.yield(slow, 0) == nil

    # The second start was admitted and is initializing beside the blocked one.
    LemonPlatformTest.Testing.AsyncHelpers.assert_eventually(fn ->
      length(SessionSupervisor.list_sessions() -- existing) == 2
    end)

    assert Task.yield(slow, 0) == nil
    send(handler, :release)

    assert {:ok, session} = Task.await(slow, 30_000)
    on_exit(fn -> SessionSupervisor.stop_session(session) end)
    assert Session.get_state(session).mcp_session_id =~ "profile-mcp-"

    assert {:ok, pid} = Task.await(other, 60_000)
    on_exit(fn -> SessionSupervisor.stop_session(pid) end)
    assert session in SessionSupervisor.list_sessions()
    assert pid in SessionSupervisor.list_sessions()
  end

  test "a failed deferred init reports its error, releases the journal and spares the caller",
       ctx do
    Process.flag(:trap_exit, true)
    closed = %{ctx.server | "url" => "http://127.0.0.1:9/mcp"}
    id = "failed-startup-#{System.unique_integer([:positive])}"
    path = SessionManager.session_file_path(ctx.cwd, id)

    assert {:error, {:profile_mcp, _reason}} =
             Session.start_link(
               base_opts(ctx) ++
                 [session_id: id, executor_root: true, invocation_mcp_servers: [closed]]
             )

    refute_receive {:EXIT, _, _}, 100
    assert Ownership.owner(path) == nil

    assert {:ok, session} = SessionSupervisor.start_session(base_opts(ctx) ++ [session_id: id])
    on_exit(fn -> SessionSupervisor.stop_session(session) end)
    assert Ownership.owner(path) == session
  end

  test "another conversation's checkout succeeds while one root's prepare_root_turn is slow",
       ctx do
    {:ok, slow_root} = SessionSupervisor.start_session(base_opts(ctx) ++ [executor_root: true])
    {:ok, fast_root} = SessionSupervisor.start_session(base_opts(ctx) ++ [executor_root: true])

    on_exit(fn ->
      SessionSupervisor.stop_session(slow_root)
      SessionSupervisor.stop_session(fast_root)
    end)

    slow_opts =
      Keyword.put(Session.get_state(slow_root).tool_opts, :invocation_mcp_servers, [ctx.server])

    slow = Task.async(fn -> RootLifecycle.checkout(session_id(slow_root), slow_opts) end)
    assert_receive {:mcp_initialize, handler}, 5_000

    fast_opts = Session.get_state(fast_root).tool_opts
    fast = Task.async(fn -> RootLifecycle.checkout(session_id(fast_root), fast_opts) end)
    assert {:ok, {:ok, ^fast_root}} = Task.yield(fast, 5_000) || Task.shutdown(fast)

    send(handler, :release)
    assert {:ok, ^slow_root} = Task.await(slow, 10_000)
  end

  defp base_opts(ctx), do: [cwd: ctx.cwd, model: Mocks.mock_model()]

  defp session_id(session), do: Session.get_state(session).session_manager.header.id
end

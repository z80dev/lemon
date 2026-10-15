defmodule LemonControlPlane.Methods.OmpMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.EventBridge
  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.Presence
  alias LemonControlPlane.Protocol.{Frames, Schemas}

  @fake_omp Path.expand("../../support/fake_omp", __DIR__)
  @omp_env_keys [:executable, :agent_dir, :command_timeout_ms, :ready_timeout_ms]

  @read_methods ~w(omp.status omp.sessions.list omp.sessions.get omp.sessions.discover omp.models omp.sessions.subagent)
  @write_methods ~w(omp.sessions.start omp.sessions.resume omp.sessions.send
                    omp.sessions.cancel omp.sessions.close omp.sessions.startMany omp.sessions.configure)

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-omp-cp-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(workspace)
    File.mkdir_p!(agent_dir)

    previous_app = Map.new(@omp_env_keys, &{&1, Application.get_env(:lemon_omp, &1)})
    previous_bin = System.get_env("LEMON_OMP_BIN")
    System.delete_env("LEMON_OMP_BIN")

    Application.put_env(:lemon_omp, :executable, @fake_omp)
    Application.put_env(:lemon_omp, :agent_dir, agent_dir)
    Application.put_env(:lemon_omp, :command_timeout_ms, 2_000)
    Application.put_env(:lemon_omp, :ready_timeout_ms, 5_000)

    on_exit(fn ->
      for session <- LemonOmp.list(include_ended: false, limit: 100) do
        LemonOmp.close(session["id"])
      end

      Enum.each(previous_app, fn
        {key, nil} -> Application.delete_env(:lemon_omp, key)
        {key, value} -> Application.put_env(:lemon_omp, key, value)
      end)

      if previous_bin, do: System.put_env("LEMON_OMP_BIN", previous_bin)
      File.rm_rf!(root)
    end)

    {:ok, workspace: workspace, agent_dir: agent_dir}
  end

  describe "registration and authorization" do
    test "every omp method is registered with a schema, scope and dispatch mode" do
      for method <- @read_methods ++ @write_methods do
        assert {:ok, module} = Registry.lookup(method)
        assert Schemas.get(method) != nil
        expected = if method in @write_methods, do: [:write], else: [:read]
        assert module.scopes() == expected
        assert Authorize.required_scopes(method) == expected
        assert method in Registry.list_methods()
      end

      for method <- @write_methods ++ ~w(omp.status omp.models omp.sessions.subagent) do
        assert Registry.dispatch_mode(method) == :async
      end

      for method <- ~w(omp.sessions.list omp.sessions.get omp.sessions.discover) do
        assert Registry.dispatch_mode(method) == :inline
      end

      assert "omp.session" in Frames.supported_events()
    end

    test "read scope cannot mutate and write scope cannot read", %{workspace: workspace} do
      read_only = ctx([:read])
      write_only = ctx([:write])

      assert {:ok, %{"available" => true}} = Registry.dispatch("omp.status", %{}, read_only)
      assert {:ok, %{"sessions" => _}} = Registry.dispatch("omp.sessions.list", %{}, read_only)

      writes = [
        {"omp.sessions.start", %{"prompt" => "hi", "cwd" => workspace}},
        {"omp.sessions.resume", %{"ompSessionId" => "01abcdef", "cwd" => workspace}},
        {"omp.sessions.send", %{"id" => "omp_x", "message" => "hi"}},
        {"omp.sessions.cancel", %{"id" => "omp_x"}},
        {"omp.sessions.close", %{"id" => "omp_x"}}
      ]

      for {method, params} <- writes do
        assert {:error, {:forbidden, _}} = Registry.dispatch(method, params, read_only)
      end

      reads = [
        {"omp.status", %{}},
        {"omp.sessions.list", %{}},
        {"omp.sessions.get", %{"id" => "omp_x"}},
        {"omp.sessions.discover", %{"cwd" => workspace}}
      ]

      for {method, params} <- reads do
        assert {:error, {:forbidden, _}} = Registry.dispatch(method, params, write_only)
      end

      assert LemonOmp.list(include_ended: false) == []
    end
  end

  describe "expanded operator methods" do
    test "resume continues without a caller prompt and forwards approval mode", %{
      workspace: cwd,
      agent_dir: agent_dir
    } do
      omp_id = "01a137c9-4e60-73f4-a776-ece03008a9fe"
      write_session_file(agent_dir, cwd, omp_id)

      assert {:ok, %{"session" => session}} =
               Registry.dispatch(
                 "omp.sessions.resume",
                 %{
                   "cwd" => cwd,
                   "ompSessionId" => omp_id,
                   "continue" => true,
                   "approvalMode" => "always-ask"
                 },
                 ctx([:write])
               )

      assert session["approvalMode"] == "always-ask"
      assert await_status(session["id"], "idle")["lastTurn"] == "completed"
    end

    test "catalog filters, batches, configuration and child transcripts", %{workspace: cwd} do
      all = ctx([:read, :write])

      assert {:ok, %{"models" => [%{"selector" => "fake/free", "free" => true}]}} =
               Registry.dispatch(
                 "omp.models",
                 %{"provider" => "fake", "query" => "free", "freeOnly" => true, "limit" => 1},
                 all
               )

      assert {:ok, %{"results" => [%{"index" => 0, "session" => session}]}} =
               Registry.dispatch(
                 "omp.sessions.startMany",
                 %{
                   "isolate" => false,
                   "tasks" => [
                     %{
                       "cwd" => cwd,
                       "prompt" => "HOLD",
                       "approvalMode" => "write",
                       "thinking" => "low",
                       "model" => "fake/free"
                     }
                   ]
                 },
                 all
               )

      id = session["id"]
      assert session["owner"] == %{"kind" => "operator"}
      assert session["approvalMode"] == "write"
      assert session["worktree"] == nil
      await_status(id, "running")

      assert {:ok, %{"session" => %{"id" => ^id, "thinking" => "low"}}} =
               Registry.dispatch(
                 "omp.sessions.configure",
                 %{"id" => id, "model" => "fake/free", "thinking" => "low"},
                 all
               )

      assert {:ok,
              %{
                "id" => ^id,
                "subagentId" => "child",
                "transcript" => %{"nextByte" => 42, "messages" => [_]}
              }} =
               Registry.dispatch(
                 "omp.sessions.subagent",
                 %{"id" => id, "subagentId" => "child", "limit" => 1},
                 all
               )

      assert {:ok, %{"accepted" => true, "delivery" => "redirect"}} =
               Registry.dispatch(
                 "omp.sessions.send",
                 %{"id" => id, "message" => "HOLD again", "mode" => "redirect"},
                 all
               )
    end

    test "bounds new parameters and validates whole batches", %{workspace: cwd} do
      all = ctx([:read, :write])

      for {method, params} <- [
            {"omp.models", %{"limit" => 201}},
            {"omp.models", %{"query" => String.duplicate("x", 129)}},
            {"omp.sessions.subagent", %{"id" => "x", "subagentId" => "child", "limit" => 51}},
            {"omp.sessions.configure", %{"id" => "x"}},
            {"omp.sessions.start", %{"cwd" => cwd, "prompt" => "hi", "approvalMode" => "unsafe"}},
            {"omp.sessions.resume",
             %{"cwd" => cwd, "ompSessionId" => "abcd", "continue" => true, "prompt" => "hi"}},
            {"omp.sessions.startMany", %{"tasks" => []}},
            {"omp.sessions.startMany",
             %{"tasks" => List.duplicate(%{"cwd" => cwd, "prompt" => "hi"}, 9)}}
          ] do
        assert {:error, {:invalid_params, _, _}} = Registry.dispatch(method, params, all)
      end

      assert {:error, {:invalid_params, _, %{"code" => "OMP_INVALID_TASK", "index" => 1}}} =
               Registry.dispatch(
                 "omp.sessions.startMany",
                 %{"tasks" => [%{"cwd" => cwd, "prompt" => "hi"}, %{"cwd" => cwd}]},
                 all
               )

      assert {:error, {:invalid_params, _, %{"code" => "OMP_NOT_A_GIT_REPO", "field" => "cwd"}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"cwd" => cwd, "prompt" => "hi", "isolate" => true},
                 all
               )

      assert LemonOmp.list(include_ended: false) == []
    end

    test "public error mappings preserve partial application and uncertain ids" do
      alias LemonControlPlane.Methods.OmpSupport, as: Support

      for {reason, category, code} <- [
            {:not_a_git_repo, :invalid_params, "OMP_NOT_A_GIT_REPO"},
            {:worktree_failed, :unavailable, "OMP_WORKTREE_FAILED"},
            {{:catalog_failed, "private"}, :unavailable, "OMP_CATALOG_FAILED"},
            {{:invalid_task, 2, :invalid_prompt}, :invalid_params, "OMP_INVALID_TASK"}
          ] do
        assert {:error, {^category, _, %{"code" => ^code}}} = Support.error(reason)
      end

      assert {:error,
              {:conflict, _,
               %{
                 "code" => "OMP_PARTIALLY_APPLIED",
                 "applied" => ["model"],
                 "failedStep" => "thinking",
                 "retrySafe" => false
               }}} =
               Support.error({:partially_applied, ["model"], "thinking", :outcome_unknown})

      assert {:error, {:unavailable, _, %{"id" => "fixed", "retrySafe" => false}}} =
               Support.error({:outcome_unknown, "fixed"})
    end
  end

  describe "parameter validation" do
    test "rejects missing, mistyped and out-of-bounds params before reaching omp",
         %{workspace: workspace} do
      all = ctx([:read, :write])

      assert {:error, {:invalid_request, "Missing required fields: cwd"}} =
               Registry.dispatch("omp.sessions.start", %{"prompt" => "hi"}, all)

      assert {:error, {:invalid_request, "Missing required fields: cwd"}} =
               Registry.dispatch("omp.sessions.discover", %{}, all)

      assert {:error, {:invalid_request, "Type errors: cwd: expected string, got integer"}} =
               Registry.dispatch("omp.sessions.start", %{"prompt" => "hi", "cwd" => 1}, all)

      assert {:error, {:invalid_request, _}} =
               Registry.dispatch("omp.sessions.list", %{"limit" => "10"}, all)

      for limit <- [0, 101] do
        assert {:error, {:invalid_params, _, %{"field" => "limit"}}} =
                 Registry.dispatch("omp.sessions.list", %{"limit" => limit}, all)

        assert {:error, {:invalid_params, _, %{"field" => "limit"}}} =
                 Registry.dispatch(
                   "omp.sessions.discover",
                   %{"cwd" => workspace, "limit" => limit},
                   all
                 )
      end

      oversized = String.duplicate("a", 16_385)

      assert {:error,
              {:invalid_params, "message must be at most 16 KiB", %{"field" => "message"}}} =
               Registry.dispatch(
                 "omp.sessions.send",
                 %{"id" => "omp_x", "message" => oversized},
                 all
               )

      assert {:error, {:invalid_params, _, %{"field" => "message"}}} =
               Registry.dispatch("omp.sessions.send", %{"id" => "omp_x", "message" => "  "}, all)

      assert {:error,
              {:invalid_params, "mode must be steer, followUp or redirect", %{"field" => "mode"}}} =
               Registry.dispatch(
                 "omp.sessions.send",
                 %{"id" => "omp_x", "message" => "hi", "mode" => "interrupt"},
                 all
               )

      assert {:error, {:invalid_params, _, %{"field" => "cwd", "code" => "OMP_INVALID_PARAMS"}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "hi", "cwd" => Path.join(workspace, "missing")},
                 all
               )

      assert {:error, {:invalid_params, _, %{"field" => "thinking"}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "hi", "cwd" => workspace, "thinking" => "galaxy-brain"},
                 all
               )

      assert {:error, {:invalid_params, _, %{"field" => "ompSessionId"}}} =
               Registry.dispatch(
                 "omp.sessions.resume",
                 %{"ompSessionId" => String.duplicate("a", 65), "cwd" => workspace},
                 all
               )

      assert LemonOmp.list(include_ended: false) == []
    end
  end

  describe "omp not installed" do
    test "status degrades and starts fail as unavailable", %{workspace: workspace} do
      Application.put_env(:lemon_omp, :executable, "/nonexistent/lemon-test/omp")

      assert {:ok, status} = Registry.dispatch("omp.status", %{}, ctx([:read]))
      assert status["available"] == false
      assert status["reason"] == "not_installed"
      assert status["version"] == nil

      assert {:error, {:unavailable, message, %{"code" => "OMP_NOT_INSTALLED"}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "hi", "cwd" => workspace},
                 ctx([:write])
               )

      assert message == LemonOmp.error_message(:not_installed)

      assert {:error, {:unavailable, _, %{"code" => "OMP_NOT_INSTALLED"}}} =
               Registry.dispatch(
                 "omp.sessions.resume",
                 %{"ompSessionId" => "01abcdef", "cwd" => workspace},
                 ctx([:write])
               )
    end
  end

  describe "unknown sessions" do
    test "reads and control of an unknown id are not_found" do
      all = ctx([:read, :write])

      for {method, params} <- [
            {"omp.sessions.get", %{"id" => "omp_000000000000"}},
            {"omp.sessions.send", %{"id" => "omp_000000000000", "message" => "hi"}},
            {"omp.sessions.cancel", %{"id" => "omp_000000000000"}},
            {"omp.sessions.close", %{"id" => "omp_000000000000"}}
          ] do
        assert {:error, {:not_found, message, %{"code" => "OMP_SESSION_NOT_FOUND"}}} =
                 Registry.dispatch(method, params, all)

        assert message == LemonOmp.error_message(:not_found)
      end
    end
  end

  describe "live sessions against a fake omp" do
    test "start, get, follow-up, close, then fail closed", %{workspace: workspace} do
      all = ctx([:read, :write])

      assert {:ok, %{"version" => "omp 9.9.9-test", "available" => true}} =
               Registry.dispatch("omp.status", %{}, all)

      assert {:ok, %{"session" => session}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "Summarize the repo", "cwd" => workspace, "thinking" => "low"},
                 all
               )

      id = session["id"]
      assert "omp_" <> _ = id
      assert session["owner"] == %{"kind" => "operator"}
      assert session["thinking"] == "low"

      idle = await_status(id, "idle")
      assert idle["lastTurn"] == "completed"
      assert idle["result"] == "fake omp done"

      assert {:ok, %{"session" => %{"id" => ^id}, "summary" => summary}} =
               Registry.dispatch("omp.sessions.get", %{"id" => id}, all)

      assert is_binary(summary) and summary != ""

      assert {:ok, %{"sessions" => [%{"id" => ^id} | _]}} =
               Registry.dispatch("omp.sessions.list", %{"limit" => 1}, all)

      assert {:ok, %{"accepted" => true, "delivery" => "prompt"}} =
               Registry.dispatch(
                 "omp.sessions.send",
                 %{"id" => id, "message" => "and again"},
                 all
               )

      await_status(id, "idle")

      assert {:error, {:conflict, _, %{"code" => "OMP_NO_ACTIVE_TURN"}}} =
               Registry.dispatch("omp.sessions.cancel", %{"id" => id}, all)

      assert {:ok, %{"session" => %{"id" => ^id, "status" => "closed"}}} =
               Registry.dispatch("omp.sessions.close", %{"id" => id}, all)

      assert {:error, {:conflict, message, %{"code" => "OMP_SESSION_NOT_RUNNING"}}} =
               Registry.dispatch("omp.sessions.send", %{"id" => id, "message" => "late"}, all)

      assert message == LemonOmp.error_message(:not_running)

      assert {:error, {:conflict, _, %{"code" => "OMP_SESSION_NOT_RUNNING"}}} =
               Registry.dispatch("omp.sessions.cancel", %{"id" => id}, all)

      assert {:error, {:conflict, _, %{"code" => "OMP_SESSION_NOT_RUNNING"}}} =
               Registry.dispatch("omp.sessions.close", %{"id" => id}, all)

      # Ended sessions stay listed unless the caller asks for live ones only.
      assert {:ok, %{"sessions" => listed}} = Registry.dispatch("omp.sessions.list", %{}, all)
      assert id in Enum.map(listed, & &1["id"])

      assert {:ok, %{"sessions" => live}} =
               Registry.dispatch("omp.sessions.list", %{"includeEnded" => false}, all)

      refute id in Enum.map(live, & &1["id"])
    end

    test "steers, queues follow-ups and cancels a running turn", %{workspace: workspace} do
      all = ctx([:read, :write])

      assert {:ok, %{"session" => %{"id" => id}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "HOLD this turn", "cwd" => workspace},
                 all
               )

      await_status(id, "running")

      assert {:ok, %{"accepted" => true, "delivery" => "steer"}} =
               Registry.dispatch("omp.sessions.send", %{"id" => id, "message" => "focus"}, all)

      assert {:ok, %{"accepted" => true, "delivery" => "followUp"}} =
               Registry.dispatch(
                 "omp.sessions.send",
                 %{"id" => id, "message" => "then this", "mode" => "followUp"},
                 all
               )

      assert {:ok, %{"cancelled" => true}} =
               Registry.dispatch("omp.sessions.cancel", %{"id" => id}, all)

      assert %{"lastTurn" => "aborted"} = await_status(id, "idle")
    end

    test "omp rejections are conflicts carrying omp's bounded message", %{workspace: workspace} do
      all = ctx([:read, :write])

      assert {:error, {:conflict, message, %{"code" => "OMP_REJECTED"}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "REJECT me", "cwd" => workspace},
                 all
               )

      assert message =~ "fake omp refused"

      assert {:ok, %{"session" => %{"id" => id}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "ok", "cwd" => workspace},
                 all
               )

      await_status(id, "idle")

      assert {:error, {:conflict, _, %{"code" => "OMP_REJECTED"}}} =
               Registry.dispatch("omp.sessions.send", %{"id" => id, "message" => "REJECT"}, all)
    end

    test "unacknowledged mutations are outcome-unknown and not retry-safe",
         %{workspace: workspace} do
      Application.put_env(:lemon_omp, :command_timeout_ms, 300)
      all = ctx([:read, :write])

      assert {:ok, %{"session" => %{"id" => id}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "ok", "cwd" => workspace},
                 all
               )

      await_status(id, "idle")

      assert {:error, {:unavailable, message, details}} =
               Registry.dispatch("omp.sessions.send", %{"id" => id, "message" => "NO_ACK"}, all)

      assert details == %{"code" => "OMP_OUTCOME_UNKNOWN", "retrySafe" => false, "id" => id}
      assert message == LemonOmp.error_message(:outcome_unknown)

      assert {:error, {:unavailable, _, %{"code" => "OMP_OUTCOME_UNKNOWN", "retrySafe" => false}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "NO_ACK start", "cwd" => workspace},
                 all
               )
    end
  end

  describe "discovery" do
    test "lists omp's stored sessions for a workspace and validates cwd",
         %{workspace: workspace, agent_dir: agent_dir} do
      all = ctx([:read])
      omp_session_id = "01a137c9-4e60-73f4-a776-ece03008a9fe"
      write_session_file(agent_dir, workspace, omp_session_id)

      assert {:ok, %{"sessions" => [discovered]}} =
               Registry.dispatch(
                 "omp.sessions.discover",
                 %{"cwd" => workspace, "limit" => 5},
                 all
               )

      assert discovered["ompSessionId"] == omp_session_id
      assert discovered["title"] == "Fix the flaky test"
      assert discovered["liveId"] == nil

      assert {:error, {:invalid_params, _, %{"field" => "cwd"}}} =
               Registry.dispatch(
                 "omp.sessions.discover",
                 %{"cwd" => Path.join(workspace, "missing")},
                 all
               )
    end
  end

  describe "omp.session events" do
    setup do
      bridge = Process.whereis(EventBridge) || start_supervised!(EventBridge)
      Process.whereis(Presence) || start_supervised!(Presence)
      conn_id = "omp-conn-#{System.unique_integer([:positive])}"
      node_conn_id = "omp-node-#{System.unique_integer([:positive])}"
      parent = self()

      node_pid =
        spawn_link(fn ->
          receive do
            {:event, name, _payload, _version} -> send(parent, {:node_got, name})
          end
        end)

      :ok = Presence.register(conn_id, %{role: :operator, client_id: "omp-test", pid: self()})
      :ok = Presence.register(node_conn_id, %{role: :node, client_id: "node-1", pid: node_pid})

      on_exit(fn ->
        Presence.unregister(conn_id)
        Presence.unregister(node_conn_id)
      end)

      {:ok, bridge: bridge}
    end

    test "bus snapshots reach operator clients unchanged, never nodes", %{bridge: bridge} do
      session = %{"id" => "omp_feedfacecafe", "status" => "running", "turns" => 1}
      event = LemonCore.Event.new(:omp_session, %{"reason" => "updated", "session" => session})

      LemonCore.Bus.broadcast(LemonOmp.bus_topic(), event)
      :sys.get_state(bridge)

      assert_receive {:event, "omp.session", payload, _state_version}, 1_000
      assert payload == %{"reason" => "updated", "session" => session}
      assert :ok = Schemas.validate_event("omp.session", payload)
      refute_receive {:node_got, _}, 100

      assert {:error, _} = Schemas.validate_event("omp.session", %{"reason" => "updated"})
    end

    test "a real session publishes lifecycle events through the bridge",
         %{workspace: workspace} do
      assert {:ok, %{"session" => %{"id" => id}}} =
               Registry.dispatch(
                 "omp.sessions.start",
                 %{"prompt" => "go", "cwd" => workspace},
                 ctx([:write])
               )

      assert_receive {:event, "omp.session",
                      %{"reason" => "started", "session" => %{"id" => ^id}}, _},
                     2_000

      assert_receive {:event, "omp.session",
                      %{"reason" => "settled", "session" => %{"id" => ^id, "status" => "idle"}},
                      _},
                     5_000
    end
  end

  defp ctx(scopes) do
    %{
      conn_id: "omp-test-conn",
      conn_pid: self(),
      auth: %{role: :operator, scopes: scopes, token: nil, client_id: nil, identity: nil}
    }
  end

  defp await_status(id, status, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_status(id, status, deadline)
  end

  defp do_await_status(id, status, deadline) do
    {:ok, session} = LemonOmp.get(id)

    cond do
      session["status"] == status ->
        session

      System.monotonic_time(:millisecond) > deadline ->
        flunk("omp session #{id} stayed #{session["status"]}, expected #{status}")

      true ->
        Process.sleep(20)
        do_await_status(id, status, deadline)
    end
  end

  # omp's on-disk layout: `<agent_dir>/sessions/<encoded cwd>/<ts>_<uuid>.jsonl`,
  # using the absolute-path encoding (`--<path with / as ->--`).
  defp write_session_file(agent_dir, cwd, omp_session_id) do
    encoded = "--" <> (cwd |> String.trim_leading("/") |> String.replace("/", "-")) <> "--"
    dir = Path.join([agent_dir, "sessions", encoded])
    File.mkdir_p!(dir)

    lines = [
      %{"type" => "title", "v" => 1, "title" => "Fix the flaky test"},
      %{
        "type" => "session",
        "id" => omp_session_id,
        "cwd" => cwd,
        "timestamp" => "2026-10-13T00:00:00.000Z"
      },
      %{
        "type" => "message",
        "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => "hi"}]}
      }
    ]

    File.write!(
      Path.join(dir, "2026-10-13T00-00-00-000Z_#{omp_session_id}.jsonl"),
      Enum.map_join(lines, "\n", &Jason.encode!/1) <> "\n"
    )
  end
end

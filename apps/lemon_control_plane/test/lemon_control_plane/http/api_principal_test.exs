defmodule LemonControlPlane.HTTP.APIPrincipalTest do
  @moduledoc """
  The OpenAI-compatible and POST `/acp` API tokens are their own principals:
  they hold read/write authority only, see only runs they submitted, stay in
  their own session-key namespace and workspace, and cannot relax approvals.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.HTTP.Router

  @openai_token "openai-principal-test-token"
  @acp_token "acp-principal-test-token"
  @operator_token "operator-principal-test-token"

  setup do
    env =
      Map.new(
        ~w(LEMON_OPENAI_COMPAT_API_TOKEN LEMON_ACP_API_TOKEN LEMON_AGENT_DIR),
        &{&1, System.get_env(&1)}
      )

    app_keys = [
      :operator_token,
      :allow_unauthenticated_loopback_operator,
      :openai_compat_submitter,
      :openai_compat_run_getter,
      :openai_compat_canceller
    ]

    app_env = Map.new(app_keys, &{&1, Application.fetch_env(:lemon_control_plane, &1)})

    agent_dir =
      Path.join(System.tmp_dir!(), "lemon-api-principal-#{System.unique_integer([:positive])}")

    workspace = Path.join(agent_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, "project"))
    outside = Path.join(agent_dir, "outside")
    File.mkdir_p!(outside)

    System.put_env("LEMON_OPENAI_COMPAT_API_TOKEN", @openai_token)
    System.put_env("LEMON_ACP_API_TOKEN", @acp_token)
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    Application.put_env(:lemon_control_plane, :operator_token, @operator_token)
    Application.put_env(:lemon_control_plane, :allow_unauthenticated_loopback_operator, false)

    parent = self()

    Application.put_env(:lemon_control_plane, :openai_compat_submitter, fn request ->
      send(parent, {:submitted, request})
      {:ok, "run_api_own_#{System.unique_integer([:positive])}"}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_run_getter, fn _run_id ->
      %{started_at: 1_700_000_000_000, events: [:started], summary: nil}
    end)

    Application.put_env(:lemon_control_plane, :openai_compat_canceller, fn run_id, reason ->
      send(parent, {:cancelled, run_id, reason})
      :ok
    end)

    on_exit(fn ->
      for {key, value} <- env do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      for {key, value} <- app_env do
        case value do
          {:ok, value} -> Application.put_env(:lemon_control_plane, key, value)
          :error -> Application.delete_env(:lemon_control_plane, key)
        end
      end

      File.rm_rf!(agent_dir)
    end)

    {:ok, workspace: workspace, outside: outside}
  end

  describe "OpenAI-compatible principal" do
    test "cannot read or cancel a run another principal submitted" do
      for path <- ["/v1/runs/run_foreign_1", "/v1/responses/resp_run_foreign_1"] do
        response = :get |> conn(path) |> openai_auth() |> Router.call([]) |> json_response()
        assert response.status == 404, "#{path} exposed a foreign run: #{inspect(response)}"
      end

      response =
        :post
        |> conn("/v1/runs/run_foreign_1/cancel")
        |> openai_auth()
        |> Router.call([])
        |> json_response()

      assert response.status == 404
      refute_received {:cancelled, "run_foreign_1", _}
    end

    test "cannot chain onto a run another principal submitted" do
      response =
        chat(:responses, %{
          "input" => "hello",
          "previous_response_id" => "resp_run_foreign_2"
        })

      assert response.status == 404
      refute_received {:submitted, _}
    end

    test "reads and cancels the runs it submitted" do
      created = chat(:completions, %{})
      assert created.status == 200
      run_id = created.body["lemon"]["runId"]

      status =
        :get |> conn("/v1/runs/#{run_id}") |> openai_auth() |> Router.call([]) |> json_response()

      assert status.status == 200

      cancel =
        :post
        |> conn("/v1/runs/#{run_id}/cancel")
        |> openai_auth()
        |> Router.call([])
        |> json_response()

      assert cancel.status == 200
      assert cancel.body["status"] == "cancelling"
      assert_received {:cancelled, ^run_id, :openai_compat_cancel}
    end

    test "reports a failed cancellation instead of claiming cancelling" do
      created = chat(:completions, %{})
      run_id = created.body["lemon"]["runId"]

      Application.put_env(:lemon_control_plane, :openai_compat_canceller, fn _run_id, _reason ->
        {:error, :not_found}
      end)

      cancel =
        :post
        |> conn("/v1/runs/#{run_id}/cancel")
        |> openai_auth()
        |> Router.call([])
        |> json_response()

      refute cancel.status == 200 and cancel.body["status"] == "cancelling"
    end

    test "cannot target another principal's session key" do
      for key <- [
            "agent:default:telegram:bot:dm:12345",
            "agent:default:main",
            "agent:default:openai",
            "agent:default:openai:api:../x",
            "a:telegram:bot:dm:1",
            %{"metadata" => "agent:default:main"}
          ] do
        params =
          case key do
            %{"metadata" => key} -> %{"metadata" => %{"session_key" => key}}
            key -> %{"session_key" => key}
          end

        response = chat(:completions, params)
        key = with %{"metadata" => key} <- key, do: key

        if response.status == 200 do
          assert_received {:submitted, request}
          refute request.session_key == key

          assert String.starts_with?(request.session_key, "agent:default:openai:api"),
                 "API principal ran in #{request.session_key}"
        else
          assert response.status == 400
        end
      end
    end

    test "session labels stay inside the principal namespace and round-trip" do
      first = chat(:completions, %{"session_key" => "notes"})
      assert first.status == 200
      assert_received {:submitted, request}
      assert request.session_key == "agent:default:openai:api:notes"
      assert first.body["lemon"]["sessionKey"] == request.session_key

      again = chat(:completions, %{"session_key" => request.session_key})
      assert again.status == 200
      assert_received {:submitted, %{session_key: "agent:default:openai:api:notes"}}
    end

    test "agent_id cannot smuggle a foreign session key" do
      response = chat(:completions, %{"agent_id" => "default:telegram:bot:dm:1"})
      assert response.status == 400
      refute_received {:submitted, _}
    end

    test "rejects a raw tool_policy that fails ToolPolicy.parse" do
      response = chat(:completions, %{"tool_policy" => %{"allow" => "everything", "bogus" => 1}})
      assert response.status == 400
      assert response.body["error"]["message"] =~ "tool_policy"
      refute_received {:submitted, _}
    end

    test "cannot relax approvals through tool_policy" do
      for policy <- [
            %{"approval_mode" => "yolo"},
            %{"approvals" => %{"bash" => "never"}},
            %{"approvals" => %{"bash" => "dangerous"}}
          ] do
        response = chat(:completions, %{"tool_policy" => policy})
        assert response.status in [400, 403], "accepted #{inspect(policy)}"
        refute_received {:submitted, _}
      end
    end

    test "rejects a cwd outside the principal workspace", %{
      workspace: workspace,
      outside: outside
    } do
      escape = Path.join(workspace, "escape")
      File.ln_s!(outside, escape)

      for cwd <- [outside, "/", "../outside", "escape", escape, "~", 7] do
        response = chat(:completions, %{"cwd" => cwd})
        assert response.status == 400, "accepted cwd #{cwd}: #{inspect(response)}"
        assert response.body["error"]["message"] =~ "cwd"
        refute_received {:submitted, _}
      end
    end

    test "runs inside the principal workspace", %{workspace: workspace} do
      response = chat(:completions, %{})
      assert response.status == 200
      assert_received {:submitted, request}
      assert request.cwd == real(workspace)

      response = chat(:completions, %{"cwd" => Path.join(workspace, "project")})
      assert response.status == 200
      assert_received {:submitted, request}
      assert request.cwd == real(Path.join(workspace, "project"))
    end
  end

  describe "POST /acp principal" do
    test "cannot set approval=auto without the approvals scope", %{workspace: workspace} do
      session_id = acp_session!(workspace)

      response =
        acp(%{
          "jsonrpc" => "2.0",
          "id" => "approval",
          "method" => "session/set_config_option",
          "params" => %{"sessionId" => session_id, "configId" => "approval", "value" => "auto"}
        })

      assert response.status == 200
      assert %{"error" => %{"message" => message}} = response.body
      assert message =~ "approval"
      refute get_acp_session(session_id)[:approval_mode] == "auto"
    end

    test "session/new cwd is confined to the API workspace", %{
      workspace: workspace,
      outside: outside
    } do
      escape = Path.join(workspace, "acp-escape")
      File.ln_s!(outside, escape)

      for cwd <- [outside, "/", escape] do
        response = acp(new_session_request(cwd))
        assert %{"error" => %{"message" => message}} = response.body, "accepted #{cwd}"
        assert message =~ "cwd"
      end

      session_id = acp_session!(Path.join(workspace, "project"))

      assert get_acp_session(session_id).cwd ==
               real(Path.join(workspace, "project"))

      response =
        acp(
          put_in(new_session_request(workspace), ["params", "_meta"], %{
            "lemon" => %{"agentId" => "x:telegram:bot:dm:1"}
          })
        )

      assert %{"error" => _} = response.body
    end

    test "only reaches ACP sessions this principal created", %{workspace: workspace} do
      # An operator-created session (the in-process caller carries no principal).
      {:ok, %{"result" => %{"sessionId" => foreign}}} =
        LemonControlPlane.ACP.handle_jsonrpc(new_session_request(workspace))

      on_exit(fn -> delete_acp_session(foreign) end)
      own = acp_session!(workspace)

      for {method, params} <- [
            {"session/load", %{"cwd" => workspace, "mcpServers" => []}},
            {"session/resume", %{"cwd" => workspace, "mcpServers" => []}},
            {"session/fork", %{"cwd" => workspace, "mcpServers" => []}},
            {"session/close", %{}},
            {"session/cancel", %{}},
            {"session/prompt", %{"prompt" => [%{"type" => "text", "text" => "hi"}]}},
            {"session/set_config_option", %{"configId" => "thinking", "value" => "high"}}
          ] do
        response =
          acp(%{
            "jsonrpc" => "2.0",
            "id" => method,
            "method" => method,
            "params" => Map.put(params, "sessionId", foreign)
          })

        assert %{"error" => %{"message" => "session not found"}} = response.body,
               "#{method} reached a foreign session: #{inspect(response.body)}"
      end

      assert get_acp_session(foreign)[:closed] == false

      listed =
        acp(%{"jsonrpc" => "2.0", "id" => "list", "method" => "session/list", "params" => %{}})

      ids = Enum.map(listed.body["result"]["sessions"], & &1["sessionId"])
      assert own in ids
      refute foreign in ids

      resumed =
        acp(%{
          "jsonrpc" => "2.0",
          "id" => "resume",
          "method" => "session/resume",
          "params" => %{"sessionId" => own, "cwd" => workspace, "mcpServers" => []}
        })

      assert %{"result" => _} = resumed.body
    end

    test "an operator fork of an API session belongs to the operator", %{workspace: workspace} do
      source = acp_session!(workspace)

      {:ok, %{"result" => %{"sessionId" => fork}}} =
        LemonControlPlane.ACP.handle_jsonrpc(
          %{
            "jsonrpc" => "2.0",
            "id" => "fork",
            "method" => "session/fork",
            "params" => %{"sessionId" => source, "cwd" => real(workspace), "mcpServers" => []}
          },
          scopes: [:admin, :read, :write, :approvals, :pairing],
          principal: "operator"
        )

      on_exit(fn -> delete_acp_session(fork) end)
      assert get_acp_session(fork).owner == "operator"

      listed =
        acp(%{"jsonrpc" => "2.0", "id" => "list", "method" => "session/list", "params" => %{}})

      refute fork in Enum.map(listed.body["result"]["sessions"], & &1["sessionId"])

      for {method, params} <- [
            {"session/prompt", %{"prompt" => [%{"type" => "text", "text" => "hi"}]}},
            {"session/cancel", %{}},
            {"session/close", %{}}
          ] do
        response =
          acp(%{
            "jsonrpc" => "2.0",
            "id" => method,
            "method" => method,
            "params" => Map.put(params, "sessionId", fork)
          })

        assert %{"error" => %{"message" => "session not found"}} = response.body,
               "#{method} reached the operator's fork: #{inspect(response.body)}"
      end

      assert get_acp_session(fork)[:closed] == false
    end
  end

  describe "tool_policy authority" do
    test "a full_access request is clamped to the effective session policy" do
      session_key = "agent:default:openai:api:clamp"

      :ok =
        LemonCore.PolicyStore.put_session(session_key, %{tool_policy: %{"profile" => "read_only"}})

      on_exit(fn -> LemonCore.PolicyStore.delete_session(session_key) end)

      response = chat(:completions, %{"session_key" => "clamp", "tool_policy" => "full_access"})
      assert response.status == 200
      assert_received {:submitted, request}
      assert request.session_key == session_key

      assert {:ok, submission} =
               LemonRouter.SubmissionBuilder.build(
                 %{request | run_id: "run_clamp_#{System.unique_integer([:positive])}"},
                 %{
                   run_supervisor: LemonRouter.RunSupervisor,
                   run_process_module: LemonRouter.RunProcess,
                   run_process_opts: %{notify_pid: self()}
                 }
               )

      policy = submission.execution_request.tool_policy
      refute LemonCore.ToolPolicy.allowed?(policy, "bash")
      refute LemonCore.ToolPolicy.allowed?(policy, "write")
    end
  end

  describe "run owner retention" do
    test "owner rows expire and are swept" do
      created = chat(:completions, %{})
      run_id = created.body["lemon"]["runId"]
      owner = LemonCore.Store.get(:openai_compat_run_owners, run_id)
      assert owner.principal == "api:openai"
      assert owner.expires_at > System.system_time(:millisecond)

      expired = %{owner | expires_at: System.system_time(:millisecond) - 1}
      :ok = LemonCore.Store.put(:openai_compat_run_owners, run_id, expired)

      response =
        :get |> conn("/v1/runs/#{run_id}") |> openai_auth() |> Router.call([]) |> json_response()

      assert response.status == 404

      send(LemonCore.Store, :sweep_expired)
      _ = LemonCore.Store.list(:openai_compat_run_owners)
      assert LemonCore.Store.get(:openai_compat_run_owners, run_id) == nil
    end
  end

  describe "credential-derived scopes" do
    test "connect on a non-operator API credential cannot claim admin" do
      for token <- [@openai_token, @acp_token] do
        assert {:error, _} =
                 Authorize.from_params(
                   %{
                     "role" => "operator",
                     "auth" => %{"token" => token},
                     "scopes" => ["operator.admin"]
                   },
                   local?: true
                 )
      end
    end

    test "requested scopes never exceed what the credential grants" do
      assert {:ok, %{scopes: [:read]}} =
               Authorize.from_params(
                 %{"auth" => %{"token" => @operator_token}, "scopes" => ["operator.read"]},
                 local?: false
               )
    end

    test "the stale catalog and implicit-local helpers are gone" do
      Code.ensure_loaded!(Authorize)
      refute function_exported?(Authorize, :required_scopes, 1)
      refute function_exported?(Authorize, :node_context, 1)
      refute function_exported?(Authorize, :from_params, 1)
      assert Authorize.node_only_method?("node.shell.event")
    end
  end

  defp chat(:completions, extra) do
    body =
      Map.merge(
        %{"model" => "zai:glm-5-turbo", "messages" => [%{"role" => "user", "content" => "hi"}]},
        extra
      )

    :post
    |> json_conn("/v1/chat/completions", body)
    |> openai_auth()
    |> Router.call([])
    |> json_response()
  end

  defp chat(:responses, extra) do
    :post
    |> json_conn("/v1/responses", Map.merge(%{"model" => "zai:glm-5-turbo"}, extra))
    |> openai_auth()
    |> Router.call([])
    |> json_response()
  end

  defp new_session_request(cwd) do
    %{
      "jsonrpc" => "2.0",
      "id" => "new",
      "method" => "session/new",
      "params" => %{"cwd" => cwd, "mcpServers" => []}
    }
  end

  defp acp_session!(cwd) do
    created = acp(new_session_request(cwd))
    assert created.status == 200
    assert %{"result" => %{"sessionId" => session_id}} = created.body
    on_exit(fn -> delete_acp_session(session_id) end)
    session_id
  end

  defp get_acp_session(session_id) do
    {:ok, session} = LemonCore.SessionMetadataStore.fetch_acp_by_id(session_id)
    session
  end

  defp delete_acp_session(session_id) do
    case LemonCore.SessionMetadataStore.fetch_acp_by_id(session_id) do
      {:ok, %{session_key: session_key}} -> LemonCore.SessionMetadataStore.delete(session_key)
      _ -> :ok
    end
  end

  defp acp(body) do
    :post
    |> json_conn("/acp", body)
    |> put_req_header("authorization", "Bearer " <> @acp_token)
    |> Router.call([])
    |> json_response()
  end

  defp openai_auth(conn), do: put_req_header(conn, "authorization", "Bearer " <> @openai_token)

  defp json_conn(method, path, body) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
  end

  defp conn(method, path, body \\ nil),
    do: %{Plug.Test.conn(method, path, body) | host: "localhost"}

  defp json_response(conn), do: %{status: conn.status, body: Jason.decode!(conn.resp_body)}

  defp real(path) do
    {:ok, real} = LemonCore.TrustedRoot.realpath(path)
    real
  end
end

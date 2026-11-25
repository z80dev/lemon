defmodule LemonControlPlane.Methods.AgentSessionKeyTest do
  # Reads the registered run orchestrator and swaps the profile config path.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Agent
  alias LemonRouter.RunOrchestrator

  defmodule RouterStub do
    def submit_with_receipt(request) do
      send(self(), {:submitted, request})

      {:ok,
       %{
         run_id: request.run_id,
         session_key: request.session_key,
         state: :accepted,
         effective_mode: :new_run,
         target_run_id: request.run_id
       }}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "agent-method-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    config = Path.join(root, "config.toml")
    File.write!(config, "[profiles.workspace]\nname = \"Workspace\"\n")
    previous = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      (previous || [])
      |> Keyword.put(:global_config, config)
      |> Keyword.put(:home_state_dir, root)
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)

      File.rm_rf!(root)
    end)

    %{root: root, ctx: %{router_mod: RouterStub}}
  end

  # #646: a malformed session key is a definite 4xx-style refusal at the method
  # boundary; nothing reaches admission and the orchestrator keeps running.
  test "an empty or malformed session key is refused before any admission" do
    orchestrator = Process.whereis(RunOrchestrator)
    assert is_pid(orchestrator)

    for key <- ["", "   ", "agent:default:main\n", 123, String.duplicate("k", 1025)] do
      run_id = "run_bad_session_#{System.unique_integer([:positive])}"

      assert {:error, {:invalid_params, message}} =
               Agent.handle(%{"prompt" => "hello", "sessionKey" => key, "runId" => run_id}, %{})

      assert message =~ "sessionKey must be a nonblank string"
      assert LemonCore.Store.get(RunOrchestrator.admission_table(), run_id) == nil
    end

    assert Process.whereis(RunOrchestrator) == orchestrator
    assert Process.alive?(orchestrator)
  end

  # #620: one spelling, the schema's.
  test "sessionKey, agentId, queueMode and runId reach the router as given", %{ctx: ctx} do
    params = %{
      "prompt" => "hello",
      "agentId" => "builder",
      "sessionKey" => "agent:builder:main:sub:agent-method",
      "queueMode" => "steer_backlog",
      "runId" => "run_agent_method_fixed"
    }

    assert {:ok, %{"runId" => "run_agent_method_fixed", "state" => "accepted"} = result} =
             Agent.handle(params, ctx)

    assert result["sessionKey"] == "agent:builder:main:sub:agent-method"
    assert_received {:submitted, request}
    assert request.session_key == "agent:builder:main:sub:agent-method"
    assert request.agent_id == "builder"
    assert request.queue_mode == :steer_backlog
    assert request.run_id == "run_agent_method_fixed"
  end

  test "renamed snake_case fields and unknown queue modes are rejected, never ignored",
       %{ctx: ctx} do
    for {field, value} <- [
          {"session_key", "agent:builder:main"},
          {"agent_id", "builder"},
          {"queue_mode", "steer"}
        ] do
      assert {:error, {:invalid_params, message, %{fields: [^field]}}} =
               Agent.handle(%{"prompt" => "hello", field => value}, ctx)

      assert message =~ "Renamed agent parameters"
    end

    assert {:error, {:invalid_params, _}} =
             Agent.handle(%{"prompt" => "hello", "queueMode" => "sideways"}, ctx)

    refute_received {:submitted, _}
  end

  test "a profile agentId runs in its workspace and cannot override it", %{root: root, ctx: ctx} do
    assert {:ok, profile} = LemonCore.ProfileStore.get("workspace")

    assert {:error, {:invalid_request, "cwd cannot override a profile workspace", nil}} =
             Agent.handle(%{"prompt" => "hello", "agentId" => "workspace", "cwd" => root}, ctx)

    refute_received {:submitted, _}

    assert {:ok, %{"sessionKey" => session_key}} =
             Agent.handle(%{"prompt" => "hello", "agentId" => "workspace"}, ctx)

    assert_received {:submitted, request}
    assert session_key == profile["canonicalSessionKey"]
    assert request.agent_id == "workspace"
    assert request.cwd == profile["paths"]["workspace"]
    assert request.meta.profile_id == "workspace"
  end

  test "a plain agent's cwd must be an absolute existing directory", %{root: root, ctx: ctx} do
    assert {:error, {:invalid_request, _, nil}} =
             Agent.handle(%{"prompt" => "hello", "cwd" => "relative"}, ctx)

    assert {:ok, _} = Agent.handle(%{"prompt" => "hello", "cwd" => root}, ctx)
    assert_received {:submitted, %{cwd: ^root, session_key: "agent:default:main"}}
  end
end

defmodule LemonControlPlane.Methods.SubagentsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    Registry,
    SubagentsCancel,
    SubagentsList,
    SubagentsSend,
    SubagentsTranscript
  }

  alias LemonControlPlane.Protocol.Schemas

  @key "agent:default:tui:local:dm:hub"

  defmodule Runtime do
    @key "agent:default:tui:local:dm:hub"

    def subagents_list(key) do
      send(self(), {:list, key})

      {:ok,
       [
         %{
           task_id: "t1",
           status: "running",
           depth: 0,
           name: "Researcher\n\u001b[31mred",
           agent: "scout",
           description: String.duplicate("long ", 400),
           model: "anthropic/claude-sonnet-4-5",
           activity: "reading lib/app.ex",
           created_at_ms: 1_000,
           started_at_ms: 1_500,
           context_percent: 12.5,
           usage: %{tokens: 1_200, cost_usd: 0.04, requests: 3, private: "x"},
           messaging: true,
           cancellable: true,
           prompt: "the full private assignment",
           session_file: "/Users/alice/.lemon/sessions/child.jsonl",
           cwd: "/Users/alice/project"
         },
         %{task_id: "t2", status: :parked, depth: 1, parent_task_id: "t1"},
         %{task_id: "../escape", status: "running"},
         %{task_id: "t3", status: "exploded"},
         "garbage"
       ]}
    end

    def subagent_transcript(@key, "t1"),
      do:
        {:ok,
         %{task_id: "t1", status: "running", text: "# Task t1\nStatus: running", truncated: false}}

    def subagent_transcript(@key, "bad"),
      do: {:ok, %{task_id: "other", status: "running", text: ""}}

    def subagent_transcript(_key, _id), do: {:error, :not_found}

    def subagent_send(@key, "t1", message) do
      send(self(), {:send, message})
      {:ok, :injected}
    end

    def subagent_send(@key, "idle", _message), do: {:ok, :woken}
    def subagent_send(@key, "unknown", _message), do: {:ok, :outcome_unknown}
    def subagent_send(@key, "crash", _message), do: raise("lost after delivery")
    def subagent_send(@key, "done", _message), do: {:error, :not_running}
    def subagent_send(@key, "gone", _message), do: {:error, :not_resumable}

    def subagent_send(_key, _id, _message),
      do: {:error, {:secret, "/Users/alice/.secrets/token.json"}}

    def subagent_cancel(@key, "t1"), do: :ok
    def subagent_cancel(@key, "done"), do: {:error, :not_running}
    def subagent_cancel(_key, _id), do: {:error, :not_found}
  end

  setup do
    previous = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, Runtime)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)
  end

  defp operator(scopes), do: %{auth: %{role: :operator, scopes: scopes}}

  test "registers the hub methods with schemas and distinct read/write scopes" do
    for {name, module, scopes} <- [
          {"subagents.list", SubagentsList, [:read]},
          {"subagents.transcript", SubagentsTranscript, [:read]},
          {"subagents.send", SubagentsSend, [:write]},
          {"subagents.cancel", SubagentsCancel, [:write]}
        ] do
      assert {:ok, ^module} = Registry.lookup(name)
      assert module.scopes() == scopes
      assert Schemas.get(name) != nil
    end
  end

  test "requires an authenticated operator with the method's scope" do
    params = %{"sessionKey" => @key, "taskId" => "t1", "message" => "hi"}

    assert {:error, _} =
             Registry.dispatch("subagents.list", params, %{auth: %{role: :node, scopes: [:node]}})

    assert {:error, _} = Registry.dispatch("subagents.send", params, operator([:read]))
    assert {:error, _} = Registry.dispatch("subagents.cancel", params, operator([:read]))
    refute_received {:send, _}

    assert {:ok, %{"total" => 2}} = Registry.dispatch("subagents.list", params, operator([:read]))

    assert {:ok, %{"accepted" => true}} =
             Registry.dispatch("subagents.send", params, operator([:write]))
  end

  test "projects a bounded roster without prompts, paths or malformed rows" do
    assert {:ok, %{"sessionKey" => @key, "agents" => [first, second], "total" => 2}} =
             SubagentsList.handle(%{"sessionKey" => @key}, %{})

    assert_received {:list, @key}

    assert first["taskId"] == "t1"
    assert first["status"] == "running"
    assert first["name"] == "Researcher [31mred"
    assert byte_size(first["description"]) <= 512
    assert first["model"] == "anthropic/claude-sonnet-4-5"
    assert first["activity"] == "reading lib/app.ex"
    assert first["usage"] == %{"tokens" => 1_200, "costUsd" => 0.04, "requests" => 3}
    assert first["contextPercent"] == 12.5
    assert first["messaging"] and first["cancellable"]

    assert second == %{
             "taskId" => "t2",
             "status" => "parked",
             "depth" => 1,
             "parentTaskId" => "t1",
             "messaging" => false,
             "cancellable" => false
           }

    encoded = Jason.encode!([first, second])
    refute encoded =~ "private"
    refute encoded =~ "/Users/alice"
    refute encoded =~ "escape"
  end

  test "transcripts are scoped: foreign or mismatched tasks are not found or refused" do
    assert {:ok, %{"taskId" => "t1", "status" => "running", "text" => text, "truncated" => false}} =
             SubagentsTranscript.handle(%{"sessionKey" => @key, "taskId" => "t1"}, %{})

    assert text =~ "Status: running"

    assert {:error, {:not_found, _, %{"code" => "SUBAGENT_NOT_FOUND"}}} =
             SubagentsTranscript.handle(%{"sessionKey" => @key, "taskId" => "foreign"}, %{})

    assert {:error, {:not_found, _, _}} =
             SubagentsTranscript.handle(%{"sessionKey" => "agent:x:main", "taskId" => "t1"}, %{})

    assert {:error, {:unavailable, _, _}} =
             SubagentsTranscript.handle(%{"sessionKey" => @key, "taskId" => "bad"}, %{})
  end

  test "send reports delivery honestly and never exposes runtime failure terms" do
    send_to = fn id, message ->
      SubagentsSend.handle(%{"sessionKey" => @key, "taskId" => id, "message" => message}, %{})
    end

    assert {:ok, %{"delivery" => "injected", "accepted" => true, "retrySafe" => true}} =
             send_to.("t1", "focus on the parser")

    assert_received {:send, "focus on the parser"}
    assert {:ok, %{"delivery" => "woken", "accepted" => true}} = send_to.("idle", "continue")

    for id <- ["unknown", "crash"] do
      assert {:ok, %{"delivery" => "outcome_unknown", "accepted" => false, "retrySafe" => false}} =
               send_to.(id, "maybe")
    end

    assert {:error, {:conflict, _, %{"code" => "SUBAGENT_NOT_ACTIVE"}}} = send_to.("done", "x")
    assert {:error, {:conflict, _, %{"code" => "SUBAGENT_NOT_RESUMABLE"}}} = send_to.("gone", "x")
    assert {:error, {:unavailable, message, _}} = send_to.("other", "x")
    refute message =~ "/Users"

    assert {:error, {:invalid_params, _, _}} = send_to.("t1", "   ")

    assert {:error, {:invalid_params, _, _}} =
             send_to.("t1", String.duplicate("a", 32 * 1024 + 1))

    refute_received {:send, _}
  end

  test "cancel is scoped and refuses finished children" do
    cancel = fn id -> SubagentsCancel.handle(%{"sessionKey" => @key, "taskId" => id}, %{}) end
    assert {:ok, %{"taskId" => "t1", "cancelled" => true}} = cancel.("t1")
    assert {:error, {:conflict, _, %{"code" => "SUBAGENT_NOT_ACTIVE"}}} = cancel.("done")
    assert {:error, {:not_found, _, _}} = cancel.("foreign")

    assert {:error, {:invalid_params, _, _}} =
             SubagentsCancel.handle(%{"sessionKey" => @key}, %{})
  end

  test "an unregistered runtime is unavailable, not an empty roster" do
    Application.delete_env(:lemon_core, :agent_runtime_provider)

    assert {:error, {:unavailable, _, _}} = SubagentsList.handle(%{"sessionKey" => @key}, %{})

    assert {:error, {:unavailable, _, _}} =
             SubagentsSend.handle(
               %{"sessionKey" => @key, "taskId" => "t1", "message" => "x"},
               %{}
             )
  end
end

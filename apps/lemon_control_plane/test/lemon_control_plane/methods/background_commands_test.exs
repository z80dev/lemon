defmodule LemonControlPlane.Methods.BackgroundCommandsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    BackgroundCancel,
    BackgroundList,
    BackgroundResult,
    BackgroundStart,
    BackgroundStatus,
    Registry,
    SessionBtw
  }

  alias LemonControlPlane.Protocol.Schemas

  defmodule FakeRuntime do
    def background_start("run checks", opts) do
      send(self(), {:background_start, opts})
      {:ok, %{id: "bg_123", status: :queued}}
    end

    def background_list(status: "running") do
      [%{id: "bg_123", status: :running, result_available: false}]
    end

    def background_status("bg_123") do
      {:ok, %{id: "bg_123", status: :running, result_available: false}}
    end

    def background_result("bg_123"), do: {:error, :not_ready}
    def background_result("bg_done"), do: {:ok, "checks passed"}
    def background_cancel("bg_123"), do: :ok

    def side_query("telegram:42", "what is running?", opts) do
      send(self(), {:side_query, opts})
      {:ok, "One background check is running."}
    end
  end

  setup do
    previous = Application.get_env(:lemon_control_plane, :agent_runtime_provider)
    Application.put_env(:lemon_control_plane, :agent_runtime_provider, FakeRuntime)

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_control_plane, :agent_runtime_provider, previous)
      else
        Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
      end
    end)
  end

  test "registers every background lifecycle and side-query method with schemas and scopes" do
    expected = [
      {"background.start", BackgroundStart, [:write]},
      {"background.list", BackgroundList, [:read]},
      {"background.status", BackgroundStatus, [:read]},
      {"background.result", BackgroundResult, [:read]},
      {"background.cancel", BackgroundCancel, [:write]},
      {"session.btw", SessionBtw, [:write]}
    ]

    for {name, module, scopes} <- expected do
      assert {:ok, ^module} = Registry.lookup(name)
      assert module.scopes() == scopes
      assert Schemas.get(name) != nil
    end
  end

  test "starts and lists durable background commands through the runtime boundary" do
    params = %{
      "prompt" => "run checks",
      "sessionKey" => "telegram:42",
      "cwd" => "/tmp/project",
      "model" => "test-model",
      "thinkingLevel" => "high",
      "timeoutMs" => 10_000
    }

    assert :ok = Schemas.validate("background.start", params)

    assert {:ok, %{"id" => "bg_123", "status" => "queued"}} =
             BackgroundStart.handle(params, %{})

    assert_received {:background_start, opts}
    assert opts[:session_key] == "telegram:42"
    assert opts[:cwd] == "/tmp/project"
    assert opts[:model] == "test-model"
    assert opts[:thinking_level] == "high"
    assert opts[:timeout_ms] == 10_000

    assert {:ok, %{"runs" => [run], "total" => 1}} =
             BackgroundList.handle(%{"status" => "running"}, %{})

    assert run["id"] == "bg_123"
    assert run["status"] == "running"
  end

  test "reports status, readiness, results, and cancellation" do
    assert {:ok, %{"status" => "running", "result_available" => false}} =
             BackgroundStatus.handle(%{"id" => "bg_123"}, %{})

    assert {:ok, %{"id" => "bg_123", "ready" => false}} =
             BackgroundResult.handle(%{"id" => "bg_123"}, %{})

    assert {:ok, %{"id" => "bg_done", "ready" => true, "answer" => "checks passed"}} =
             BackgroundResult.handle(%{"id" => "bg_done"}, %{})

    assert {:ok, %{"id" => "bg_123", "cancelled" => true}} =
             BackgroundCancel.handle(%{"id" => "bg_123"}, %{})
  end

  test "accepts either a session id or durable session key for a no-tools side query" do
    params = %{
      "sessionKey" => "telegram:42",
      "question" => "what is running?",
      "timeoutMs" => 5_000
    }

    assert :ok = Schemas.validate("session.btw", params)
    assert {:error, message} = Schemas.validate("session.btw", %{"question" => "missing"})
    assert message =~ "sessionId or sessionKey"

    assert {:ok,
            %{
              "answer" => "One background check is running.",
              "parentHistoryChanged" => false,
              "tools" => []
            }} = SessionBtw.handle(params, %{})

    assert_received {:side_query, opts}
    assert opts[:session_key] == "telegram:42"
    assert opts[:timeout_ms] == 5_000
  end
end

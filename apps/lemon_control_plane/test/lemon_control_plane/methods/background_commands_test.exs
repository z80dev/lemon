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

  alias LemonControlPlane.Protocol.{Errors, Schemas}

  defmodule BackgroundCommandsFakeRuntime do
    def background_start("run checks", opts) do
      send(self(), {:background_start, opts})
      {:ok, %{id: "bg_123", status: :queued}}
    end

    def background_start("leak-start", _opts), do: private_failure()

    def background_list(status: "running") do
      [%{id: "bg_123", status: :running, result_available: false}]
    end

    def background_list(status: "leak-error"), do: private_failure()

    def background_list(status: "persisted-error") do
      [
        %{
          id: "bg_private",
          status: :error,
          result_available: false,
          error: private_text(),
          provider: %{api_key: "sk-private-provider"}
        }
      ]
    end

    def background_status("bg_123") do
      {:ok, %{id: "bg_123", status: :running, result_available: false}}
    end

    def background_status("bg_private") do
      {:ok,
       %{
         id: "bg_private",
         status: :error,
         result_available: false,
         error: private_text(),
         provider: %{api_key: "sk-private-provider"}
       }}
    end

    def background_status("bg_leak"), do: private_failure()

    def background_result("bg_123"), do: {:error, :not_ready}
    def background_result("bg_done"), do: {:ok, "checks passed"}
    def background_result("bg_leak"), do: private_failure()
    def background_cancel("bg_123"), do: :ok
    def background_cancel("bg_leak"), do: private_failure()

    def side_query("telegram:42", "what is running?", opts) do
      send(self(), {:side_query, opts})
      {:ok, "One background check is running."}
    end

    def side_query("telegram:42", "leak", _opts), do: private_failure()

    defp private_failure do
      {:error,
       {:provider_failed, private_text(),
        %{api_key: "sk-private-provider", provider: "private-provider"}}}
    end

    defp private_text, do: "/Users/alice/.secrets/private-provider.json"
  end

  setup do
    previous = Application.get_env(:lemon_control_plane, :agent_runtime_provider)

    Application.put_env(
      :lemon_control_plane,
      :agent_runtime_provider,
      BackgroundCommandsFakeRuntime
    )

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

  test "redacts internal provider failures for every background and side-query RPC" do
    cases = [
      {BackgroundStart, %{"prompt" => "leak-start"}, "BACKGROUND_START_FAILED"},
      {BackgroundList, %{"status" => "leak-error"}, "BACKGROUND_LIST_FAILED"},
      {BackgroundStatus, %{"id" => "bg_leak"}, "BACKGROUND_STATUS_FAILED"},
      {BackgroundResult, %{"id" => "bg_leak"}, "BACKGROUND_RESULT_FAILED"},
      {BackgroundCancel, %{"id" => "bg_leak"}, "BACKGROUND_CANCEL_FAILED"},
      {SessionBtw, %{"sessionKey" => "telegram:42", "question" => "leak"}, "SIDE_QUERY_FAILED"}
    ]

    for {module, params, public_code} <- cases do
      assert {:error, {rpc_code, message, %{"code" => ^public_code}} = error} =
               module.handle(params, %{})

      assert rpc_code == :internal_error
      assert is_binary(message)
      assert byte_size(message) <= 64

      serialized = inspect(error)
      refute serialized =~ "/Users/alice"
      refute serialized =~ "sk-private-provider"
      refute serialized =~ "private-provider"

      json = error |> Errors.to_payload() |> Jason.encode!()
      refute json =~ "/Users/alice"
      refute json =~ "sk-private-provider"
      refute json =~ "private-provider"
    end
  end

  test "allowlists lifecycle summaries and replaces persisted errors with stable codes" do
    assert {:ok, %{"runs" => [run], "total" => 1}} =
             BackgroundList.handle(%{"status" => "persisted-error"}, %{})

    assert run == %{
             "id" => "bg_private",
             "status" => "error",
             "result_available" => false,
             "errorCode" => "BACKGROUND_FAILED"
           }

    assert {:ok, status} = BackgroundStatus.handle(%{"id" => "bg_private"}, %{})
    assert status == run

    serialized = inspect([run, status])
    refute serialized =~ "/Users/alice"
    refute serialized =~ "sk-private-provider"
    refute serialized =~ "private-provider"
    refute serialized =~ "provider"
  end
end

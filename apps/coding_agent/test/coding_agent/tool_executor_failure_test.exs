defmodule CodingAgent.ToolExecutorFailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodingAgent.{ToolExecutor, ToolPolicy}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @secret "approval-service-sensitive-payload"

  test "exceptions, exits, and throws fail closed without exposing their payloads" do
    failures = [
      fn _request -> raise @secret end,
      fn _request -> exit({:service_down, @secret}) end,
      fn _request -> throw({:service_failure, @secret}) end
    ]

    log =
      capture_log(fn ->
        for failure <- failures do
          result = assert_not_executed(failure)
          assert result.details.approval_error == :approval_unavailable
          refute inspect(result) =~ @secret
        end
      end)

    refute log =~ @secret
  end

  test "a call to a dead approval process fails closed" do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    result = assert_not_executed(fn _request -> GenServer.call(pid, :approve) end)

    assert result.details.approval_error == :approval_unavailable
  end

  test "malformed replies and unsupported approval scopes do not authorize execution" do
    replies = [
      :ok,
      nil,
      {:ok, :approved},
      {:ok, :approved, :auto},
      {:ok, :approved, @secret},
      {:ok, %{token: @secret}}
    ]

    log =
      capture_log(fn ->
        for reply <- replies do
          result = assert_not_executed(fn _request -> reply end)
          assert result.details.approval_error == :invalid_approval_response
          refute inspect(result) =~ @secret
        end
      end)

    refute log =~ @secret
  end

  test "returned service errors expose only a bounded error category" do
    log =
      capture_log(fn ->
        result = assert_not_executed(fn _request -> {:error, %{token: @secret}} end)
        assert result.details.approval_error == :approval_request_failed
        refute inspect(result) =~ @secret
      end)

    refute log =~ @secret

    result = assert_not_executed(fn _request -> {:error, :service_unavailable} end)
    assert result.details.approval_error == :service_unavailable
  end

  test "all stored-policy and explicit-resolution scopes execute exactly once" do
    scopes = [
      :once,
      :session,
      :agent,
      :node,
      :global,
      :approve_once,
      :approve_session,
      :approve_agent,
      :approve_global
    ]

    for scope <- scopes do
      marker = make_ref()
      caller = self()
      expected = %AgentToolResult{details: %{scope: scope}}

      result =
        ToolExecutor.execute_with_approval(
          "write",
          %{},
          fn ->
            send(caller, marker)
            expected
          end,
          %{approval_request_fun: fn _request -> {:ok, :approved, scope} end}
        )

      assert result == expected
      assert_received ^marker
      refute_received ^marker
    end
  end

  test "an approved tool's exception is not caught as an approval failure" do
    assert_raise RuntimeError, "tool execution failed", fn ->
      ToolExecutor.execute_with_approval(
        "write",
        %{},
        fn -> raise "tool execution failed" end,
        %{approval_request_fun: fn _request -> {:ok, :approved, :once} end}
      )
    end
  end

  test "the wrapped tool also fails closed" do
    marker = make_ref()
    caller = self()

    tool = %AgentTool{
      name: "write",
      execute: fn _id, _params, _signal, _on_update ->
        send(caller, marker)
        %AgentToolResult{}
      end
    }

    wrapped =
      ToolExecutor.wrap_with_approval(
        tool,
        ToolPolicy.custom(require_approval: ["write"]),
        %{approval_request_fun: fn _request -> raise @secret end}
      )

    result = wrapped.execute.("call-1", %{}, nil, nil)

    assert result.details.approval_error == :approval_unavailable
    refute_received ^marker
  end

  test "denials and timeouts never execute, including the default infinite timeout" do
    denied = assert_not_executed(fn _request -> {:ok, :denied} end)
    assert denied.details.reason == :approval_denied

    for timeout <- [:infinity, 1000] do
      result = assert_not_executed(fn _request -> {:error, :timeout} end, timeout_ms: timeout)
      assert result.details.reason == :approval_timeout
      assert result.details.timeout_ms == timeout
    end
  end

  defp assert_not_executed(request_fun, opts \\ []) do
    marker = make_ref()
    caller = self()

    result =
      ToolExecutor.execute_with_approval(
        "write",
        %{},
        fn ->
          send(caller, marker)
          %AgentToolResult{}
        end,
        Map.merge(Map.new(opts), %{approval_request_fun: request_fun})
      )

    assert %AgentToolResult{} = result
    refute_received ^marker
    result
  end
end

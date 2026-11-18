defmodule LemonControlPlane.Methods.SystemMethodsTest do
  use ExUnit.Case, async: true

  @operator_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}

  alias LemonControlPlane.Methods.LogsTail

  defmodule LogRingStub do
    def get_logs(limit, level) do
      [
        %{
          "level" => "info",
          "message" => "ready api_key=test123 authorization Bearer abc.def",
          "metadata" => %{"token" => "nested-secret", "safe" => "ok"}
        },
        %{"level" => "error", "message" => "failed"},
        %{"level" => "info", "message" => "done"}
      ]
      |> Enum.filter(fn log -> is_nil(level) or log["level"] == level end)
      |> Enum.take(limit)
    end
  end

  describe "LogsTail.handle/2" do
    setup do
      old_log_ring = Application.get_env(:lemon_control_plane, :log_ring_module)

      Application.put_env(:lemon_control_plane, :log_ring_module, LogRingStub)

      on_exit(fn ->
        if old_log_ring do
          Application.put_env(:lemon_control_plane, :log_ring_module, old_log_ring)
        else
          Application.delete_env(:lemon_control_plane, :log_ring_module)
        end
      end)

      :ok
    end

    test "returns filtered logs with summary and cleanup flags" do
      {:ok, result} = LogsTail.handle(%{"lines" => "10", "filter" => "INFO"}, @operator_ctx)

      assert result["total"] == 2
      assert result["filters"]["limit"] == 10
      assert result["filters"]["level"] == "info"
      assert result["summary"]["count"] == 2
      assert result["summary"]["levelCounts"]["info"] == 2

      assert result["logs"] |> hd() |> get_in(["metadata", "token"]) == "[REDACTED]"

      assert result["logs"] |> hd() |> get_in(["metadata", "safe"]) == "ok"
      refute inspect(result) =~ "test123"
      refute inspect(result) =~ "nested-secret"
      refute inspect(result) =~ "abc.def"
      assert result["summary"]["cleanup"]["includesLogMessages"] == true
      assert result["summary"]["cleanup"]["redactsSensitiveLogValues"] == true
      assert result["summary"]["cleanup"]["includesRawProcessState"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns empty summarized response when log ring is unavailable" do
      Application.put_env(
        :lemon_control_plane,
        :log_ring_module,
        :"Elixir.LemonControlPlane.MissingLogRingForTest"
      )

      {:ok, result} = LogsTail.handle(%{"limit" => -1}, @operator_ctx)

      assert result["logs"] == []
      assert result["total"] == 0
      assert result["filters"]["limit"] == 100
      assert result["summary"]["count"] == 0
      assert result["summary"]["cleanup"]["includesLogMessages"] == true
    end
  end
end

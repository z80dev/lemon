defmodule LemonCore.ProviderManagementTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias LemonCore.ProviderManagement

  # Explicit offline mock: never resolves credentials or contacts a provider.
  defmodule OfflineServiceMock do
    def list(opts), do: result(opts)

    def set_api_key(provider, value, opts) do
      send(self(), {:mock_mutation, provider, value, opts[:target]})
      result(opts)
    end

    def disconnect(provider, opts) do
      send(self(), {:mock_disconnect, provider, opts[:target]})
      result(opts)
    end

    def set_default(provider, model, opts) do
      send(self(), {:mock_default, provider, model, opts[:target]})
      result(opts)
    end

    defp result(opts) do
      target = Map.new(opts[:target], fn {key, value} -> {Atom.to_string(key), value} end)

      {:ok,
       %{
         "target" => target,
         "default" => %{"providerId" => nil, "modelId" => nil},
         "providers" => []
       }}
    end
  end

  defmodule RaisingOfflineMock do
    def set_api_key(_, value, _), do: raise(value)
  end

  test "registered implementations serve both controller and named destination calls" do
    previous = ProviderManagement.service()

    on_exit(fn ->
      if previous,
        do: ProviderManagement.register(previous),
        else: Application.delete_env(:lemon_core, :provider_management_service)
    end)

    Application.delete_env(:lemon_core, :provider_management_service)
    assert {:error, :unavailable} = ProviderManagement.execute("list", %{}, node_id: "mock-node")
    assert :ok = ProviderManagement.register(OfflineServiceMock)
    assert {:ok, controller} = ProviderManagement.execute("list", %{})
    assert controller["target"]["nodeId"] == nil
    assert {:ok, worker} = ProviderManagement.execute("list", %{}, node_id: "mock-node")
    assert worker["target"]["nodeId"] == "mock-node"
  end

  test "destination identity is exact and mismatches cannot mutate" do
    opts = [node_id: "node-a", service: OfflineServiceMock]
    assert {:ok, a} = ProviderManagement.execute("list", %{}, opts)
    assert a["target"]["nodeId"] == "node-a"

    assert {:ok, b} =
             ProviderManagement.execute("list", %{},
               node_id: "node-b",
               service: OfflineServiceMock
             )

    refute a["target"]["id"] == b["target"]["id"]

    args = %{
      "targetId" => b["target"]["id"],
      "providerId" => "openai",
      "value" => "OFFLINE_MOCK_SECRET"
    }

    assert {:error, :target_mismatch} = ProviderManagement.execute("api_key.set", args, opts)
    refute_received {:mock_mutation, _, _, _}

    assert {:ok, ^a} =
             ProviderManagement.execute(
               "api_key.set",
               Map.put(args, "targetId", a["target"]["id"]),
               opts
             )

    assert_received {:mock_mutation, "openai", "OFFLINE_MOCK_SECRET", %{nodeId: "node-a"}}
  end

  test "unknown fields, oversized values, and malformed strings fail closed" do
    args = %{"targetId" => "node:a", "providerId" => "openai", "value" => "OFFLINE_MOCK_SECRET"}

    assert {:error, :invalid_request} =
             ProviderManagement.validate(
               "api_key.set",
               Map.put(args, "config_path", "/tmp/other")
             )

    assert {:error, :invalid_request} =
             ProviderManagement.validate(
               "api_key.set",
               Map.put(args, "value", String.duplicate("x", 16_385))
             )

    assert {:error, :invalid_request} =
             ProviderManagement.validate("api_key.set", Map.put(args, "value", <<0>>))

    assert {:error, :invalid_request} = ProviderManagement.validate("list", %{"nodeId" => "a"})

    assert {:error, :invalid_request} =
             ProviderManagement.validate(
               "api_key.set",
               Map.put(args, "targetId", "node:invalid/id")
             )

    assert {:error, :invalid_request} =
             ProviderManagement.validate("list", %{"nodeId" => String.duplicate("a", 252)}, true)

    assert {:error, :invalid_target} = ProviderManagement.target("invalid/node")
  end

  test "node transport crash diagnostics redact credential-bearing requests" do
    secret = "OFFLINE_MOCK_SECRET_CRASH_DIAGNOSTIC"

    status =
      LemonCore.NodeRegistry.format_status(%{
        state: %{private: secret},
        message: {:invoke, "node.providers.management.api_key.set", %{"value" => secret}},
        reason: {:unexpected, secret},
        log: [secret]
      })

    refute inspect(status) =~ secret
    assert status.message == :redacted
    assert status.reason == :redacted
    assert status.log == []
  end

  test "exception messages never expose credential values in errors or logs" do
    secret = "OFFLINE_MOCK_SECRET_DO_NOT_LOG"
    args = %{"targetId" => "node:redaction", "providerId" => "openai", "value" => secret}

    logs =
      capture_log(fn ->
        assert {:error, :unavailable} =
                 ProviderManagement.execute("api_key.set", args,
                   node_id: "redaction",
                   service: RaisingOfflineMock
                 )
      end)

    refute logs =~ secret
  end
end

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

    for operation <- [
          :device_start,
          :device_poll,
          :device_challenge,
          :device_cancel,
          :device_complete
        ] do
      def unquote(operation)(params, opts) do
        send(self(), {:mock_device, unquote(operation), params, opts})

        {:ok,
         %{
           loginId: params["loginId"],
           targetId: opts[:target].id,
           providerId: params["providerId"],
           status: "pending",
           verificationUrl: "https://auth.openai.com/codex/device",
           userCode: "MOCK-CODE",
           expiresAtMs: 1_900_000_000_000,
           pollIntervalMs: 5_000,
           challengeNonce: String.duplicate("n", 43),
           accessToken: "OFFLINE_DEVICE_TOKEN_NEVER_EXPOSE",
           refreshToken: "OFFLINE_DEVICE_REFRESH_NEVER_EXPOSE",
           ownerId: params["ownerId"],
           sessionId: params["sessionId"]
         }}
      end
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
    def device_start(_, _), do: raise("OFFLINE_DEVICE_TOKEN_EXCEPTION")
  end

  defmodule OfflineBindingMock do
    def device_complete(%{"sessionId" => "foreign-session"}, _),
      do: {:error, :provider_binding_rejected}

    def device_complete(_, _), do: {:error, :forbidden}
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

  test "device calls preserve exact binding and destination options without token echo" do
    params = device_params()

    opts = [
      node_id: "device-node",
      service: OfflineServiceMock,
      cwd: "/mock/cwd",
      config_path: "/mock/config.toml"
    ]

    for {operation, function} <- [
          {"device.start", :device_start},
          {"device.poll", :device_poll},
          {"device.cancel", :device_cancel}
        ] do
      assert {:ok, result} = ProviderManagement.execute(operation, params, opts)
      assert_received {:mock_device, ^function, ^params, destination_opts}
      assert destination_opts[:cwd] == "/mock/cwd"
      assert destination_opts[:config_path] == "/mock/config.toml"
      assert destination_opts[:target].id == params["targetId"]
      assert destination_opts[:target].nodeId == "device-node"

      assert Enum.sort(Map.keys(result)) ==
               Enum.sort(
                 ~w(loginId targetId providerId status verificationUrl userCode expiresAtMs pollIntervalMs)
               )

      assert result["loginId"] == params["loginId"]
      assert result["status"] == "pending"
      refute inspect(result) =~ "OFFLINE_DEVICE"
      refute Map.has_key?(result, "ownerId")
      refute Map.has_key?(result, "sessionId")

      assert {:error, :target_mismatch} =
               ProviderManagement.execute(
                 operation,
                 %{params | "targetId" => "node:foreign"},
                 opts
               )

      refute_received {:mock_device, _, _, _}
    end
  end

  test "every device binding field is required, bounded and rejects nonidentity strings" do
    params = device_params()

    for operation <- ~w(device.start device.poll device.challenge device.cancel) do
      assert :ok = ProviderManagement.validate(operation, params)

      assert :ok =
               ProviderManagement.validate(
                 operation,
                 Map.put(params, "nodeId", "device-node"),
                 true
               )

      for field <- ~w(targetId providerId loginId ownerId sessionId) do
        assert {:error, :invalid_request} =
                 ProviderManagement.validate(operation, Map.delete(params, field))

        for value <- ["", "invalid/id", "two words", <<0>>, String.duplicate("x", 257), nil] do
          assert {:error, :invalid_request} =
                   ProviderManagement.validate(operation, Map.put(params, field, value))
        end
      end

      for field <-
            ~w(value accessToken refreshToken deviceCode verifier clientNonce config_path cwd) do
        assert {:error, :invalid_request} =
                 ProviderManagement.validate(operation, Map.put(params, field, "mock-private"))
      end

      assert {:error, :invalid_request} =
               ProviderManagement.validate(operation, %{params | "providerId" => "openai"})

      assert {:error, :invalid_request} =
               ProviderManagement.validate(operation, %{params | "providerId" => "openai-codex"})
    end
  end

  test "device projections accept only exact public status, target and verification URL" do
    params = device_params()
    result = Map.take(params, ~w(loginId targetId providerId))

    for status <- ~w(starting completed denied expired cancelled lost failed) do
      assert {:ok, projection} =
               ProviderManagement.device_result(Map.put(result, "status", status), params)

      assert projection["verificationUrl"] == nil
      assert projection["userCode"] == nil
      assert projection["expiresAtMs"] == nil
      assert projection["pollIntervalMs"] == nil
    end

    assert {:error, :unavailable} =
             ProviderManagement.device_result(Map.put(result, "status", "pending"), params)

    result =
      Map.merge(result, %{
        "status" => "pending",
        "verificationUrl" => "https://auth.openai.com/codex/device",
        "userCode" => "MOCK-CODE",
        "expiresAtMs" => 1_900_000_000_000,
        "pollIntervalMs" => 5_000
      })

    assert {:ok, ^result} = ProviderManagement.device_result(result, params)

    for {field, value} <- [
          {"loginId", "foreign"},
          {"targetId", "node:foreign"},
          {"providerId", "openai"},
          {"providerId", "openai-codex"},
          {"status", "success"},
          {"verificationUrl", "https://auth.openai.com/codex/device?token=MOCK"},
          {"verificationUrl", "https://foreign.invalid/"},
          {"userCode", String.duplicate("x", 65)},
          {"userCode", "unsafe:code"},
          {"expiresAtMs", -1},
          {"pollIntervalMs", 999},
          {"pollIntervalMs", 60_001},
          {"status", "completed"}
        ] do
      assert {:error, :unavailable} =
               ProviderManagement.device_result(Map.put(result, field, value), params)
    end
  end

  test "internal challenge preserves only its nonce and exact public binding" do
    params = device_params()
    authority = {self(), 7}

    assert {:ok, challenge} =
             ProviderManagement.execute("device.challenge", params,
               node_id: "device-node",
               service: OfflineServiceMock,
               authority: authority
             )

    assert_received {:mock_device, :device_challenge, ^params, opts}
    assert opts[:authority] == authority
    assert challenge["challengeNonce"] == String.duplicate("n", 43)
    assert {:ok, public} = ProviderManagement.device_result(challenge, params)
    refute Map.has_key?(public, "challengeNonce")

    assert {:ok, pending} =
             ProviderManagement.device_challenge_result(
               Map.put(public, "challengeNonce", nil),
               params
             )

    assert pending["challengeNonce"] == nil

    for invalid <- [
          Map.delete(challenge, "challengeNonce"),
          Map.put(challenge, "challengeNonce", ""),
          Map.put(challenge, "challengeNonce", String.duplicate("x", 44)),
          Map.put(challenge, "challengeNonce", String.duplicate("/", 43))
        ] do
      assert {:error, :unavailable} = ProviderManagement.device_challenge_result(invalid, params)
    end
  end

  test "completion validates single-use identity/nonce and preserves local authority" do
    params =
      Map.merge(device_params(), %{
        "completionId" => "fixed-completion-id",
        "challengeNonce" => String.duplicate("n", 43),
        "commit" => true
      })

    authority = {self(), 7}
    assert :ok = ProviderManagement.validate("device.complete", params)

    assert {:ok, result} =
             ProviderManagement.execute("device.complete", params,
               node_id: "device-node",
               service: OfflineServiceMock,
               authority: authority
             )

    assert_received {:mock_device, :device_complete, ^params, opts}
    assert opts[:authority] == authority
    assert result["status"] == "pending"
    refute inspect(result) =~ "completionId"
    refute inspect(result) =~ "OFFLINE_DEVICE"
    refute Map.has_key?(result, "challengeNonce")

    assert :ok =
             ProviderManagement.validate("device.complete", %{
               params
               | "commit" => false,
                 "challengeNonce" => ""
             })

    assert {:error, :invalid_request} =
             ProviderManagement.validate(
               "device.complete",
               Map.put(params, "authorizationExpiresAtMs", 0)
             )

    for {field, bad} <- [
          {"completionId", nil},
          {"completionId", "bad/id"},
          {"challengeNonce", nil},
          {"challengeNonce", ""},
          {"challengeNonce", String.duplicate("/", 43)},
          {"challengeNonce", String.duplicate("n", 44)},
          {"commit", "true"}
        ] do
      assert {:error, :invalid_request} =
               ProviderManagement.validate("device.complete", Map.put(params, field, bad))
    end
  end

  test "completion preserves exact binding rejection separately from generic forbidden" do
    params =
      Map.merge(device_params(), %{
        "completionId" => "fixed-completion-id",
        "challengeNonce" => "",
        "commit" => false
      })

    opts = [node_id: "device-node", service: OfflineBindingMock]

    assert {:error, :provider_binding_rejected} =
             ProviderManagement.execute(
               "device.complete",
               Map.put(params, "sessionId", "foreign-session"),
               opts
             )

    assert {:error, :forbidden} = ProviderManagement.execute("device.complete", params, opts)
  end

  test "device exceptions are classified without token-bearing errors or logs" do
    logs =
      capture_log(fn ->
        assert {:error, :unavailable} =
                 ProviderManagement.execute("device.start", device_params(),
                   node_id: "device-node",
                   service: RaisingOfflineMock
                 )
      end)

    refute logs =~ "OFFLINE_DEVICE_TOKEN_EXCEPTION"
  end

  defp device_params do
    %{
      "targetId" => "node:device-node",
      "providerId" => "openai_codex",
      "loginId" => "fixed-product-nonce",
      "ownerId" => "owner-hash",
      "sessionId" => "session-hash"
    }
  end
end

defmodule LemonControlPlane.Methods.OptionalParityMethodsTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{
    VoicewakeGet,
    VoicewakeSet,
    TtsStatus,
    TtsProviders,
    TtsEnable,
    TtsDisable,
    TtsSetProvider,
    UpdateRun,
    ConfigGet,
    ConfigSet,
    ConfigPatch,
    ConfigSchema,
    DevicePairRequest,
    WizardStart,
    WizardStep,
    WizardCancel,
    ConnectChallenge,
    UsageStatus,
    UsageCost
  }

  alias LemonControlPlane.{ConfigStore, TtsStore, VoicewakeStore}
  alias LemonCore.Store

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  describe "VoicewakeGet" do
    test "returns voicewake configuration" do
      {:ok, result} = VoicewakeGet.handle(%{}, @ctx)

      assert is_boolean(result["enabled"])
      assert is_binary(result["keyword"])
      assert is_boolean(result["configured"])
      assert is_map(result["summary"])
      assert result["summary"]["status"] in ["enabled", "disabled"]
      assert result["includesAudioSamples"] == false
      assert result["includesSecretValues"] == false
    end

    test "preserves explicit stored false and zero-like values" do
      previous = VoicewakeStore.get()

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:voicewake_config, :global)
          config -> VoicewakeStore.put(config)
        end
      end)

      :ok =
        VoicewakeStore.put(%{
          "enabled" => false,
          "keyword" => "lemon",
          "sensitivity" => 0.0,
          "backend" => "local",
          "updated_at_ms" => 456
        })

      {:ok, result} = VoicewakeGet.handle(%{}, @ctx)

      assert result["enabled"] == false
      assert result["keyword"] == "lemon"
      assert result["sensitivity"] == 0.0
      assert result["backend"] == "local"
      assert result["updatedAtMs"] == 456
      assert result["configured"] == true
      assert result["summary"]["status"] == "disabled"
    end

    test "has correct method name and scopes" do
      assert VoicewakeGet.name() == "voicewake.get"
      assert VoicewakeGet.scopes() == [:read]
    end
  end

  describe "VoicewakeSet" do
    test "requires enabled parameter" do
      {:error, error} = VoicewakeSet.handle(%{}, @ctx)
      assert error == {:invalid_request, "enabled is required"}
    end

    test "sets voicewake configuration" do
      {:ok, result} =
        VoicewakeSet.handle(
          %{"enabled" => true, "keyword" => "hey", "sensitivity" => 0.0, "backend" => "local"},
          @ctx
        )

      assert result["enabled"] == true
      assert result["keyword"] == "hey"
      assert result["sensitivity"] == 0.0
      assert result["backend"] == "local"
      assert is_integer(result["updatedAtMs"])
      assert result["summary"]["enabled"] == true
      assert result["summary"]["backend"] == "local"
      assert result["summary"]["keywordConfigured"] == true
      assert result["summary"]["sensitivityConfigured"] == true
      assert result["summary"]["cleanup"]["includesAudio"] == false
      assert result["summary"]["cleanup"]["includesTranscript"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "has correct method name and scopes" do
      assert VoicewakeSet.name() == "voicewake.set"
      assert VoicewakeSet.scopes() == [:admin]
    end
  end

  describe "TtsStatus" do
    test "returns TTS status" do
      {:ok, result} = TtsStatus.handle(%{}, @ctx)

      assert is_boolean(result["enabled"])
      assert is_binary(result["provider"])
      assert is_boolean(result["configured"])
      assert is_boolean(result["knownProvider"])
      assert is_boolean(result["providerAvailable"])
      assert is_list(result["providers"])
      assert is_map(result["summary"])

      assert result["summary"]["status"] in [
               "disabled",
               "unknown_provider",
               "provider_unavailable",
               "ready"
             ]

      assert result["includesSecretValues"] == false
      assert result["includesRawKeyMaterial"] == false
      assert result["includesRawProviderErrors"] == false
    end

    test "preserves explicit stored false and zero-like values" do
      previous = TtsStore.get()

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:tts_config, :global)
          config -> TtsStore.put(config)
        end
      end)

      :ok =
        TtsStore.put(%{
          "enabled" => false,
          "provider" => "openai",
          "voice" => false,
          "rate" => 0.0,
          "updated_at_ms" => 123
        })

      {:ok, result} = TtsStatus.handle(%{}, @ctx)

      assert result["enabled"] == false
      assert result["provider"] == "openai"
      assert result["voice"] == false
      assert result["rate"] == 0.0
      assert result["updatedAtMs"] == 123
      assert result["configured"] == true
      assert result["summary"]["status"] == "disabled"
    end

    test "marks enabled unknown provider separately from provider availability" do
      previous = TtsStore.get()

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:tts_config, :global)
          config -> TtsStore.put(config)
        end
      end)

      :ok = TtsStore.put(%{enabled: true, provider: "missing-provider"})

      {:ok, result} = TtsStatus.handle(%{}, @ctx)

      assert result["enabled"] == true
      assert result["knownProvider"] == false
      assert result["providerAvailable"] == false
      assert result["summary"]["status"] == "unknown_provider"
    end

    test "has correct method name and scopes" do
      assert TtsStatus.name() == "tts.status"
      assert TtsStatus.scopes() == [:read]
    end
  end

  describe "TtsProviders" do
    test "returns list of providers" do
      {:ok, result} = TtsProviders.handle(%{}, @ctx)

      assert is_list(result["providers"])
      assert result["providers"] != []

      provider = hd(result["providers"])
      assert is_binary(provider["id"])
      assert is_binary(provider["name"])
      assert result["summary"]["providerCount"] == length(result["providers"])
      assert result["summary"]["availableCount"] >= 1
      assert "system" in result["summary"]["providerIds"]
      assert result["summary"]["voiceCount"] >= 0
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      assert result["summary"]["cleanup"]["includesRawProviderErrors"] == false
    end

    test "has correct method name and scopes" do
      assert TtsProviders.name() == "tts.providers"
      assert TtsProviders.scopes() == [:read]
    end
  end

  describe "TtsEnable" do
    test "enables TTS" do
      {:ok, result} = TtsEnable.handle(%{}, @ctx)

      assert result["enabled"] == true
      assert result["summary"]["action"] == "enable"
      assert result["summary"]["enabled"] == true
      assert result["summary"]["provider"] == "system"
      assert result["summary"]["cleanup"]["includesInputText"] == false
      assert result["summary"]["cleanup"]["includesAudio"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "enables TTS with specific provider" do
      {:ok, result} = TtsEnable.handle(%{"provider" => "openai"}, @ctx)

      assert result["enabled"] == true
      assert result["provider"] == "openai"
      assert result["summary"]["provider"] == "openai"
    end

    test "has correct method name and scopes" do
      assert TtsEnable.name() == "tts.enable"
      assert TtsEnable.scopes() == [:admin]
    end
  end

  describe "TtsDisable" do
    test "disables TTS" do
      {:ok, result} = TtsDisable.handle(%{}, @ctx)

      assert result["enabled"] == false
      assert result["summary"]["action"] == "disable"
      assert result["summary"]["enabled"] == false
      assert result["summary"]["cleanup"]["includesInputText"] == false
      assert result["summary"]["cleanup"]["includesAudio"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "summarizes provider from string-keyed config" do
      TtsStore.put(%{"enabled" => true, "provider" => "elevenlabs"})

      {:ok, result} = TtsDisable.handle(%{}, @ctx)

      assert result["summary"]["provider"] == "elevenlabs"
    end

    test "has correct method name and scopes" do
      assert TtsDisable.name() == "tts.disable"
      assert TtsDisable.scopes() == [:admin]
    end
  end

  describe "TtsSetProvider" do
    test "requires provider parameter" do
      {:error, error} = TtsSetProvider.handle(%{}, @ctx)
      assert error == {:invalid_request, "provider is required"}
    end

    test "validates provider value" do
      {:error, error} = TtsSetProvider.handle(%{"provider" => "invalid"}, @ctx)
      assert elem(error, 0) == :invalid_request
    end

    test "sets valid provider" do
      {:ok, result} = TtsSetProvider.handle(%{"provider" => "openai"}, @ctx)

      assert result["provider"] == "openai"
      assert result["summary"]["action"] == "set_provider"
      assert result["summary"]["provider"] == "openai"
      assert result["summary"]["cleanup"]["includesInputText"] == false
      assert result["summary"]["cleanup"]["includesAudio"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "has correct method name and scopes" do
      assert TtsSetProvider.name() == "tts.set-provider"
      assert TtsSetProvider.scopes() == [:admin]
    end
  end

  describe "UpdateRun" do
    test "returns update status" do
      {:ok, result} = UpdateRun.handle(%{}, @ctx)

      assert is_binary(result["currentVersion"])
      assert is_boolean(result["updateAvailable"])
      assert result["summary"]["action"] == "update.run"
      assert result["summary"]["currentVersion"] == result["currentVersion"]
      assert result["summary"]["latestVersion"] == result["latestVersion"]
      assert is_boolean(result["summary"]["configured"])
      assert result["summary"]["cleanup"]["includesDownloadUrl"] == false
      assert result["summary"]["cleanup"]["includesChecksum"] == false
      assert result["summary"]["cleanup"]["includesDownloadedBytes"] == false
    end

    test "has correct method name and scopes" do
      assert UpdateRun.name() == "update.run"
      assert UpdateRun.scopes() == [:admin]
    end
  end

  describe "ConfigGet" do
    test "returns config for specific key" do
      {:ok, result} = ConfigGet.handle(%{"key" => "logLevel"}, @ctx)

      assert result["key"] == "logLevel"
      assert result["summary"]["requestedKey"] == "logLevel"
      assert result["summary"]["keyCount"] == 1
      assert result["summary"]["sensitive"] == false
      assert result["summary"]["cleanup"]["includesSensitiveValues"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "returns all config when no key specified" do
      {:ok, result} = ConfigGet.handle(%{}, @ctx)

      assert is_map(result)
      assert result["summary"]["keyCount"] == map_size(Map.delete(result, "summary"))
      assert is_integer(result["summary"]["sensitiveKeyCount"])
      assert result["summary"]["cleanup"]["includesSensitiveValues"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "redacts sensitive stored config values" do
      key = "openai_api_key"
      previous = ConfigStore.get(key)

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:system_config, key)
          value -> ConfigStore.put(key, value)
        end
      end)

      :ok = ConfigStore.put(key, "sk-private-test-value")

      {:ok, single} = ConfigGet.handle(%{"key" => key}, @ctx)
      {:ok, all_config} = ConfigGet.handle(%{}, @ctx)

      assert single["value"] == %{"redacted" => true, "kind" => "secret"}
      assert all_config[key] == %{"redacted" => true, "kind" => "secret"}
      assert single["summary"]["sensitive"] == true
      assert single["summary"]["valueReturned"] == false
      assert all_config["summary"]["sensitiveKeyCount"] >= 1
      refute inspect(single["summary"]) =~ "sk-private-test-value"
      refute inspect(all_config["summary"]) =~ "sk-private-test-value"
    end

    test "has correct method name and scopes" do
      assert ConfigGet.name() == "config.get"
      assert ConfigGet.scopes() == [:read]
    end
  end

  describe "ConfigSet" do
    test "requires key and value" do
      {:error, error1} = ConfigSet.handle(%{}, @ctx)
      assert error1 == {:invalid_request, "key is required"}

      {:error, error2} = ConfigSet.handle(%{"key" => "test"}, @ctx)
      assert error2 == {:invalid_request, "value is required"}
    end

    test "sets config value" do
      {:ok, result} = ConfigSet.handle(%{"key" => "testKey", "value" => "testValue"}, @ctx)

      assert result["key"] == "testKey"
      assert result["value"] == "testValue"
      assert result["success"] == true
      assert result["summary"]["key"] == "testKey"
      assert result["summary"]["valueStored"] == true
      assert result["summary"]["sensitive"] == false
      assert result["summary"]["cleanup"]["includesValue"] == true
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "redacts sensitive config value in response" do
      key = "provider_secret_token"
      previous = ConfigStore.get(key)

      on_exit(fn ->
        case previous do
          nil -> Store.delete(:system_config, key)
          value -> ConfigStore.put(key, value)
        end
      end)

      {:ok, result} = ConfigSet.handle(%{"key" => key, "value" => "private-token"}, @ctx)

      assert result["key"] == key
      assert result["value"] == %{"redacted" => true, "kind" => "secret"}
      assert result["summary"]["sensitive"] == true
      assert result["summary"]["cleanup"]["includesValue"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      assert ConfigStore.get(key) == "private-token"
    end

    test "has correct method name and scopes" do
      assert ConfigSet.name() == "config.set"
      assert ConfigSet.scopes() == [:admin]
    end
  end

  describe "ConfigPatch" do
    test "requires non-empty patch" do
      {:error, error} = ConfigPatch.handle(%{"patch" => %{}}, @ctx)
      assert error == {:invalid_request, "patch must be a non-empty map"}
    end

    test "applies config patch" do
      {:ok, result} = ConfigPatch.handle(%{"patch" => %{"a" => 1, "b" => 2}}, @ctx)

      assert result["success"] == true
      assert "a" in result["applied"]
      assert "b" in result["applied"]
      assert result["summary"]["appliedCount"] == 2
      assert "a" in result["summary"]["appliedKeys"]
      assert "b" in result["summary"]["appliedKeys"]
      assert result["summary"]["sensitiveKeyCount"] == 0
      assert result["summary"]["cleanup"]["includesValues"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "summarizes sensitive config keys without values" do
      {:ok, result} =
        ConfigPatch.handle(%{"patch" => %{"apiToken" => "redacted", "safe" => true}}, @ctx)

      assert result["summary"]["appliedCount"] == 2
      assert result["summary"]["sensitiveKeyCount"] == 1
      assert result["summary"]["cleanup"]["includesValues"] == false
    end

    test "has correct method name and scopes" do
      assert ConfigPatch.name() == "config.patch"
      assert ConfigPatch.scopes() == [:admin]
    end
  end

  describe "ConfigSchema" do
    test "returns schema" do
      {:ok, result} = ConfigSchema.handle(%{}, @ctx)

      assert is_map(result["schema"])
      assert result["schema"]["type"] == "object"
      assert result["summary"]["type"] == "object"
      assert result["summary"]["propertyCount"] == 4
      assert "logLevel" in result["summary"]["propertyKeys"]
      assert result["summary"]["cleanup"]["includesValues"] == false
      assert result["summary"]["cleanup"]["includesCredentialValues"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "has correct method name and scopes" do
      assert ConfigSchema.name() == "config.schema"
      assert ConfigSchema.scopes() == [:read]
    end
  end

  describe "DevicePairRequest" do
    test "requires deviceType and deviceName" do
      {:error, error1} = DevicePairRequest.handle(%{}, @ctx)
      assert error1 == {:invalid_request, "deviceType is required"}

      {:error, error2} = DevicePairRequest.handle(%{"deviceType" => "mobile"}, @ctx)
      assert error2 == {:invalid_request, "deviceName is required"}
    end

    test "creates pairing request" do
      {:ok, result} =
        DevicePairRequest.handle(
          %{
            "deviceType" => "mobile",
            "deviceName" => "My Phone"
          },
          @ctx
        )

      assert is_binary(result["pairingId"])
      assert is_binary(result["code"])
      assert is_integer(result["expiresAt"])
    end

    test "has correct method name and scopes" do
      assert DevicePairRequest.name() == "device.pair.request"
      assert DevicePairRequest.scopes() == [:admin]
    end
  end

  describe "WizardStart" do
    test "starts wizard with default type" do
      {:ok, result} = WizardStart.handle(%{}, @ctx)

      assert is_binary(result["wizardId"])
      assert result["type"] == "setup"
      assert is_list(result["steps"])
      assert result["currentStep"] == 0
      assert result["summary"]["action"] == "wizard.start"
      assert result["summary"]["wizardIdReturned"] == true
      assert result["summary"]["type"] == "setup"
      assert result["summary"]["stepCount"] == length(result["steps"])
      assert result["summary"]["currentStep"] == 0
      assert result["summary"]["cleanup"]["includesWizardData"] == false
    end

    test "starts wizard with specified type" do
      {:ok, result} = WizardStart.handle(%{"wizardId" => "channel"}, @ctx)

      assert result["type"] == "channel"
      assert result["summary"]["type"] == "channel"
    end

    test "has correct method name and scopes" do
      assert WizardStart.name() == "wizard.start"
      assert WizardStart.scopes() == [:admin]
    end
  end

  describe "WizardStep" do
    test "requires wizardId and stepId" do
      {:error, error1} = WizardStep.handle(%{}, @ctx)
      assert error1 == {:invalid_request, "wizardId is required"}

      {:error, error2} = WizardStep.handle(%{"wizardId" => "wiz"}, @ctx)
      assert error2 == {:invalid_request, "stepId is required"}
    end

    test "advances wizard with bounded data summary" do
      {:ok, started} = WizardStart.handle(%{}, @ctx)

      {:ok, result} =
        WizardStep.handle(
          %{
            "wizardId" => started["wizardId"],
            "stepId" => "api_keys",
            "data" => %{"OPENAI_API_KEY" => "super-private-value", "workspace" => "ops"}
          },
          @ctx
        )

      assert result["wizardId"] == started["wizardId"]
      assert result["stepId"] == "api_keys"
      assert result["complete"] == false
      assert result["data"]["OPENAI_API_KEY"] == %{"redacted" => true, "kind" => "secret"}
      assert result["data"]["workspace"] == "ops"
      assert result["summary"]["action"] == "wizard.step"
      assert result["summary"]["wizardIdReturned"] == true
      assert result["summary"]["stepIdReturned"] == true
      assert result["summary"]["currentStep"] == 1
      assert result["summary"]["complete"] == false
      assert result["summary"]["dataKeyCount"] == 2
      assert result["summary"]["cleanup"]["includesWizardData"] == true
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result) =~ "super-private-value"
    end

    test "has correct method name and scopes" do
      assert WizardStep.name() == "wizard.step"
      assert WizardStep.scopes() == [:admin]
    end
  end

  describe "WizardCancel" do
    test "requires wizardId" do
      {:error, error} = WizardCancel.handle(%{}, @ctx)
      assert error == {:invalid_request, "wizardId is required"}
    end

    test "cancels wizard with cleanup summary" do
      {:ok, started} = WizardStart.handle(%{}, @ctx)

      {:ok, result} = WizardCancel.handle(%{"wizardId" => started["wizardId"]}, @ctx)

      assert result["success"] == true
      assert result["summary"]["action"] == "wizard.cancel"
      assert result["summary"]["success"] == true
      assert result["summary"]["wizardIdReturned"] == false
      assert result["summary"]["cleanup"]["includesWizardData"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
      refute inspect(result["summary"]) =~ started["wizardId"]
    end

    test "has correct method name and scopes" do
      assert WizardCancel.name() == "wizard.cancel"
      assert WizardCancel.scopes() == [:admin]
    end
  end

  describe "ConnectChallenge" do
    test "requires challenge" do
      {:error, error} = ConnectChallenge.handle(%{}, @ctx)
      assert error == {:invalid_request, "challenge is required"}
    end

    test "has correct method name and scopes" do
      assert ConnectChallenge.name() == "connect.challenge"
      assert ConnectChallenge.scopes() == []
    end
  end

  describe "UsageStatus" do
    test "returns usage status" do
      {:ok, result} = UsageStatus.handle(%{}, @ctx)

      assert is_binary(result["period"])
      assert is_integer(result["periodStart"])
      assert is_map(result["quotas"])
      assert is_map(result["summary"])
      assert is_list(result["providers"])
      assert result["includesPrompts"] == false
      assert result["includesResponses"] == false
      assert result["includesMessageBodies"] == false
      assert result["includesCredentials"] == false
      assert result["includesSecretValues"] == false
    end

    test "reports usage recorded through usage.cost" do
      :ok =
        UsageCost.record_usage(%{
          provider: "usage_status_test",
          cost: 0.02,
          input_tokens: 12,
          output_tokens: 3
        })

      {:ok, result} = UsageStatus.handle(%{}, @ctx)

      assert result["runs"] >= 1
      assert result["cost"] >= 0.02
      assert result["tokens"]["input"] >= 12
      assert result["tokens"]["output"] >= 3
      assert result["summary"]["totalTokens"] >= 15

      provider = Enum.find(result["providers"], &(&1["provider"] == "usage_status_test"))
      assert provider["cost"] >= 0.02
      assert provider["requests"] >= 1
      assert provider["inputTokens"] >= 12
      assert provider["outputTokens"] >= 3
    end

    test "uses shared usage diagnostics without leaking stored sensitive fields" do
      previous_summary = LemonCore.UsageStore.get_summary(:current)
      today_key = Date.to_iso8601(Date.utc_today())
      previous_today = LemonCore.UsageStore.get_record(today_key)

      on_exit(fn ->
        if previous_summary do
          LemonCore.UsageStore.put_summary(:current, previous_summary)
        else
          LemonCore.Store.delete(:usage_data, :current)
        end

        if previous_today do
          LemonCore.UsageStore.put_record(today_key, previous_today)
        else
          LemonCore.Store.delete(:usage_records, today_key)
        end
      end)

      LemonCore.UsageStore.put_summary(:current, %{
        total_cost: 0.42,
        total_requests: 3,
        total_tokens: %{input: 1_000, output: 500},
        breakdown: %{"openai" => 0.42},
        requests: %{"openai" => 3},
        tokens: %{"openai" => %{input: 1_000, output: 500}},
        prompt: "private usage status prompt",
        response: "private usage status response",
        api_key: "usage-status-secret-key"
      })

      LemonCore.UsageStore.put_record(today_key, %{
        date: today_key,
        total_cost: 0.42,
        requests: %{"openai" => 3},
        message_body: "private usage status message"
      })

      {:ok, result} = UsageStatus.handle(%{}, @ctx)

      assert result["runs"] == 3
      assert result["cost"] == 0.42
      assert result["tokens"] == %{"input" => 1_000, "output" => 500}
      assert result["summary"]["status"] in ["within_limits", "unlimited"]
      assert result["summary"]["totalTokens"] == 1_500
      assert result["includesPrompts"] == false
      assert result["includesResponses"] == false
      assert result["includesMessageBodies"] == false
      assert result["includesCredentials"] == false
      assert result["includesSecretValues"] == false

      assert [provider] = result["providers"]
      assert provider["provider"] == "openai"
      assert provider["cost"] == 0.42
      assert provider["requests"] == 3
      assert provider["inputTokens"] == 1_000
      assert provider["outputTokens"] == 500

      result_text = inspect(result)
      refute result_text =~ "private usage status prompt"
      refute result_text =~ "private usage status response"
      refute result_text =~ "private usage status message"
      refute result_text =~ "usage-status-secret-key"
    end

    test "has correct method name and scopes" do
      assert UsageStatus.name() == "usage.status"
      assert UsageStatus.scopes() == [:read]
    end
  end

  describe "UsageCost" do
    test "returns cost breakdown" do
      {:ok, result} = UsageCost.handle(%{}, @ctx)

      assert is_binary(result["startDate"])
      assert is_binary(result["endDate"])
      assert is_number(result["totalCost"])
      assert is_map(result["breakdown"])
      assert result["summary"]["providerCount"] == map_size(result["breakdown"])
      assert result["summary"]["dailyReturned"] == Map.has_key?(result, "daily")
      assert result["summary"]["cleanup"]["includesPrompts"] == false
      assert result["summary"]["cleanup"]["includesResponses"] == false
      assert result["summary"]["cleanup"]["includesCredentials"] == false
      assert result["summary"]["cleanup"]["includesSecretValues"] == false
    end

    test "accepts date range parameters" do
      {:ok, result} =
        UsageCost.handle(
          %{
            "startDate" => "2024-01-01",
            "endDate" => "2024-01-31"
          },
          @ctx
        )

      assert result["startDate"] == "2024-01-01"
      assert result["endDate"] == "2024-01-31"
    end

    test "has correct method name and scopes" do
      assert UsageCost.name() == "usage.cost"
      assert UsageCost.scopes() == [:read]
    end
  end
end

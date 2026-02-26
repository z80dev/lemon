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

  @ctx %{conn_id: "test-conn", auth: %{role: :operator}}

  describe "VoicewakeGet" do
    test "returns voicewake configuration" do
      {:ok, result} = VoicewakeGet.handle(%{}, @ctx)

      assert is_boolean(result["enabled"])
      assert is_binary(result["keyword"])
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
      {:ok, result} = VoicewakeSet.handle(%{"enabled" => true, "keyword" => "hey"}, @ctx)

      assert result["enabled"] == true
      assert result["keyword"] == "hey"
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
      assert length(result["providers"]) > 0

      provider = hd(result["providers"])
      assert is_binary(provider["id"])
      assert is_binary(provider["name"])
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
    end

    test "enables TTS with specific provider" do
      {:ok, result} = TtsEnable.handle(%{"provider" => "openai"}, @ctx)

      assert result["enabled"] == true
      assert result["provider"] == "openai"
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
    end

    test "returns all config when no key specified" do
      {:ok, result} = ConfigGet.handle(%{}, @ctx)

      assert is_map(result)
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
      {:ok, result} = DevicePairRequest.handle(%{
        "deviceType" => "mobile",
        "deviceName" => "My Phone"
      }, @ctx)

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
    end

    test "starts wizard with specified type" do
      {:ok, result} = WizardStart.handle(%{"wizardId" => "channel"}, @ctx)

      assert result["type"] == "channel"
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
    end

    test "accepts date range parameters" do
      {:ok, result} = UsageCost.handle(%{
        "startDate" => "2024-01-01",
        "endDate" => "2024-01-31"
      }, @ctx)

      assert result["startDate"] == "2024-01-01"
      assert result["endDate"] == "2024-01-31"
    end

    test "has correct method name and scopes" do
      assert UsageCost.name() == "usage.cost"
      assert UsageCost.scopes() == [:read]
    end
  end
end

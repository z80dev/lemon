defmodule CodingAgent.Session.ModelAvailabilityTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager
  alias LemonAgent.ModelRuntime.ModelCatalog

  setup do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    LemonAi.ModelCache.invalidate_all()
    saved = Map.new(["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"], &{&1, System.get_env(&1)})
    Enum.each(Map.keys(saved), &System.delete_env/1)

    on_exit(fn ->
      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
      LemonAi.ModelCache.invalidate_all()

      Enum.each(saved, fn {name, value} ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end)
    end)

    jwt =
      "header." <>
        Base.url_encode64(
          Jason.encode!(%{
            "https://api.openai.com/auth" => %{"chatgpt_account_id" => "synthetic-native-account"}
          }),
          padding: false
        ) <> ".signature"

    settings = %SettingsManager{
      providers: %{
        "openai-codex" => %{
          auth_source: "api_key",
          api_key: jwt,
          base_url: "https://example.invalid/backend-api"
        }
      },
      model_roles: %{"smol" => "openai-codex:gpt-6-luna", "slow" => "openai-codex:gpt-6.1-sol"},
      provider_routing: %{enabled: false}
    }

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"models" => [%{"slug" => "gpt-6.1-sol", "supported_in_api" => true}]})
    end)

    %{settings: settings}
  end

  test "picker offers only account-supported Codex IDs", %{settings: settings} do
    models = ModelCatalog.available_models(config: settings)
    codex = Enum.filter(models, &(&1.provider == :openai_codex))
    assert Enum.map(codex, & &1.id) == ["gpt-6.1-sol"]
    refute Enum.any?(codex, &(&1.id == "gpt-6-luna"))
  end

  test "session, task and compaction roles fail before a provider request with an actionable account error",
       %{settings: settings} do
    parent = LemonAi.Models.get_model(:openai_codex, "gpt-6.1-sol")

    for resolve <- [
          fn -> ModelResolver.resolve_session_model("@smol", settings) end,
          fn -> ModelResolver.resolve_task_model("@smol", settings, parent) end,
          fn -> ModelResolver.resolve_compaction_model("@smol", settings, parent) end
        ] do
      error = assert_raise ArgumentError, resolve
      assert error.message =~ "@smol"
      assert error.message =~ "not available for this ChatGPT account"
      assert error.message =~ "config.toml"
      assert error.message =~ "gpt-6.1-sol"
    end

    assert ModelResolver.resolve_session_model("@slow", settings).id == "gpt-6.1-sol"
  end

  test "default role is checked too, while static resolution remains possible without concrete ChatGPT identity",
       %{settings: settings} do
    assert_raise ArgumentError, fn ->
      ModelResolver.resolve_session_model(nil, %{settings | default_model: "@smol"})
    end

    static = %{
      settings
      | providers: %{"openai-codex" => %{auth_source: "api_key", api_key: "synthetic-non-jwt"}}
    }

    assert ModelResolver.resolve_session_model("@smol", static).id == "gpt-6-luna"
  end
end

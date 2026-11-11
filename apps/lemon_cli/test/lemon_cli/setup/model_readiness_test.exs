defmodule LemonCli.Setup.ModelReadinessTest do
  use ExUnit.Case, async: false

  alias LemonCli.Setup.ModelReadiness

  defmodule EmptySecrets do
    def get(_name), do: {:error, :not_found}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "model_readiness_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "status/1" do
    test "reports not_configured without a default provider", %{root: root} do
      opts = offline(root, "", setup_provider(nil, nil, false, :missing_default_provider))

      assert %{
               state: :not_configured,
               provider_id: nil,
               model_id: nil,
               check: nil,
               reason: :no_default,
               available_model_ids: nil,
               suggested_model_id: nil,
               checked_at_ms: nil
             } = ModelReadiness.status(opts)
    end

    test "reports action_required when the default model is missing", %{root: root} do
      config = """
      [defaults]
      provider = "openai-codex"

      [providers.openai-codex]
      auth_source = "api_key"
      api_key = "synthetic-codex-key"
      """

      opts =
        offline(root, config, setup_provider("openai-codex", nil, true, :missing_default_model))

      assert %{
               state: :action_required,
               provider_id: "openai_codex",
               model_id: nil,
               reason: :no_default
             } = ModelReadiness.status(opts)
    end

    test "reports model_provider_mismatch from the setup state", %{root: root} do
      config = """
      [defaults]
      provider = "openai-codex"
      model = "anthropic:claude-sonnet-5.5"

      [providers.openai-codex]
      auth_source = "api_key"
      api_key = "synthetic-codex-key"
      """

      opts =
        offline(
          root,
          config,
          setup_provider(
            "openai-codex",
            "anthropic:claude-sonnet-5.5",
            true,
            :model_provider_mismatch
          )
        )

      readiness = ModelReadiness.status(opts)
      assert readiness.state == :action_required
      assert readiness.reason == :model_provider_mismatch
      assert readiness.provider_id == "openai_codex"
    end

    test "reports saved with a resolvable credential and never verified", %{root: root} do
      config = """
      [defaults]
      provider = "openai-codex"
      model = "openai-codex:gpt-6.1-sol"

      [providers.openai-codex]
      auth_source = "api_key"
      api_key = "synthetic-codex-key"
      """

      opts =
        offline(
          root,
          config,
          setup_provider("openai-codex", "openai-codex:gpt-6.1-sol", true, nil)
        )

      readiness = ModelReadiness.status(opts)
      assert readiness.state == :saved
      assert readiness.provider_id == "openai_codex"
      assert readiness.model_id == "gpt-6.1-sol"
      assert readiness.reason == nil
      assert readiness.check == nil
      assert readiness.checked_at_ms == nil
      assert readiness.suggested_model_id == "gpt-6.1-sol"
    end

    test "reports action_required when no credential resolves", %{root: root} do
      config = """
      [defaults]
      provider = "openai-codex"
      model = "openai-codex:gpt-6.1-sol"

      [providers.openai-codex]
      auth_source = "oauth"
      oauth_secret = "llm_openai_codex_api_key"
      """

      opts =
        offline(
          root,
          config,
          setup_provider(
            "openai-codex",
            "openai-codex:gpt-6.1-sol",
            false,
            :credential_not_usable
          )
        )

      readiness = ModelReadiness.status(opts)
      assert readiness.state == :action_required
      assert readiness.reason == :credential_missing
    end
  end

  describe "check/1" do
    test "verified when Codex discovery advertises the configured model", %{root: root} do
      opts =
        codex_opts(root, fn discovery_opts ->
          assert discovery_opts[:access_token] == "synthetic-codex-key"
          assert discovery_opts[:force_refresh] == true
          {:ok, [%{id: "gpt-6.1-sol"}, %{id: "gpt-6-sol"}]}
        end)

      readiness = ModelReadiness.check(opts)

      assert readiness.state == :verified
      assert readiness.provider_id == "openai_codex"
      assert readiness.model_id == "gpt-6.1-sol"
      assert readiness.check == :codex_discovery
      assert readiness.reason == nil
      assert readiness.available_model_ids == ["gpt-6-sol", "gpt-6.1-sol"]
      assert readiness.suggested_model_id == "gpt-6.1-sol"
      assert is_integer(readiness.checked_at_ms)
    end

    test "action_required/model_unavailable when the account lacks the model", %{root: root} do
      opts = codex_opts(root, fn _ -> {:ok, [%{id: "gpt-6-sol"}]} end)

      readiness = ModelReadiness.check(opts)

      assert readiness.state == :action_required
      assert readiness.reason == :model_unavailable
      assert readiness.check == :codex_discovery
      assert readiness.available_model_ids == ["gpt-6-sol"]
      assert readiness.suggested_model_id == "gpt-6-sol"
    end

    test "action_required/credential_rejected on 401", %{root: root} do
      opts = codex_opts(root, fn _ -> {:error, {:authentication_rejected, 401}} end)

      readiness = ModelReadiness.check(opts)
      assert readiness.state == :action_required
      assert readiness.reason == :credential_rejected
      assert readiness.check == :codex_discovery
    end

    test "saved/provider_unreachable on transport failure", %{root: root} do
      opts = codex_opts(root, fn _ -> {:error, :transport_failure} end)

      readiness = ModelReadiness.check(opts)
      assert readiness.state == :saved
      assert readiness.reason == :provider_unreachable
    end

    test "saved/check_failed on an HTTP error", %{root: root} do
      opts = codex_opts(root, fn _ -> {:error, {:http_error, 503}} end)

      readiness = ModelReadiness.check(opts)
      assert readiness.state == :saved
      assert readiness.reason == :check_failed
    end

    test "verified with the models endpoint for API-key providers", %{root: root} do
      config = """
      [defaults]
      provider = "openai"
      model = "openai:gpt-4o"

      [providers.openai]
      api_key = "synthetic-openai-key"
      """

      opts =
        offline(root, config, setup_provider("openai", "openai:gpt-4o", true, nil))
        |> Keyword.put(:verifier, fn input ->
          assert input.api == :openai_responses
          assert input.model_id == "gpt-4o"
          assert input.probe? == false
          {:ok, %{http_status: 200, check: :models_endpoint}}
        end)

      readiness = ModelReadiness.check(opts)
      assert readiness.state == :verified
      assert readiness.check == :models_endpoint
      assert readiness.reason == nil
    end

    test "falls back to the offline state when no live input resolves", %{root: root} do
      config = """
      [defaults]
      provider = "openai-codex"

      [providers.openai-codex]
      auth_source = "api_key"
      api_key = "synthetic-codex-key"
      """

      opts =
        offline(root, config, setup_provider("openai-codex", nil, true, :missing_default_model))

      readiness = ModelReadiness.check(opts)
      assert readiness.state == :action_required
      assert readiness.reason == :no_default
      assert readiness.checked_at_ms == nil
    end
  end

  describe "detect/1" do
    test "offers a present Codex CLI login first and lists env variable names" do
      detected =
        ModelReadiness.detect(
          codex_login_status: fn _ -> :present end,
          env_lookup: %{"ANTHROPIC_API_KEY" => "sk-ant", "OPENAI_API_KEY" => "sk-openai"}
        )

      assert hd(detected) == %{source: :codex_cli, provider_id: "openai_codex"}

      assert %{source: :environment, provider_id: "anthropic", variable: "ANTHROPIC_API_KEY"} in detected

      assert %{source: :environment, provider_id: "openai", variable: "OPENAI_API_KEY"} in detected
    end

    test "omits absent or unusable Codex logins and blank variables" do
      for status <- [:absent, {:unusable, :not_chatgpt_oauth}] do
        assert ModelReadiness.detect(
                 codex_login_status: fn _ -> status end,
                 env_lookup: %{"ANTHROPIC_API_KEY" => "   "}
               ) == []
      end
    end

    test "passes an explicit CLI login path to the probe" do
      assert ModelReadiness.detect(
               codex_auth_path: "/tmp/codex-auth.json",
               codex_login_status: fn opts ->
                 assert opts[:path] == "/tmp/codex-auth.json"
                 :absent
               end,
               env_lookup: fn _ -> nil end
             ) == []
    end

    test "classifies real Codex CLI login files without reading tokens", %{root: root} do
      path = Path.join(root, "codex-auth.json")
      env = fn _ -> nil end

      assert ModelReadiness.detect(codex_auth_path: path, env_lookup: env) == []

      File.write!(path, Jason.encode!(codex_login()))
      contents = File.read!(path)

      assert ModelReadiness.detect(codex_auth_path: path, env_lookup: env) == [
               %{source: :codex_cli, provider_id: "openai_codex"}
             ]

      # Detection never rewrites the Codex CLI's own file.
      assert File.read!(path) == contents

      File.write!(path, Jason.encode!(%{"OPENAI_API_KEY" => "synthetic-key"}))
      assert ModelReadiness.detect(codex_auth_path: path, env_lookup: env) == []

      no_refresh = update_in(codex_login(), ["tokens"], &Map.delete(&1, "refresh_token"))
      File.write!(path, Jason.encode!(no_refresh))
      assert ModelReadiness.detect(codex_auth_path: path, env_lookup: env) == []

      File.write!(path, "not json")
      assert ModelReadiness.detect(codex_auth_path: path, env_lookup: env) == []
    end
  end

  describe "to_wire/1" do
    test "projects readiness to the camelCase wire shape" do
      readiness = %{
        state: :verified,
        provider_id: "openai_codex",
        model_id: "gpt-6.1-sol",
        check: :codex_discovery,
        reason: nil,
        available_model_ids: ["gpt-6.1-sol"],
        suggested_model_id: "gpt-6.1-sol",
        checked_at_ms: 1_731_283_200_000
      }

      assert ModelReadiness.to_wire(readiness) == %{
               "state" => "verified",
               "providerId" => "openai_codex",
               "modelId" => "gpt-6.1-sol",
               "check" => "codex_discovery",
               "reason" => nil,
               "availableModelIds" => ["gpt-6.1-sol"],
               "suggestedModelId" => "gpt-6.1-sol",
               "checkedAtMs" => 1_731_283_200_000
             }
    end

    test "projects detected logins" do
      detected = [
        %{source: :codex_cli, provider_id: "openai_codex"},
        %{source: :environment, provider_id: "anthropic", variable: "ANTHROPIC_API_KEY"}
      ]

      assert ModelReadiness.to_wire(detected) == [
               %{"source" => "codex_cli", "providerId" => "openai_codex"},
               %{
                 "source" => "environment",
                 "providerId" => "anthropic",
                 "variable" => "ANTHROPIC_API_KEY"
               }
             ]
    end
  end

  defp codex_opts(root, discover) do
    config = """
    [defaults]
    provider = "openai-codex"
    model = "openai-codex:gpt-6.1-sol"

    [providers.openai-codex]
    auth_source = "api_key"
    api_key = "synthetic-codex-key"
    """

    root
    |> offline(config, setup_provider("openai-codex", "openai-codex:gpt-6.1-sol", true, nil))
    |> Keyword.put(:codex_discover, discover)
  end

  defp offline(root, config, provider_state) do
    path = Path.join(root, "config_#{System.unique_integer([:positive])}.toml")
    File.write!(path, config)

    [
      config_path: path,
      cwd: root,
      secrets: EmptySecrets,
      setup_state: %{
        config: %{complete: true, path: path},
        secrets: %{complete: true, source: :env},
        provider: provider_state
      }
    ]
  end

  defp setup_provider(provider, model, credential_ready?, reason) do
    %{
      complete: is_nil(reason),
      provider: provider,
      model: model,
      credential_ready: credential_ready?,
      reason: reason
    }
  end

  defp codex_login do
    exp = DateTime.utc_now() |> DateTime.add(3_600, :second) |> DateTime.to_unix()

    claims =
      Jason.encode!(%{
        "exp" => exp,
        "https://api.openai.com/auth" => %{"chatgpt_account_id" => "acc_readiness"}
      })

    jwt = "header." <> Base.url_encode64(claims, padding: false) <> ".signature"

    %{
      "auth_mode" => "chatgpt",
      "OPENAI_API_KEY" => nil,
      "tokens" => %{
        "access_token" => jwt,
        "refresh_token" => "synthetic-refresh",
        "account_id" => "acc_readiness",
        "id_token" => jwt
      }
    }
  end
end

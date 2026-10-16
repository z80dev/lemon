defmodule LemonCore.Setup.ReadinessTest do
  use ExUnit.Case, async: false

  alias LemonCore.Doctor.ProviderDiagnostics
  alias LemonCore.Setup.Readiness

  for {provider, config_provider, model, reason} <- [
        {"ollama", "ollama", "qwen3:32b", nil},
        {"ollama", "ollama", "qwen3:32b:instruct", nil},
        {"ollama", "ollama", "ollama:qwen3:32b", nil},
        {"local-gateway", "LOCAL_GATEWAY", "LOCAL_GATEWAY:qwen3:32b", nil},
        {"ollama", "ollama", "foreign_gateway:qwen3:32b", :model_provider_mismatch},
        {"ollama", "ollama", ":32b", nil},
        {"ollama", "ollama", "foreign_gateway:", nil}
      ] do
    test "persisted #{provider} / #{model} derives local provider identity" do
      path =
        Path.join(
          System.tmp_dir!(),
          "readiness_identity_#{System.unique_integer([:positive])}.toml"
        )

      on_exit(fn -> File.rm!(path) end)

      File.write!(path, """
      [defaults]
      provider = "#{unquote(provider)}"
      model = "#{unquote(model)}"
      [providers.#{unquote(config_provider)}]
      api_key = "fixture-local-key"
      [providers.foreign-gateway]
      api_key = "fixture-foreign-key"
      """)

      state = Readiness.status(config_path: path).provider
      assert state.provider == unquote(provider)
      assert state.model == unquote(model)
      assert state.reason == unquote(reason)
      assert state.complete == is_nil(unquote(reason))
      assert state.credential_ready
    end
  end

  test "an explicitly declared namespaced id is not foreign provider qualification" do
    path =
      Path.join(
        System.tmp_dir!(),
        "readiness_declared_#{System.unique_integer([:positive])}.toml"
      )

    on_exit(fn -> File.rm!(path) end)

    File.write!(path, """
    [defaults]
    provider = "local-gateway"
    model = "openai:private:32b"
    [providers.LOCAL_GATEWAY]
    api_key = "fixture-local-key"
    [[providers.LOCAL_GATEWAY.models]]
    id = "openai:private:32b"
    [providers.openai]
    api_key = "fixture-foreign-key"
    """)

    assert %{complete: true, reason: nil, model: "openai:private:32b", credential_ready: true} =
             Readiness.status(config_path: path).provider
  end

  test "environment-only credentials agree with doctor and reject blank values" do
    path =
      Path.join(System.tmp_dir!(), "readiness_env_#{System.unique_integer([:positive])}.toml")

    previous = System.get_env("OPENAI_API_KEY")
    File.write!(path, "[defaults]\nprovider = \"openai\"\nmodel = \"gpt-5\"\n")

    on_exit(fn ->
      if previous,
        do: System.put_env("OPENAI_API_KEY", previous),
        else: System.delete_env("OPENAI_API_KEY")

      File.rm!(path)
    end)

    System.put_env("OPENAI_API_KEY", "test-env-key")
    assert Readiness.status(config_path: path).provider.complete
    assert ProviderDiagnostics.ambient_configured?("openai")

    System.put_env("OPENAI_API_KEY", " \n")
    refute Readiness.status(config_path: path).provider.complete
    refute ProviderDiagnostics.ambient_configured?("openai")
  end

  for {provider, auth, ready?} <- [
        {"ollama", "", true},
        {"custom", "auth = \"none\"", true},
        {"openai", "", false},
        {"ollama_cloud", "", false}
      ] do
    test "#{provider} credential readiness is #{ready?}" do
      path =
        Path.join(System.tmp_dir!(), "readiness_#{System.unique_integer([:positive])}.toml")

      File.write!(path, """
      [defaults]
      provider = "#{unquote(provider)}"
      model = "test-model"
      [providers.#{unquote(provider)}]
      #{unquote(auth)}
      """)

      on_exit(fn -> File.rm!(path) end)
      state = Readiness.status(config_path: path)
      assert state.provider.credential_ready == unquote(ready?)
      assert state.provider.complete == unquote(ready?)
    end
  end

  test "keyless auth accepts atom-keyed effective config without trusting a local URL" do
    assert Readiness.keyless_provider?("custom", %{auth: "none"})
    refute Readiness.keyless_provider?("openai", %{base_url: "http://localhost:8080/v1"})
  end

  test "pending steps remain ordered and ready?/1 agrees with them" do
    pending = %{
      config: %{complete: false, path: "/tmp/config.toml"},
      secrets: %{complete: true, source: :env},
      provider: %{
        complete: false,
        provider: "openai",
        model: nil,
        credential_ready: true,
        reason: :missing_default_model
      }
    }

    assert Readiness.pending_steps(pending) == [:config, :provider]
    refute Readiness.ready?(pending)

    ready =
      pending
      |> put_in([:config, :complete], true)
      |> put_in([:provider, :complete], true)
      |> put_in([:provider, :reason], nil)

    assert Readiness.pending_steps(ready) == []
    assert Readiness.ready?(ready)
  end
end

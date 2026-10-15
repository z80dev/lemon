defmodule LemonCore.Setup.ReadinessTest do
  use ExUnit.Case, async: true

  alias LemonCore.Setup.Readiness

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

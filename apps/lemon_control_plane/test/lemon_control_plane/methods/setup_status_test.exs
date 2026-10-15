defmodule LemonControlPlane.Methods.SetupStatusTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, SetupStatus}
  alias LemonCore.Setup.Readiness

  setup do
    previous_fun = Application.fetch_env(:lemon_control_plane, :setup_status_fun)
    previous_secrets = Application.fetch_env(:lemon_core, LemonCore.Secrets)
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    previous_openai = System.get_env("OPENAI_API_KEY")
    path = Path.join(System.tmp_dir!(), "setup_status_#{System.unique_integer([:positive])}.toml")

    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env])
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.delete_env("OPENAI_API_KEY")

    Application.put_env(:lemon_control_plane, :setup_status_fun, fn ->
      Readiness.status(config_path: path)
    end)

    on_exit(fn ->
      restore_env(:lemon_control_plane, :setup_status_fun, previous_fun)
      restore_env(:lemon_core, LemonCore.Secrets, previous_secrets)
      restore_system_env("LEMON_SECRETS_MASTER_KEY", previous_key)
      restore_system_env("OPENAI_API_KEY", previous_openai)
      File.rm(path)
    end)

    %{path: path}
  end

  test "is registered with read scope" do
    assert SetupStatus.name() == "setup.status"
    assert SetupStatus.scopes() == [:read]
    assert "setup.status" in Registry.list_methods()
  end

  test "ready state exposes only readiness, not credentials or config content", %{path: path} do
    File.write!(path, """
    [defaults]
    provider = "openai"
    model = "private-model"
    [providers.openai]
    api_key = "private-test-credential"
    """)

    assert {:ok, %{"ready" => true, "pendingSteps" => []}} = SetupStatus.handle(%{}, %{})
  end

  test "missing config and credentials return fixed pending steps without paths", %{path: path} do
    System.delete_env("LEMON_SECRETS_MASTER_KEY")

    assert {:ok, result} = SetupStatus.handle(%{"config_path" => path <> ".ignored"}, %{})

    assert result == %{
             "ready" => false,
             "pendingSteps" => [
               %{"id" => "config", "label" => "Create configuration", "command" => "lemon setup"},
               %{"id" => "secrets", "label" => "Configure secrets", "command" => "lemon setup"},
               %{
                 "id" => "provider",
                 "label" => "Choose a default provider and model with usable credentials",
                 "command" => "lemon setup provider"
               }
             ]
           }

    refute inspect(result) =~ path
  end

  test "configured cloud provider without credentials remains pending", %{path: path} do
    File.write!(path, "[defaults]\nprovider = \"openai\"\nmodel = \"private-model\"\n")

    assert {:ok, %{"ready" => false, "pendingSteps" => [%{"id" => "provider"}]}} =
             SetupStatus.handle(%{}, %{})
  end

  test "keyless local provider is ready without a credential", %{path: path} do
    File.write!(path, "[defaults]\nprovider = \"ollama\"\nmodel = \"local-model\"\n")
    assert {:ok, %{"ready" => true, "pendingSteps" => []}} = SetupStatus.handle(%{}, %{})
  end

  test "environment-only credentials are ready", %{path: path} do
    File.write!(path, "[defaults]\nprovider = \"openai\"\nmodel = \"private-model\"\n")
    System.put_env("OPENAI_API_KEY", "private-env-credential")
    assert {:ok, %{"ready" => true, "pendingSteps" => []}} = SetupStatus.handle(%{}, %{})
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end

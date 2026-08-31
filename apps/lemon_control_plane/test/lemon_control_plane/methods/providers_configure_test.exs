defmodule LemonControlPlane.Methods.ProvidersConfigureTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.ProvidersConfigure

  @ctx %{auth: %{role: :operator, scopes: [:admin]}, conn_id: "test", conn_pid: nil}

  setup do
    original_home = System.get_env("HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "providers_configure_rpc_test_#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(home, ".lemon"))
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home,
        do: System.put_env("HOME", original_home),
        else: System.delete_env("HOME")

      File.rm_rf!(root)
    end)

    %{config_path: Path.join(home, ".lemon/config.toml")}
  end

  test "previews and applies fallback changes through the admin RPC", ctx do
    File.write!(ctx.config_path, "# preserve me\n")

    assert {:ok, preview} =
             ProvidersConfigure.handle(
               %{"action" => "fallback.add", "provider" => "zai"},
               @ctx
             )

    refute preview["applied"]
    assert preview["proposedRoutingConfig"]["fallbackProviders"] == ["zai"]
    assert File.read!(ctx.config_path) == "# preserve me\n"

    assert {:ok, applied} =
             ProvidersConfigure.handle(
               %{"action" => "fallback.add", "provider" => "zai", "apply" => true},
               @ctx
             )

    assert applied["applied"]
    assert applied["summary"]["action"] == "providers.configure"
    assert applied["summary"]["fallbackProviderCount"] == 1
    assert File.read!(ctx.config_path) =~ "# preserve me"
  end

  test "maps destructive confirmation failures to a redacted conflict", ctx do
    File.write!(ctx.config_path, """
    [runtime.provider_routing]
    fallback_providers = ["zai"]
    """)

    assert {:error, {:conflict, message, %{"code" => "confirmation_required"}}} =
             ProvidersConfigure.handle(
               %{
                 "action" => "fallback.remove",
                 "provider" => "zai",
                 "apply" => true
               },
               @ctx
             )

    assert message =~ "requires confirmation"
    assert File.read!(ctx.config_path) =~ "zai"
  end

  test "maps stale preview revisions to a redacted conflict", ctx do
    File.write!(ctx.config_path, "# initial\n")

    assert {:ok, preview} =
             ProvidersConfigure.handle(
               %{"action" => "fallback.add", "provider" => "zai"},
               @ctx
             )

    File.write!(ctx.config_path, "# changed elsewhere\n")

    assert {:error, {:conflict, message, %{"code" => "stale_configuration"}}} =
             ProvidersConfigure.handle(
               %{
                 "action" => "fallback.add",
                 "provider" => "zai",
                 "apply" => true,
                 "expectedRevision" => preview["configRevision"]
               },
               @ctx
             )

    assert message == "Provider configuration changed after the preview; preview again"
    assert File.read!(ctx.config_path) == "# changed elsewhere\n"
  end

  test "never returns credential reference names", _ctx do
    assert {:ok, result} =
             ProvidersConfigure.handle(
               %{
                 "action" => "pool.credential.add",
                 "pool" => "burst",
                 "provider" => "openai",
                 "credentialRef" => "secret:private_pool_reference",
                 "apply" => true
               },
               @ctx
             )

    assert result["summary"]["credentialReferenceCount"] == 1
    refute inspect(result) =~ "private_pool_reference"
    assert result["cleanup"]["includesCredentialReferences"] == false
  end

  test "declares the admin-scoped method contract" do
    assert ProvidersConfigure.name() == "providers.configure"
    assert ProvidersConfigure.scopes() == [:admin]
  end
end

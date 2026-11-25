defmodule LemonControlPlane.Methods.SecretsMethodsTest do
  @moduledoc "Write-only `secrets.set` / `secrets.delete` for one-shot CLI clients (#667)."
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, SecretsDelete, SecretsSet}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.Secrets

  @name "CONTROL_PLANE_SECRET_TEST"

  setup do
    previous_secrets = Application.fetch_env(:lemon_core, :secrets)
    previous_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

    Application.put_env(:lemon_core, :secrets, key_providers: [:env])
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    on_exit(fn ->
      _ = Secrets.delete(@name)

      case previous_secrets do
        {:ok, value} -> Application.put_env(:lemon_core, :secrets, value)
        :error -> Application.delete_env(:lemon_core, :secrets)
      end

      if previous_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", previous_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)

    :ok
  end

  test "both methods are admin-only and schema-bound" do
    for {method, module} <- [{"secrets.set", SecretsSet}, {"secrets.delete", SecretsDelete}] do
      assert {:ok, ^module} = Registry.lookup(method)
      assert module.scopes() == [:admin]
    end

    assert Schemas.get("secrets.set").required == %{"name" => :string, "value" => :string}
    assert Schemas.get("secrets.delete").required == %{"name" => :string}

    ctx = %{
      conn_id: "secrets-test",
      conn_pid: self(),
      auth: %{role: :operator, scopes: [:read, :write], token: nil, client_id: nil, identity: nil}
    }

    assert {:error, {:forbidden, _}} =
             Registry.dispatch("secrets.set", %{"name" => @name, "value" => "v"}, ctx)

    assert {:error, :not_found} = Secrets.get(@name)
  end

  test "set stores the secret and returns metadata without the value" do
    params = %{"name" => @name, "value" => "cp-secret-value", "provider" => "cli"}

    assert {:ok, result} = SecretsSet.handle(params, %{})
    assert %{"name" => @name, "owner" => "default", "provider" => "cli"} = result
    refute inspect(result) =~ "cp-secret-value"
    assert {:ok, "cp-secret-value"} = Secrets.get(@name)

    assert {:ok, %{"name" => @name, "deleted" => true}} =
             SecretsDelete.handle(%{"name" => @name}, %{})

    assert {:error, :not_found} = Secrets.get(@name)
  end

  test "a store refusal names a bounded reason and promises nothing was written" do
    System.delete_env("LEMON_SECRETS_MASTER_KEY")

    assert {:error, {:unavailable, "Could not store the secret", details}} =
             SecretsSet.handle(%{"name" => @name, "value" => "never-stored"}, %{})

    assert details == %{
             "reason" => "missing_master_key",
             "retrySafe" => true,
             "mutationMayHaveApplied" => false
           }

    assert {:error, :not_found} = Secrets.get(@name)
  end

  test "rejects malformed parameters before touching the store" do
    for params <- [
          %{"name" => "", "value" => "v"},
          %{"name" => @name, "value" => ""},
          %{"name" => @name, "value" => "v", "expiresAt" => -1},
          %{"name" => @name, "value" => "v", "provider" => ""}
        ] do
      assert {:error, {:invalid_request, _}} = SecretsSet.handle(params, %{})
    end

    assert {:error, {:invalid_request, _}} = SecretsDelete.handle(%{"name" => 7}, %{})
    assert {:error, :not_found} = Secrets.get(@name)
  end
end

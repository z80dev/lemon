defmodule LemonControlPlane.Methods.SecretsMethodsTest do
  @moduledoc "Write-only `secrets.set` / `secrets.delete` for one-shot CLI clients (#667)."
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{Registry, SecretsDelete, SecretsSet}
  alias LemonControlPlane.Protocol.Schemas
  alias LemonCore.{Secrets, Store}
  alias LemonPlatformTest.Testing.Helpers

  @name "CONTROL_PLANE_SECRET_TEST"

  setup do
    previous_secrets = Application.fetch_env(:lemon_core, :secrets)
    table = Secrets.table()
    {:ok, previous_rows} = Store.fetch_all(table)
    key_env = "LEMON_CONTROL_PLANE_SECRETS_TEST_KEY_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case previous_secrets do
        {:ok, value} -> Application.put_env(:lemon_core, :secrets, value)
        :error -> Application.delete_env(:lemon_core, :secrets)
      end

      System.delete_env(key_env)
      Helpers.clear_store_table(table)

      for {key, row} <- previous_rows, do: :ok = Store.put(table, key, row)
    end)

    # The shared table can hold an earlier test's key verifier even with no
    # remaining values. Give the fresh key an empty table for this test only.
    Helpers.clear_store_table(table)
    System.put_env(key_env, Helpers.random_master_key())
    Application.put_env(:lemon_core, :secrets, key_providers: [:env], env_var: key_env)

    %{key_env: key_env}
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

  test "a store refusal names a bounded reason and promises nothing was written",
       %{key_env: key_env} do
    System.delete_env(key_env)

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

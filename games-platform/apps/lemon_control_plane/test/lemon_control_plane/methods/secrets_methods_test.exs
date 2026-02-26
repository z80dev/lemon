defmodule LemonControlPlane.Methods.SecretsMethodsTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{
    SecretsDelete,
    SecretsExists,
    SecretsList,
    SecretsSet,
    SecretsStatus,
    Registry
  }

  alias LemonCore.Secrets
  alias LemonCore.Store

  setup do
    clear_secrets_table()

    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    on_exit(fn ->
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)

    :ok
  end

  test "set/list/exists/delete/status methods work end-to-end" do
    assert {:ok, set_result} = SecretsSet.handle(%{"name" => "cp_secret", "value" => "v1"}, %{})
    assert set_result["ok"] == true
    assert set_result["secret"]["name"] == "cp_secret"

    assert {:ok, exists_result} = SecretsExists.handle(%{"name" => "cp_secret"}, %{})
    assert exists_result["exists"] == true

    assert {:ok, list_result} = SecretsList.handle(%{}, %{})
    assert Enum.any?(list_result["secrets"], &(&1["name"] == "cp_secret"))
    refute inspect(list_result) =~ "\"v1\""

    assert {:ok, status_result} = SecretsStatus.handle(%{}, %{})
    assert status_result["configured"] == true
    assert status_result["count"] >= 1

    assert {:ok, delete_result} = SecretsDelete.handle(%{"name" => "cp_secret"}, %{})
    assert delete_result["ok"] == true

    assert {:ok, exists_result_after} =
             SecretsExists.handle(%{"name" => "cp_secret", "envFallback" => false}, %{})

    assert exists_result_after["exists"] == false
  end

  test "set rejects missing or invalid params" do
    assert {:error, {:invalid_request, _}} = SecretsSet.handle(%{}, %{})
    assert {:error, {:invalid_request, _}} = SecretsSet.handle(%{"name" => "demo"}, %{})

    assert {:error, {:invalid_request, _}} =
             SecretsSet.handle(%{"name" => "demo", "value" => 42}, %{})
  end

  test "registry dispatch enforces scopes for secrets methods" do
    ensure_registry_started()

    assert {:error, {:forbidden, _}} =
             Registry.dispatch(
               "secrets.set",
               %{"name" => "scope_demo", "value" => "x"},
               ctx_with_scopes([:read])
             )

    assert {:ok, _} =
             Registry.dispatch(
               "secrets.set",
               %{"name" => "scope_demo", "value" => "x"},
               ctx_with_scopes([:admin])
             )

    assert {:ok, _} =
             Registry.dispatch(
               "secrets.exists",
               %{"name" => "scope_demo"},
               ctx_with_scopes([:read])
             )
  end

  defp ensure_registry_started do
    case Process.whereis(Registry) do
      nil -> start_supervised!(Registry)
      _pid -> :ok
    end
  end

  defp ctx_with_scopes(scopes) do
    %{
      conn_id: "secrets-test-conn",
      conn_pid: self(),
      auth: %{
        role: :operator,
        scopes: scopes,
        token: nil,
        client_id: nil,
        identity: nil
      }
    }
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end

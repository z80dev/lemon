defmodule LemonCore.SecretsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Clock
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

  test "set/get round-trip works" do
    assert {:ok, metadata} = Secrets.set("demo_secret", "value-123")

    assert metadata.name == "demo_secret"
    assert metadata.owner == "default"
    assert metadata.provider == "manual"

    assert {:ok, "value-123"} = Secrets.get("demo_secret")
  end

  test "expired secret returns expired error" do
    expires_at = Clock.now_ms() - 1_000

    assert {:ok, _metadata} = Secrets.set("expired_secret", "value", expires_at: expires_at)
    assert {:error, :expired} = Secrets.get("expired_secret")
    refute Secrets.exists?("expired_secret", env_fallback: false)
  end

  test "list never returns plaintext values" do
    assert {:ok, _} = Secrets.set("alpha", "first")
    assert {:ok, _} = Secrets.set("beta", "second")

    assert {:ok, listed} = Secrets.list()

    assert Enum.all?(listed, fn item ->
             Map.has_key?(item, :name) and not Map.has_key?(item, :ciphertext)
           end)

    refute inspect(listed) =~ "first"
    refute inspect(listed) =~ "second"
  end

  test "resolve uses store first and env fallback" do
    System.put_env("ENV_ONLY_SECRET", "from-env")
    System.put_env("MISSING_SECRET", "from-env-fallback")

    assert {:ok, _} = Secrets.set("ENV_ONLY_SECRET", "from-store")
    assert {:ok, "from-store", :store} = Secrets.resolve("ENV_ONLY_SECRET")

    assert {:ok, "from-env-fallback", :env} =
             Secrets.resolve("MISSING_SECRET", env_fallback: true)
  after
    System.delete_env("ENV_ONLY_SECRET")
    System.delete_env("MISSING_SECRET")
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end

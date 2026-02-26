defmodule LemonCore.SecretsTest do
  use ExUnit.Case, async: false

  alias LemonCore.Clock
  alias LemonCore.Secrets
  alias LemonCore.Store

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

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

  test "resolve with prefer_env true uses env before store" do
    System.put_env("PREFER_ENV_SECRET", "from-env")
    assert {:ok, _} = Secrets.set("PREFER_ENV_SECRET", "from-store")

    assert {:ok, "from-env", :env} =
             Secrets.resolve("PREFER_ENV_SECRET", prefer_env: true, env_fallback: true)
  after
    System.delete_env("PREFER_ENV_SECRET")
  end

  test "resolve with env_fallback false returns store error when store is missing" do
    System.put_env("NO_FALLBACK_SECRET", "from-env")

    assert {:error, :not_found} =
             Secrets.resolve("NO_FALLBACK_SECRET", prefer_env: false, env_fallback: false)
  after
    System.delete_env("NO_FALLBACK_SECRET")
  end

  test "reading a secret updates usage metadata without changing updated_at" do
    assert {:ok, initial} = Secrets.set("usage_meta_secret", "value-123")
    assert initial.usage_count == 0
    assert initial.last_used_at == nil

    Process.sleep(5)
    assert {:ok, "value-123"} = Secrets.get("usage_meta_secret")
    assert {:ok, [after_read]} = Secrets.list()
    assert after_read.name == "usage_meta_secret"
    assert after_read.usage_count == 1
    assert is_integer(after_read.last_used_at)
    assert after_read.updated_at == initial.updated_at
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end

defmodule LemonCore.Secrets.KeyProviderTest do
  # Mutates :lemon_core app env, so it must not run alongside other tests.
  use ExUnit.Case, async: false

  alias LemonCore.Secrets.KeyProvider
  alias LemonCore.Secrets.MasterKey

  defmodule KeychainDouble do
    def available?, do: true
    def get_master_key(_opts), do: {:ok, Base.encode64(:binary.copy(<<1>>, 32))}
    def put_master_key(_value, _opts), do: :ok
  end

  setup do
    original = Application.get_env(:lemon_core, LemonCore.Secrets)

    on_exit(fn ->
      if original do
        Application.put_env(:lemon_core, LemonCore.Secrets, original)
      else
        Application.delete_env(:lemon_core, LemonCore.Secrets)
      end
    end)

    dir = Path.join(System.tmp_dir!(), "lemon-key-provider-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir, original: original}
  end

  defp put_settings(original, extra) do
    Application.put_env(:lemon_core, LemonCore.Secrets, Keyword.merge(original || [], extra))
  end

  test "defaults preserve the historical provider order" do
    assert KeyProvider.default_order() == [:keychain, :env, :file]
  end

  test "app env can reorder providers", %{dir: dir, original: original} do
    path = Path.join(dir, "master.key")
    File.write!(path, Base.encode64(:binary.copy(<<2>>, 32)))
    put_settings(original, key_providers: [:file, :env], key_file: path)

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> Base.encode64(:binary.copy(<<3>>, 32))
      _ -> nil
    end

    assert {:ok, key, :file} = MasterKey.resolve(env_getter: env_getter)
    assert key == :binary.copy(<<2>>, 32)
  end

  test "app env can drop the keychain entirely", %{original: original} do
    put_settings(original, key_providers: [:env])

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> Base.encode64(:binary.copy(<<4>>, 32))
      _ -> nil
    end

    assert [KeyProvider.Env] == KeyProvider.order([])

    assert {:ok, _key, :env} =
             MasterKey.resolve(keychain_module: KeychainDouble, env_getter: env_getter)
  end

  test "app env can rename the environment variable", %{original: original} do
    put_settings(original, key_providers: [:env], env_var: "ACME_MASTER_KEY")

    env_getter = fn
      "ACME_MASTER_KEY" -> Base.encode64(:binary.copy(<<5>>, 32))
      _ -> nil
    end

    assert MasterKey.env_var() == "ACME_MASTER_KEY"
    assert {:ok, _key, :env} = MasterKey.resolve(env_getter: env_getter)
  end

  test "unknown providers are ignored rather than crashing resolution", %{original: original} do
    put_settings(original, key_providers: [Definitely.Not.A.Module, :env])

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> Base.encode64(:binary.copy(<<6>>, 32))
      _ -> nil
    end

    assert {:ok, _key, :env} = MasterKey.resolve(env_getter: env_getter)
  end

  describe "keychain provider" do
    test "is inert off macOS" do
      refute KeyProvider.Keychain.available?(os_type: {:unix, :linux})
      assert {:error, :unavailable} = KeyProvider.Keychain.fetch(os_type: {:unix, :linux})
      assert {:error, :unavailable} = KeyProvider.Keychain.put("key", os_type: {:unix, :linux})
    end

    test "a substituted module is used on any platform" do
      assert KeyProvider.Keychain.available?(keychain_module: KeychainDouble)
      assert {:ok, _encoded} = KeyProvider.Keychain.fetch(keychain_module: KeychainDouble)
    end
  end

  describe "file provider" do
    test "resolves ~ against the caller-visible home", %{dir: dir} do
      assert KeyProvider.key_file(key_file: "~/.lemon/secrets_master_key", home_dir: dir) ==
               Path.join([dir, ".lemon", "secrets_master_key"])
    end

    test "has no path when home cannot be determined" do
      assert KeyProvider.key_file(env_getter: fn _ -> nil end) == nil
    end

    test "reports the written path", %{dir: dir} do
      path = Path.join(dir, "master.key")
      assert :ok = KeyProvider.File.put(Base.encode64(:binary.copy(<<7>>, 32)), key_file: path)
      assert KeyProvider.File.path(key_file: path) == path
      assert {:ok, _encoded} = KeyProvider.File.fetch(key_file: path)
    end
  end
end

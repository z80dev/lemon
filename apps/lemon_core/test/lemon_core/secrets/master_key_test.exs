defmodule LemonCore.Secrets.MasterKeyTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.MasterKey

  defmodule KeychainOk do
    def available?, do: true

    def get_master_key(_opts) do
      {:ok, Base.encode64(:binary.copy(<<1>>, 32))}
    end

    def put_master_key(_value, _opts), do: :ok
  end

  defmodule KeychainMissing do
    def available?, do: true
    def get_master_key(_opts), do: {:error, :missing}
    def put_master_key(_value, _opts), do: :ok
  end

  defmodule KeychainRecorder do
    def available?, do: true
    def get_master_key(_opts), do: {:error, :missing}

    def put_master_key(value, _opts) do
      send(self(), {:stored_master_key, value})
      :ok
    end
  end

  defmodule KeychainDenied do
    def available?, do: true

    def get_master_key(_opts),
      do: {:error, {:command_failed, 36, "User interaction is not allowed"}}

    def put_master_key(_value, _opts), do: :ok
  end

  defmodule KeychainInvalid do
    def available?, do: true
    def get_master_key(_opts), do: {:ok, "short"}
    def put_master_key(_value, _opts), do: :ok
  end

  defmodule KeychainUnavailable do
    def available?, do: false
    def get_master_key(_opts), do: {:error, :keychain_unavailable}
    def put_master_key(_value, _opts), do: {:error, :unavailable}
  end

  test "resolves master key from keychain first" do
    env_getter = fn _ -> nil end

    assert {:ok, key, :keychain} =
             MasterKey.resolve(keychain_module: KeychainOk, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "falls back to env key when keychain is unavailable" do
    encoded = Base.encode64(:binary.copy(<<4>>, 32))

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> encoded
      _ -> nil
    end

    assert {:ok, key, :env} =
             MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "falls back to ~/.lemon/secrets_master_key when env is missing" do
    temp_home =
      Path.join(System.tmp_dir!(), "lemon-master-key-test-#{System.unique_integer([:positive])}")

    key_path = Path.join([temp_home, ".lemon", "secrets_master_key"])
    File.mkdir_p!(Path.dirname(key_path))

    encoded = Base.encode64(:binary.copy(<<7>>, 32))
    File.write!(key_path, encoded)

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> nil
      "HOME" -> temp_home
    end

    assert {:ok, key, :file} =
             MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "falls back to env master key when keychain has no key" do
    encoded = Base.encode64(:binary.copy(<<2>>, 32))

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> encoded
      _ -> nil
    end

    assert {:ok, key, :env} =
             MasterKey.resolve(keychain_module: KeychainMissing, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "returns keychain failure when keychain lookup fails and env is missing" do
    env_getter = fn _ -> nil end

    assert {:error, {:keychain_failed, {:command_failed, 36, "User interaction is not allowed"}}} =
             MasterKey.resolve(keychain_module: KeychainDenied, env_getter: env_getter)
  end

  test "falls back to env key when keychain lookup fails" do
    encoded = Base.encode64(:binary.copy(<<3>>, 32))

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> encoded
      _ -> nil
    end

    assert {:ok, key, :env} =
             MasterKey.resolve(keychain_module: KeychainDenied, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "returns invalid when keychain key is malformed and env is missing" do
    env_getter = fn _ -> nil end

    assert {:error, :invalid_master_key} =
             MasterKey.resolve(keychain_module: KeychainInvalid, env_getter: env_getter)
  end

  test "uses env key when keychain key is malformed but env is valid" do
    encoded = Base.encode64(:binary.copy(<<5>>, 32))

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> encoded
      _ -> nil
    end

    assert {:ok, key, :env} =
             MasterKey.resolve(keychain_module: KeychainInvalid, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "init generates and writes keychain master key" do
    assert {:ok, %{source: :keychain, configured: true}} =
             MasterKey.init(keychain_module: KeychainRecorder)

    assert_receive {:stored_master_key, stored}
    assert is_binary(stored)
    assert stored != ""
  end

  describe "provider order" do
    setup do
      home =
        Path.join(
          System.tmp_dir!(),
          "lemon-master-key-order-#{System.unique_integer([:positive])}"
        )

      key_path = Path.join([home, ".lemon", "secrets_master_key"])
      File.mkdir_p!(Path.dirname(key_path))
      File.write!(key_path, Base.encode64(:binary.copy(<<9>>, 32)))
      on_exit(fn -> File.rm_rf!(home) end)

      env_getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> Base.encode64(:binary.copy(<<10>>, 32))
        "HOME" -> home
      end

      {:ok, home: home, env_getter: env_getter}
    end

    test "defaults to env before file", %{env_getter: env_getter} do
      assert {:ok, key, :env} =
               MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)

      assert key == :binary.copy(<<10>>, 32)
    end

    test "honours a caller-supplied order", %{env_getter: env_getter} do
      assert {:ok, key, :file} =
               MasterKey.resolve(
                 key_providers: [:file, :env],
                 keychain_module: KeychainUnavailable,
                 env_getter: env_getter
               )

      assert key == :binary.copy(<<9>>, 32)
    end

    test "an order without the keychain never consults it", %{env_getter: env_getter} do
      status =
        MasterKey.status(
          key_providers: [:env],
          keychain_module: KeychainDenied,
          env_getter: env_getter
        )

      assert status.providers == [:env]
      assert status.source == :env
      assert status.keychain_available == false
      assert status.keychain_error == nil
    end

    test "accepts provider modules directly", %{env_getter: env_getter} do
      assert {:ok, key, :env} =
               MasterKey.resolve(
                 key_providers: [LemonCore.Secrets.KeyProvider.Env],
                 env_getter: env_getter
               )

      assert key == :binary.copy(<<10>>, 32)
    end
  end

  describe "key file location" do
    test "reads the configured key file instead of the default path" do
      dir = Path.join(System.tmp_dir!(), "lemon-key-file-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = Path.join(dir, "master.key")
      File.write!(path, Base.encode64(:binary.copy(<<11>>, 32)))
      on_exit(fn -> File.rm_rf!(dir) end)

      env_getter = fn _ -> nil end

      assert {:ok, key, :file} =
               MasterKey.resolve(
                 key_file: path,
                 keychain_module: KeychainUnavailable,
                 env_getter: env_getter
               )

      assert key == :binary.copy(<<11>>, 32)
    end
  end

  describe "weak keys" do
    test "rejects raw string keys" do
      env_getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> "test-key-32-chars-exactly-here!!"
        _ -> nil
      end

      assert {:error, :weak_master_key} =
               MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)
    end

    test "rejection stops the chain so a stale file key cannot mask it" do
      home =
        Path.join(System.tmp_dir!(), "lemon-weak-key-#{System.unique_integer([:positive])}")

      key_path = Path.join([home, ".lemon", "secrets_master_key"])
      File.mkdir_p!(Path.dirname(key_path))
      File.write!(key_path, Base.encode64(:binary.copy(<<12>>, 32)))
      on_exit(fn -> File.rm_rf!(home) end)

      env_getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> "another-raw-passphrase-that-is-long-enough"
        "HOME" -> home
      end

      assert {:error, :weak_master_key} =
               MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)
    end

    test "accepts raw string keys when legacy support is opted into" do
      raw = "test-key-32-chars-exactly-here!!"

      env_getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> raw
        _ -> nil
      end

      assert {:ok, ^raw, :env} =
               MasterKey.resolve(
                 allow_legacy_raw_keys: true,
                 keychain_module: KeychainUnavailable,
                 env_getter: env_getter
               )
    end

    test "still reports short keys as invalid" do
      env_getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> "too-short"
        _ -> nil
      end

      assert {:error, :invalid_master_key} =
               MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)
    end
  end

  describe "init without a keychain" do
    setup do
      home = Path.join(System.tmp_dir!(), "lemon-init-file-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)

      {:ok, home: home, key_path: Path.join([home, ".lemon", "secrets_master_key"])}
    end

    test "writes the key file with 0600 permissions", %{home: home, key_path: key_path} do
      assert {:ok, %{source: :file, configured: true, key_file: ^key_path}} =
               MasterKey.init(keychain_module: KeychainUnavailable, home_dir: home)

      assert {:ok, stat} = File.stat(key_path)
      assert rem(stat.mode, 0o1000) == 0o600
      assert {:ok, dir_stat} = File.stat(Path.dirname(key_path))
      assert rem(dir_stat.mode, 0o1000) == 0o700

      assert {:ok, decoded} = key_path |> File.read!() |> String.trim() |> Base.decode64()
      assert byte_size(decoded) == 32

      env_getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> nil
        "HOME" -> home
      end

      assert {:ok, ^decoded, :file} =
               MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)
    end

    test "refuses to overwrite an existing key file", %{home: home, key_path: key_path} do
      assert {:ok, _} = MasterKey.init(keychain_module: KeychainUnavailable, home_dir: home)
      original = File.read!(key_path)

      assert {:error, {:key_file_exists, ^key_path}} =
               MasterKey.init(keychain_module: KeychainUnavailable, home_dir: home)

      assert File.read!(key_path) == original

      assert {:ok, %{source: :file}} =
               MasterKey.init(keychain_module: KeychainUnavailable, home_dir: home, force: true)

      refute File.read!(key_path) == original
    end

    test "target: :file skips an available keychain", %{home: home, key_path: key_path} do
      assert {:ok, %{source: :file}} =
               MasterKey.init(keychain_module: KeychainRecorder, home_dir: home, target: :file)

      refute_receive {:stored_master_key, _}
      assert File.exists?(key_path)
    end

    test "reports keychain_unavailable when no provider can store a key" do
      assert {:error, :keychain_unavailable} =
               MasterKey.init(
                 keychain_module: KeychainUnavailable,
                 env_getter: fn _ -> nil end,
                 home_dir: nil
               )
    end
  end

  test "status exposes keychain errors" do
    env_getter = fn _ -> nil end
    status = MasterKey.status(keychain_module: KeychainDenied, env_getter: env_getter)

    assert status.keychain_available
    assert status.source == nil
    assert status.keychain_error == {:command_failed, 36, "User interaction is not allowed"}
  end

  test "status reports env source without keychain error when keychain is unavailable" do
    encoded = Base.encode64(:binary.copy(<<6>>, 32))

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> encoded
      _ -> nil
    end

    status = MasterKey.status(keychain_module: KeychainUnavailable, env_getter: env_getter)

    refute status.keychain_available
    assert status.source == :env
    assert status.configured
    assert status.keychain_error == nil
  end

  test "status reports file source when default local master key file exists" do
    temp_home =
      Path.join(
        System.tmp_dir!(),
        "lemon-master-key-status-#{System.unique_integer([:positive])}"
      )

    key_path = Path.join([temp_home, ".lemon", "secrets_master_key"])
    File.mkdir_p!(Path.dirname(key_path))

    encoded = Base.encode64(:binary.copy(<<8>>, 32))
    File.write!(key_path, encoded)

    env_getter = fn
      "LEMON_SECRETS_MASTER_KEY" -> nil
      "HOME" -> temp_home
    end

    status = MasterKey.status(keychain_module: KeychainUnavailable, env_getter: env_getter)

    refute status.keychain_available
    assert status.source == :file
    assert status.configured
    assert status.file_fallback
    assert status.keychain_error == nil
  end
end

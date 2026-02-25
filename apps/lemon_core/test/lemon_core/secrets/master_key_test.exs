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
    env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

    assert {:ok, key, :env} =
             MasterKey.resolve(keychain_module: KeychainUnavailable, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "falls back to env master key when keychain has no key" do
    encoded = Base.encode64(:binary.copy(<<2>>, 32))
    env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

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
    env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

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
    env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

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

  test "status exposes keychain errors" do
    env_getter = fn _ -> nil end
    status = MasterKey.status(keychain_module: KeychainDenied, env_getter: env_getter)

    assert status.keychain_available
    assert status.source == nil
    assert status.keychain_error == {:command_failed, 36, "User interaction is not allowed"}
  end

  test "status reports env source without keychain error when keychain is unavailable" do
    encoded = Base.encode64(:binary.copy(<<6>>, 32))
    env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

    status = MasterKey.status(keychain_module: KeychainUnavailable, env_getter: env_getter)

    refute status.keychain_available
    assert status.source == :env
    assert status.configured
    assert status.keychain_error == nil
  end
end

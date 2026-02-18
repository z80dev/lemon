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

  test "resolves master key from keychain first" do
    env_getter = fn _ -> nil end

    assert {:ok, key, :keychain} =
             MasterKey.resolve(keychain_module: KeychainOk, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "falls back to env master key when keychain has no key" do
    encoded = Base.encode64(:binary.copy(<<2>>, 32))
    env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

    assert {:ok, key, :env} =
             MasterKey.resolve(keychain_module: KeychainMissing, env_getter: env_getter)

    assert byte_size(key) >= 32
  end

  test "init generates and writes keychain master key" do
    assert {:ok, %{source: :keychain, configured: true}} =
             MasterKey.init(keychain_module: KeychainRecorder)

    assert_receive {:stored_master_key, stored}
    assert is_binary(stored)
    assert stored != ""
  end
end

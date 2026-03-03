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

  # -----------------------------------------------------------------
  # Multi-backend tests (no :keychain_module — exercises new path)
  # -----------------------------------------------------------------

  defmodule BackendOk do
    @behaviour LemonCore.Secrets.KeyBackend
    def available?, do: true

    def get_master_key(_opts) do
      {:ok, Base.encode64(:binary.copy(<<7>>, 32))}
    end

    def put_master_key(_value, _opts), do: :ok
    def delete_master_key(_opts), do: :ok
  end

  defmodule BackendMissing do
    @behaviour LemonCore.Secrets.KeyBackend
    def available?, do: true
    def get_master_key(_opts), do: {:error, :missing}

    def put_master_key(_value, _opts), do: :ok
    def delete_master_key(_opts), do: :ok
  end

  defmodule BackendUnavailable do
    @behaviour LemonCore.Secrets.KeyBackend
    def available?, do: false
    def get_master_key(_opts), do: {:error, :unavailable}
    def put_master_key(_value, _opts), do: {:error, :unavailable}
    def delete_master_key(_opts), do: {:error, :unavailable}
  end

  defmodule BackendRecorder do
    @behaviour LemonCore.Secrets.KeyBackend
    def available?, do: true
    def get_master_key(_opts), do: {:error, :missing}

    def put_master_key(value, _opts) do
      send(self(), {:backend_stored, value})
      :ok
    end

    def delete_master_key(_opts), do: :ok
  end

  defmodule BackendFailing do
    @behaviour LemonCore.Secrets.KeyBackend
    def available?, do: true
    def get_master_key(_opts), do: {:error, {:command_failed, 1, "fail"}}
    def put_master_key(_value, _opts), do: {:error, :disk_full}
    def delete_master_key(_opts), do: {:error, :disk_full}
  end

  describe "multi-backend resolution" do
    test "resolves from first available backend" do
      env_getter = fn _ -> nil end

      assert {:ok, key, :backend_ok} =
               MasterKey.resolve(
                 backends: [BackendOk],
                 env_getter: env_getter
               )

      assert byte_size(key) >= 32
    end

    test "skips unavailable backends" do
      env_getter = fn _ -> nil end

      assert {:ok, _key, :backend_ok} =
               MasterKey.resolve(
                 backends: [BackendUnavailable, BackendOk],
                 env_getter: env_getter
               )
    end

    test "skips backends with :missing and tries next" do
      env_getter = fn _ -> nil end

      assert {:ok, _key, :backend_ok} =
               MasterKey.resolve(
                 backends: [BackendMissing, BackendOk],
                 env_getter: env_getter
               )
    end

    test "skips backends that error and tries next" do
      env_getter = fn _ -> nil end

      assert {:ok, _key, :backend_ok} =
               MasterKey.resolve(
                 backends: [BackendFailing, BackendOk],
                 env_getter: env_getter
               )
    end

    test "falls through to env when all backends fail" do
      encoded = Base.encode64(:binary.copy(<<8>>, 32))
      env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

      assert {:ok, _key, :env} =
               MasterKey.resolve(
                 backends: [BackendMissing],
                 env_getter: env_getter
               )
    end

    test "returns :missing_master_key when no backends and no env" do
      env_getter = fn _ -> nil end

      assert {:error, :missing_master_key} =
               MasterKey.resolve(
                 backends: [BackendMissing],
                 env_getter: env_getter
               )
    end
  end

  describe "multi-backend init" do
    test "writes to first available backend" do
      assert {:ok, %{source: :backend_recorder, configured: true}} =
               MasterKey.init(backends: [BackendRecorder])

      assert_receive {:backend_stored, value}
      assert is_binary(value) and value != ""
    end

    test "skips unavailable backends" do
      assert {:ok, %{source: :backend_recorder, configured: true}} =
               MasterKey.init(backends: [BackendUnavailable, BackendRecorder])

      assert_receive {:backend_stored, _}
    end

    test "skips backends that fail to write" do
      assert {:ok, %{source: :backend_recorder, configured: true}} =
               MasterKey.init(backends: [BackendFailing, BackendRecorder])

      assert_receive {:backend_stored, _}
    end

    test "returns :no_backend_available when all backends fail" do
      assert {:error, :no_backend_available} =
               MasterKey.init(backends: [BackendUnavailable])
    end
  end

  describe "multi-backend status" do
    test "includes backends list" do
      env_getter = fn _ -> nil end

      status =
        MasterKey.status(
          backends: [BackendOk],
          env_getter: env_getter
        )

      assert is_list(status.backends)
      assert length(status.backends) == 1
      [entry] = status.backends
      assert entry.backend == :backend_ok
      assert entry.available
      assert entry.result == :ok
    end

    test "reports source from first configured backend" do
      env_getter = fn _ -> nil end

      status =
        MasterKey.status(
          backends: [BackendMissing, BackendOk],
          env_getter: env_getter
        )

      assert status.source == :backend_ok
      assert status.configured
    end

    test "falls back to :env source when no backend has a key" do
      encoded = Base.encode64(:binary.copy(<<9>>, 32))
      env_getter = fn "LEMON_SECRETS_MASTER_KEY" -> encoded end

      status =
        MasterKey.status(
          backends: [BackendMissing],
          env_getter: env_getter
        )

      assert status.source == :env
      assert status.configured
    end

    test "preserves keychain_available backward-compat field" do
      env_getter = fn _ -> nil end

      status =
        MasterKey.status(
          backends: [BackendOk],
          env_getter: env_getter
        )

      # BackendOk is not Keychain, so keychain_available should be false
      refute status.keychain_available
      assert is_nil(status.keychain_error)
    end
  end

  describe "backward compat" do
    test "legacy path still works with :keychain_module" do
      env_getter = fn _ -> nil end

      assert {:ok, _key, :keychain} =
               MasterKey.resolve(keychain_module: KeychainOk, env_getter: env_getter)
    end

    test "legacy status returns no :backends key" do
      env_getter = fn _ -> nil end
      status = MasterKey.status(keychain_module: KeychainOk, env_getter: env_getter)

      refute Map.has_key?(status, :backends)
    end

    test "default_backends returns platform-appropriate list" do
      backends = MasterKey.default_backends()
      assert is_list(backends)
      assert length(backends) >= 1
      # KeyFile should always be present
      assert LemonCore.Secrets.KeyFile in backends
    end
  end
end

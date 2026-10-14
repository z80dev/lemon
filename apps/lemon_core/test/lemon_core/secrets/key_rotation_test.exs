defmodule LemonCore.Secrets.KeyRotationTest do
  # Shares the global Store's secrets table with other suites.
  use ExUnit.Case, async: false

  alias LemonCore.Clock
  alias LemonCore.Secrets
  alias LemonCore.Secrets.{Crypto, KeyProvider, KeyRotation}
  alias LemonCore.Store

  # Reads the real key file, then "crashes" before the new key is stored.
  defmodule CrashBeforeSwitch do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :file

    @impl true
    def fetch(opts), do: KeyProvider.File.fetch(opts)

    @impl true
    def put(_value, _opts), do: raise("simulated crash before the key switch")
  end

  # Stores the new key, then "crashes" before any record is promoted.
  defmodule CrashAfterSwitch do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :file

    @impl true
    def fetch(opts), do: KeyProvider.File.fetch(opts)

    @impl true
    def put(value, opts) do
      :ok = KeyProvider.File.put(value, opts)
      raise "simulated crash after the key switch"
    end
  end

  # A Keychain that accepts the new key and then stops answering for a while,
  # so resolution falls back to a key file that still holds the old key.
  defmodule FlakyKeychain do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :keychain

    @impl true
    def on_invalid, do: :continue

    @impl true
    def fetch(_opts) do
      Agent.get_and_update(__MODULE__, fn
        %{failures: failures} = state when failures > 0 ->
          {{:error, :timeout}, %{state | failures: failures - 1}}

        state ->
          {{:ok, state.key}, state}
      end)
    end

    @impl true
    def put(value, _opts) do
      Agent.update(__MODULE__, &%{&1 | key: value, failures: &1.failures_after_put})
      :ok
    end
  end

  # Pauses inside the key switch until the test sends `:continue`.
  defmodule BlockingFile do
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :file

    @impl true
    def fetch(opts), do: KeyProvider.File.fetch(opts)

    @impl true
    def put(value, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:put_called, self()})

      receive do
        :continue -> KeyProvider.File.put(value, opts)
      end
    end
  end

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    clear_secrets_table()

    dir = Path.join(System.tmp_dir!(), "lemon-key-rotation-#{System.unique_integer([:positive])}")
    key_file = Path.join(dir, "secrets_master_key")
    File.mkdir_p!(dir)
    File.write!(key_file, Base.encode64(:crypto.strong_rand_bytes(32)))
    File.chmod!(key_file, 0o600)

    on_exit(fn ->
      clear_secrets_table()
      File.rm_rf!(dir)
    end)

    # Never the real Keychain, LEMON_SECRETS_MASTER_KEY, or a runtime on the
    # default control port: only the temp file and a port nobody listens on.
    # The directory flush is stubbed so the key-file path runs on any host;
    # the refusal without one is tested separately.
    opts = [
      key_providers: [:file],
      key_file: key_file,
      control_port: closed_port(),
      directory_sync: fn _dir -> :ok end
    ]

    {:ok, key_file: key_file, opts: opts}
  end

  test "rotation re-encrypts every secret under a new key and retires the old one", ctx do
    old_key = read_key(ctx.key_file)

    values = %{
      {"default", "ALPHA"} => "alpha-value",
      {"default", "BETA"} => "beta-value",
      {"other", "GAMMA"} => "gamma-value"
    }

    for {{owner, name}, value} <- values do
      assert {:ok, _} = Secrets.set(name, value, [owner: owner] ++ ctx.opts)
    end

    assert {:ok, "alpha-value", credential_revision} =
             Secrets.get_with_revision("ALPHA", ctx.opts)

    assert {:ok, preview} = KeyRotation.preview(ctx.opts)
    assert %{source: :file, count: 3, expired: 0, resumed: 0} = preview
    assert preview.key_file == ctx.key_file
    assert preview.confirmation_token =~ ~r/\A[0-9a-f]{64}\z/
    assert read_key(ctx.key_file) == old_key

    assert {:ok, %{rotated: 3, pruned: 0, source: :file}} =
             KeyRotation.rotate(preview.confirmation_token, ctx.opts)

    new_key = read_key(ctx.key_file)
    assert byte_size(new_key) == 32
    refute new_key == old_key
    assert Bitwise.band(File.stat!(ctx.key_file).mode, 0o777) == 0o600

    for {{owner, name}, value} <- values do
      assert {:ok, ^value} = Secrets.get(name, [owner: owner] ++ ctx.opts)
    end

    for {_ref, entry} <- Store.list(Secrets.table()) do
      refute Map.has_key?(entry, :staged)
      assert {:ok, _} = Crypto.decrypt(entry, new_key)
      assert {:error, _} = Crypto.decrypt(entry, old_key)
    end

    assert {:ok, "alpha-value", ^credential_revision} =
             Secrets.get_with_revision("ALPHA", ctx.opts)

    assert {:ok, _} =
             Secrets.set_if_revision("ALPHA", "refreshed-alpha", credential_revision, ctx.opts)

    assert {:ok, "refreshed-alpha"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, refreshed_entry} = Store.fetch(Secrets.table(), {"default", "ALPHA"})
    assert {:ok, "refreshed-alpha"} = Crypto.decrypt(refreshed_entry, new_key)
    assert {:error, _} = Crypto.decrypt(refreshed_entry, old_key)
  end

  test "expired secrets are deleted rather than re-encrypted", ctx do
    assert {:ok, _} = Secrets.set("LIVE", "live-value", ctx.opts)

    assert {:ok, _} =
             Secrets.set("STALE", "stale-value", [expires_at: Clock.now_ms() - 1_000] ++ ctx.opts)

    assert {:ok, %{count: 1, expired: 1} = preview} = KeyRotation.preview(ctx.opts)

    assert {:ok, %{rotated: 1, pruned: 1}} =
             KeyRotation.rotate(preview.confirmation_token, ctx.opts)

    assert Store.get(Secrets.table(), {"default", "STALE"}) == nil
    assert {:ok, "live-value"} = Secrets.get("LIVE", ctx.opts)
  end

  test "a stale or missing confirmation is refused without changing anything", ctx do
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(ctx.opts)

    # The value changed after the preview: same names, new revision.
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value-2", ctx.opts)
    key_before = File.read!(ctx.key_file)
    alpha_before = Store.get(Secrets.table(), {"default", "ALPHA"})

    assert {:error, :confirmation_mismatch} = KeyRotation.rotate(token, ctx.opts)
    assert {:error, :confirmation_required} = KeyRotation.rotate("", ctx.opts)

    # A secret added after a fresh preview also invalidates it.
    assert {:ok, %{confirmation_token: fresh}} = KeyRotation.preview(ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)
    assert {:error, :confirmation_mismatch} = KeyRotation.rotate(fresh, ctx.opts)

    assert File.read!(ctx.key_file) == key_before
    assert Store.get(Secrets.table(), {"default", "ALPHA"}) == alpha_before

    refute Enum.any?(Store.list(Secrets.table()), fn {_ref, entry} ->
             Map.has_key?(entry, :staged)
           end)

    assert {:ok, "alpha-value-2"} = Secrets.get("ALPHA", ctx.opts)
  end

  test "a secret the current key cannot decrypt blocks rotation with no change", ctx do
    assert {:ok, _} = Secrets.set("GOOD", "good-value", ctx.opts)

    {:ok, foreign} = Crypto.encrypt("foreign-value", :crypto.strong_rand_bytes(32))
    record = Map.merge(foreign, %{provider: "manual", created_at: 1, updated_at: 1})
    :ok = Store.put(Secrets.table(), {"default", "FOREIGN"}, record)

    key_before = File.read!(ctx.key_file)
    rows_before = Enum.sort(Store.list(Secrets.table()))

    assert {:error, {:undecryptable_secrets, [%{owner: "default", name: "FOREIGN"}]} = reason} =
             KeyRotation.preview(ctx.opts)

    assert KeyRotation.rotate(String.duplicate("0", 64), ctx.opts) == {:error, reason}

    message = KeyRotation.describe_error(reason)
    assert message =~ "1 stored secret(s)"
    assert message =~ "default/FOREIGN"
    refute message =~ "foreign-value"
    refute message =~ "good-value"

    assert File.read!(ctx.key_file) == key_before
    assert Enum.sort(Store.list(Secrets.table())) == rows_before
  end

  test "a crash after re-encryption but before the key switch leaves the store readable",
       ctx do
    old_key = read_key(ctx.key_file)
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)

    crashing = Keyword.put(ctx.opts, :key_providers, [CrashBeforeSwitch])
    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(crashing)

    assert_raise RuntimeError, ~r/before the key switch/, fn ->
      KeyRotation.rotate(token, crashing)
    end

    # Every record was re-encrypted (staged) but the old key is still the one
    # loaded next, and it still opens everything.
    assert read_key(ctx.key_file) == old_key
    assert Enum.all?(Store.list(Secrets.table()), fn {_ref, entry} -> is_map(entry.staged) end)
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)

    # A later rotation starts from that state and completes.
    assert {:ok, %{count: 2, resumed: 0} = preview} = KeyRotation.preview(ctx.opts)
    assert {:ok, %{rotated: 2}} = KeyRotation.rotate(preview.confirmation_token, ctx.opts)
    refute read_key(ctx.key_file) == old_key
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)
  end

  test "a crash after the key switch but before promotion leaves the store readable", ctx do
    old_key = read_key(ctx.key_file)
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)

    crashing = Keyword.put(ctx.opts, :key_providers, [CrashAfterSwitch])
    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(crashing)

    assert_raise RuntimeError, ~r/after the key switch/, fn ->
      KeyRotation.rotate(token, crashing)
    end

    # The new key is loaded next; records still hold old-key ciphertext and
    # are read through their staged copy.
    new_key = read_key(ctx.key_file)
    refute new_key == old_key
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)

    assert {:ok, %{count: 2, resumed: 2} = preview} = KeyRotation.preview(ctx.opts)
    assert {:ok, %{rotated: 2}} = KeyRotation.rotate(preview.confirmation_token, ctx.opts)

    final_key = read_key(ctx.key_file)

    for {_ref, entry} <- Store.list(Secrets.table()) do
      refute Map.has_key?(entry, :staged)
      assert {:ok, _} = Crypto.decrypt(entry, final_key)
    end

    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)
  end

  test "a key supplied by the environment is not rotated", ctx do
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    encoded = File.read!(ctx.key_file)

    env_opts = [
      key_providers: [:env],
      control_port: ctx.opts[:control_port],
      env_getter: fn
        "LEMON_SECRETS_MASTER_KEY" -> encoded
        _ -> nil
      end
    ]

    assert {:error, {:read_only_key_source, :env}} = KeyRotation.preview(env_opts)

    assert {:error, {:read_only_key_source, :env}} =
             KeyRotation.rotate(String.duplicate("0", 64), env_opts)

    assert File.read!(ctx.key_file) == encoded
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", env_opts)
  end

  test "a key switch the provider cannot confirm keeps every secret readable with both keys",
       ctx do
    old_encoded = File.read!(ctx.key_file)
    old_key = read_key(ctx.key_file)

    {:ok, _agent} =
      Agent.start_link(fn -> %{key: old_encoded, failures: 0, failures_after_put: 1_000} end,
        name: FlakyKeychain
      )

    # Keychain first, with a stale key file holding the same old key behind it.
    opts = Keyword.put(ctx.opts, :key_providers, [FlakyKeychain, :file])
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", opts)

    assert {:ok, %{source: :keychain, confirmation_token: token}} = KeyRotation.preview(opts)
    assert {:error, {:key_switch_unverified, :keychain}} = KeyRotation.rotate(token, opts)

    # While the Keychain is unreachable the old key file is what loads.
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", ctx.opts)

    # The Keychain recovers holding the new key: still nothing is lost.
    Agent.update(FlakyKeychain, &%{&1 | failures: 0, failures_after_put: 0})
    {:ok, new_key, :keychain} = LemonCore.Secrets.MasterKey.resolve(opts)
    refute new_key == old_key
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", opts)
    assert {:ok, "beta-value"} = Secrets.get("BETA", opts)

    # A fresh rotation finishes from that state.
    assert {:ok, %{resumed: 2} = preview} = KeyRotation.preview(opts)
    assert {:ok, %{rotated: 2}} = KeyRotation.rotate(preview.confirmation_token, opts)
    {:ok, final_key, :keychain} = LemonCore.Secrets.MasterKey.resolve(opts)

    for {_ref, entry} <- Store.list(Secrets.table()) do
      refute Map.has_key?(entry, :staged)
      assert {:ok, _} = Crypto.decrypt(entry, final_key)
    end
  end

  test "writes during a rotation are serialised and re-encrypted, never left under the old key",
       ctx do
    old_key = read_key(ctx.key_file)
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    assert {:ok, _} = Secrets.set("BETA", "beta-value", ctx.opts)

    blocking =
      ctx.opts
      |> Keyword.put(:key_providers, [BlockingFile])
      |> Keyword.put(:test_pid, self())

    assert {:ok, %{confirmation_token: token}} = KeyRotation.preview(blocking)
    rotation = Task.async(fn -> KeyRotation.rotate(token, blocking) end)
    assert_receive {:put_called, switcher}, 5_000

    # A concurrent `set` waits for the rotation instead of encrypting under
    # the key that is being retired.
    late = Task.async(fn -> Secrets.set("LATE", "late-value", ctx.opts) end)
    assert Task.yield(late, 200) == nil

    # Writers that bypass the lock (a stale runtime, a clobbered record) after
    # verification are caught by convergence, not silently skipped.
    {:ok, stale} = Crypto.encrypt("stale-value", old_key)
    stale_record = Map.merge(stale, %{provider: "manual", created_at: 1, updated_at: 1})
    :ok = Store.put(Secrets.table(), {"default", "STALE_WRITER"}, stale_record)

    alpha = Store.get(Secrets.table(), {"default", "ALPHA"})
    :ok = Store.put(Secrets.table(), {"default", "ALPHA"}, Map.delete(alpha, :staged))

    send(switcher, :continue)
    assert {:ok, %{rotated: 2}} = Task.await(rotation, 10_000)
    assert {:ok, _} = Task.await(late, 10_000)

    new_key = read_key(ctx.key_file)
    refute new_key == old_key

    for {_ref, entry} <- Store.list(Secrets.table()) do
      refute Map.has_key?(entry, :staged)
      assert {:ok, _} = Crypto.decrypt(entry, new_key)
    end

    for {name, value} <- [
          {"ALPHA", "alpha-value"},
          {"BETA", "beta-value"},
          {"STALE_WRITER", "stale-value"},
          {"LATE", "late-value"}
        ] do
      assert {:ok, ^value} = Secrets.get(name, ctx.opts)
    end
  end

  test "rotation refuses while a Lemon runtime answers on the control port", ctx do
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    running = Keyword.put(ctx.opts, :control_port, fake_runtime_port())
    key_before = File.read!(ctx.key_file)

    assert {:ok, %{runtime_running: true, confirmation_token: token}} =
             KeyRotation.preview(running)

    assert {:error, :runtime_running} = KeyRotation.rotate(token, running)
    assert KeyRotation.describe_error(:runtime_running) =~ "lemon stop"
    assert File.read!(ctx.key_file) == key_before

    refute Enum.any?(Store.list(Secrets.table()), fn {_ref, entry} ->
             Map.has_key?(entry, :staged)
           end)
  end

  test "a key file is not rotated where its replacement cannot be made durable", ctx do
    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", ctx.opts)
    key_before = File.read!(ctx.key_file)
    rows_before = Enum.sort(Store.list(Secrets.table()))
    {:ok, %{confirmation_token: token}} = KeyRotation.preview(ctx.opts)

    unsupported =
      Keyword.put(ctx.opts, :directory_sync, fn _dir -> {:error, :directory_sync_unsupported} end)

    assert {:error, {:key_file_not_durable, :directory_sync_unsupported} = reason} =
             KeyRotation.preview(unsupported)

    assert {:error, ^reason} = KeyRotation.rotate(token, unsupported)
    assert KeyRotation.describe_error(reason) =~ "Keychain"
    assert File.read!(ctx.key_file) == key_before
    assert Enum.sort(Store.list(Secrets.table())) == rows_before
    assert {:ok, "alpha-value"} = Secrets.get("ALPHA", ctx.opts)
  end

  test "rotation retains proofs and tombstones while invalidating original bindings", ctx do
    opts = Keyword.put(ctx.opts, :node_id, "receipt-node")
    assert {:ok, _} = Secrets.set("LIVE", "live", [operation_id: "live"] ++ opts)
    assert {:ok, _} = Secrets.set("DELETED", "deleted", [operation_id: "deleted"] ++ opts)
    assert :ok = Secrets.delete("DELETED", opts)
    assert {:ok, _} = Secrets.set("EXPIRED", "expired", [operation_id: "expired"] ++ opts)
    expired = Store.get(Secrets.table(), {"default", "EXPIRED"})
    :ok = Store.put(Secrets.table(), {"default", "EXPIRED"}, Map.put(expired, :expires_at, Clock.now_ms() - 1))
    assert {:ok, %{count: 1, expired: 1} = preview} = KeyRotation.preview(opts)
    assert {:ok, %{rotated: 1, pruned: 1}} = KeyRotation.rotate(preview.confirmation_token, opts)

    assert {:ok, "live"} = Secrets.get("LIVE", opts)
    assert {:ok, [%{name: "LIVE"}]} = Secrets.list(opts)
    for id <- ["live", "deleted", "expired"] do
      assert {:ok, %{status: "applied", current_binding_matches: false}} = Secrets.receipt(id, opts)
      assert {:error, :secret_operation_conflict} = Secrets.set(String.upcase(id), id, [operation_id: id] ++ opts)
    end
    assert LemonCore.Secrets.Receipts.receipt_only?(Store.get(Secrets.table(), {"default", "DELETED"}))
    assert LemonCore.Secrets.Receipts.receipt_only?(Store.get(Secrets.table(), {"default", "EXPIRED"}))
  end

  defp read_key(path), do: path |> File.read!() |> String.trim() |> Base.decode64!()

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Answers /healthz like a live Lemon control plane until the test exits.
  defp fake_runtime_port do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    spawn_link(fn -> serve_health(listen) end)
    port
  end

  defp serve_health(listen) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      _ = :gen_tcp.recv(socket, 0, 1_000)
      body = ~s({"ok":true})

      :gen_tcp.send(
        socket,
        "HTTP/1.0 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n" <> body
      )

      :gen_tcp.close(socket)
      serve_health(listen)
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> Store.list()
    |> Enum.each(fn {key, _value} -> Store.delete(Secrets.table(), key) end)
  end
end

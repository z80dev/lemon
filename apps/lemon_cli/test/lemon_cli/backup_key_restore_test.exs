defmodule LemonCli.BackupKeyRestoreTest do
  @moduledoc """
  Regression: a backup restore and the master-key lifecycle (initialization,
  rotation) never interleave, including for a key file configured at a
  nested path inside the restore target. Interleavings are forced with
  message barriers, not sleeps.
  """
  # Rotation uses the global Store's secrets table.
  use ExUnit.Case, async: false

  alias LemonCli.Backup
  alias LemonCli.Secrets.KeyRotation
  alias LemonCore.Secrets
  alias LemonCore.Secrets.{KeyLock, KeyProvider, MasterKey}
  alias LemonCore.Store

  @moduletag :tmp_dir

  # File provider that announces the key switch and waits for the test.
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

  setup %{tmp_dir: tmp_dir} do
    source_home = Path.join(tmp_dir, "source_home")
    source = Path.join(source_home, ".lemon")
    File.mkdir_p!(Path.join(source, "keys"))
    File.write!(Path.join(source, "config.toml"), "[defaults]\nprovider = \"test\"\n")
    backed_up_key = MasterKey.generate_encoded_key()
    File.write!(Path.join(source, "keys/master"), backed_up_key <> "\n")
    File.chmod!(Path.join(source, "keys/master"), 0o600)

    bundle = Path.join(tmp_dir, "keys.lemonbackup")

    assert {:ok, _} =
             Backup.create(
               paths_opts: [home_dir: source_home],
               output: bundle,
               include_credentials: true
             )

    target_home = Path.join(tmp_dir, "target_home")
    key_path = Path.join([target_home, ".lemon", "keys", "master"])
    File.mkdir_p!(target_home)

    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    clear = fn ->
      for {ref, _} <- Store.list(Secrets.table()), do: Store.delete(Secrets.table(), ref)
    end

    clear.()
    on_exit(clear)

    {:ok,
     bundle: bundle,
     backed_up_key: backed_up_key,
     target_home: target_home,
     target: Path.join(target_home, ".lemon"),
     key_path: key_path,
     init_opts: [key_file: key_path, key_providers: [:file], env_getter: fn _ -> nil end]}
  end

  defp restore(ctx, hook, extra \\ []) do
    Backup.restore(
      ctx.bundle,
      [
        paths_opts: [home_dir: ctx.target_home],
        secrets_opts: [key_file: ctx.key_path],
        after_runtime_check: hook
      ] ++ extra
    )
  end

  defp read_key(path), do: path |> File.read!() |> String.trim()

  test "a key initialized before the restore installs is never replaced", ctx do
    hook = fn -> assert {:ok, %{source: :file}} = MasterKey.init(ctx.init_opts) end

    assert {:error, _reason} = restore(ctx, hook)

    {:ok, key, :file} = MasterKey.resolve(ctx.init_opts)
    refute Base.encode64(key) == ctx.backed_up_key
    assert read_key(ctx.key_path) == Base.encode64(key)
  end

  test "a restore waits for an init holding the nested key-file lock", ctx do
    parent = self()

    holder =
      Task.async(fn ->
        KeyLock.with_lock(ctx.init_opts, fn ->
          send(parent, :held)
          receive(do: (:go -> :ok))
          MasterKey.init(ctx.init_opts)
        end)
      end)

    assert_receive :held
    restorer = Task.async(fn -> restore(ctx, fn -> send(parent, :restore_at_lock) end) end)

    # The restore has verified everything and now needs the key lock that the
    # initializer holds; only then may the initializer publish its key.
    assert_receive :restore_at_lock, 10_000
    # While the initializer holds the lock the restore cannot finish (the
    # bound only detects a restore that wrongly ran; correctness never
    # depends on it).
    assert Task.yield(restorer, 1_000) == nil
    send(holder.pid, :go)

    assert {:ok, %{source: :file}} = Task.await(holder, 15_000)
    assert {:error, _conflict} = Task.await(restorer, 15_000)

    {:ok, key, :file} = MasterKey.resolve(ctx.init_opts)
    assert read_key(ctx.key_path) == Base.encode64(key)
  end

  test "an authorized overwrite restore waits for a rotation of the nested key file", ctx do
    assert {:ok, _} = MasterKey.init(ctx.init_opts)
    original = read_key(ctx.key_path)
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)

    rotation_opts = [
      key_providers: [BlockingFile],
      key_file: ctx.key_path,
      control_port: port,
      directory_sync: fn _dir -> :ok end,
      test_pid: self()
    ]

    assert {:ok, _} = Secrets.set("ALPHA", "alpha-value", rotation_opts)
    {:ok, %{confirmation_token: token}} = KeyRotation.preview(rotation_opts)
    rotator = Task.async(fn -> KeyRotation.rotate(token, rotation_opts) end)

    # Rotation now holds the key lock inside its key switch.
    assert_receive {:put_called, put_pid}, 10_000

    {:ok, summary} = Backup.verify(ctx.bundle, target: ctx.target)
    parent = self()

    restorer =
      Task.async(fn ->
        restore(ctx, fn -> send(parent, :restore_at_lock) end,
          overwrite: true,
          confirmation: summary.overwrite_confirmation
        )
      end)

    assert_receive :restore_at_lock, 10_000
    assert Task.yield(restorer, 1_000) == nil
    send(put_pid, :continue)

    assert {:ok, %{rotated: 1}} = Task.await(rotator, 15_000)
    assert {:ok, %{rollback_path: rollback}} = Task.await(restorer, 15_000)

    # The restore ran after the rotation finished: what it moved aside is the
    # rotated key, and what it installed is the backed-up key.
    rotated = read_key(Path.join(rollback, "keys/master"))
    refute rotated == original
    assert read_key(ctx.key_path) == ctx.backed_up_key
  end
end

defmodule LemonCore.Secrets.MasterKeyReplacementTest do
  @moduledoc """
  Regression tests: an existing master key is never silently replaced, key
  initialization is race-free across providers, the store's key verifier
  refuses writes and fallbacks under another key, and every entry point
  resolves the same key.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Secrets
  alias LemonCore.Secrets.{Crypto, KeyCheck, KeyLock, KeyProvider, MasterKey}
  alias LemonCore.Store

  # Backing module for the keychain provider that is available on every
  # platform and drives the real `Keychain` wrapper through a fake runner.
  defmodule RunnerKeychain do
    alias LemonCore.Secrets.Keychain
    def available?, do: true
    def get_master_key(opts), do: Keychain.get_master_key(opts)
    def put_master_key(value, opts), do: Keychain.put_master_key(value, opts)
  end

  # Emulates `security(1)` for one generic-password item: `add` without `-U`
  # on an existing item fails with errSecDuplicateItem (45), as the real tool
  # does. The state lives in an Agent so concurrent initializers share it.
  defp fake_security(find_result \\ nil) do
    {:ok, agent} = Agent.start_link(fn -> %{item: nil, calls: []} end)

    runner = fn "security", args, _opts ->
      Agent.get_and_update(agent, fn state ->
        state = %{state | calls: state.calls ++ [args]}

        case args do
          ["find-generic-password" | _] ->
            reply =
              find_result ||
                if state.item, do: {state.item <> "\n", 0}, else: {"not found", 44}

            {reply, state}

          ["add-generic-password" | rest] ->
            value = List.last(rest)

            cond do
              "-U" in rest -> {{"", 0}, %{state | item: value}}
              state.item -> {{"already exists", 45}, state}
              true -> {{"", 0}, %{state | item: value}}
            end
        end
      end)
    end

    {agent, runner}
  end

  defp adds(agent),
    do: Enum.filter(Agent.get(agent, & &1.calls), &match?(["add-generic-password" | _], &1))

  setup do
    home = Path.join(System.tmp_dir!(), "lemon_mk_replace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".lemon"))
    on_exit(fn -> File.rm_rf!(home) end)
    {:ok, home: home, key_path: Path.join([home, ".lemon", "secrets_master_key"])}
  end

  defp keychain_opts(runner, home, extra \\ []) do
    [
      keychain_module: RunnerKeychain,
      runner: runner,
      key_providers: [:keychain],
      home_dir: home,
      env_getter: fn _ -> nil end
    ]
    |> Keyword.merge(extra)
  end

  describe "keychain provider" do
    test "a second init never issues -U and leaves the first key decrypting", %{home: home} do
      {agent, runner} = fake_security()
      opts = keychain_opts(runner, home)

      assert {:ok, %{source: :keychain}} = MasterKey.init(opts)
      assert {:ok, first_key, :keychain} = MasterKey.resolve(opts)
      {:ok, sealed} = Crypto.encrypt("survives", first_key)

      assert {:error, :master_key_exists} = MasterKey.init(opts)

      calls = Agent.get(agent, & &1.calls)
      refute Enum.any?(calls, &("-U" in &1)), "init must never pass -U: #{inspect(calls)}"
      assert {:ok, ^first_key, :keychain} = MasterKey.resolve(opts)
      assert {:ok, "survives"} = Crypto.decrypt(sealed, first_key)
    end

    test "an add racing an existing item is reported as :master_key_exists", %{home: home} do
      {agent, runner} = fake_security({"not found", 44})
      Agent.update(agent, &%{&1 | item: MasterKey.generate_encoded_key()})

      assert {:error, :master_key_exists} = MasterKey.init(keychain_opts(runner, home))
    end

    test "a keychain read failure refuses init without writing", %{home: home} do
      {agent, runner} = fake_security({"User interaction is not allowed.", 36})

      assert {:error, {:master_key_check_failed, {:keychain_failed, _}}} =
               MasterKey.init(keychain_opts(runner, home))

      assert adds(agent) == []
    end

    test "force: true replaces the item with -U", %{home: home} do
      {agent, runner} = fake_security()
      opts = keychain_opts(runner, home)

      assert {:ok, _} = MasterKey.init(opts)
      {:ok, first_key, :keychain} = MasterKey.resolve(opts)
      assert {:ok, _} = MasterKey.init([force: true] ++ opts)
      assert {:ok, second_key, :keychain} = MasterKey.resolve(opts)
      refute second_key == first_key
      assert Enum.any?(adds(agent), &("-U" in &1))
    end
  end

  describe "existing key in another provider" do
    test "a key in the env var blocks provisioning the keychain", %{home: home} do
      {agent, runner} = fake_security()
      env = MasterKey.generate_encoded_key()

      opts =
        keychain_opts(runner, home,
          key_providers: [:keychain, :env],
          env_getter: fn
            "LEMON_SECRETS_MASTER_KEY" -> env
            _ -> nil
          end
        )

      assert {:error, :master_key_exists} = MasterKey.init(opts)
      assert adds(agent) == []
    end
  end

  describe "file provider" do
    defp file_opts(home),
      do: [home_dir: home, key_providers: [:file], env_getter: fn _ -> nil end]

    test "an unreadable key file still counts as occupied", %{home: home, key_path: path} do
      opts = file_opts(home)
      original = MasterKey.generate_encoded_key() <> "\n"
      File.write!(path, original)
      File.chmod!(path, 0o000)
      on_exit(fn -> File.chmod(path, 0o600) end)

      assert {:error, {:key_file_exists, ^path}} =
               KeyProvider.File.put(MasterKey.generate_encoded_key(), opts)

      assert {:error, {:master_key_check_failed, {:key_provider_failed, :file, _}}} =
               MasterKey.init(opts)

      File.chmod!(path, 0o600)
      assert File.read!(path) == original
    end

    test "a dangling key-file symlink counts as occupied", %{home: home, key_path: path} do
      File.ln_s!(Path.join(home, "elsewhere"), path)

      assert {:error, :master_key_exists} = MasterKey.init(file_opts(home))
      refute File.exists?(Path.join(home, "elsewhere"))
    end

    test "an empty key file is not replaced without force", %{home: home, key_path: path} do
      File.write!(path, "")

      assert {:error, :master_key_exists} = MasterKey.init(file_opts(home))
      assert File.read!(path) == ""
    end

    test "a failed occupancy check is an error, not a free slot", %{home: home} do
      dir = Path.join(home, "locked")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o000)
      on_exit(fn -> File.chmod(dir, 0o700) end)

      opts = [key_file: Path.join([dir, "sub", "key"]), key_providers: [:file]]

      assert {:error, {:key_file_check_failed, :eacces}} =
               KeyProvider.File.put(MasterKey.generate_encoded_key(), opts)
    end
  end

  describe "concurrent initialization" do
    test "initializers in separate OS processes publish exactly one key", %{home: home} do
      count = 4
      key_path = Path.join([home, ".lemon", "keys", "master"])
      barrier = Path.join(home, "go")

      script = """
      dir = System.fetch_env!("T07B_DIR")
      File.write!(Path.join(dir, "ready-" <> System.fetch_env!("T07B_ID")), "")
      wait = fn wait ->
        unless File.exists?(System.fetch_env!("T07B_GO")), do: (Process.sleep(2); wait.(wait))
      end
      wait.(wait)
      result =
        LemonCore.Secrets.MasterKey.init(
          key_file: System.fetch_env!("T07B_KEY"),
          key_providers: [:file],
          env_getter: fn _ -> nil end
        )
      IO.write("RESULT " <> inspect(result))
      """

      code_paths = Enum.flat_map(:code.get_path(), &["-pa", to_string(&1)])

      tasks =
        for id <- 1..count do
          Task.async(fn ->
            System.cmd("elixir", code_paths ++ ["-e", script],
              env: [
                {"T07B_DIR", home},
                {"T07B_ID", to_string(id)},
                {"T07B_GO", barrier},
                {"T07B_KEY", key_path}
              ],
              stderr_to_stdout: true
            )
          end)
        end

      # Start barrier: every OS process is up and spinning before any runs init.
      ready = fn ready ->
        n = home |> File.ls!() |> Enum.count(&String.starts_with?(&1, "ready-"))

        if n < count,
          do:
            (
              Process.sleep(10)
              ready.(ready)
            )
      end

      ready.(ready)
      File.write!(barrier, "")

      results =
        for {output, 0} <- Task.await_many(tasks, 60_000) do
          [_, result] = String.split(output, "RESULT ", parts: 2)
          result
        end

      assert length(results) == count, inspect(results)
      assert Enum.count(results, &String.starts_with?(&1, "{:ok,")) == 1, inspect(results)
      assert Enum.count(results, &(&1 == "{:error, :master_key_exists}")) == count - 1

      opts = [key_file: key_path, key_providers: [:file], env_getter: fn _ -> nil end]
      assert {:ok, _key, :file} = MasterKey.resolve(opts)
    end

    defp race(count, fun) do
      parent = self()

      tasks =
        for index <- 1..count do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> fun.(index)
            end
          end)
        end

      pids = for _ <- tasks, do: receive(do: ({:ready, pid} -> pid))
      Enum.each(pids, &send(&1, :go))
      Task.await_many(tasks, 30_000)
    end

    test "racing initializers of one provider publish exactly one key", %{
      home: home,
      key_path: path
    } do
      results = race(8, fn _ -> MasterKey.init(file_opts(home)) end)

      assert [{:ok, %{source: :file}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :master_key_exists})) == 7

      {:ok, key, :file} = MasterKey.resolve(file_opts(home))
      assert {:ok, ^key} = path |> File.read!() |> String.trim() |> Base.decode64()
    end

    test "racing initializers of different providers create one key", %{home: home} do
      {agent, runner} = fake_security()
      opts = keychain_opts(runner, home, key_providers: [:keychain, :file])

      results =
        race(8, fn index ->
          target = if rem(index, 2) == 0, do: :file, else: :keychain
          MasterKey.init([target: target] ++ opts)
        end)

      assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :master_key_exists})) == 7

      assert length(adds(agent)) + if(File.exists?(KeyProvider.key_file(opts)), do: 1, else: 0) ==
               1

      assert {:ok, _key, _source} = MasterKey.resolve(opts)
    end

    test "an initializer waits for the key lock and then sees the key", %{home: home} do
      opts = file_opts(home)
      parent = self()

      holder =
        Task.async(fn ->
          KeyLock.with_lock(opts, fn ->
            send(parent, :locked)
            receive(do: (:release -> :ok))
            MasterKey.init(opts)
          end)
        end)

      assert_receive :locked
      contender = Task.async(fn -> MasterKey.init(opts) end)
      Process.sleep(100)
      send(holder.pid, :release)

      assert {:ok, %{source: :file}} = Task.await(holder)
      assert {:error, :master_key_exists} = Task.await(contender)
    end
  end

  describe "one resolution contract" do
    test "different keys in env and file fail instead of depending on order", %{
      home: home,
      key_path: path
    } do
      File.write!(path, MasterKey.generate_encoded_key())
      env = MasterKey.generate_encoded_key()

      getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> env
        "HOME" -> home
        _ -> nil
      end

      for order <- [[:env, :file], [:file, :env]] do
        opts = [key_providers: order, env_getter: getter, home_dir: home]
        assert {:error, {:conflicting_master_keys, sources}} = MasterKey.resolve(opts)
        assert Enum.sort(sources) == [:env, :file]
        assert {:error, {:conflicting_master_keys, _}} = MasterKey.resolve_fresh(opts)
      end
    end

    test "the same key in env and file resolves", %{home: home, key_path: path} do
      encoded = MasterKey.generate_encoded_key()
      File.write!(path, encoded)

      opts = [
        key_providers: [:env, :file],
        env_getter: fn
          "LEMON_SECRETS_MASTER_KEY" -> encoded
          _ -> nil
        end,
        home_dir: home
      ]

      assert {:ok, _key, :env} = MasterKey.resolve(opts)
    end

    test "a launcher keychain preload stands in only for the keychain provider", %{home: home} do
      {_agent, runner} = fake_security({"User interaction is not allowed.", 36})
      preload = MasterKey.generate_encoded_key()
      file_key = MasterKey.generate_encoded_key()
      File.write!(Path.join([home, ".lemon", "secrets_master_key"]), file_key)

      opts = keychain_opts(runner, home, key_providers: [:keychain, :file])

      assert {:error, {:conflicting_master_keys, [:keychain, :file]}} =
               MasterKey.resolve([keychain_preload: preload] ++ opts)

      assert {:ok, _key, :file} =
               MasterKey.resolve(
                 [keychain_preload: preload] ++ Keyword.put(opts, :key_providers, [:file])
               )
    end
  end

  describe "store key verifier" do
    setup do
      case Store.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      clear = fn ->
        Store.list(Secrets.table())
        |> Enum.each(fn {key, _} -> Store.delete(Secrets.table(), key) end)
      end

      clear.()
      on_exit(clear)

      key_a = MasterKey.generate_encoded_key()
      key_b = MasterKey.generate_encoded_key()

      opts = fn key ->
        [
          key_providers: [:env],
          env_getter: fn
            "LEMON_SECRETS_MASTER_KEY" -> key
            "T07B_ONE" -> "from-env"
            _ -> nil
          end
        ]
      end

      {:ok, key_a: Base.decode64!(key_a), under_a: opts.(key_a), under_b: opts.(key_b)}
    end

    test "writes and reads under a different key are refused as a mismatch", ctx do
      assert {:ok, _} = Secrets.set("t07b_one", "value-a", ctx.under_a)

      assert {:error, :master_key_mismatch} = Secrets.set("t07b_two", "value-b", ctx.under_b)

      assert {:error, :master_key_mismatch} =
               Secrets.get("t07b_one", [env_fallback: false] ++ ctx.under_b)

      {:ok, "value-a", revision} = Secrets.get_with_revision("t07b_one", ctx.under_a)

      assert {:error, :master_key_mismatch} =
               Secrets.set_if_revision("t07b_one", "value-b", revision, ctx.under_b)

      {:ok, snapshot} = Secrets.snapshot("t07b_one", ctx.under_a)
      :ok = Secrets.delete("t07b_one", ctx.under_a)
      assert {:error, :master_key_mismatch} = Secrets.restore("t07b_one", snapshot, ctx.under_b)
      assert {:ok, _} = Secrets.restore("t07b_one", snapshot, ctx.under_a)

      assert {:ok, "value-a"} = Secrets.get("t07b_one", ctx.under_a)
      assert {:error, :not_found} = Secrets.get("t07b_two", [env_fallback: false] ++ ctx.under_a)
    end

    test "a mismatch never falls through to env or external credentials", ctx do
      assert {:ok, _} = Secrets.set("T07B_ONE", "value-a", ctx.under_a)

      assert {:error, :master_key_mismatch} = Secrets.resolve("T07B_ONE", ctx.under_b)
      assert {:error, :master_key_mismatch} = Secrets.resolve_local("T07B_ONE", ctx.under_b)
      assert {:ok, "value-a", :store} = Secrets.resolve("T07B_ONE", ctx.under_a)
    end

    test "conflicting or failing key providers never fall through to env", ctx do
      key_path = Path.join([ctx.home, ".lemon", "secrets_master_key"])
      File.write!(key_path, Base.encode64(ctx.key_a))
      stale = MasterKey.generate_encoded_key()

      getter = fn
        "LEMON_SECRETS_MASTER_KEY" -> stale
        "T07B_ONE" -> "from-env"
        _ -> nil
      end

      file_only = [key_providers: [:file], home_dir: ctx.home, env_getter: getter]
      assert {:ok, _} = Secrets.set("T07B_ONE", "value-a", file_only)

      # A stale env key beside the file key: a conflict, not a fallback.
      conflicting = Keyword.put(file_only, :key_providers, [:file, :env])

      for resolve <- [&Secrets.resolve/2, &Secrets.resolve_local/2] do
        assert {:error, {:conflicting_master_keys, [:file, :env]}} =
                 resolve.("T07B_ONE", conflicting)
      end

      # An unreadable key file is a provider failure, not an absent key.
      File.chmod!(key_path, 0o000)
      on_exit(fn -> File.chmod(key_path, 0o600) end)

      for resolve <- [&Secrets.resolve/2, &Secrets.resolve_local/2] do
        assert {:error, {:key_provider_failed, :file, _}} = resolve.("T07B_ONE", file_only)
      end

      File.chmod!(key_path, 0o600)
      assert {:ok, "value-a", :store} = Secrets.resolve("T07B_ONE", file_only)
    end

    test "the verifier survives deletion of every secret", ctx do
      assert {:ok, _} = Secrets.set("t07b_only", "value-a", ctx.under_a)
      :ok = Secrets.delete("t07b_only", ctx.under_a)
      assert {:ok, []} = Secrets.list(ctx.under_a)

      assert {:error, :master_key_mismatch} = Secrets.set("t07b_new", "value-b", ctx.under_b)
      assert {:ok, _} = Secrets.set("t07b_new", "value-a", ctx.under_a)
    end

    test "the verifier survives expiry and receipt-only tombstones", ctx do
      past = LemonCore.Clock.now_ms() - 1_000

      assert {:ok, _} =
               Secrets.set(
                 "t07b_receipt",
                 "value-a",
                 [operation_id: "op-t07b-1", node_id: "node-t07b"] ++ ctx.under_a
               )

      :ok = Secrets.delete("t07b_receipt", ctx.under_a)
      assert {:ok, _} = Secrets.set("t07b_old", "value-a", [expires_at: past] ++ ctx.under_a)

      assert {:error, :master_key_mismatch} = Secrets.set("t07b_new", "value-b", ctx.under_b)
    end

    test "an interrupted rotation blocks writes under either key", ctx do
      assert {:ok, _} = Secrets.set("t07b_one", "value-a", ctx.under_a)

      {:ok, key_b, :env} = MasterKey.resolve(ctx.under_b)
      :ok = KeyCheck.begin_rotation(ctx.key_a, key_b)

      assert {:error, :key_rotation_incomplete} = Secrets.set("t07b_x", "a", ctx.under_a)
      assert {:error, :key_rotation_incomplete} = Secrets.set("t07b_x", "b", ctx.under_b)
      assert {:error, :key_rotation_incomplete} = Secrets.set("t07b_x", "a", ctx.under_a)

      assert {:error, :key_rotation_unresolved} = KeyCheck.check_rotation(ctx.key_a)
      assert :ok = KeyCheck.check_rotation(key_b)

      assert {:error, :master_key_mismatch} =
               KeyCheck.check_rotation(:crypto.strong_rand_bytes(32))

      assert {:ok, "value-a"} = Secrets.get("t07b_one", ctx.under_a)
    end

    test "legacy stores migrate only under a key that opens every record", ctx do
      assert {:ok, _} = Secrets.set("t07b_one", "value-a", ctx.under_a)
      :ok = Store.delete(Secrets.table(), :key_check)

      assert {:error, :master_key_mismatch} = Secrets.set("t07b_two", "b", ctx.under_b)
      assert {:ok, nil} = KeyCheck.fetch()

      assert {:ok, _} = Secrets.set("t07b_two", "a", ctx.under_a)
      assert {:ok, %{next: nil}} = KeyCheck.fetch()
      assert {:error, :master_key_mismatch} = Secrets.set("t07b_three", "b", ctx.under_b)
    end

    test "an empty store accepts any key", ctx do
      assert {:ok, _} = Secrets.set("t07b_first", "value", ctx.under_b)
      assert {:ok, "value"} = Secrets.get("t07b_first", ctx.under_b)
    end
  end
end

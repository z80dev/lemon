defmodule LemonCli.SecretsCommandTestClient do
  @moduledoc false
  # Control-plane double: records each request and answers with the reply the
  # test stored in its own process dictionary (`CLI.run/1` runs in-process).
  def request(method, params, opts) do
    send(self(), {:control_plane_request, method, params, opts})
    Process.get(:secrets_command_reply, {:error, {:control_plane_unavailable, :econnrefused}})
  end
end

defmodule LemonCli.SecretsCommandTest do
  @moduledoc """
  The shipped `lemon secrets` command through `LemonCli.CLI.run/1`: stdout,
  stderr and exit codes for every subcommand (#717), and writes that defer to
  a running runtime owning the store (#667).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCore.Secrets
  alias LemonCore.Secrets.EnvCatalog

  @moduletag :tmp_dir

  defmodule FailingKeychain do
    @moduledoc false
    use LemonCore.Secrets.KeyProvider

    @impl true
    def name, do: :keychain

    @impl true
    def fetch(_opts), do: {:error, :timeout}
  end

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    env =
      Map.new(
        ["HOME", "LEMON_SECRETS_MASTER_KEY", "LEMON_SECRETS_KEYCHAIN_PRELOAD"],
        &{&1, System.get_env(&1)}
      )

    secrets_config = Application.fetch_env(:lemon_core, :secrets)

    # Never the developer's Keychain: env, then a key file under the test HOME.
    Application.put_env(:lemon_core, :secrets, key_providers: [:env, :file])
    System.put_env("HOME", home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    System.delete_env("LEMON_SECRETS_KEYCHAIN_PRELOAD")
    clear_secrets_table()

    on_exit(fn ->
      clear_secrets_table()
      Enum.each(env, fn {name, value} -> restore_env(name, value) end)

      case secrets_config do
        {:ok, config} -> Application.put_env(:lemon_core, :secrets, config)
        :error -> Application.delete_env(:lemon_core, :secrets)
      end
    end)

    %{home: home}
  end

  describe "list" do
    test "prints the empty-store line" do
      assert run(["secrets", "list"]) == {0, "No secrets configured\n", ""}
    end

    test "golden output: sorted metadata, never values" do
      assert {:ok, _} = Secrets.set("ZETA_KEY", "zeta-plaintext")

      assert {:ok, _} =
               Secrets.set("ALPHA_KEY", "alpha-plaintext",
                 provider: "anthropic",
                 expires_at: 4_102_444_800_000
               )

      assert run(["secrets", "list"]) ==
               {0,
                """
                ALPHA_KEY provider=anthropic usage=0 expires_at=4102444800000
                ZETA_KEY provider=manual usage=0 expires_at=never
                """, ""}
    end
  end

  describe "status" do
    test "reports a configured env key and the secret count" do
      assert {:ok, _} = Secrets.set("STATUS_KEY", "value")

      assert {0, out, ""} = run(["secrets", "status"])

      assert out ==
               """
               configured: true
               source: env
               keychain_available: false
               env_fallback: true
               owner: default
               count: 1
               """
    end

    test "reports an unconfigured store" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      assert {0, out, ""} = run(["secrets", "status"])
      assert out =~ "configured: false\nsource: none\n"
      assert out =~ "env_fallback: false\n"
      assert out =~ "count: 0\n"
    end

    test "names a keychain failure with recovery guidance instead of a raw term" do
      Application.put_env(:lemon_core, :secrets, key_providers: [FailingKeychain, :env])

      assert {0, out, ""} = run(["secrets", "status"])
      assert out =~ "source: env\nkeychain_available: true\n"

      assert out =~
               "Keychain access failed: the operation timed out. Run `lemon secrets status` for recovery guidance."

      refute out =~ ":timeout"
    end
  end

  describe "init" do
    setup do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      Application.put_env(:lemon_core, :secrets, key_providers: [:file])
    end

    test "writes a 0600 key file and refuses to replace it without --force", %{home: home} do
      key_path = Path.join([home, ".lemon", "secrets_master_key"])

      assert run(["secrets", "init", "--target", "file"]) ==
               {0, "Secrets master key written to #{key_path} (0600)\n", ""}

      assert {:ok, %{mode: mode}} = File.stat(key_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      assert {:ok, <<_::binary-size(32)>>} =
               key_path |> File.read!() |> String.trim() |> Base.decode64()

      original = File.read!(key_path)

      assert {1, "", err} = run(["secrets", "init", "--target", "file"])
      assert err =~ "A secrets master key already exists (see `lemon secrets status`)."
      assert err =~ "run `lemon secrets rotate-key`"
      assert File.read!(key_path) == original

      assert {0, _out, ""} = run(["secrets", "init", "--target", "file", "--force"])
      refute File.read!(key_path) == original
    end
  end

  describe "set" do
    test "usage errors exit 2 without writing" do
      for argv <- [[], ["ONLY_NAME"], ["--name", "N"], ["--value", "V"], ["-n", "", "-v", "x"]] do
        assert run(["secrets", "set" | argv]) ==
                 {2, "", "Usage: lemon secrets set <name> <value>\n"},
               "argv #{inspect(argv)}"
      end

      assert {:ok, []} = Secrets.list()
    end

    test "stores positional, named and aliased forms with provider and expiry" do
      assert run(["secrets", "set", "POS_KEY", "pos-value"]) ==
               {0, "Stored secret POS_KEY (owner=default)\n", ""}

      assert {0, _, ""} = run(["secrets", "set", "--name", "NAMED_KEY", "--value", "named"])
      assert {0, _, ""} = run(["secrets", "set", "-n", "ALIAS_KEY", "-v", "alias"])

      assert {0, _, ""} =
               run([
                 "secrets",
                 "set",
                 "META_KEY",
                 "meta",
                 "--provider",
                 "openai",
                 "--expires-at",
                 "4102444800000"
               ])

      assert {:ok, "pos-value"} = Secrets.get("POS_KEY")
      assert {:ok, "named"} = Secrets.get("NAMED_KEY")
      assert {:ok, "alias"} = Secrets.get("ALIAS_KEY")
      assert {:ok, entries} = Secrets.list()

      assert %{provider: "openai", expires_at: 4_102_444_800_000} =
               Enum.find(entries, &(&1.name == "META_KEY"))
    end

    test "a missing master key exits 1 with init guidance" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      assert {1, "", err} = run(["secrets", "set", "NO_KEY", "value"])

      assert err =~
               "Missing secrets master key. Run `lemon secrets init` or set LEMON_SECRETS_MASTER_KEY."
    end

    test "a keychain failure writes nothing and says not to re-initialize" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      Application.put_env(:lemon_core, :secrets, key_providers: [FailingKeychain, :env])

      assert {1, "", err} = run(["secrets", "set", "KEYCHAIN_KEY", "value"])

      assert err =~
               "Could not read the secrets master key from keychain: the operation timed out. Nothing was written."

      assert err =~ "do not re-initialize the key"
    end
  end

  describe "delete" do
    test "deletes by positional, --name or -n (trimmed) and tolerates a missing secret" do
      for {argv, name} <- [
            {["POS_DEL"], "POS_DEL"},
            {["--name", "NAMED_DEL"], "NAMED_DEL"},
            {["-n", "  ALIAS_DEL  "], "ALIAS_DEL"}
          ] do
        assert {:ok, _} = Secrets.set(name, "value")
        assert run(["secrets", "delete" | argv]) == {0, "Deleted secret #{name}\n", ""}
        assert {:error, :not_found} = Secrets.get(name)
      end

      assert run(["secrets", "delete", "NEVER_STORED"]) ==
               {0, "Deleted secret NEVER_STORED\n", ""}
    end

    test "usage errors exit 2" do
      for argv <- [[], [""], ["   "], ["--name"]] do
        assert run(["secrets", "delete" | argv]) ==
                 {2, "", "Usage: lemon secrets delete <name>\n"},
               "argv #{inspect(argv)}"
      end
    end
  end

  describe "import-env and check" do
    test "imports set catalog variables, skips stored ones unless --force, and summarizes" do
      with_clean_catalog_env(fn ->
        System.put_env("GITHUB_TOKEN", "ghp-import")
        System.put_env("OPENAI_API_KEY", "sk-import")
        assert {:ok, _} = Secrets.set("OPENAI_API_KEY", "sk-stored")
        missing = length(EnvCatalog.names()) - 2

        assert {0, out, ""} = run(["secrets", "import-env"])
        assert out =~ "GITHUB_TOKEN: imported\n"
        assert out =~ "OPENAI_API_KEY: already in store\n"
        assert out =~ "1 imported, 1 already in store, #{missing} not in env\n"
        assert {:ok, "ghp-import"} = Secrets.get("GITHUB_TOKEN")
        assert {:ok, "sk-stored"} = Secrets.get("OPENAI_API_KEY")

        assert {0, out, ""} = run(["secrets", "import-env", "--force"])
        assert out =~ "2 imported, 0 already in store"
        assert {:ok, "sk-import"} = Secrets.get("OPENAI_API_KEY")
        refute out =~ "sk-import"
      end)
    end

    test "check reports sources and never prints values" do
      with_clean_catalog_env(fn ->
        assert {:ok, _} = Secrets.set("ANTHROPIC_API_KEY", "sk-ant-store-value")
        System.put_env("GITHUB_TOKEN", "ghp-env-value")

        assert {0, out, ""} = run(["secrets", "check"])
        assert out =~ ~r/ANTHROPIC_API_KEY\s+store\s+present/
        assert out =~ ~r/GITHUB_TOKEN\s+env\s+present/
        assert out =~ "1 from store, 0 from external sources, 1 from env"
        refute out =~ "store-value"
        refute out =~ "env-value"
      end)
    end
  end

  test "an unknown subcommand prints help and exits 2" do
    assert {2, out, ""} = run(["secrets", "bogus"])
    assert out =~ "lemon secrets <command>"
  end

  # A running runtime owns the store: this VM's store refuses writes, so the
  # command sends them to the runtime's control plane (#667).
  describe "beside a runtime that owns the store" do
    setup %{tmp_dir: tmp_dir} do
      database = Path.join(tmp_dir, "owned.sqlite3")
      lock = LemonCore.RuntimeOwner.lock_path(database)
      test = self()

      holder =
        spawn(fn ->
          LemonCore.FileLock.with_lock_path(lock, [], fn ->
            send(test, :runtime_lock_held)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :runtime_lock_held

      store_config = Application.fetch_env!(:lemon_core, LemonCore.Store)
      override = Application.get_env(:lemon_core, :store_runtime_override, [])
      client = Application.fetch_env(:lemon_cli, :control_plane_client)

      restart_store(
        [
          backend: LemonCore.Store.SqliteBackend,
          backend_opts: [path: database],
          defer_to_runtime: true
        ],
        []
      )

      Application.put_env(:lemon_cli, :control_plane_client, LemonCli.SecretsCommandTestClient)

      on_exit(fn ->
        case client do
          {:ok, module} -> Application.put_env(:lemon_cli, :control_plane_client, module)
          :error -> Application.delete_env(:lemon_cli, :control_plane_client)
        end

        restart_store(store_config, override)
        send(holder, :release)
      end)

      assert {:error, :runtime_owned} = LemonCore.Store.write_access()
      :ok
    end

    test "set goes to the runtime and never writes this VM's store" do
      Process.put(
        :secrets_command_reply,
        {:ok, %{"name" => "ROUTED_KEY", "owner" => "default", "provider" => "openai"}}
      )

      assert run([
               "secrets",
               "set",
               "ROUTED_KEY",
               "routed",
               "--provider",
               "openai",
               "--expires-at",
               "9"
             ]) ==
               {0, "Stored secret ROUTED_KEY (owner=default)\n", ""}

      assert_received {:control_plane_request, "secrets.set", params, _opts}

      assert params == %{
               "name" => "ROUTED_KEY",
               "value" => "routed",
               "provider" => "openai",
               "expiresAt" => 9
             }

      assert {:ok, nil} = LemonCore.Store.fetch(Secrets.table(), {"default", "ROUTED_KEY"})
    end

    test "delete and import-env go to the runtime" do
      Process.put(:secrets_command_reply, {:ok, %{"name" => "GONE", "deleted" => true}})
      assert run(["secrets", "delete", "GONE"]) == {0, "Deleted secret GONE\n", ""}
      assert_received {:control_plane_request, "secrets.delete", %{"name" => "GONE"}, _}

      with_clean_catalog_env(fn ->
        System.put_env("GITHUB_TOKEN", "ghp-routed")

        Process.put(
          :secrets_command_reply,
          {:ok, %{"name" => "GITHUB_TOKEN", "owner" => "default"}}
        )

        assert {0, out, ""} = run(["secrets", "import-env"])
        assert out =~ "GITHUB_TOKEN: imported\n"

        assert_received {:control_plane_request, "secrets.set",
                         %{
                           "name" => "GITHUB_TOKEN",
                           "value" => "ghp-routed",
                           "provider" => "import_env"
                         }, _}
      end)
    end

    test "an unreachable runtime, a refusal and an unconfirmed write each fail closed" do
      cases = [
        {{:error, {:control_plane_unavailable, :econnrefused}},
         "control plane did not answer, so nothing was written"},
        {{:error, :control_plane_timeout}, "it may or may not have been applied"},
        {{:error,
          {:control_plane, %{"code" => "INTERNAL_ERROR", "details" => %{"retrySafe" => false}}}},
         "it may or may not have been applied"},
        {{:error, {:control_plane, %{"code" => "FORBIDDEN", "message" => "no"}}},
         "LEMON_CONTROL_PLANE_OPERATOR_TOKEN"},
        {{:error, {:control_plane, %{"code" => "METHOD_NOT_FOUND", "message" => "no"}}},
         "Restart it on this version"},
        {{:error,
          {:control_plane,
           %{
             "code" => "UNAVAILABLE",
             "details" => %{"reason" => "missing_master_key", "mutationMayHaveApplied" => false}
           }}}, "Missing secrets master key."}
      ]

      for {reply, message} <- cases do
        Process.put(:secrets_command_reply, reply)
        assert {1, "", err} = run(["secrets", "set", "FAIL_KEY", "fail-secret-value"])
        assert err =~ message, "#{inspect(reply)}: #{err}"
        refute err =~ "fail-secret-value"
      end

      assert {:ok, nil} = LemonCore.Store.fetch(Secrets.table(), {"default", "FAIL_KEY"})
    end

    test "reads still work and never call the runtime" do
      assert run(["secrets", "list"]) == {0, "No secrets configured\n", ""}
      refute_received {:control_plane_request, _, _, _}
    end
  end

  defp run(argv) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:exit_code, CLI.run(argv)}) end)
        send(parent, {:stdout, out})
      end)

    assert_received {:exit_code, code}
    assert_received {:stdout, out}
    {code, out, err}
  end

  # `:store_runtime_override` (the test run's LEMON_STORE_PATH) would replace the path.
  defp restart_store(config, override) do
    :ok = Supervisor.terminate_child(LemonCore.Supervisor, LemonCore.Store)
    Application.put_env(:lemon_core, LemonCore.Store, config)
    Application.put_env(:lemon_core, :store_runtime_override, override)
    {:ok, _pid} = Supervisor.restart_child(LemonCore.Supervisor, LemonCore.Store)
  end

  defp with_clean_catalog_env(fun) do
    snapshot = Map.new(EnvCatalog.names(), &{&1, System.get_env(&1)})
    Enum.each(EnvCatalog.names(), &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(snapshot, fn {name, value} -> restore_env(name, value) end)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end

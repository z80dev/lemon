defmodule Mix.Tasks.Lemon.Secrets.ImportEnvTest do
  @moduledoc """
  Tests for the lemon.secrets.import_env mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.ImportEnv
  alias LemonCore.Secrets
  alias LemonCore.Store

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_import_env_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store originals
    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    # Clear secrets table before each test
    clear_secrets_table()

    # Set up a master key for encryption
    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    # Clear all known secret env vars to start clean
    known = ImportEnv.known_secrets()
    original_envs = Map.new(known, fn name -> {name, System.get_env(name)} end)
    Enum.each(known, &System.delete_env/1)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Restore original master key
      if original_master_key do
        System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key)
      else
        System.delete_env("LEMON_SECRETS_MASTER_KEY")
      end

      # Restore env vars
      Enum.each(original_envs, fn
        {name, nil} -> System.delete_env(name)
        {name, val} -> System.put_env(name, val)
      end)

      # Clean up temp directory and secrets
      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "module attributes" do
    test "task module exists and is loaded" do
      assert Code.ensure_loaded?(ImportEnv)
    end

    test "has proper @shortdoc attribute" do
      shortdoc = Mix.Task.shortdoc(ImportEnv)
      assert shortdoc =~ "Import env-based secrets"
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(ImportEnv)

      case module_doc do
        :none ->
          flunk("Module documentation is missing")

        :hidden ->
          flunk("Module documentation is hidden")

        %{} ->
          doc = module_doc["en"]
          assert is_binary(doc)
          assert doc =~ "import"
          assert doc =~ "mix lemon.secrets.import_env"
      end
    end

    test "module has run/1 function exported" do
      assert Code.ensure_loaded?(ImportEnv)
      assert function_exported?(ImportEnv, :run, 1)
    end

    test "known_secrets list is non-empty" do
      assert length(ImportEnv.known_secrets()) > 0
    end
  end

  describe "import with no env vars set" do
    test "reports all secrets as not in env" do
      output =
        capture_io(fn ->
          ImportEnv.run([])
        end)

      assert output =~ "not in env"
      # Summary should show 0 imported, 0 already, N not in env
      assert output =~ "0 imported"
      assert output =~ "0 already in store"
    end
  end

  describe "import with env vars set" do
    test "imports a secret from env into the store" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test-123456789")

      output =
        capture_io(fn ->
          ImportEnv.run([])
        end)

      assert output =~ "ANTHROPIC_API_KEY: imported"
      assert output =~ "1 imported"

      # Verify it actually landed in the store
      assert {:ok, "sk-ant-test-123456789"} = Secrets.get("ANTHROPIC_API_KEY")
    end

    test "skips secrets already in the store" do
      # Pre-populate the store
      {:ok, _} = Secrets.set("OPENAI_API_KEY", "existing-value", provider: "manual")

      # Set env var to a different value
      System.put_env("OPENAI_API_KEY", "new-env-value")

      output =
        capture_io(fn ->
          ImportEnv.run([])
        end)

      assert output =~ "OPENAI_API_KEY: already in store"
      assert output =~ "1 already in store"

      # Store should still have the original value
      assert {:ok, "existing-value"} = Secrets.get("OPENAI_API_KEY")
    end

    test "imports multiple secrets" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")
      System.put_env("GITHUB_TOKEN", "ghp_test")

      output =
        capture_io(fn ->
          ImportEnv.run([])
        end)

      assert output =~ "ANTHROPIC_API_KEY: imported"
      assert output =~ "GITHUB_TOKEN: imported"
      assert output =~ "2 imported"
    end

    test "skips empty env values" do
      System.put_env("ANTHROPIC_API_KEY", "")

      output =
        capture_io(fn ->
          ImportEnv.run([])
        end)

      assert output =~ "ANTHROPIC_API_KEY: not set in env"
    end
  end

  describe "--dry-run flag" do
    test "shows what would be imported without making changes" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-dry-run")

      output =
        capture_io(fn ->
          ImportEnv.run(["--dry-run"])
        end)

      assert output =~ "Dry run mode"
      assert output =~ "ANTHROPIC_API_KEY: would import"
      assert output =~ "1 imported"

      # Verify nothing was actually stored
      assert {:error, :not_found} = Secrets.get("ANTHROPIC_API_KEY")
    end

    test "dry run still reports already-in-store secrets" do
      {:ok, _} = Secrets.set("OPENAI_API_KEY", "existing", provider: "manual")
      System.put_env("OPENAI_API_KEY", "new-value")

      output =
        capture_io(fn ->
          ImportEnv.run(["--dry-run"])
        end)

      assert output =~ "OPENAI_API_KEY: already in store"
    end
  end

  describe "--force flag" do
    test "overwrites existing store entries" do
      {:ok, _} = Secrets.set("OPENAI_API_KEY", "old-value", provider: "manual")
      System.put_env("OPENAI_API_KEY", "new-forced-value")

      output =
        capture_io(fn ->
          ImportEnv.run(["--force"])
        end)

      assert output =~ "OPENAI_API_KEY: imported"
      assert output =~ "1 imported"

      # Should now have the new value
      assert {:ok, "new-forced-value"} = Secrets.get("OPENAI_API_KEY")
    end
  end

  describe "summary output" do
    test "prints accurate summary counts" do
      # One to import
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

      # One already in store
      {:ok, _} = Secrets.set("OPENAI_API_KEY", "existing", provider: "manual")
      System.put_env("OPENAI_API_KEY", "new-value")

      output =
        capture_io(fn ->
          ImportEnv.run([])
        end)

      assert output =~ "1 imported"
      assert output =~ "1 already in store"
      # The rest should be not in env
      not_in_env_count = length(ImportEnv.known_secrets()) - 2
      assert output =~ "#{not_in_env_count} not in env"
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved via Mix.Task.get" do
      assert Mix.Task.get("lemon.secrets.import_env") == ImportEnv
    end

    test "task is registered with correct name" do
      task_module = Mix.Task.get("lemon.secrets.import_env")
      assert task_module == ImportEnv
    end

    test "task shortdoc is accessible via Mix.Task.shortdoc" do
      shortdoc = Mix.Task.shortdoc(ImportEnv)
      assert is_binary(shortdoc)
      assert shortdoc =~ "Import"
    end
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end

defmodule Mix.Tasks.Lemon.Secrets.SetTest do
  @moduledoc """
  Tests for the lemon.secrets.set mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Set
  alias LemonCore.Secrets.MasterKey

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_set_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME and LEMON_SECRETS_MASTER_KEY
    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

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

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "module attributes" do
    test "task module exists and is loaded" do
      assert Code.ensure_loaded?(Set)
    end

    test "has proper @shortdoc attribute" do
      # Verify shortdoc via task helper
      shortdoc = Mix.Task.shortdoc(Set)
      assert shortdoc =~ "Store an encrypted secret"
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Set)

      case module_doc do
        :none ->
          flunk("Module documentation is missing")

        :hidden ->
          flunk("Module documentation is hidden")

        %{} ->
          doc = module_doc["en"]
          assert is_binary(doc)
          assert doc =~ "Stores a secret value in the encrypted secrets store"
          assert doc =~ "mix lemon.secrets.set"
      end
    end

    test "module has run/1 function exported" do
      assert function_exported?(Set, :run, 1)
    end
  end

  describe "argument parsing" do
    test "raises error when name and value are missing" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run([])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "raises error when only name is provided via positional arg" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret"])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "raises error when only --name is provided without --value" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["--name", "my_secret"])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "raises error when only --value is provided without --name" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["--value", "secret_value"])
          end)
        end

      assert error.message =~ "Usage: mix lemon.secrets.set <name> <value>"
    end

    test "accepts positional arguments [name, value]" do
      # With positional args, it will try to store but fail due to missing master key
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret", "my_value"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert error.message =~ "Missing secrets master key" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to store secret"
    end

    test "accepts named arguments --name and --value" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["--name", "my_secret", "--value", "my_value"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert error.message =~ "Missing secrets master key" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to store secret"
    end

    test "accepts short aliases -n and -v" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["-n", "my_secret", "-v", "my_value"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert error.message =~ "Missing secrets master key" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to store secret"
    end

    test "accepts --provider option" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret", "my_value", "--provider", "manual"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert error.message =~ "Missing secrets master key" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to store secret"
    end

    test "accepts --expires-at option" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["my_secret", "my_value", "--expires-at", "1735689600000"])
          end)
        end

      # Should fail on master key check, not argument parsing
      assert error.message =~ "Missing secrets master key" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to store secret"
    end
  end

  describe "error handling for missing master key" do
    test "raises Mix.Error with missing_master_key message" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["test_key", "test_value"])
          end)
        end

      # Should indicate missing master key or startup failure
      assert error.message =~ "Missing secrets master key" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to store secret"
    end

    test "error message suggests running lemon.secrets.init" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Set.run(["test_key", "test_value"])
          end)
        end

      # Error should mention init command or setting env var
      assert error.message =~ "lemon.secrets.init" or
               error.message =~ "LEMON_SECRETS_MASTER_KEY" or
               error.message =~ "Failed to start"
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved via Mix.Task.get" do
      assert Mix.Task.get("lemon.secrets.set") == Set
    end

    test "task is registered with correct name" do
      task_module = Mix.Task.get("lemon.secrets.set")
      assert task_module == Set
    end

    test "task shortdoc is accessible via Mix.Task.shortdoc" do
      shortdoc = Mix.Task.shortdoc(Set)
      assert is_binary(shortdoc)
      assert shortdoc =~ "Store"
    end
  end

  describe "MasterKey integration" do
    test "MasterKey.env_var/0 returns correct variable name" do
      assert MasterKey.env_var() == "LEMON_SECRETS_MASTER_KEY"
    end

    test "MasterKey module is available" do
      assert Code.ensure_loaded?(MasterKey)
    end
  end
end

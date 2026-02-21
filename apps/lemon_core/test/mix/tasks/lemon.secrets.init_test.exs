defmodule Mix.Tasks.Lemon.Secrets.InitTest do
  @moduledoc """
  Tests for the lemon.secrets.init mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Init
  alias LemonCore.Secrets.MasterKey

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_init_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "module attributes" do
    test "task module exists and is loaded" do
      assert Code.ensure_loaded?(Init)
    end

    test "has proper @shortdoc attribute" do
      # Verify shortdoc via task helper
      shortdoc = Mix.Task.shortdoc(Init)
      assert shortdoc =~ "Initialize Lemon secrets master key"
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Init)

      case module_doc do
        :none ->
          flunk("Module documentation is missing")

        :hidden ->
          flunk("Module documentation is hidden")

        %{} ->
          doc = module_doc["en"]
          assert is_binary(doc)
          assert doc =~ "Initializes the encrypted secrets master key"
          assert doc =~ "mix lemon.secrets.init"
      end
    end

    test "module has run/1 function exported" do
      assert Code.ensure_loaded?(Init)
      assert function_exported?(Init, :run, 1)
    end
  end

  describe "run/1 error handling" do
    test "raises Mix.Error when keychain is unavailable", %{mock_home: _mock_home} do
      # When LEMON_SECRETS_MASTER_KEY is not set and keychain is unavailable,
      # the task should raise with keychain_unavailable error
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      # Capture any output and catch the error
      error =
        assert_raise Mix.Error, fn ->
          capture_io(fn ->
            Init.run([])
          end)
        end

      assert error.message =~ "Keychain is unavailable" or
               error.message =~ "Failed to start" or
               error.message =~ "Failed to initialize"
    end

    test "task handles empty args list" do
      # Test that the task runs with empty args (will likely fail due to keychain)
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      # Should raise an error, but not crash with function clause
      assert_raise Mix.Error, fn ->
        capture_io(fn ->
          Init.run([])
        end)
      end
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved via Mix.Task.get" do
      assert Mix.Task.get("lemon.secrets.init") == Init
    end

    test "task is registered with correct name" do
      task_module = Mix.Task.get("lemon.secrets.init")
      assert task_module == Init
    end

    test "task shortdoc is accessible via Mix.Task.shortdoc" do
      shortdoc = Mix.Task.shortdoc(Init)
      assert is_binary(shortdoc)
      assert shortdoc =~ "Initialize"
    end
  end

  describe "MasterKey integration" do
    test "MasterKey.env_var/0 returns correct variable name" do
      assert MasterKey.env_var() == "LEMON_SECRETS_MASTER_KEY"
    end

    test "MasterKey module is available" do
      assert Code.ensure_loaded?(MasterKey)
      assert function_exported?(MasterKey, :init, 0)
      assert function_exported?(MasterKey, :init, 1)
    end
  end
end

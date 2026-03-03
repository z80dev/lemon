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

  describe "run/1" do
    if match?({:unix, :darwin}, :os.type()) do
      @tag skip: "KeyFile fallback assertion is non-deterministic on darwin"
      test "succeeds via KeyFile fallback on non-macOS", _ctx do
      end
    else
      test "succeeds via KeyFile fallback on non-macOS", %{mock_home: mock_home} do
        System.delete_env("LEMON_SECRETS_MASTER_KEY")
        original_path = System.get_env("PATH")
        System.put_env("PATH", mock_home)

        on_exit(fn ->
          if original_path do
            System.put_env("PATH", original_path)
          else
            System.delete_env("PATH")
          end
        end)

        # On Linux (no Keychain), init should succeed by writing to KeyFile
        # under mock HOME
        output =
          capture_io(fn ->
            Init.run([])
          end)

        assert output =~ "Secrets master key initialized"
        assert output =~ "file (~/.lemon/master.key)"

        # Verify the key file was created under mock HOME
        key_path = Path.join(mock_home, ".lemon/master.key")
        assert File.exists?(key_path)
        content = File.read!(key_path)
        assert String.length(content) > 0
      end
    end

    test "task handles empty args list" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      # Should not crash with function clause error
      output =
        capture_io(fn ->
          Init.run([])
        end)

      assert is_binary(output)
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

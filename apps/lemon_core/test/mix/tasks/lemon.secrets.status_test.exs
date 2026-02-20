defmodule Mix.Tasks.Lemon.Secrets.StatusTest do
  @moduledoc """
  Tests for the lemon.secrets.status mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Status
  alias LemonCore.Secrets.MasterKey

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_status_test_#{System.unique_integer([:positive])}"
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
      assert Code.ensure_loaded?(Status)
    end

    test "has proper @shortdoc attribute" do
      # Verify shortdoc via task helper
      shortdoc = Mix.Task.shortdoc(Status)
      assert shortdoc =~ "Show encrypted secrets status"
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Status)

      case module_doc do
        :none ->
          flunk("Module documentation is missing")

        :hidden ->
          flunk("Module documentation is hidden")

        %{} ->
          doc = module_doc["en"]
          assert is_binary(doc)
          assert doc =~ "Shows master key status and secret count"
          assert doc =~ "mix lemon.secrets.status"
      end
    end

    test "module has run/1 function exported" do
      assert function_exported?(Status, :run, 1)
    end
  end

  describe "status output" do
    test "displays status when configured" do
      # Set up a temporary master key
      master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
      System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

      on_exit(fn ->
        System.delete_env("LEMON_SECRETS_MASTER_KEY")
      end)

      output =
        capture_io(fn ->
          Status.run([])
        end)

      assert output =~ "configured:"
      assert output =~ "source:"
      assert output =~ "keychain_available:"
      assert output =~ "env_fallback:"
      assert output =~ "owner:"
      assert output =~ "count:"
    end

    test "displays status when not configured" do
      # Ensure no master key is set
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      output =
        capture_io(fn ->
          Status.run([])
        end)

      assert output =~ "configured:"
      assert output =~ "source:"
      assert output =~ "count:"
    end
  end

  describe "output format" do
    test "all expected fields are present" do
      output =
        capture_io(fn ->
          Status.run([])
        end)

      # Check for all expected field labels
      assert output =~ "configured:"
      assert output =~ "source:"
      assert output =~ "keychain_available:"
      assert output =~ "env_fallback:"
      assert output =~ "owner:"
      assert output =~ "count:"
    end

    test "displays boolean values as strings" do
      output =
        capture_io(fn ->
          Status.run([])
        end)

      # Should contain "true" or "false" after the field names
      assert output =~ ~r/configured: (true|false)/
      assert output =~ ~r/keychain_available: (true|false)/
      assert output =~ ~r/env_fallback: (true|false)/
    end

    test "displays source as 'none' when not configured" do
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      output =
        capture_io(fn ->
          Status.run([])
        end)

      assert output =~ "source: none"
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved via Mix.Task.get" do
      assert Mix.Task.get("lemon.secrets.status") == Status
    end

    test "task is registered with correct name" do
      task_module = Mix.Task.get("lemon.secrets.status")
      assert task_module == Status
    end

    test "task shortdoc is accessible via Mix.Task.shortdoc" do
      shortdoc = Mix.Task.shortdoc(Status)
      assert is_binary(shortdoc)
      assert shortdoc =~ "status"
    end
  end

  describe "MasterKey integration" do
    test "MasterKey.env_var/0 returns correct variable name" do
      assert MasterKey.env_var() == "LEMON_SECRETS_MASTER_KEY"
    end

    test "MasterKey module is available" do
      assert Code.ensure_loaded?(MasterKey)
      assert function_exported?(MasterKey, :status, 0)
      assert function_exported?(MasterKey, :status, 1)
    end
  end
end

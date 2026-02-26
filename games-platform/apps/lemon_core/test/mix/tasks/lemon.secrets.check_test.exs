defmodule Mix.Tasks.Lemon.Secrets.CheckTest do
  @moduledoc """
  Tests for the lemon.secrets.check mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Lemon.Secrets.Check
  alias LemonCore.Secrets
  alias LemonCore.Store

  setup do
    # Create a temporary directory for test
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_check_test_#{System.unique_integer([:positive])}"
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
    known = Check.known_secrets()
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
      assert Code.ensure_loaded?(Check)
    end

    test "has proper @shortdoc attribute" do
      shortdoc = Mix.Task.shortdoc(Check)
      assert shortdoc =~ "Check secret resolution sources"
    end

    test "moduledoc is present" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Check)

      case module_doc do
        :none ->
          flunk("Module documentation is missing")

        :hidden ->
          flunk("Module documentation is hidden")

        %{} ->
          doc = module_doc["en"]
          assert is_binary(doc)
          assert doc =~ "resolution source"
          assert doc =~ "mix lemon.secrets.check"
      end
    end

    test "module has run/1 function exported" do
      assert Code.ensure_loaded?(Check)
      assert function_exported?(Check, :run, 1)
    end

    test "known_secrets list is non-empty" do
      assert length(Check.known_secrets()) > 0
    end
  end

  describe "check with no secrets available" do
    test "reports all secrets as missing" do
      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "missing"
      # Summary should show 0 from store, 0 from env, N missing
      missing_count = length(Check.known_secrets())
      assert output =~ "0 from store, 0 from env, #{missing_count} missing"
    end

    test "displays header line" do
      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "NAME"
      assert output =~ "SOURCE"
      assert output =~ "VALUE"
    end
  end

  describe "check with store secrets" do
    test "reports secret resolved from store" do
      {:ok, _} = Secrets.set("ANTHROPIC_API_KEY", "sk-ant-test-123456789", provider: "manual")

      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "ANTHROPIC_API_KEY"
      assert output =~ "store"
      # Masked value: first 4 + ... + last 4
      assert output =~ "sk-a...6789"
    end
  end

  describe "check with env secrets" do
    test "reports secret resolved from env" do
      System.put_env("GITHUB_TOKEN", "ghp_abcdef123456789xyz")

      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "GITHUB_TOKEN"
      assert output =~ "env"
      # Masked value: first 4 + ... + last 4
      assert output =~ "ghp_...9xyz"
    end
  end

  describe "value masking" do
    test "masks long values showing first 4 and last 4 chars" do
      {:ok, _} = Secrets.set("OPENAI_API_KEY", "sk-longvalue12345678", provider: "manual")

      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "sk-l...5678"
    end

    test "masks short values as ***" do
      {:ok, _} = Secrets.set("AWS_ACCESS_KEY_ID", "short", provider: "manual")

      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "***"
    end
  end

  describe "summary output" do
    test "prints accurate summary counts" do
      # One in store
      {:ok, _} = Secrets.set("ANTHROPIC_API_KEY", "sk-ant-test-12345678", provider: "manual")

      # One in env only
      System.put_env("GITHUB_TOKEN", "ghp_test-12345678")

      output =
        capture_io(fn ->
          Check.run([])
        end)

      assert output =~ "1 from store"
      assert output =~ "1 from env"
      missing_count = length(Check.known_secrets()) - 2
      assert output =~ "#{missing_count} missing"
    end
  end

  describe "Mix.Task integration" do
    test "task can be retrieved via Mix.Task.get" do
      assert Mix.Task.get("lemon.secrets.check") == Check
    end

    test "task is registered with correct name" do
      task_module = Mix.Task.get("lemon.secrets.check")
      assert task_module == Check
    end

    test "task shortdoc is accessible via Mix.Task.shortdoc" do
      shortdoc = Mix.Task.shortdoc(Check)
      assert is_binary(shortdoc)
      assert shortdoc =~ "Check"
    end
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end

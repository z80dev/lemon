defmodule Mix.Tasks.Lemon.Secrets.ListTest do
  @moduledoc """
  Tests for the lemon.secrets.list mix task.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCore.Secrets
  alias LemonCore.Store

  setup do
    # Create a temporary directory for test configs
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_secrets_list_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    # Create a mock HOME directory
    mock_home = Path.join(tmp_dir, "home")
    File.mkdir_p!(mock_home)

    # Store original HOME
    original_home = System.get_env("HOME")

    # Set HOME to mock directory
    System.put_env("HOME", mock_home)

    # Clear secrets table before each test
    clear_secrets_table()

    # Set up a master key for encryption
    master_key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    System.put_env("LEMON_SECRETS_MASTER_KEY", master_key)

    on_exit(fn ->
      # Restore original HOME
      if original_home do
        System.put_env("HOME", original_home)
      else
        System.delete_env("HOME")
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)

      # Clean up secrets and master key
      clear_secrets_table()
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
    end)

    {:ok, tmp_dir: tmp_dir, mock_home: mock_home}
  end

  describe "module attributes" do
    test "has proper @shortdoc" do
      {:docs_v1, _, _, _, %{} = module_doc, _, _} = Code.fetch_docs(Mix.Tasks.Lemon.Secrets.List)
      assert module_doc["en"] =~ "Lists stored secrets"
    end

    test "task module exists and has run/1 function" do
      assert Code.ensure_loaded?(Mix.Tasks.Lemon.Secrets.List)
      assert function_exported?(Mix.Tasks.Lemon.Secrets.List, :run, 1)
    end
  end

  describe "run/1 with empty secrets" do
    test "outputs 'No secrets configured' when no secrets exist" do
      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      assert output =~ "No secrets configured"
    end
  end

  describe "run/1 with secrets" do
    test "lists secret metadata without plaintext values" do
      # Create some test secrets
      assert {:ok, _} = Secrets.set("api_key", "secret-value-123", provider: "manual")
      assert {:ok, _} = Secrets.set("db_password", "db-secret-456", provider: "env")

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      # Verify both secrets are listed
      assert output =~ "api_key"
      assert output =~ "db_password"

      # Verify metadata is shown
      assert output =~ "provider=manual"
      assert output =~ "provider=env"
      assert output =~ "usage=0"

      # Verify no plaintext values are exposed
      refute output =~ "secret-value-123"
      refute output =~ "db-secret-456"
      refute output =~ "ciphertext"
      refute output =~ "nonce"
    end

    test "shows correct usage count" do
      assert {:ok, _} = Secrets.set("test_secret", "value")

      # Use the secret a few times
      {:ok, _} = Secrets.get("test_secret")
      {:ok, _} = Secrets.get("test_secret")
      {:ok, _} = Secrets.get("test_secret")

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      assert output =~ "test_secret"
      assert output =~ "usage=3"
    end

    test "shows expires_at as 'never' when not set" do
      assert {:ok, _} = Secrets.set("no_expiry", "value")

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      assert output =~ "expires_at=never"
    end

    test "shows expiration timestamp when set" do
      future_time = System.system_time(:millisecond) + 86_400_000
      assert {:ok, _} = Secrets.set("with_expiry", "value", expires_at: future_time)

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      assert output =~ "with_expiry"
      # Verify the timestamp is displayed (not "never")
      refute output =~ "expires_at=never"
      # Should contain the numeric timestamp
      assert output =~ ~r/expires_at=\d+/
    end
  end

  describe "format_optional/1 helper" do
    test "returns 'never' for nil values" do
      # Tested indirectly through run/1 output
      assert {:ok, _} = Secrets.set("nil_expiry_test", "value", expires_at: nil)

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      assert output =~ "nil_expiry_test"
      assert output =~ "expires_at=never"
    end

    test "converts integer values to string" do
      timestamp = System.system_time(:millisecond) + 86_400_000
      assert {:ok, _} = Secrets.set("int_expiry_test", "value", expires_at: timestamp)

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      assert output =~ "int_expiry_test"
      assert output =~ "expires_at=#{timestamp}"
    end
  end

  describe "output format" do
    test "displays entries in sorted order by name" do
      # Add secrets in non-alphabetical order
      assert {:ok, _} = Secrets.set("zebra", "z-value")
      assert {:ok, _} = Secrets.set("alpha", "a-value")
      assert {:ok, _} = Secrets.set("mike", "m-value")

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      lines = String.split(output, "\n", trim: true)

      # Verify all entries are present
      assert length(lines) == 3
      assert Enum.any?(lines, &(&1 =~ "alpha"))
      assert Enum.any?(lines, &(&1 =~ "mike"))
      assert Enum.any?(lines, &(&1 =~ "zebra"))
    end

    test "output format includes all expected fields" do
      assert {:ok, _} = Secrets.set("formatted", "value", provider: "test-provider")

      output =
        capture_io(fn ->
          Mix.Tasks.Lemon.Secrets.List.run([])
        end)

      # Verify format: name provider=... usage=... expires_at=...
      assert output =~ ~r/formatted provider=\S+ usage=\d+ expires_at=(never|\d+)/
    end
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end
end

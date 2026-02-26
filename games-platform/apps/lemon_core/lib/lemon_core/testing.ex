defmodule LemonCore.Testing do
  @moduledoc """
  Test harness for constructing test environments with sensible defaults.

  Inspired by Ironclaw's testing.rs, this module provides utilities for
  setting up test environments without external dependencies.

  ## Usage

      defmodule MyTest do
        use LemonCore.Testing.Case, async: true

        test "something", %{harness: harness} do
          # Use harness.tmp_dir, harness.store, etc.
        end
      end

  Or use the builder directly:

      harness = LemonCore.Testing.Harness.new()
        |> LemonCore.Testing.Harness.with_env("KEY", "value")
        |> LemonCore.Testing.Harness.build()
  """

  defmodule Harness do
    @moduledoc """
    Test harness struct containing all test resources.

    Fields:
      * `:tmp_dir` - Temporary directory path (cleaned up on exit)
      * `:store` - The Store process (if started)
      * `:env_vars` - Map of environment variables set during test
      * `:original_env` - Original environment values for restoration
    """
    defstruct [:tmp_dir, :store, :env_vars, :original_env]

    @doc """
    Creates a new harness builder with defaults.
    """
    def new do
      %{
        tmp_dir: nil,
        env_vars: %{},
        start_store: false,
        async: true
      }
    end

    @doc """
    Sets a temporary directory for the test. If not called, a temp dir
    is created automatically on build.
    """
    def with_tmp_dir(builder, path) do
      Map.put(builder, :tmp_dir, path)
    end

    @doc """
    Sets an environment variable that will be restored after the test.
    """
    def with_env(builder, key, value) do
      Map.update!(builder, :env_vars, &Map.put(&1, key, value))
    end

    @doc """
    Configures whether to start the Store process. Default: false.
    """
    def with_store(builder, enabled \\ true) do
      Map.put(builder, :start_store, enabled)
    end

    @doc """
    Marks the test as async or not. Affects cleanup strategy.
    """
    def set_async(builder, async) do
      Map.put(builder, :async, async)
    end

    @doc """
    Builds the harness, creating temp directory and setting up environment.
    Returns a map suitable for use as test context.
    """
    def build(builder) do
      # Create temp directory
      tmp_dir = builder.tmp_dir || create_temp_dir()

      # Store original env values
      original_env =
        Map.new(builder.env_vars, fn {key, _} ->
          {key, System.get_env(key)}
        end)

      # Set environment variables
      Enum.each(builder.env_vars, fn {key, value} ->
        System.put_env(key, value)
      end)

      # Create harness struct
      harness = %__MODULE__{
        tmp_dir: tmp_dir,
        env_vars: builder.env_vars,
        original_env: original_env,
        store: nil
      }

      # Start store if requested
      harness =
        if builder.start_store do
          start_store!(harness)
        else
          harness
        end

      # Register cleanup
      if not builder.async do
        ExUnit.Callbacks.on_exit(fn ->
          cleanup(harness)
        end)
      end

      %{harness: harness, tmp_dir: tmp_dir}
    end

    @doc """
    Cleans up the harness resources.
    """
    def cleanup(harness) do
      # Restore original environment
      Enum.each(harness.original_env, fn {key, value} ->
        if value do
          System.put_env(key, value)
        else
          System.delete_env(key)
        end
      end)

      # Remove temp directory
      if File.dir?(harness.tmp_dir) do
        File.rm_rf!(harness.tmp_dir)
      end
    end

    defp create_temp_dir do
      tmp_dir =
        Path.join(System.tmp_dir!(), "lemon_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      tmp_dir
    end

    defp start_store!(harness) do
      # Ensure Store application is started
      case LemonCore.Store.start_link([]) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        error -> raise "Failed to start Store: #{inspect(error)}"
      end

      %{harness | store: LemonCore.Store}
    end
  end

  defmodule Case do
    @moduledoc """
    Test case module that provides the testing harness.

    ## Usage

        defmodule MyTest do
          use LemonCore.Testing.Case, async: true

          # Harness is available in context
          test "example", %{harness: harness} do
            File.write!(Path.join(harness.tmp_dir, "file.txt"), "content")
          end
        end

    ## Options

      * `:async` - Whether tests run asynchronously (default: true)
      * `:with_store` - Whether to start the Store process (default: false)
    """

    use ExUnit.CaseTemplate

    using opts do
      quote do
        import LemonCore.Testing
        import LemonCore.Testing.Helpers

        @async unquote(opts[:async] || true)
      end
    end

    setup ctx do
      async = Map.get(ctx, :async, true)
      with_store = Map.get(ctx, :with_store, false)

      harness_ctx =
        LemonCore.Testing.Harness.new()
        |> LemonCore.Testing.Harness.set_async(async)
        |> LemonCore.Testing.Harness.with_store(with_store)
        |> LemonCore.Testing.Harness.build()

      harness_ctx
    end
  end

  defmodule Helpers do
    @moduledoc """
    Helper functions for tests.
    """

    @doc """
    Generates a unique token for test isolation.
    """
    def unique_token do
      System.unique_integer([:positive, :monotonic])
    end

    @doc """
    Generates a unique scope for test isolation.
    """
    def unique_scope(prefix \\ :test) do
      {prefix, unique_token()}
    end

    @doc """
    Generates a unique session key for test isolation.
    """
    def unique_session_key(prefix \\ "test") do
      "agent:#{prefix}_#{unique_token()}:main"
    end

    @doc """
    Generates a unique run ID for test isolation.
    """
    def unique_run_id(prefix \\ "run") do
      "#{prefix}_#{unique_token()}"
    end

    @doc """
    Creates a temporary file with the given content.
    Returns the file path.
    """
    def temp_file!(harness, filename, content) do
      path = Path.join(harness.tmp_dir, filename)
      File.write!(path, content)
      path
    end

    @doc """
    Creates a temporary directory inside the harness temp dir.
    Returns the directory path.
    """
    def temp_dir!(harness, name) do
      path = Path.join(harness.tmp_dir, name)
      File.mkdir_p!(path)
      path
    end

    @doc """
    Clears all entries from a Store table.
    """
    def clear_store_table(table) do
      LemonCore.Store.list(table)
      |> Enum.each(fn {key, _value} ->
        LemonCore.Store.delete(table, key)
      end)
    end

    @doc """
    Sets up a mock HOME directory for config tests.
    Returns the path to the mock home directory.
    """
    def mock_home!(harness) do
      home = Path.join(harness.tmp_dir, "home")
      File.mkdir_p!(home)

      original_home = System.get_env("HOME")
      System.put_env("HOME", home)

      ExUnit.Callbacks.on_exit(fn ->
        if original_home do
          System.put_env("HOME", original_home)
        else
          System.delete_env("HOME")
        end
      end)

      home
    end

    @doc """
    Generates a random master key for secrets testing.
    """
    def random_master_key do
      :crypto.strong_rand_bytes(32) |> Base.encode64()
    end

    @doc """
    Waits for a process to be alive, with timeout.
    """
    def wait_for_process_alive(pid, timeout_ms \\ 1000) do
      case Process.alive?(pid) do
        true ->
          :ok

        false ->
          if timeout_ms <= 0 do
            {:error, :timeout}
          else
            Process.sleep(10)
            wait_for_process_alive(pid, timeout_ms - 10)
          end
      end
    end
  end
end

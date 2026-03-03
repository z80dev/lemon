defmodule LemonCore.Secrets.SecretService do
  @moduledoc """
  Linux Secret Service (libsecret / freedesktop.org D-Bus) integration for Lemon secrets.

  Uses `secret-tool` from the `libsecret` package to store and retrieve
  the master key via the desktop keyring (GNOME Keyring, KWallet, etc.).
  """

  @behaviour LemonCore.Secrets.KeyBackend

  @default_service "Lemon Secrets"
  @default_account "default"
  @default_timeout_ms 5_000

  @spec available?() :: boolean()
  def available? do
    case :os.type() do
      {:unix, :darwin} -> false
      {:unix, _} -> is_binary(System.find_executable("secret-tool"))
      _ -> false
    end
  end

  @spec get_master_key(keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_master_key(opts \\ []) do
    if available_with_opts?(opts) do
      args = ["lookup", "service", service(opts), "account", account(opts)]

      case run_secret_tool(args, nil, opts) do
        {:ok, ""} -> {:error, :missing}
        {:ok, value} -> {:ok, value}
        {:error, _} = error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  @spec put_master_key(String.t(), keyword()) :: :ok | {:error, term()}
  def put_master_key(value, opts \\ [])

  def put_master_key(value, opts) when is_binary(value) do
    if available_with_opts?(opts) do
      label = Keyword.get(opts, :label, "Lemon Secrets Master Key")
      args = ["store", "--label", label, "service", service(opts), "account", account(opts)]

      case run_secret_tool(args, value, opts) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  def put_master_key(_, _), do: {:error, :invalid_value}

  @spec delete_master_key(keyword()) :: :ok | {:error, term()}
  def delete_master_key(opts \\ []) do
    if available_with_opts?(opts) do
      args = ["clear", "service", service(opts), "account", account(opts)]

      case run_secret_tool(args, nil, opts) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  defp service(opts), do: Keyword.get(opts, :service, @default_service)
  defp account(opts), do: Keyword.get(opts, :account, @default_account)

  # When a :runner is injected (tests), skip the real available?() check
  defp available_with_opts?(opts) do
    if Keyword.has_key?(opts, :runner), do: true, else: available?()
  end

  defp run_secret_tool(args, stdin, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    runner = Keyword.get(opts, :runner)

    task =
      Task.async(fn ->
        try do
          if runner do
            runner.("secret-tool", args, stderr_to_stdout: true, stdin: stdin)
          else
            exec_secret_tool(args, stdin)
          end
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, reason}} -> {:error, {:command_failed, reason}}
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {"", 1}} -> {:error, :missing}
      {:ok, {output, code}} -> {:error, {:command_failed, code, String.trim(output)}}
      nil -> {:error, :timeout}
      _ -> {:error, :command_failed}
    end
  end

  # Execute secret-tool, piping stdin_data when needed (e.g. for `store`).
  # Arguments are passed directly without shell interpolation.
  defp exec_secret_tool(args, nil) do
    System.cmd("secret-tool", args, stderr_to_stdout: true)
  end

  defp exec_secret_tool(args, stdin_data) do
    System.cmd("secret-tool", args, stderr_to_stdout: true, input: stdin_data)
  end
end

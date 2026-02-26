defmodule LemonCore.Secrets.Keychain do
  @moduledoc """
  macOS Keychain integration for Lemon secrets.
  """

  @default_service "Lemon Secrets"
  @default_account "default"
  @default_timeout_ms 5_000

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec available?() :: boolean()
  def available? do
    match?({:unix, :darwin}, :os.type()) and is_binary(System.find_executable("security"))
  end

  @spec get_master_key(keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_master_key(opts \\ []) do
    if available?() do
      args = ["find-generic-password", "-s", service(opts), "-a", account(opts), "-w"]

      case run_security(args, opts) do
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
    if available?() do
      args = [
        "add-generic-password",
        "-U",
        "-s",
        service(opts),
        "-a",
        account(opts),
        "-w",
        value
      ]

      case run_security(args, opts) do
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
    if available?() do
      args = ["delete-generic-password", "-s", service(opts), "-a", account(opts)]

      case run_security(args, opts) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  defp service(opts), do: Keyword.get(opts, :service, @default_service)
  defp account(opts), do: Keyword.get(opts, :account, @default_account)

  defp run_security(args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    task =
      Task.async(fn ->
        try do
          runner.("security", args, stderr_to_stdout: true)
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, reason}} -> {:error, {:command_failed, reason}}
      {:ok, {_output, 44}} -> {:error, :missing}
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, code}} -> {:error, {:command_failed, code, String.trim(output)}}
      nil -> {:error, :timeout}
      _ -> {:error, :command_failed}
    end
  end
end

defmodule CodingAgent.ExecutionNode.CLI do
  @moduledoc "CLI entrypoint for joining a controller as a named execution node."

  alias CodingAgent.ExecutionNode.Worker

  @switches [
    name: :string,
    controller: :string,
    pair: :boolean,
    operator_token: :string,
    token: :string,
    cwd: :string,
    help: :boolean
  ]

  @aliases [h: :help]

  @spec main([String.t()]) :: no_return() | :ok
  def main(argv) do
    case run(argv) do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "lemon node join: #{message}")
        System.halt(2)
    end
  end

  @spec run([String.t()], keyword()) :: :ok | {:error, String.t()}
  def run(argv, deps \\ []) do
    Process.flag(:trap_exit, true)

    with {:ok, opts} <- parse(argv),
         false <- opts[:help] == true,
         {:ok, _started} <- Application.ensure_all_started(:coding_agent),
         {:ok, worker} <-
           Worker.start_link(
             node_name: opts[:name],
             controller: opts[:controller],
             pair: opts[:pair] == true,
             operator_token: opts[:operator_token] || System.get_env("LEMON_NODE_OPERATOR_TOKEN"),
             token: opts[:token] || System.get_env("LEMON_NODE_TOKEN"),
             cwd: default_cwd(opts),
             notify_pid: self(),
             socket_module: Keyword.get(deps, :socket_module, CodingAgent.ExecutionNode.Socket),
             executor_module: Keyword.get(deps, :executor_module, CodingAgent.Executor),
             token_store_module:
               Keyword.get(deps, :token_store_module, CodingAgent.ExecutionNode.TokenStore),
             token_store_opts: Keyword.get(deps, :token_store_opts, [])
           ) do
      monitor = Process.monitor(worker)
      await_worker(worker, monitor)
    else
      true ->
        IO.puts(help())
        :ok

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, format_reason(reason)}
    end
  end

  @spec parse([String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def parse(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} -> validate(opts)
      {_opts, positional, []} -> {:error, "unexpected arguments: #{Enum.join(positional, " ")}"}
      {_opts, _positional, invalid} -> {:error, "invalid options: #{inspect(invalid)}"}
    end
  end

  defp validate(opts) do
    cond do
      opts[:help] == true -> {:ok, opts}
      blank?(opts[:name]) -> {:error, "--name is required"}
      blank?(opts[:controller]) -> {:error, "--controller is required"}
      true -> {:ok, opts}
    end
  end

  defp await_worker(worker, monitor) do
    receive do
      {:execution_node_worker, ^worker, {:status, :online, node_id}} ->
        suffix = if is_binary(node_id), do: " (#{node_id})", else: ""
        IO.puts("Execution node online#{suffix}")
        await_worker(worker, monitor)

      {:execution_node_worker, ^worker, {:status, status}} ->
        IO.puts("Execution node #{status}")
        await_worker(worker, monitor)

      {:execution_node_worker, ^worker, {:status, status, _detail}} ->
        IO.puts("Execution node #{status}")
        await_worker(worker, monitor)

      {:DOWN, ^monitor, :process, ^worker, :normal} ->
        :ok

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        {:error, format_reason(reason)}

      {:EXIT, ^worker, _reason} ->
        await_worker(worker, monitor)
    end
  end

  @doc false
  def default_cwd(
        opts,
        launch_cwd \\ System.get_env("LEMON_NODE_LAUNCH_CWD"),
        process_cwd \\ File.cwd!()
      ) do
    opts[:cwd] || launch_cwd || process_cwd
  end

  @spec help() :: String.t()
  def help do
    """
    Usage: ./bin/lemon node join --name NAME --controller ws://HOST:4040/ws [options]

    Options:
      --pair                    Pair and store a controller-issued node token
      --operator-token TOKEN    Operator token used only during pairing
      --token TOKEN             Existing node session token (overrides stored token)
      --cwd PATH                Default local working directory (default: current directory)
      --help, -h                Show this help

    Prefer LEMON_NODE_OPERATOR_TOKEN and LEMON_NODE_TOKEN over command-line token
    flags so credentials do not enter shell history. Stored node tokens live only
    on this machine in a mode-0600 file keyed by node name.
    """
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp format_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 2_000)
  end
end

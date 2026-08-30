defmodule CodingAgent.ExecutionNode.CLI do
  @moduledoc "CLI entrypoint for joining a controller as a named execution node."

  alias CodingAgent.ExecutionNode.Worker

  @switches [
    name: :string,
    controller: :string,
    pair: :boolean,
    operator_token: :string,
    token: :string,
    node_id: :string,
    repair: :boolean,
    allow_insecure_controller: :boolean,
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
             node_id: opts[:node_id],
             repair: opts[:repair] == true,
             allow_insecure_controller: allow_insecure_controller?(opts),
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

  @doc false
  def allow_insecure_controller?(opts) do
    opts[:allow_insecure_controller] == true or
      enabled_env?("LEMON_NODE_ALLOW_INSECURE_CONTROLLER")
  end

  @spec help() :: String.t()
  def help do
    """
    Usage: ./bin/lemon node join --name NAME --controller wss://HOST/ws [options]

    Options:
      --pair                    Pair and store a controller-issued node token
      --operator-token TOKEN    Operator token used only during pairing
      --token TOKEN             Existing node session token (overrides stored token)
      --node-id ID              Load or repair a credential by durable controller node ID
      --repair                  Operator-authorized repair for a legacy record without a recovery token
      --allow-insecure-controller
                                Allow non-loopback ws:// only on development or a verified encrypted overlay
      --cwd PATH                Default local working directory (default: current directory)
      --help, -h                Show this help

    LEMON_NODE_OPERATOR_TOKEN must match the controller's
    LEMON_CONTROL_PLANE_OPERATOR_TOKEN when operator authentication is enabled.
    Prefer LEMON_NODE_OPERATOR_TOKEN and LEMON_NODE_TOKEN over command-line token
    flags so credentials do not enter shell history. Stored node tokens live only
    on this machine in a mode-0600 file keyed by durable node ID. Non-loopback
    controllers require wss:// by default. The insecure override is acceptable
    only when another verified transport layer, such as Tailscale, encrypts and
    authenticates the complete path.
    """
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp format_reason(:operator_token_required) do
    "the controller requires an operator token for pairing; set LEMON_NODE_OPERATOR_TOKEN or pass --operator-token"
  end

  defp format_reason(:operator_token_invalid) do
    "the controller rejected the operator token; check LEMON_NODE_OPERATOR_TOKEN or --operator-token"
  end

  defp format_reason(:controller_operator_token_not_configured) do
    "the remote controller has not configured LEMON_CONTROL_PLANE_OPERATOR_TOKEN; configure it on the controller before pairing"
  end

  defp format_reason(:operator_authentication_failed) do
    "operator authentication failed while pairing"
  end

  defp format_reason(:node_authentication_failed) do
    "node authentication failed; rotate it with --pair or provide a valid LEMON_NODE_TOKEN"
  end

  defp format_reason(:missing_node_recovery_token) do
    "the legacy node credential has no recovery token; rerun --pair --repair with operator authorization"
  end

  defp format_reason(:insecure_controller_url) do
    "non-loopback ws:// controllers are blocked; use wss:// or explicitly pass --allow-insecure-controller only for development or a verified encrypted overlay"
  end

  defp format_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 1_000)
    |> String.slice(0, 2_000)
  end

  defp enabled_env?(name) do
    System.get_env(name) in ["1", "true", "TRUE", "yes", "YES", "on", "ON"]
  end
end

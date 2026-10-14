defmodule CodingAgent.ExecutionNode.CLI do
  @moduledoc "CLI entrypoint for joining a controller as a named execution node."

  alias CodingAgent.ExecutionNode.Worker

  @switches [
    name: :string,
    controller: :string,
    pair: :boolean,
    operator_token: :string,
    invite_code_stdin: :boolean,
    token: :string,
    node_id: :string,
    repair: :boolean,
    allow_insecure_controller: :boolean,
    allowed_root: [:string, :keep],
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
  def run(argv, deps \\ [])

  def run(["capabilities" | argv], deps) do
    case OptionParser.parse(argv, strict: [json: :boolean, require_bot: :boolean,
           expected_version: :string, help: :boolean], aliases: @aliases) do
      {opts, [], []} ->
        if opts[:help] do
          IO.puts(help())
          :ok
        else
          provider = Keyword.get(deps, :runtime_features, &Worker.runtime_features/0)
          snapshot = provider.()
          if opts[:json] do
            IO.puts(Jason.encode!(snapshot))
          else
            IO.puts("Lemon #{snapshot["lemonVersion"]}; bot runtime compatible: #{snapshot["botReady"]}")
            IO.puts("Missing features: #{Enum.join(snapshot["missingFeatures"], ", ")}")
          end
          cond do
            opts[:expected_version] &&
                (byte_size(opts[:expected_version]) > 64 or not LemonCore.Update.Version.valid?(opts[:expected_version])) ->
              {:error, "--expected-version must be an exact Lemon CalVer"}
            opts[:expected_version] && opts[:expected_version] != snapshot["lemonVersion"] ->
              {:error, "Installed Lemon version does not match the configured worker build"}
            opts[:require_bot] && snapshot["botReady"] != true ->
              {:error, "Compatible bot worker APIs are missing; use the matching source checkout or an operator-supported build"}
            true -> :ok
          end
        end
      _ -> {:error, "invalid compatibility inspection options"}
    end
  end

  def run(argv, deps) do
    Process.flag(:trap_exit, true)

    with {:ok, opts} <- parse(argv),
         false <- opts[:help] == true,
         :ok <- require_invite_features(opts, deps),
         {:ok, opts} <- read_invite(opts),
         {:ok, _started} <- Application.ensure_all_started(:coding_agent),
         {:ok, worker} <-
           Worker.start_link(
             node_name: opts[:name],
             controller: opts[:controller],
             pair: opts[:pair] == true,
             operator_token: opts[:operator_token] || System.get_env("LEMON_NODE_OPERATOR_TOKEN"),
             invite_code: opts[:invite_code],
             token: opts[:token] || System.get_env("LEMON_NODE_TOKEN"),
             node_id: opts[:node_id],
             repair: opts[:repair] == true,
             allowed_roots: allowed_roots(opts),
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
      {_opts, _positional, []} -> {:error, "unexpected arguments"}
      {_opts, _positional, _invalid} -> {:error, "invalid options"}
    end
  end

  defp require_invite_features(opts, deps) do
    if opts[:invite_code_stdin] do
      provider = Keyword.get(deps, :runtime_features, &Worker.runtime_features/0)
      if provider.()["botReady"] == true, do: :ok,
        else: {:error, "Invite enrollment requires the matching source checkout or a compatible host/MCP/stream/profile worker build"}
    else
      :ok
    end
  end

  defp validate(opts) do
    cond do
      opts[:help] == true -> {:ok, opts}
      blank?(opts[:name]) -> {:error, "--name is required"}
      blank?(opts[:controller]) -> {:error, "--controller is required"}
      opts[:invite_code_stdin] && Enum.any?([:node_id, :repair, :operator_token, :token],
                              &Keyword.has_key?(opts, &1)) ->
        {:error, "--invite-code-stdin cannot be combined with recovery or token flags"}
      opts[:invite_code_stdin] -> validate_invite_destination(Keyword.put(opts, :pair, true))
      true -> {:ok, opts}
    end
  end

  defp validate_invite_destination(opts) do
    uri = URI.parse(opts[:controller])
    if byte_size(opts[:name]) in 1..64 and
         not String.match?(opts[:name], ~r/[\x00-\x1f\x7f]/) and
         byte_size(opts[:controller]) <= 2048 and
         uri.scheme in ["ws", "wss"] and is_binary(uri.host) and uri.host != "" and
         uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
         (is_nil(uri.port) or (is_integer(uri.port) and uri.port in 1..65_535)) and
         not String.match?(opts[:controller], ~r/[\s\x00-\x1f\x7f]/) and
         (uri.scheme == "wss" or uri.host in ["localhost", "127.0.0.1", "::1"]) do
      {:ok, opts}
    else
      {:error, "invalid enrollment name or secure controller URL"}
    end
  rescue
    ArgumentError -> {:error, "invalid enrollment name or secure controller URL"}
  end

  defp read_invite(opts) do
    if opts[:invite_code_stdin] do
      case IO.binread(:stdio, 45) do
        <<code::binary-size(43), "\n">> ->
          if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, code),
            do: {:ok, Keyword.put(opts, :invite_code, code)},
            else: {:error, "invalid enrollment credential on stdin"}
        _ -> {:error, "expected a 43-character enrollment credential and newline on stdin"}
      end
    else
      {:ok, opts}
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
  def allowed_roots(opts) do
    Enum.uniq([System.user_home!() | Keyword.get_values(opts, :allowed_root)])
  end


  @doc false
  def allow_insecure_controller?(opts) do
    opts[:allow_insecure_controller] == true or
      enabled_env?("LEMON_NODE_ALLOW_INSECURE_CONTROLLER")
  end

  @spec help() :: String.t()
  def help do
    """
    Usage: lemon node join --name NAME --controller wss://HOST/ws [options]
           lemon node capabilities [--json] [--require-bot] [--expected-version VERSION]

    Options:
      --pair                    Pair and store a controller-issued node token
      --operator-token TOKEN    Operator token used only during pairing
      --invite-code-stdin       Read one bounded enrollment code from stdin (implies --pair)
      --token TOKEN             Existing node session token (overrides stored token)
      --node-id ID              Load or repair a credential by durable controller node ID
      --repair                  Operator-authorized repair for a legacy record without a recovery token
      --allow-insecure-controller
                                Allow non-loopback ws:// only on development or a verified encrypted overlay
      --cwd PATH                Default local working directory (default: current directory)
      --allowed-root PATH       Allowed host file/shell root (repeatable; default: home directory)
      --help, -h                Show this help

    Compatibility inspection runs locally without starting another runtime.
    --require-bot fails closed unless the installed host, file CAS/preview,
    secret-receipt, PTY, MCP discovery, profile sync and live-stream APIs exist.
    A matching version alone does not establish compatibility. Provider login
    and OS grants remain destination-local prerequisites, inspected separately.

    LEMON_NODE_OPERATOR_TOKEN must match the controller's
    LEMON_CONTROL_PLANE_OPERATOR_TOKEN when operator authentication is enabled.
    Prefer LEMON_NODE_OPERATOR_TOKEN and LEMON_NODE_TOKEN over command-line token
    flags so credentials do not enter shell history. The repository join script
    prompts with hidden terminal input and sends the one-use enrollment code only
    through stdin, never command arguments or environment variables.
    A repair invite's durable node ID is bound by the controller, not a CLI flag.
    Stored node tokens live only on this machine in a mode-0600 file keyed by durable node ID. Non-loopback
    controllers require wss:// by default. The insecure override is acceptable
    only when another verified transport layer, such as Tailscale, encrypts and
    authenticates the complete path.
    File RPC paths and shell working directories use --allowed-root (home by default).
    Explicit roots extend the home default; repeat the flag to permit multiple roots.
    """
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp format_reason({:pairing_failed, :outcome_unknown}) do
    "enrollment outcome is unknown; do not retry this code; ask the owner to reconcile the durable node and issue a repair invitation if needed"
  end

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

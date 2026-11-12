defmodule LemonAi.Auth.OmpToken do
  @moduledoc """
  Access-only bridge to omp's Kimi Code login. omp owns refresh and its leases;
  Lemon never reads or stores omp's refresh credentials. Access tokens are cached
  only in this BEAM node's memory, until two minutes before their JWT expiry.

  Execution is argv-only, with closed stdin, a 20-second deadline and a 64 KiB
  combined-output limit. Only stable, credential-free errors leave the adapter.
  """

  alias LemonAi.Auth.{KimiCodeOAuth, OAuthFlow}

  @timeout_ms 20_000
  @max_output_bytes 65_536
  @skew_s 120

  @spec discover(String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def discover(path \\ nil) do
    candidates =
      if is_nil(path) do
        home = System.get_env("HOME") || System.user_home!()
        [System.find_executable("omp"), Path.join(home, ".bun/bin/omp")]
      else
        [path]
      end

    case Enum.find(candidates, &executable?/1) do
      nil -> {:error, :omp_not_found}
      executable -> {:ok, Path.expand(executable)}
    end
  end

  @spec resolve(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, atom()}
  def resolve(path \\ nil, opts \\ []) do
    with {:ok, executable} <- discover(path) do
      scope =
        Enum.map(~w(HOME XDG_CONFIG_HOME PI_CODING_AGENT_DIR OMP_PROFILE), &System.get_env/1)

      key = {__MODULE__, executable, scope}
      :global.trans({key, self()}, fn -> resolve_cached(key, executable, opts) end, [node()])
    end
  end

  # Hold the per-key lock through publication so an ordinary in-flight fetch
  # cannot restore a rejected token after another caller's forced refresh.
  defp resolve_cached(key, executable, opts) do
    now = System.system_time(:second)
    cached = :persistent_term.get(key, nil)

    if not Keyword.get(opts, :force_refresh, false) and fresh?(cached, now) do
      {token, _exp} = cached
      {:ok, token}
    else
      :persistent_term.erase(key)

      args =
        ["token", "kimi-code"] ++ if(opts[:force_refresh], do: ["--force-refresh"], else: [])

      with {:ok, output} <- run(executable, args),
           {:ok, token, exp} <- parse(output, System.system_time(:second)) do
        if exp > System.system_time(:second) + @skew_s,
          do: :persistent_term.put(key, {token, exp})

        {:ok, token}
      end
    end
  end

  @doc "Credential-free guidance suitable for operator diagnostics."
  def error_message(:omp_not_found),
    do:
      "omp was not found; install omp or set providers.kimi_coding.omp_path to its absolute executable path."

  def error_message(:omp_exit_nonzero),
    do: "omp could not provide a Kimi Code token; run `omp` and `/login kimi-code`, then retry."

  def error_message(:omp_invalid_token),
    do: "omp output was not a JWT; update omp and retry `omp token kimi-code`."

  def error_message(:omp_expired_token),
    do: "omp returned an expired JWT; run `omp token kimi-code --force-refresh` and retry."

  def error_message(:omp_timeout),
    do: "omp token timed out; run `omp` and `/login kimi-code`, then retry."

  def error_message(:omp_output_too_large),
    do: "omp token exceeded the output limit; update omp and retry."

  def error_message(_),
    do:
      "omp token could not start; check providers.kimi_coding.omp_path and executable permissions."

  defp executable?(path) when is_binary(path) do
    Path.type(path) == :absolute and
      case File.stat(path) do
        {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _ -> false
      end
  end

  defp executable?(_), do: false

  defp fresh?({token, exp}, now), do: is_binary(token) and exp > now + @skew_s
  defp fresh?(_, _), do: false

  defp parse(output, now) do
    token =
      if String.valid?(output) do
        output
        |> String.split("\n")
        |> Enum.reverse()
        |> Enum.find_value(fn line ->
          candidate = String.trim(line)
          if KimiCodeOAuth.oauth_token?(candidate), do: candidate
        end)
      end

    if token do
      case OAuthFlow.jwt_claims(token) do
        %{"exp" => exp} when is_integer(exp) and exp > now -> {:ok, token, exp}
        _ -> {:error, :omp_expired_token}
      end
    else
      {:error, :omp_invalid_token}
    end
  end

  defp run(executable, args) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> send(caller, {ref, execute(executable, args)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :omp_spawn_failed}
    after
      @timeout_ms + 1_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :omp_timeout}
    end
  end

  defp execute(executable, args) do
    # :in opens only the child's stdout pipe; its stdin is /dev/null.
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :in,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:env, [{~c"KIMI_API_KEY", false}, {~c"MOONSHOT_API_KEY", false}]},
        {:args, Enum.map(args, &String.to_charlist/1)}
      ])

    try do
      collect(port, System.monotonic_time(:millisecond) + @timeout_ms, [], 0)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> {:error, :omp_spawn_failed}
  end

  defp collect(port, deadline, chunks, size) do
    receive do
      {^port, {:data, data}} ->
        if size + byte_size(data) > @max_output_bytes do
          {:error, :omp_output_too_large}
        else
          collect(port, deadline, [data | chunks], size + byte_size(data))
        end

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :omp_exit_nonzero}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :omp_timeout}
    end
  end
end

defmodule CodingAgent.Tools.Bash.ShellState do
  @moduledoc """
  Per-session shell state (cwd and exported environment) carried between
  foreground bash calls.

  State lives in memory only, keyed by session id and owned by its session pid.
  It is discarded when that process exits or is replaced, and never persists a
  cwd outside the session workspace. Only environment variables with valid names
  that differ from the host environment are retained; shell functions, aliases
  and jobs are not. Capture tokens prevent commands from restoring discarded
  state after a reset, owner replacement, or owner exit.
  """

  use GenServer

  @ignored_env ~w(PWD OLDPWD SHLVL _ BASH_EXECUTION_STRING)
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(_opts), do: {:ok, %{sessions: %{}, monitors: %{}}}

  @doc """
  Establishes session ownership and returns its cwd, environment, and capture token.

  A different owner starts with empty state. The token must be passed to
  `capture/6`; it becomes invalid on reset, owner replacement, or owner exit.
  """
  @spec get(term(), String.t(), pid()) :: %{
          cwd: String.t() | nil,
          env: %{optional(String.t()) => String.t()},
          token: reference() | nil
        }
  def get(nil, _workspace, _owner_pid), do: empty_state()

  def get(session_id, workspace, owner_pid) when is_pid(owner_pid) do
    state = GenServer.call(__MODULE__, {:get, session_id, owner_pid})

    if state.cwd && File.dir?(state.cwd) && within?(state.cwd, workspace),
      do: state,
      else: %{state | cwd: nil}
  end

  @doc "Discards the session's shell state."
  @spec reset(term()) :: :ok
  def reset(nil), do: :ok

  def reset(session_id), do: GenServer.call(__MODULE__, {:reset, session_id})

  @doc """
  Records state captured after a command if its ownership token is still current.

  `cwd_file` holds `pwd -P` output and `env_file` the NUL-separated `env -0`
  dump; `call_env` (per-call variables) is excluded from persistence unless the
  command changed it. Captures never establish ownership or recreate state.
  """
  @spec capture(term(), reference() | nil, String.t(), String.t(), String.t(), map()) :: :ok
  def capture(nil, _token, _workspace, _cwd_file, _env_file, _call_env), do: :ok
  def capture(_session_id, nil, _workspace, _cwd_file, _env_file, _call_env), do: :ok

  def capture(session_id, token, workspace, cwd_file, env_file, call_env) do
    cwd = read_cwd(cwd_file, workspace)
    env = read_env(env_file, call_env)
    GenServer.call(__MODULE__, {:capture, session_id, token, cwd, env})
  end

  @impl true
  def handle_call({:get, session_id, owner_pid}, _from, state) do
    if Process.alive?(owner_pid) do
      {entry, state} =
        case Map.get(state.sessions, session_id) do
          %{owner_pid: ^owner_pid} = entry ->
            {entry, state}

          _ ->
            state = discard(state, session_id)
            token = Process.monitor(owner_pid)
            entry = %{owner_pid: owner_pid, token: token, cwd: nil, env: %{}}

            {entry,
             %{
               state
               | sessions: Map.put(state.sessions, session_id, entry),
                 monitors: Map.put(state.monitors, token, session_id)
             }}
        end

      {:reply, Map.take(entry, [:cwd, :env, :token]), state}
    else
      {:reply, empty_state(), discard(state, session_id)}
    end
  end

  def handle_call({:reset, session_id}, _from, state) do
    {:reply, :ok, discard(state, session_id)}
  end

  def handle_call({:capture, session_id, token, cwd, env}, _from, state) do
    state =
      case Map.get(state.sessions, session_id) do
        %{token: ^token} = entry ->
          if Process.alive?(entry.owner_pid) do
            entry = %{entry | cwd: cwd || entry.cwd, env: env || entry.env}
            %{state | sessions: Map.put(state.sessions, session_id, entry)}
          else
            discard(state, session_id)
          end

        _ ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, token, :process, _owner_pid, _reason}, state) do
    case Map.fetch(state.monitors, token) do
      {:ok, session_id} -> {:noreply, discard(state, session_id)}
      :error -> {:noreply, state}
    end
  end

  defp empty_state, do: %{cwd: nil, env: %{}, token: nil}

  defp discard(state, session_id) do
    case Map.pop(state.sessions, session_id) do
      {nil, _sessions} ->
        state

      {%{token: token}, sessions} ->
        Process.demonitor(token, [:flush])
        %{state | sessions: sessions, monitors: Map.delete(state.monitors, token)}
    end
  end

  defp read_cwd(file, workspace) do
    with {:ok, raw} <- File.read(file),
         cwd = String.trim_trailing(raw, "\n"),
         true <- cwd != "" and File.dir?(cwd),
         true <- within?(cwd, workspace) do
      cwd
    else
      _ -> nil
    end
  end

  defp read_env(file, call_env) do
    case File.read(file) do
      {:ok, raw} when raw != "" ->
        base = System.get_env()

        raw
        |> String.split(<<0>>, trim: true)
        |> Enum.flat_map(fn entry ->
          case String.split(entry, "=", parts: 2) do
            [name, value] -> [{name, value}]
            _ -> []
          end
        end)
        |> Enum.reject(fn {name, value} ->
          not Regex.match?(@env_name, name) or name in @ignored_env or
            Map.get(base, name) == value or Map.get(call_env, name) == value
        end)
        |> Map.new()

      _ ->
        nil
    end
  end

  @doc false
  def within?(path, workspace) do
    with {:ok, root} <- real(workspace),
         {:ok, target} <- real(path) do
      target == root or String.starts_with?(target, String.trim_trailing(root, "/") <> "/")
    else
      _ -> false
    end
  end

  # Follow links before interpreting subsequent parent components. Expanding a
  # link target first would incorrectly collapse "link/.." lexically.
  defp real(path) do
    parts =
      if Path.type(path) == :absolute,
        do: Path.split(path),
        else: Path.split(File.cwd!()) ++ Path.split(path)

    walk(parts, "/", 40)
  end

  defp walk([], current, _hops), do: {:ok, current}
  defp walk(["/" | rest], _current, hops), do: walk(rest, "/", hops)
  defp walk(["." | rest], current, hops), do: walk(rest, current, hops)
  defp walk([".." | rest], current, hops), do: walk(rest, Path.dirname(current), hops)

  defp walk([part | rest], current, hops) do
    next = Path.join(current, part)

    case File.lstat(next) do
      {:ok, %{type: :symlink}} when hops > 0 ->
        with {:ok, target} <- File.read_link(next) do
          parts =
            if Path.type(target) == :absolute,
              do: Path.split(target),
              else: Path.split(current) ++ Path.split(target)

          walk(parts ++ rest, "/", hops - 1)
        end

      {:ok, %{type: :symlink}} ->
        {:error, :symlink_loop}

      {:ok, %{type: type}} when rest != [] and type != :directory ->
        {:error, :not_directory}

      {:ok, _} ->
        walk(rest, next, hops)

      {:error, reason} ->
        {:error, reason}
    end
  end
end

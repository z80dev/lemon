defmodule LemonOmp do
  @moduledoc """
  Lemon's omp delegate: start, observe, steer, cancel and resume omp sessions.

  omp (oh-my-pi) is an external coding agent. Lemon never runs it as an
  executor; it spawns `omp --mode rpc` processes on request, follows their
  structured event stream and exposes a bounded projection of each session.
  See `LemonOmp.Session` for process lifecycle, `LemonOmp.Projection` for the
  snapshot shape and `LemonOmp.SessionFiles` for read-only discovery.

  Every function returns JSON-safe maps with camelCase string keys. Strings
  that came from omp are untrusted data.

  ## Ownership

  `opts[:owner]` scopes access. `:any` is the operator (control plane, CLI,
  TUI). `{:session_key, key}` is a Lemon agent session: it sees and controls only
  sessions it started, and a foreign id is indistinguishable from a missing one.
  """

  alias LemonOmp.{Config, Manager, Projection, Session, SessionFiles}

  @thinking_levels ~w(off minimal low medium high xhigh max auto)
  @approval_modes ~w(always-ask write yolo)
  @model_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._:\/@+-]{0,127}\z/
  @resume_pattern ~r/\A[0-9A-Za-z][0-9A-Za-z-]{3,63}\z/
  @max_prompt_bytes 65_536
  @max_message_bytes 16_384
  @default_list_limit 50
  @max_list_limit 100

  @type owner_filter :: :any | {:session_key, String.t()}
  @type reason ::
          :not_installed
          | :invalid_cwd
          | :invalid_prompt
          | :invalid_params
          | :too_many_sessions
          | :not_found
          | :not_running
          | :not_ready
          | :no_active_turn
          | {:rejected, String.t()}
          | {:startup_failed, String.t()}
          | :startup_failed
          | :outcome_unknown
          | {:outcome_unknown, String.t()}
          | :invalid_message
          | :unavailable

  @doc "Bus topic carrying `:omp_session` events."
  @spec bus_topic() :: String.t()
  defdelegate bus_topic(), to: Manager

  @doc "Whether omp is installed, its version, and live-session counts."
  @spec status() :: map()
  def status do
    case Config.executable() do
      nil ->
        %{
          "available" => false,
          "version" => nil,
          "reason" => "not_installed",
          "live" => Manager.live_count(),
          "maxSessions" => Config.max_sessions()
        }

      executable ->
        %{
          "available" => true,
          "version" => version(executable),
          "reason" => nil,
          "live" => Manager.live_count(),
          "maxSessions" => Config.max_sessions()
        }
    end
  end

  @doc "Known sessions (live and recently ended), newest first."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    owner = Keyword.get(opts, :owner, :any)
    include_ended = Keyword.get(opts, :include_ended, true)
    limit = clamp(Keyword.get(opts, :limit), @default_list_limit, @max_list_limit)

    Manager.all()
    |> Enum.filter(fn {_id, pid, wire} ->
      owns?(owner, wire) and (include_ended or Manager.live?(pid, wire))
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {_id, _pid, wire} -> wire end)
  end

  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def get(id, opts \\ []) do
    with {:ok, _pid, wire} <- fetch(id, opts), do: {:ok, wire}
  end

  @doc "A bounded plain-text report of what a session is doing."
  @spec summary(String.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def summary(id, opts \\ []) do
    with {:ok, wire} <- get(id, opts), do: {:ok, Projection.summary(wire)}
  end

  @doc """
  Start an omp process for `params` (`prompt`, `cwd`, optional `model`,
  `thinking`, `resume`, `approval_mode`). Approval mode is `always-ask`, `write`
  or `yolo`; omitting it keeps omp's configured mode. Returns once omp
  acknowledged the prompt, or once it is ready when resuming without one.
  """
  @spec start(map(), keyword()) :: {:ok, map()} | {:error, reason()}
  def start(params, opts \\ []) when is_map(params) do
    with {:ok, executable} <- executable(),
         {:ok, params} <- validate_start(params) do
      start_validated(params, executable, opts)
    end
  end

  @doc """
  Validate every task before starting any, then start concurrently within the
  live-session cap. Results retain input order, including outcome-unknown ids.
  Invalid task indexes are zero-based. Admission is also enforced per start.
  """
  @spec start_many([map()], keyword()) ::
          [{:ok, map()} | {:error, reason()}]
          | {:error, {:invalid_task, non_neg_integer(), reason()} | reason()}
  def start_many(tasks, opts \\ [])

  def start_many(tasks, opts) when is_list(tasks) do
    with {:ok, params} <- validate_tasks(tasks),
         true <- length(params) <= Config.max_sessions() - Manager.live_count(),
         {:ok, executable} <- executable() do
      params
      |> Task.async_stream(&start_validated(&1, executable, opts),
        max_concurrency: Config.max_sessions(),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
    else
      false -> {:error, :too_many_sessions}
      {:error, _} = error -> error
    end
  end

  def start_many(_tasks, _opts), do: {:error, :invalid_params}

  defp validate_tasks(tasks) do
    tasks
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {task, index}, {:ok, acc} ->
      case validate_start(task) do
        {:ok, params} -> {:cont, {:ok, [params | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_task, index, reason}}}
      end
    end)
    |> case do
      {:ok, params} -> {:ok, Enum.reverse(params)}
      error -> error
    end
  end

  defp validate_start(params) when is_map(params) do
    params = normalize_keys(params)

    with {:ok, cwd} <- validate_cwd(params["cwd"]),
         {:ok, resume} <- validate_optional(params["resume"], @resume_pattern),
         {:ok, prompt} <- validate_prompt(params["prompt"], resume),
         {:ok, model} <- validate_optional(params["model"], @model_pattern),
         {:ok, thinking} <- validate_thinking(params["thinking"]),
         {:ok, approval_mode} <- validate_approval_mode(params["approval_mode"]) do
      {:ok,
       [
         cwd: cwd,
         prompt: prompt,
         model: model,
         thinking: thinking,
         resume: resume,
         approval_mode: approval_mode
       ]}
    end
  end

  defp validate_start(_params), do: {:error, :invalid_params}

  defp start_validated(params, executable, opts) do
    id = "omp_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    session_opts =
      Keyword.merge(params,
        id: id,
        executable: executable,
        owner: normalize_owner(Keyword.get(opts, :owner, %{kind: :operator}))
      )

    with {:ok, pid} <- Manager.start_session(session_opts, Config.max_sessions()) do
      case Session.await_started(pid, Config.ready_timeout_ms() + Config.command_timeout_ms()) do
        {:error, {:rejected, _message}} = error ->
          # omp is up but refused the task; nothing will run, so do not leave
          # an idle process behind.
          :ok = Session.close(pid)
          error

        {:error, :outcome_unknown} ->
          # omp never acknowledged the prompt, so it may or may not run. Keep
          # the process and hand back its fixed id so the caller can
          # reconcile (status) or close it instead of retrying blind.
          {:error, {:outcome_unknown, id}}

        result ->
          result
      end
    end
  end

  @doc """
  Steer the running turn (`:steer`), queue a follow-up (`:follow_up`), or stop
  it and start over atomically in omp (`:redirect`). When the session is idle,
  every mode starts a new turn with `message`.
  """
  @spec send_message(String.t(), String.t(), :steer | :follow_up | :redirect, keyword()) ::
          {:ok, map()} | {:error, reason()}
  def send_message(id, message, mode, opts \\ [])
      when mode in [:steer, :follow_up, :redirect] do
    with {:ok, message} <- validate_message(message),
         {:ok, pid} <- fetch_live(id, opts) do
      Session.send_message(pid, message, mode)
    end
  end

  @doc "Abort the in-flight turn. The process stays open for follow-ups."
  @spec cancel(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def cancel(id, opts \\ []) do
    with {:ok, pid} <- fetch_live(id, opts), do: Session.cancel(pid)
  end

  @doc "End the omp process. Its session file stays resumable."
  @spec close(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def close(id, opts \\ []) do
    with {:ok, pid} <- fetch_live(id, opts) do
      :ok = Session.close(pid)
      get(id, opts)
    end
  end

  @doc """
  Wait until the session settles, closes, or `timeout_ms` passes, calling
  `opts[:on_update]` with each published snapshot. `opts[:signal]` (an abort
  signal) stops the wait — it never cancels the omp turn.
  """
  @spec wait(String.t(), non_neg_integer(), keyword()) ::
          {:ok, map(), :settled | :timeout | :aborted} | {:error, :not_found}
  def wait(id, timeout_ms, opts \\ []) do
    topic = bus_topic()
    LemonCore.Bus.subscribe(topic)

    try do
      with {:ok, wire} <- get(id, opts) do
        notify(opts[:on_update], wire)

        if wire["status"] in ["running", "starting"] do
          deadline = System.monotonic_time(:millisecond) + timeout_ms
          wait_loop(id, wire, deadline, opts)
        else
          {:ok, wire, :settled}
        end
      end
    after
      LemonCore.Bus.unsubscribe(topic)
      flush_events()
    end
  end

  @doc """
  Wait for all sessions (or any one with `mode: :any`) using one Bus
  subscription. Updates contain the full input-ordered list, at most once per
  300 ms plus an unconditional final update. Timeout/abort only stop waiting.
  """
  @spec wait_many([String.t()], non_neg_integer(), keyword()) ::
          {:ok, [map()], :settled | :timeout | :aborted} | {:error, :not_found}
  def wait_many(ids, timeout_ms, opts \\ []) do
    topic = bus_topic()
    LemonCore.Bus.subscribe(topic)

    try do
      with {:ok, wires} <- fetch_many(ids, opts) do
        state = %{
          ids: ids,
          wires: Map.new(wires, &{&1["id"], &1}),
          deadline: System.monotonic_time(:millisecond) + timeout_ms,
          last_update: System.monotonic_time(:millisecond),
          dirty: false
        }

        wait_many_loop(state, opts)
      end
    after
      LemonCore.Bus.unsubscribe(topic)
      flush_events()
    end
  end

  defp fetch_many(ids, opts) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case get(id, opts) do
        {:ok, wire} -> {:cont, {:ok, [wire | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, wires} -> {:ok, Enum.reverse(wires)}
      error -> error
    end
  end

  defp wait_many_loop(state, opts) do
    wires = Enum.map(state.ids, &Map.fetch!(state.wires, &1))
    now = System.monotonic_time(:millisecond)
    settled? = &(&1["status"] in ["idle", "closed", "failed"])

    reason =
      cond do
        wires == [] -> :settled
        opts[:mode] == :any and Enum.any?(wires, settled?) -> :settled
        opts[:mode] != :any and Enum.all?(wires, settled?) -> :settled
        aborted?(opts[:signal]) -> :aborted
        now >= state.deadline -> :timeout
        true -> nil
      end

    if reason do
      notify(opts[:on_update], wires)
      {:ok, wires, reason}
    else
      state =
        if state.dirty and now - state.last_update >= 300 do
          notify(opts[:on_update], wires)
          %{state | last_update: now, dirty: false}
        else
          state
        end

      receive do
        %LemonCore.Event{type: :omp_session, payload: %{"session" => %{"id" => id} = next}}
        when is_map_key(state.wires, id) ->
          wait_many_loop(%{state | wires: Map.put(state.wires, id, next), dirty: true}, opts)
      after
        min(100, max(state.deadline - now, 0)) -> wait_many_loop(state, opts)
      end
    end
  end

  defp wait_loop(id, wire, deadline, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      aborted?(opts[:signal]) ->
        {:ok, wire, :aborted}

      remaining <= 0 ->
        {:ok, wire, :timeout}

      true ->
        receive do
          %LemonCore.Event{type: :omp_session, payload: %{"session" => %{"id" => ^id} = next} = p} ->
            notify(opts[:on_update], next)

            if p["reason"] in ["settled", "exited"] or
                 next["status"] in ["idle", "closed", "failed"] do
              {:ok, next, :settled}
            else
              wait_loop(id, next, deadline, opts)
            end
        after
          min(remaining, 500) -> wait_loop(id, wire, deadline, opts)
        end
    end
  end

  defp notify(fun, wire) when is_function(fun, 1), do: fun.(wire)
  defp notify(_fun, _wire), do: :ok

  defp aborted?(nil), do: false

  defp aborted?(signal) do
    LemonAgent.AbortSignal.aborted?(signal)
  rescue
    _ -> false
  end

  defp flush_events do
    receive do
      %LemonCore.Event{type: :omp_session} -> flush_events()
    after
      0 -> :ok
    end
  end

  @doc """
  Read-only list of omp's stored sessions for workspace `cwd`, marking any
  that a live Lemon invocation currently owns.
  """
  @spec discover(String.t(), keyword()) :: {:ok, [map()]} | {:error, reason()}
  def discover(cwd, opts \\ [])

  def discover(cwd, opts) when is_binary(cwd) do
    with {:ok, sessions} <-
           SessionFiles.discover(cwd, Keyword.take(opts, [:limit, :sessions_dir])) do
      live =
        for {_id, pid, wire} <- Manager.all(),
            Manager.live?(pid, wire),
            is_binary(wire["ompSessionId"]),
            into: %{},
            do: {wire["ompSessionId"], wire["id"]}

      {:ok,
       Enum.map(sessions, fn session ->
         case Map.get(live, session["ompSessionId"]) do
           nil -> session
           live_id -> %{session | "liveId" => live_id, "activeElsewhere" => false}
         end
       end)}
    end
  end

  def discover(_cwd, _opts), do: {:error, :invalid_cwd}

  @doc "A bounded, safe human message for an error reason."
  @spec error_message(term()) :: String.t()
  def error_message(:not_installed),
    do: "omp is not installed (no `omp` executable on PATH; set LEMON_OMP_BIN to point at it)."

  def error_message(:invalid_cwd), do: "cwd must be an existing directory."
  def error_message(:invalid_prompt), do: "prompt must be non-empty text (at most 64 KiB)."
  def error_message(:invalid_params), do: "invalid parameters."

  def error_message({:invalid_task, index, reason}),
    do: "task #{index + 1}: " <> error_message(reason)

  def error_message(:invalid_message), do: "message must be non-empty text (at most 16 KiB)."

  def error_message(:too_many_sessions),
    do: "too many live omp sessions; close one first (LEMON_OMP_MAX_SESSIONS raises the cap)."

  def error_message(:not_found), do: "no such omp session."

  def error_message(:not_running),
    do: "that omp session is no longer running; resume it to continue."

  def error_message(:not_ready), do: "that omp session is still starting."
  def error_message(:no_active_turn), do: "that omp session has no turn in progress."
  def error_message({:rejected, message}), do: "omp rejected the request: #{message}"
  def error_message({:startup_failed, message}), do: "omp failed to start: #{message}"
  def error_message(:startup_failed), do: "omp failed to start."

  def error_message({:outcome_unknown, id}),
    do:
      "omp did not confirm the prompt in time; session #{id} may already be working on it. Check its status before retrying."

  def error_message(:outcome_unknown),
    do:
      "omp did not confirm the request in time; it may already have taken effect. Check the session status before retrying."

  def error_message(:unavailable), do: "the omp integration is not running."
  def error_message(_reason), do: "the omp request failed."

  ## Internals

  defp fetch(id, opts) do
    owner = Keyword.get(opts, :owner, :any)

    case Manager.lookup(id) do
      {:ok, pid, wire} -> if owns?(owner, wire), do: {:ok, pid, wire}, else: {:error, :not_found}
      :error -> {:error, :not_found}
    end
  end

  defp fetch_live(id, opts) do
    with {:ok, pid, wire} <- fetch(id, opts) do
      if Manager.live?(pid, wire), do: {:ok, pid}, else: {:error, :not_running}
    end
  end

  defp owns?(:any, _wire), do: true

  defp owns?({:session_key, key}, %{"owner" => %{"kind" => "agent", "sessionKey" => key}})
       when is_binary(key),
       do: true

  defp owns?(_owner, _wire), do: false

  defp normalize_owner(%{kind: :agent, session_key: key} = owner)
       when is_binary(key) and key != "",
       do: Map.take(owner, [:kind, :session_key, :session_id, :run_id, :agent_id])

  defp normalize_owner(owner) when is_map(owner),
    do: owner |> Map.take([:session_id, :run_id, :agent_id]) |> Map.put(:kind, :operator)

  defp normalize_owner(_owner), do: %{kind: :operator}

  defp executable do
    case Config.executable() do
      nil -> {:error, :not_installed}
      path -> {:ok, path}
    end
  end

  defp validate_cwd(cwd) when is_binary(cwd) and cwd != "" do
    expanded = Path.expand(cwd)
    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, :invalid_cwd}
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_cwd}

  defp validate_prompt(prompt, resume) when is_binary(prompt) do
    trimmed = String.trim(prompt)

    cond do
      byte_size(prompt) > @max_prompt_bytes or not String.valid?(prompt) ->
        {:error, :invalid_prompt}

      trimmed == "" and is_binary(resume) ->
        {:ok, nil}

      trimmed == "" ->
        {:error, :invalid_prompt}

      true ->
        {:ok, prompt}
    end
  end

  defp validate_prompt(nil, resume) when is_binary(resume), do: {:ok, nil}
  defp validate_prompt(_prompt, _resume), do: {:error, :invalid_prompt}

  defp validate_message(message) when is_binary(message) do
    if String.trim(message) != "" and byte_size(message) <= @max_message_bytes and
         String.valid?(message),
       do: {:ok, message},
       else: {:error, :invalid_message}
  end

  defp validate_message(_message), do: {:error, :invalid_message}

  defp validate_optional(nil, _pattern), do: {:ok, nil}
  defp validate_optional("", _pattern), do: {:ok, nil}

  defp validate_optional(value, pattern) when is_binary(value) do
    if Regex.match?(pattern, value), do: {:ok, value}, else: {:error, :invalid_params}
  end

  defp validate_optional(_value, _pattern), do: {:error, :invalid_params}

  defp validate_thinking(nil), do: {:ok, nil}
  defp validate_thinking(""), do: {:ok, nil}
  defp validate_thinking(level) when level in @thinking_levels, do: {:ok, level}
  defp validate_thinking(_level), do: {:error, :invalid_params}

  defp validate_approval_mode(nil), do: {:ok, nil}
  defp validate_approval_mode(""), do: {:ok, nil}
  defp validate_approval_mode(mode) when mode in @approval_modes, do: {:ok, mode}
  defp validate_approval_mode(_mode), do: {:error, :invalid_params}

  defp normalize_keys(params), do: Map.new(params, fn {key, value} -> {to_string(key), value} end)

  defp clamp(value, _default, max) when is_integer(value) and value > 0, do: min(value, max)
  defp clamp(_value, default, _max), do: default

  defp version(executable) do
    # Keyed by the binary's mtime so an upgraded omp reports its new version.
    mtime =
      case File.stat(executable, time: :posix) do
        {:ok, %{mtime: mtime}} -> mtime
        _ -> nil
      end

    key = {__MODULE__, :version, executable, mtime}

    case :persistent_term.get(key, :unknown) do
      :unknown ->
        value = probe_version(executable)
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  defp probe_version(executable) do
    task =
      Task.async(fn ->
        System.cmd(executable, ["--version"], stderr_to_stdout: true, env: [{"NO_COLOR", "1"}])
      end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        output |> String.trim() |> String.split("\n") |> List.first() |> Projection.clean(64)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end

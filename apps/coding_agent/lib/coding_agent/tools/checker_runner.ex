defmodule CodingAgent.Tools.CheckerRunner do
  @moduledoc """
  Resolves and runs post-edit checkers and formatters.

  Executables come from the operator's `PATH`. An executable whose lexical
  path, canonical path or canonical parent directory lies inside the workspace
  or project root (lexical or canonical) is repo-controlled and refused unless
  the operator sets `runtime.tools.edit.repo_local_tools` (`:repo_local_tools`).
  A path that cannot be canonicalized is refused too.

  Each run is one `ProcessManager` launch under the session owner, with the
  checker deadline as its managed timeout. Its root shell is the process-group
  leader and stays alive as the group's anchor: it reads a per-run nonce from
  stdin, runs the checker as a child, prints `<nonce>:<status>` to its own
  stdout and then waits. The runner parses that line from a bounded tail of the
  managed artifact; abort and the deadline never wait on it. Completion, abort,
  timeout and the death of the calling task (a monitoring guard) all end
  through `ProcessManager.kill(id, :sigkill)`, i.e. `LemonCore.ProcessGroup`'s
  birth-bound ownership check against the live anchor, so descendants the
  checker forked are killed with it and no stale numeric group id is ever
  signalled. `ProcessSession` then observes the root exit and confirms
  termination, releasing the launch's capacity. A cleanup that cannot be
  confirmed is reported with its managed id.
  """

  alias CodingAgent.{ProcessManager, ProcessStore}
  alias LemonAgent.AbortSignal
  alias LemonCore.TrustedRoot

  @type run_result :: %{
          output: String.t(),
          exit_code: integer() | nil,
          timed_out: boolean(),
          cancelled: boolean()
        }

  @poll_ms 25
  @tail_bytes 16_384
  @stop_wait_ms 10_000
  @live_statuses [:queued, :starting, :running, :killing]

  @doc "Whether the operator allowed repo-controlled checker executables."
  @spec repo_local_allowed?(keyword()) :: boolean()
  def repo_local_allowed?(opts), do: Keyword.get(opts, :repo_local_tools, false) == true

  @doc """
  Finds `command` on `PATH`; `:repo_local` when it resolves inside any of
  `roots` (or cannot be canonicalized) and repo-local tools are not allowed.
  """
  @spec resolve(String.t(), [String.t() | nil], keyword()) ::
          {:ok, String.t()} | :missing | :repo_local
  def resolve(command, roots, opts) do
    case System.find_executable(command) do
      nil ->
        :missing

      executable ->
        if not repo_local_allowed?(opts) and inside_any?(executable, roots, opts),
          do: :repo_local,
          else: {:ok, executable}
    end
  end

  @doc """
  True when `path` (lexically, canonically, or by its canonical parent
  directory) lies inside one of `roots` (lexical or canonical), or when any of
  those canonical forms cannot be resolved. `:realpath` is a test seam.
  """
  @spec inside_any?(String.t(), [String.t() | nil], keyword()) :: boolean()
  def inside_any?(path, roots, opts \\ []) do
    realpath = Keyword.get(opts, :realpath, &TrustedRoot.realpath/1)
    path = Path.expand(path)
    roots = roots |> Enum.reject(&is_nil/1) |> Enum.map(&Path.expand/1)

    with {:ok, real_path} <- realpath.(path),
         {:ok, real_parent} <- realpath.(Path.dirname(path)),
         {:ok, real_roots} <- canonical_all(roots, realpath) do
      candidates = [path, real_path, real_parent]
      roots = roots ++ real_roots
      Enum.any?(candidates, fn candidate -> Enum.any?(roots, &under?(candidate, &1)) end)
    else
      _unresolvable -> true
    end
  end

  defp canonical_all(paths, realpath) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case realpath.(path) do
        {:ok, real} -> {:cont, {:ok, [real | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @doc "Runs `executable args` in `cwd` as an owner-bound managed process."
  @spec run(String.t(), [String.t()], String.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, run_result()} | {:error, term()}
  def run(executable, args, cwd, timeout_ms, max_bytes, opts) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    nonce = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    signal = Keyword.get(opts, :signal)

    # ProcessSession enforces the same deadline if this runner never gets to.
    launch = [
      command: anchored_command(executable, args),
      cwd: cwd,
      env: %{},
      launch_id: id,
      timeout_ms: timeout_ms,
      owner: Keyword.get(opts, :session_id),
      owner_pid: Keyword.get(opts, :session_pid)
    ]

    AbortSignal.subscribe(signal)
    guard = guard_caller(id)

    try do
      case ProcessManager.exec(launch) do
        {status, ^id} when status in [:ok, :queued] ->
          run_launched(id, nonce, signal, timeout_ms, max_bytes)

        {:error, {:outcome_unknown, ^id}} ->
          run_launched(id, nonce, signal, timeout_ms, max_bytes)

        {:error, reason} ->
          {:error, reason}
      end
    after
      send(guard, :release)
      AbortSignal.unsubscribe(signal)
    end
  end

  # If the calling tool task dies mid-run, the guard still stops the launch
  # through the verified kill; ProcessSession then releases its capacity.
  defp guard_caller(id) do
    caller = self()

    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        :release -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^caller, _} -> ProcessManager.kill(id, :sigkill)
      end
    end)
  end

  defp run_launched(id, nonce, signal, timeout_ms, max_bytes) do
    outcome = await(id, nonce, signal, deadline(timeout_ms), false)
    finish(id, outcome, nonce, max_bytes)
  end

  # The root shell ignores TERM (so a TERM to the group cannot remove the
  # anchor before the SIGKILL), reads the end-marker nonce from stdin, runs the
  # checker with closed stdin, prints `<nonce>:<status>` to its own stdout and
  # then holds the group open.
  defp anchored_command(executable, args) do
    checker = Enum.map_join([executable | args], " ", &shell_quote/1)

    "{ trap '' TERM; IFS= read -r lemon_nonce || exit 1; #{checker} </dev/null; s=$?; " <>
      "printf '\\n%s:%s\\n' \"$lemon_nonce\" \"$s\"; " <>
      "while :; do /bin/sleep 3600; done; }"
  end

  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  # Abort and the deadline are checked before anything else; parsing reads only
  # a bounded tail of the artifact. The nonce reaches the anchor over stdin
  # (retried while a queued launch is still starting) before the checker runs,
  # so it never appears in an argv or environment the checker could read.
  defp await(id, nonce, signal, deadline, sent?) do
    cond do
      AbortSignal.aborted?(signal) ->
        :cancelled

      System.monotonic_time(:millisecond) >= deadline ->
        :timed_out

      not sent? ->
        sent? = ProcessManager.write(id, nonce <> "\n") == :ok

        if not sent? and not live?(id),
          do: :anchor_lost,
          else: tick(id, nonce, signal, deadline, sent?)

      (code = exit_code(id, nonce)) != nil ->
        {:exited, code}

      not live?(id) ->
        :anchor_lost

      true ->
        tick(id, nonce, signal, deadline, sent?)
    end
  end

  defp tick(id, nonce, signal, deadline, sent?) do
    receive do
      {:lemon_abort, ^signal, _kind} -> :ok
    after
      @poll_ms -> :ok
    end

    await(id, nonce, signal, deadline, sent?)
  end

  defp exit_code(id, nonce) do
    case Regex.run(~r/\n#{Regex.escape(nonce)}:(\d{1,3})\n/, artifact_tail(id)) do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  defp live?(id) do
    case ProcessStore.get(id) do
      {:ok, %{status: status}, _} -> status in @live_statuses
      _ -> false
    end
  end

  defp finish(id, outcome, nonce, max_bytes) do
    output = read_output(id, nonce, max_bytes)

    with :ok <- stop(id, outcome) do
      case outcome do
        {:exited, code} ->
          {:ok, %{output: output, exit_code: code, timed_out: false, cancelled: false}}

        :cancelled ->
          {:ok, %{output: output, exit_code: nil, timed_out: false, cancelled: true}}

        :timed_out ->
          {:ok, %{output: output, exit_code: nil, timed_out: true, cancelled: false}}

        :anchor_lost ->
          {:error, {:outcome_unknown, id}}
      end
    end
  end

  # Kills the anchored group and waits for ProcessSession to confirm it.
  defp stop(id, outcome) do
    kill = if outcome == :anchor_lost, do: :skip, else: ProcessManager.kill(id, :sigkill)

    cond do
      kill not in [:ok, :skip] and kill != {:error, :process_not_running} ->
        {:error, {:checker_survived, id}}

      confirmed_stop?(id, deadline(@stop_wait_ms)) ->
        :ok

      true ->
        {:error, {:checker_survived, id}}
    end
  end

  defp confirmed_stop?(id, deadline) do
    case ProcessStore.get(id) do
      {:ok, %{status: status}, _} when status in [:lost, :unknown] ->
        false

      {:ok, %{status: status}, _} when status in @live_statuses ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(@poll_ms)
          confirmed_stop?(id, deadline)
        end

      {:ok, _record, _} ->
        true

      _ ->
        false
    end
  end

  defp read_output(id, nonce, max_bytes) do
    output =
      case String.split(read_artifact(id, :head, max_bytes + @tail_bytes), "\n" <> nonce <> ":",
             parts: 2
           ) do
        [before, _after] -> before
        [all] -> all
      end

    output = CodingAgent.BashExecutor.sanitize_output(output)

    if byte_size(output) > max_bytes, do: binary_part(output, 0, max_bytes), else: output
  end

  defp artifact_tail(id), do: read_artifact(id, :tail, @tail_bytes)

  defp read_artifact(id, side, bytes) do
    with {:ok, %{full_output_path: path}} when is_binary(path) <-
           ProcessManager.read_output(id, peek: true),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      offset = if side == :tail, do: max(size - bytes, 0), else: 0

      try do
        case :file.pread(file, offset, bytes) do
          {:ok, data} -> data
          _ -> ""
        end
      after
        File.close(file)
      end
    else
      _ -> ""
    end
  end
end

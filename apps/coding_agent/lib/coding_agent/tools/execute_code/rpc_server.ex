defmodule CodingAgent.Tools.ExecuteCode.RpcServer do
  @moduledoc """
  Temporary per-cell file-RPC pump for persistent `execute_code` sessions.

  Where `Rpc.serve/2` pumps requests for a single per-call script task, this
  GenServer pumps the rpc directory of one *cell* of a persistent python
  kernel. It is started by the execute_code session integration once per cell
  with the fresh `{dir, token}` bridge that `PythonRepl.Session` forwards to
  the runner, and it lives until the cell ends, the abort signal fires, or the
  owning caller dies.

  The server runs in its own process, outside `PythonRepl.Session`: a slow
  tool or an approval wait inside a sweep occupies only this process, so the
  session's Port frame handling and cancellation path are never blocked.

  ## Lifecycle

      {:ok, server} =
        RpcServer.start_link(%{
          tools: cell_tools,
          tool_policy: tool_policy,
          approval_context: approval_context,
          max_calls: config.max_rpc_calls,
          max_result_bytes: config.max_rpc_result_bytes,
          signal: signal,
          rpc_dir: bridge.dir,
          token: bridge.token
        })

      # ... cell runs; the runner configured lemon_tools with the same
      # {dir, token} pair ...

      stats = RpcServer.stats(server)
      :ok = RpcServer.stop(server)

    * `start_link/2` validates the ctx, links and monitors the calling
      process (the future session integration), and schedules the first poll.
    * Every `poll_interval_ms` the server checks the abort signal and then
      runs exactly one sweep; sweeps never overlap, so accounting stays
      single-threaded.
    * `stop/2` is synchronous and idempotent. Every stop path — explicit
      stop, abort, caller death, supervisor shutdown — funnels through
      `terminate/2`, which removes the protocol files (bounded, files and
      links only; the `0700` workspace directory itself belongs to the
      workspace teardown).
    * The process is `restart: :temporary`: a dead cell server is never
      resurrected against a directory its token has already rotated out of.

  There is deliberately no final drain, mirroring `Rpc.serve/2`: a request
  that is still pending when the server stops belongs to a cell that is
  already over, and running its tool would be work nobody is waiting for.

  ## Expected shared `Rpc` contract

  All protocol intelligence — authentication, policy, approval, budgets,
  atomic response writes, replay refusal — lives in the shared pump module
  (`CodingAgent.Tools.ExecuteCode.Rpc`), which is injected via the `:rpc`
  option so tests can substitute a fake. The server treats pump stats as
  opaque and only calls:

    * `initial_stats/0` — zeroed pump statistics.
    * `process_pending(ctx, stats)` — one bounded sweep over `ctx.rpc_dir`.
      For every pending `req-<id>.json` it verifies the request `token`
      against `ctx.token` in constant time *before* the request is counted or
      dispatched (stale, wrong, or missing tokens are denied and never
      appear in results or logs), enforces the call and result-byte budgets,
      runs allowed tools through the current `ToolPolicy`/`ToolExecutor`
      approval path, writes `res-<id>.json` atomically, and returns updated
      stats. The stats carry the pump's replay-tracking state, so a request
      id that was already answered — including one replayed after its
      response file was consumed — is refused and never re-dispatched.
    * `process_request(id, ctx, stats)` — the single-request building block
      shared with `Rpc.serve/2`; not called by this server, which always
      sweeps via `process_pending/2`.
    * `request_path/2` and `response_path/2` — protocol file naming, used by
      the integration and tests; the server itself never builds paths.

  `ctx` is the `Rpc` ctx extended with the per-cell `:token`. A wrong sweep
  implementation must not take the server down with it: a raising or throwing
  sweep is contained, logged (exception class only — exception payloads can
  embed the request body, which carries the token), and the previous stats
  are kept so the next poll resumes cleanly.
  """

  use GenServer, restart: :temporary

  require Logger

  alias CodingAgent.Tools.ExecuteCode.Rpc
  alias LemonAgent.AbortSignal

  @default_poll_interval_ms 25
  @stop_timeout_ms 5_000
  @stats_timeout_ms 5_000

  # Stop-time cleanup removes every file the cell dropped in the rpc dir, but
  # it must stay bounded work: a cell that planted an unbounded number of
  # files cannot make teardown unbounded too. Directories are left to the
  # workspace teardown, which owns the `0700` tree.
  @max_cleanup_files 10_000

  @typedoc """
  The shared pump ctx for one cell: the `Rpc` ctx plus the per-cell `:token`.

  See the "Expected shared `Rpc` contract" section of the moduledoc.
  """
  @type ctx :: %{
          required(:tools) => %{String.t() => LemonAgent.Types.AgentTool.t()},
          required(:tool_policy) => map() | nil,
          required(:approval_context) => map() | nil,
          required(:max_calls) => pos_integer(),
          required(:max_result_bytes) => pos_integer(),
          required(:signal) => reference() | nil,
          required(:rpc_dir) => String.t(),
          required(:token) => String.t(),
          optional(:poll_interval_ms) => pos_integer()
        }

  @type option ::
          {:rpc, module()}
          | {:poll_interval_ms, pos_integer()}
          | {:caller, pid()}
          | {:name, GenServer.name()}

  defstruct [:ctx, :rpc, :stats, :poll_interval_ms, :caller, :caller_monitor]

  @doc """
  Starts a pump server for one cell.

  Options:

    * `:rpc` — pump module implementing the contract in the moduledoc;
      defaults to `CodingAgent.Tools.ExecuteCode.Rpc`. Test seam.
    * `:poll_interval_ms` — overrides `ctx.poll_interval_ms` (which defaults
      to #{@default_poll_interval_ms} ms). Test seam.
    * `:caller` — process whose death stops the server; defaults to the
      caller of `start_link/2`, which is monitored and linked.
    * `:name` — optional registration, passed to `GenServer.start_link/3`.

  Returns `{:error, {:invalid_ctx, key}}` without starting a process when a
  required ctx key is missing or malformed.
  """
  @spec start_link(ctx(), [option()]) :: GenServer.on_start() | {:error, {:invalid_ctx, atom()}}
  def start_link(ctx, opts \\ []) when is_map(ctx) do
    with :ok <- validate_ctx(ctx),
         {:ok, poll_interval_ms} <- resolve_poll_interval(ctx, opts) do
      rpc = Keyword.get(opts, :rpc, Rpc)
      caller = Keyword.get(opts, :caller, self())

      gen_opts =
        case Keyword.get(opts, :name) do
          nil -> []
          name -> [name: name]
        end

      GenServer.start_link(__MODULE__, {ctx, rpc, poll_interval_ms, caller}, gen_opts)
    end
  end

  @doc """
  Stops the server synchronously and removes the cell's protocol files.

  Idempotent: stopping a server that is already gone returns `:ok`.
  """
  @spec stop(GenServer.server(), timeout()) :: :ok
  def stop(server, timeout \\ @stop_timeout_ms) do
    GenServer.stop(server, :normal, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Returns the pump statistics accumulated so far.

  The map is the shared pump's opaque stats (`calls`, `denied`, `errors`,
  `bytes`, `tools_used`, plus the pump's private replay-tracking state); it
  can be handed to the cell's result details unchanged.
  """
  @spec stats(GenServer.server(), timeout()) :: Rpc.stats()
  def stats(server, timeout \\ @stats_timeout_ms) do
    GenServer.call(server, :stats, timeout)
  end

  # ==========================================================================
  # GenServer callbacks
  # ==========================================================================

  @impl true
  def init({ctx, rpc, poll_interval_ms, caller}) do
    # Trapping exits guarantees terminate/2 — and with it protocol-file
    # cleanup — on supervisor shutdown, and turns a linked caller's death
    # into a controlled stop instead of a propagated crash.
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    schedule_poll(poll_interval_ms)

    {:ok,
     %__MODULE__{
       ctx: ctx,
       rpc: rpc,
       stats: rpc.initial_stats(),
       poll_interval_ms: poll_interval_ms,
       caller: caller,
       caller_monitor: caller_monitor
     }}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info(:poll, state) do
    if AbortSignal.aborted?(state.ctx.signal) do
      {:stop, :normal, state}
    else
      state = sweep(state)
      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    cond do
      # The owning caller (the future session integration) is gone: the cell
      # is over regardless of how it died, and cleanup must still run.
      pid == state.caller ->
        {:stop, :normal, state}

      # An unrelated linked process exiting normally says nothing about the
      # cell; tool code inside a sweep may hold transient links.
      reason == :normal ->
        {:noreply, state}

      # Supervisor shutdown and abnormal linked deaths keep their reason.
      true ->
        {:stop, reason, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_files(state.ctx.rpc_dir)
    :ok
  end

  # ==========================================================================
  # Internals
  # ==========================================================================

  # A broken sweep must never take the server down: the cell would hang
  # waiting for responses nobody will write. Keep the previous stats so the
  # next poll resumes from a consistent accounting state.
  defp sweep(state) do
    stats = state.rpc.process_pending(state.ctx, state.stats)
    %{state | stats: stats}
  rescue
    error ->
      # Class only: exception payloads can embed the request body, which
      # carries the per-cell token, and tokens never appear in logs.
      Logger.warning(
        "execute_code rpc sweep failed (#{inspect(error.__struct__)}); keeping previous stats"
      )

      state
  catch
    kind, _value ->
      Logger.warning("execute_code rpc sweep failed (#{kind}); keeping previous stats")

      state
  end

  defp schedule_poll(poll_interval_ms) do
    Process.send_after(self(), :poll, poll_interval_ms)
  end

  defp cleanup_files(rpc_dir) do
    case File.ls(rpc_dir) do
      {:ok, entries} ->
        entries
        |> Enum.take(@max_cleanup_files)
        # File.rm removes files and symlinks and reports {:error, :eisdir}
        # for directories — recursion into planted trees would be unbounded
        # work, and the workspace teardown owns the tree.
        |> Enum.each(fn entry -> File.rm(Path.join(rpc_dir, entry)) end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp validate_ctx(ctx) do
    Enum.reduce_while(
      [:rpc_dir, :token, :tools, :max_calls, :max_result_bytes],
      :ok,
      fn key, :ok ->
        if valid_ctx_value?(key, Map.get(ctx, key)),
          do: {:cont, :ok},
          else: {:halt, {:error, {:invalid_ctx, key}}}
      end
    )
  end

  defp valid_ctx_value?(:rpc_dir, value), do: is_binary(value) and value != ""
  defp valid_ctx_value?(:token, value), do: is_binary(value) and value != ""
  defp valid_ctx_value?(:tools, value), do: is_map(value)
  defp valid_ctx_value?(:max_calls, value), do: is_integer(value) and value > 0
  defp valid_ctx_value?(:max_result_bytes, value), do: is_integer(value) and value > 0

  defp resolve_poll_interval(ctx, opts) do
    value =
      Keyword.get(opts, :poll_interval_ms) ||
        Map.get(ctx, :poll_interval_ms) ||
        @default_poll_interval_ms

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:invalid_ctx, :poll_interval_ms}}
    end
  end
end

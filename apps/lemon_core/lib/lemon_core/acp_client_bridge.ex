defmodule LemonCore.ACPClientBridge do
  @moduledoc """
  Direct request/reply channel from a run's tool execution to the ACP client
  handler that owns the client connection for that run.

  This replaces the former `:acp_client_request` Bus broadcast. That event was
  RPC wearing an event's clothes: it carried a live pid and a `reference()` over
  a cluster-wide pub/sub topic to fake a synchronous request/reply. Unlike every
  other bus event it could not be serialised, persisted or replayed, and under
  `Phoenix.PubSub` it fanned the pid out to every node only for a single process
  to answer. This module makes the exchange what it always was: a direct call to
  one registered process.

  ## Roles

    * The **handler** is the process serving an ACP `session/prompt` turn
      (`LemonControlPlane.ACP`). It owns the JSON-RPC connection to the ACP
      client and calls `register/1` for the run's id while it waits, then
      services `{:acp_client_request, payload}` messages from its own receive
      loop.
    * The **requester** is a coding-agent filesystem tool
      (`CodingAgent.Tools.ACPFileBridge`) that needs the client to read or write
      a file on its side. It calls `request/4` and blocks for the reply.

  Both apps depend on `lemon_core` and neither on the other, so this shared
  rendezvous lives here rather than in either endpoint.

  ## Failure contract

  `request/4` answers rather than raises, mirroring `LemonCore.RouterBridge`.
  Three failure modes, deliberately distinguished so the caller can log the
  cause even though the consequence is the same (the file operation did not
  happen):

    * `{:error, :no_client}` — no handler is registered for the run. Under the
      old broadcast this presented as a full-timeout hang, because a broadcast to
      an empty topic is silently dropped; now it fails fast.
    * `{:error, :client_down}` — a handler was registered but its process died
      before replying. Caught via monitor so the requester is not left waiting.
    * `{:error, :timeout}` — the handler was reachable but did not reply within
      the caller's timeout.

  ## Node locality

  The registry is node-local. The ACP bridge is a single-connection JSON-RPC
  preview where the handler owns the client socket and the run it submits is
  serviced in the same BEAM, so a local registry is sufficient and correct.
  Making this cross-node would mean a distributed registry behind the same API;
  it is deliberately out of scope, and the pid/ref-over-broadcast pattern this
  replaces was never a sound way to do it either.
  """

  @registry __MODULE__

  @doc """
  Child spec for the rendezvous registry. Added to `LemonCore.Application`'s
  supervision tree so `request/4` and `register/1` are always available.
  """
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: @registry)
  end

  @doc """
  Register the calling process as the ACP client handler for `run_id`.

  Idempotent per process: a second call from the same process is a no-op. A call
  from a *different* process while one is still registered returns
  `{:error, {:already_registered, pid}}` rather than crashing the caller — a run
  is submitted and waited exactly once, so this should not happen, but a handler
  should not die trying to register.
  """
  @spec register(binary()) :: :ok | {:error, {:already_registered, pid()}}
  def register(run_id) when is_binary(run_id) do
    case Registry.register(@registry, run_id, nil) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} when pid == self() -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:already_registered, pid}}
    end
  end

  @doc """
  Unregister the calling process as the handler for `run_id`. Safe to call even
  if nothing is registered; the handler calls it from an `after` block.
  """
  @spec unregister(binary()) :: :ok
  def unregister(run_id) when is_binary(run_id) do
    Registry.unregister(@registry, run_id)
    :ok
  end

  @doc """
  Return the pid of the handler registered for `run_id`, or `nil`.
  """
  @spec whereis(binary()) :: pid() | nil
  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc """
  Make a synchronous client request against the handler registered for `run_id`.

  Sends `{:acp_client_request, %{method:, params:, reply_to:, ref:}}` to the
  handler and blocks for `{:acp_client_response, ref, response}`. The payload
  shape matches what the handler's receive loop already expects, so the handler
  side is unchanged apart from receiving a direct message instead of a bus event.
  """
  @spec request(binary(), String.t(), map(), timeout()) ::
          {:ok, term()} | {:error, :no_client | :client_down | :timeout}
  def request(run_id, method, params, timeout_ms)
      when is_binary(run_id) and is_binary(method) do
    case whereis(run_id) do
      nil -> {:error, :no_client}
      pid -> call(pid, method, params, timeout_ms)
    end
  end

  defp call(pid, method, params, timeout_ms) do
    ref = make_ref()
    mon = Process.monitor(pid)

    send(
      pid,
      {:acp_client_request, %{method: method, params: params, reply_to: self(), ref: ref}}
    )

    receive do
      {:acp_client_response, ^ref, response} ->
        Process.demonitor(mon, [:flush])
        {:ok, response}

      {:DOWN, ^mon, :process, ^pid, _reason} ->
        {:error, :client_down}
    after
      timeout_ms ->
        Process.demonitor(mon, [:flush])
        {:error, :timeout}
    end
  end
end

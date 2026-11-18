defmodule LemonCore.NodeRegistry do
  @moduledoc """
  Socket-owned live registry and targeted invocation API for named Lemon nodes.

  The authenticated WebSocket process registers its durable node ID in a unique
  `Registry`, with its live name, credential generation and metadata as value.
  Registry removes that entry when the socket dies; there is no node-monitor
  bookkeeping. Pairing credentials and durable metadata remain in the control
  plane. Exact IDs win over names, including IDs retained by the generation floor.

  Each invocation is a temporary `LemonCore.NodeInvocation` process. Events,
  results, cancellation, approvals and steer/redirect call that process directly,
  never a singleton broker. It owns its timers, recipient/socket monitors and
  sequence validation. Disconnects cancel work; reconnects never replay it.

  Registration, rename, revocation and invocation admission share a lifecycle
  mutex, not the streamed data path. Owner mutations are delivered to the socket
  through `handle_owner_message/1`; a socket that cannot acknowledge a handover
  is not silently replaced. Generation floors survive live socket removal.
  Owner mutations use the existing control timeout policy; an unacknowledged
  mutation returns `:outcome_unknown` and must not be automatically retried.
  """

  use Supervisor

  alias LemonCore.{JSONPayload, NodeInvocation}

  @default_timeout_ms 30 * 60 * 1_000
  @default_control_timeout_ms 5_000

  @type node_info :: %{
          id: String.t(),
          name: String.t(),
          pid: pid(),
          generation: non_neg_integer(),
          metadata: map(),
          connected_at_ms: integer()
        }

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        Supervisor.child_spec(
          {Registry, keys: :unique, name: __MODULE__.Connections},
          id: __MODULE__.Connections
        ),
        Supervisor.child_spec(
          {Registry, keys: :unique, name: __MODULE__.Invocations},
          id: __MODULE__.Invocations
        ),
        {DynamicSupervisor, strategy: :one_for_one, name: __MODULE__.InvocationSupervisor},
        LemonCore.NodeRegistry.Generations
      ],
      strategy: :one_for_all
    )
  end

  @doc """
  Registers a node in the calling socket process.

  The caller owns the entry; supplying a dispatch PID does not transfer Registry
  ownership. Authenticated transports must call this from the registered socket.
  """
  @spec register(String.t(), String.t(), pid(), map()) :: :ok | {:error, term()}
  def register(node_id, name, pid, metadata \\ %{})
      when is_binary(node_id) and is_binary(name) and is_pid(pid) and is_map(metadata),
      do: register_node(node_id, String.trim(name), pid, 0, metadata, false)

  @doc "Registers the calling authenticated socket and its credential generation."
  def register_session(node_id, name, pid, generation, metadata \\ %{})
      when is_binary(node_id) and is_binary(name) and is_pid(pid) and
             is_integer(generation) and generation >= 0 and is_map(metadata),
      do: register_node(node_id, String.trim(name), pid, generation, metadata, true)

  def unregister(node_id, pid) when is_binary(node_id) and is_pid(pid) do
    lifecycle(fn ->
      case lookup(node_id) do
        {owner, %{pid: ^pid}} -> owner_action(owner, node_id, {:remove, :disconnected})
        _ -> :ok
      end
    end)
  end

  @doc "Renames a live node without disturbing its connection or invocations."
  def rename(node_id, name) when is_binary(node_id) and is_binary(name) do
    name = String.trim(name)

    lifecycle(fn ->
      with :ok <- available_name(node_id, name),
           {owner, _node} <- lookup(node_id) do
        owner_action(owner, node_id, {:rename, name})
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  @spec list() :: [node_info()]
  def list, do: Enum.sort_by(live_nodes(), & &1.name)

  defp live_nodes do
    Registry.select(__MODULE__.Connections, [{{:"$1", :_, :"$2"}, [], [:"$2"]}])
    |> Enum.filter(fn node ->
      Process.alive?(node.pid) and
        node.generation >= LemonCore.NodeRegistry.Generations.generation_floor(node.id)
    end)
  end

  @doc "Resolves an exact durable ID first, otherwise a unique live name."
  def resolve(name_or_id) when is_binary(name_or_id) do
    selector = String.trim(name_or_id)

    case resolve_id(selector) do
      {:ok, _} = found ->
        found

      _ ->
        if LemonCore.NodeRegistry.Generations.known?(selector) do
          {:error, :not_found}
        else
          case Enum.find(live_nodes(), &(&1.name == selector)) do
            nil -> {:error, :not_found}
            node -> {:ok, node}
          end
        end
    end
  end

  @doc "Resolves an exact durable node ID, never another node's name."
  def resolve_id(node_id) when is_binary(node_id) do
    case lookup(node_id) do
      {_owner, node} ->
        if Process.alive?(node.pid) and
             node.generation >= LemonCore.NodeRegistry.Generations.generation_floor(node_id),
           do: {:ok, node},
           else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  def online?(selector) when is_binary(selector), do: match?({:ok, _}, resolve(selector))

  @doc "Whether live metadata advertises version 1 native privacy context support."
  def native_privacy_context_supported?(metadata) do
    capabilities =
      if is_map(metadata),
        do: Map.get(metadata, :capabilities, Map.get(metadata, "capabilities")),
        else: nil

    match?(
      %{
        "coding_agent.run" => %{
          "version" => 2,
          "executionContext" => %{"version" => 1},
          "nativePrivacyContext" => %{"version" => 1}
        }
      },
      capabilities
    )
  end

  @doc """
  Starts an invocation and returns its ID immediately.

  The recipient receives `{:lemon_node_result, invoke_id, {:ok, result} |
  {:error, reason}}`. Native runs also receive ordered
  `{:lemon_node_event, invoke_id, seq, event}` frames, beginning at sequence 1.
  Same-session retries are acknowledged without duplicate delivery.
  """
  def invoke(selector, method, args, opts \\ [])
      when is_binary(selector) and is_binary(method) and is_map(args),
      do: invoke_target(String.trim(selector), method, args, opts)

  @doc """
  Invokes only an exact durable node ID.

  `expected_pid` and `expected_generation` pin prior inspection to the dispatch
  session. `required_native_privacy_context: 1` requires its privacy descriptor;
  `required_process_execution: 1` requires the real run/get/cancel protocol.
  `session_lifecycle_admission: true` makes an unadmitted `coding_agent.run`
  register as its session's activity for the invocation's lifetime, and refuses
  it with `{:error, :session_lifecycle_in_progress}` while a reset or delete
  holds the session. Admission errors are definite pre-dispatch failures.
  """
  def invoke_node(node_id, method, args, opts \\ [])
      when is_binary(node_id) and is_binary(method) and is_map(args),
      do: invoke_target({:node_id, node_id}, method, args, opts)

  @doc """
  Dispatches bounded steer/redirect text to the invocation's original session.

  `{:ok, control_id}` is dispatch only. The recipient receives
  `{:lemon_node_control_result, control_id, invoke_id, :ok | {:error, reason}}`
  only after acknowledgement, rejection or a terminal failure.
  """
  def control(invoke_id, operation, text, opts \\ []) do
    if not is_binary(invoke_id) or String.trim(invoke_id) == "" do
      {:error, :invalid_invoke_id}
    else
      NodeInvocation.call(
        invoke_id,
        {:control, operation, text, Keyword.get(opts, :recipient, self()),
         Keyword.get(opts, :timeout_ms, @default_control_timeout_ms)},
        {:error, :terminal}
      )
    end
  end

  def max_control_text_bytes, do: 16 * 1_024

  def cancel(invoke_id, reason \\ :cancelled) when is_binary(invoke_id),
    do: NodeInvocation.call(invoke_id, {:cancel, reason}, :ok)

  # A terminal result for an invocation whose owner already ended (it was
  # cancelled, or its connection dropped) proves that remote run stopped.
  def complete(node_id, invoke_id, result, error \\ nil)
      when is_binary(node_id) and is_binary(invoke_id) do
    invoke_id
    |> NodeInvocation.call({:complete, node_id, result, error}, :missing)
    |> resolve_missing(invoke_id, node_id)
  end

  def complete_session(node_id, pid, generation, invoke_id, result, error \\ nil) do
    invoke_id
    |> NodeInvocation.call({:complete_session, node_id, pid, generation, result, error}, :missing)
    |> resolve_missing(invoke_id, node_id)
  end

  defp resolve_missing(:missing, invoke_id, node_id) do
    case LemonCore.SessionActivity.resolve_unresolved(invoke_id, node_id) do
      :resolved -> :ok
      :not_found -> {:error, :not_found}
    end
  end

  defp resolve_missing(result, _invoke_id, _node_id), do: result

  @doc """
  The worker on the live connection `pid` reports, after its cancellation
  barrier, every invocation it still runs or is still stopping. Unresolved
  presence its earlier connections left for any other invocation is cleared.
  """
  @spec report_active(String.t(), pid(), non_neg_integer(), [String.t()]) ::
          :ok | {:error, :stale_session | :unavailable}
  def report_active(node_id, pid, generation, invoke_ids)
      when is_binary(node_id) and is_pid(pid) and is_list(invoke_ids) do
    case lookup(node_id) do
      {_owner, %{pid: ^pid, generation: ^generation}} ->
        case LemonCore.SessionActivity.resolve_reported_active(node_id, pid, invoke_ids) do
          :ok -> :ok
          {:error, _} -> {:error, :unavailable}
        end

      _ ->
        {:error, :stale_session}
    end
  end

  def event_session(node_id, pid, generation, invoke_id, seq, event),
    do:
      NodeInvocation.call(
        invoke_id,
        {:event, node_id, pid, generation, seq, event},
        {:error, :terminal}
      )

  @doc "Dispatches an approval decision only for the invocation recipient caller."
  def approval(invoke_id, approval_id, decision),
    do: NodeInvocation.call(invoke_id, {:approval, approval_id, decision}, {:error, :terminal})

  def complete_control_session(
        node_id,
        pid,
        generation,
        control_id,
        invoke_id,
        run_id,
        accepted,
        reason \\ nil
      ),
      do:
        NodeInvocation.call(
          {:control, control_id},
          {:control_result, node_id, pid, generation, control_id, invoke_id, run_id, accepted,
           reason},
          {:error, :not_found}
        )

  @doc "Revokes sessions older than the retained monotonic generation floor."
  def revoke_session(node_id, generation)
      when is_binary(node_id) and is_integer(generation) and generation >= 0 do
    lifecycle(fn ->
      floor = LemonCore.NodeRegistry.Generations.advance(node_id, generation)

      case lookup(node_id) do
        {owner, %{generation: current, pid: pid}} when current < floor ->
          result = owner_action(owner, node_id, {:remove, :credential_rotated})
          send(pid, {:node_session_revoked, node_id, floor})
          result

        _ ->
          :ok
      end
    end)
  end

  @doc "Pushes a JSON-safe event to one live connection."
  def push(selector, event_name, payload)
      when is_binary(selector) and is_binary(event_name) and is_map(payload) do
    with {:ok, _} <- JSONPayload.validate(payload),
         {:ok, node} <- resolve(selector) do
      send(node.pid, {:node_event, event_name, payload})
      :ok
    else
      {:error, :not_found} = error -> error
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  def shell_event_session(node_id, pid, generation, invoke_id, payload),
    do:
      NodeInvocation.call(
        invoke_id,
        {:shell_event, node_id, pid, generation, payload},
        {:error, :stale_invocation}
      )

  @doc false
  def handle_owner_message({:node_registry_owner, from, ref, node_id, action}) do
    send(from, {ref, apply_owner_action(node_id, action)})
    :ok
  end

  defp register_node(node_id, name, pid, generation, metadata, revoke?) do
    lifecycle(fn ->
      with :ok <- available_name(node_id, name),
           :ok <- authorize_generation(node_id, generation),
           :ok <- replace_node(node_id, pid, generation, revoke?) do
        node = %{
          id: node_id,
          name: name,
          pid: pid,
          generation: generation,
          metadata: metadata,
          connected_at_ms: System.system_time(:millisecond)
        }

        case Registry.register(__MODULE__.Connections, node_id, node) do
          {:ok, _} -> :ok
          {:error, {:already_registered, _}} -> {:error, :connection_changed}
        end
      end
    end)
  end

  defp replace_node(node_id, replacement_pid, generation, revoke?) do
    case lookup(node_id) do
      {owner, node} ->
        # Cancel against the old registry value before removing it. A new
        # connection must never receive cancellation for the superseded one.
        result = owner_action(owner, node_id, {:remove, :reconnected})

        if result == :ok and revoke? and node.pid != replacement_pid,
          do: send(node.pid, {:node_session_revoked, node_id, generation})

        result

      nil ->
        :ok
    end
  end

  defp available_name(_node_id, ""), do: {:error, :invalid_name}

  defp available_name(node_id, name) do
    if Enum.any?(live_nodes(), &(&1.id != node_id and &1.name == name)),
      do: {:error, {:name_taken, name}},
      else: :ok
  end

  defp authorize_generation(node_id, generation) do
    if generation < LemonCore.NodeRegistry.Generations.generation_floor(node_id) do
      {:error, :stale_session}
    else
      LemonCore.NodeRegistry.Generations.advance(node_id, generation)
      :ok
    end
  end

  defp lookup(node_id) do
    case Registry.lookup(__MODULE__.Connections, node_id) do
      [{owner, node}] -> {owner, node}
      [] -> nil
    end
  end

  defp owner_action(owner, node_id, action) when owner == self(),
    do: apply_owner_action(node_id, action)

  defp owner_action(owner, node_id, action) do
    ref = Process.monitor(owner)
    send(owner, {:node_registry_owner, self(), ref, node_id, action})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^owner, _} ->
        :ok
    after
      # Owner handover uses the existing invocation-control timeout policy.
      @default_control_timeout_ms ->
        Process.demonitor(ref, [:flush])
        {:error, :outcome_unknown}
    end
  end

  defp apply_owner_action(node_id, {:remove, reason}) do
    case lookup(node_id) do
      {owner, _node} when owner == self() ->
        disconnect_invocations(node_id, reason)
        Registry.unregister(__MODULE__.Connections, node_id)
        :ok

      _ ->
        :ok
    end
  end

  defp apply_owner_action(node_id, {:rename, name}) do
    case Registry.update_value(__MODULE__.Connections, node_id, &%{&1 | name: name}) do
      :error -> {:error, :not_found}
      _ -> :ok
    end
  end

  defp disconnect_invocations(node_id, reason) do
    Registry.select(__MODULE__.Invocations, [
      {{:"$1", :_, {:invocation, node_id}}, [], [:"$1"]}
    ])
    |> Enum.each(&NodeInvocation.call(&1, {:disconnect, reason}, :ok))
  end

  defp lifecycle(fun) do
    case :global.trans({{__MODULE__, :lifecycle}, self()}, fun, [node()], 3) do
      :aborted -> {:error, :invocation_unavailable}
      result -> result
    end
  end

  defp invoke_target(target, method, args, opts) do
    opts =
      opts
      |> Keyword.put_new(:recipient, self())
      |> Keyword.put_new(:timeout_ms, @default_timeout_ms)
      |> Keyword.put_new(:max_payload_bytes, JSONPayload.default_max_bytes())

    with :ok <- validate_invocation(method, args, opts) do
      lifecycle(fn ->
        with {:ok, node} <- dispatch_node(target, opts) do
          id = LemonCore.Id.uuid()

          case DynamicSupervisor.start_child(
                 __MODULE__.InvocationSupervisor,
                 {NodeInvocation, {node, method, args, Keyword.put(opts, :invoke_id, id)}}
               ) do
            {:ok, _pid} -> {:ok, id}
            {:error, {:invalid_payload, reason}} -> {:error, {:invalid_payload, reason}}
            {:error, {:session_lifecycle, reason}} -> {:error, reason}
            {:error, _} -> {:error, :invocation_unavailable}
          end
        end
      end)
    end
  end

  defp validate_invocation(method, args, opts) do
    recipient = opts[:recipient]
    timeout = opts[:timeout_ms]
    bytes = opts[:max_payload_bytes]
    pid = opts[:expected_pid]
    generation = opts[:expected_generation]
    privacy = opts[:required_native_privacy_context]
    process = opts[:required_process_execution]

    cond do
      not is_pid(recipient) ->
        {:error, :invalid_recipient}

      not is_integer(timeout) or timeout <= 0 ->
        {:error, :invalid_timeout}

      not is_integer(bytes) or bytes <= 0 ->
        {:error, :invalid_payload_limit}

      not is_nil(pid) and not is_pid(pid) ->
        {:error, :invalid_expected_node_pid}

      not is_nil(generation) and (not is_integer(generation) or generation < 0) ->
        {:error, :invalid_expected_node_generation}

      not is_nil(privacy) and
          (privacy != 1 or method not in ["coding_agent.run", "node.secrets.set"]) ->
        {:error, :invalid_native_privacy_context_requirement}

      not is_nil(process) and
          (process != 1 or
             method not in ["node.process.run", "node.process.get", "node.process.cancel"]) ->
        {:error, :invalid_process_execution_requirement}

      true ->
        json_opts =
          if method == "coding_agent.run",
            do: LemonCore.ToolPolicy.execution_json_opts(max_bytes: bytes),
            else: [max_bytes: bytes]

        case JSONPayload.validate(args, json_opts) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:invalid_payload, reason}}
        end
    end
  end

  defp dispatch_node(target, opts) do
    resolved =
      case target do
        {:node_id, id} -> resolve_id(id)
        name -> resolve(name)
      end

    case resolved do
      {:ok, node} ->
        cond do
          (not is_nil(opts[:expected_pid]) and node.pid != opts[:expected_pid]) or
              (not is_nil(opts[:expected_generation]) and
                 node.generation != opts[:expected_generation]) ->
            {:error, {:node_connection_changed, node.id}}

          opts[:required_native_privacy_context] == 1 and
              not native_privacy_context_supported?(node.metadata) ->
            {:error, {:native_privacy_context_unsupported, node.id}}

          opts[:required_process_execution] == 1 and
              not process_execution_supported?(node.metadata) ->
            {:error, {:process_execution_unsupported, node.id}}

          true ->
            {:ok, node}
        end

      {:error, :not_found} ->
        selector =
          case target do
            {:node_id, id} -> id
            name -> name
          end

        {:error, {:node_offline, selector}}
    end
  end

  defp process_execution_supported?(metadata) do
    capabilities = Map.get(metadata, :capabilities, Map.get(metadata, "capabilities"))

    is_map(capabilities) and
      Enum.all?(
        ~w(node.process.run node.process.get node.process.cancel),
        &match?(%{"version" => 1}, Map.get(capabilities, &1))
      )
  end
end

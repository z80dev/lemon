defmodule CodingAgent.ExecutionNode.ProcessService do
  @moduledoc """
  Destination-native pipe process owner. Admission is durable before literal exec;
  fixed IDs bind exact intent and are never redispatched. Only minimal private
  metadata is stored in `node_process_receipts`; output is bounded volatile memory.

  Durable ID fences:

    * `running` and `outcome_unknown` receipts are unresolved: they never expire
      and at most 1,000 of them admit new work (capacity fails closed). Only the
      preview-first operator `prune/2` removes them.
    * `completed`, `cancelled` and `failed` receipts are terminal: they fence
      their ID for 24 hours after they finish and are then retired.
    * `failed` means the helper provably never started the program (spawn or
      pre-exec validation failure); it does not consume unresolved capacity.
    * At most 20,000 receipts are retained in total; beyond that admission fails
      closed until retirement frees space.

  A durable per-node generation floor (`node_process_generations`) outlives
  retired receipts, so a superseded generation stays refused. The volatile output
  cache has the same 24-hour TTL (and a separate 16-receipt bound).

  One packet4 Python Port owns each process group. Requests and cancellation are
  asynchronous inside this GenServer, so a long run cannot obstruct get/cancel.
  `owner` is the authenticated Worker, not the short-lived invocation task.
  """
  use GenServer

  alias LemonCore.Store
  alias CodingAgent.ExecutionNode.{FileService, Python}

  @table :node_process_receipts
  @generations :node_process_generations
  @ttl_ms 86_400_000
  @max_unresolved 1_000
  @max_retained 20_000
  @unresolved ~w(running outcome_unknown)
  @terminal ~w(completed cancelled failed)
  @prune_states ~w(outcome_unknown completed cancelled failed)
  @prune_ttl_ms 600_000
  @max_prune_previews 32
  @prune_display_limit 100
  @max_active 16
  @max_cached 16
  @max_frame 4 * 1_024 * 1_024
  @errors ~w(invalid_request invalid_path path_not_allowed invalid_allowed_roots
    symlink_loop executable_not_found permission_denied not_directory argv_too_large process_failed)a
  @methods ~w(node.process.run node.process.get node.process.cancel)
  @receipt_fields ~w(node_id process_id generation invoke_id state exit_code intent created_at finished_at)a
  @required_receipt_fields @receipt_fields -- [:finished_at]
  @receipt_field_names Enum.map(@receipt_fields, &Atom.to_string/1)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def handle(method, args, opts) do
    server = Keyword.get(opts, :server, __MODULE__)

    timeout =
      if method == "node.process.run" and is_map(args) and is_integer(args["timeoutMs"]),
        do: min(max(args["timeoutMs"], 1_000), 1_800_000) + 5_000,
        else: 30_000

    try do
      GenServer.call(server, {:request, method, args, opts}, timeout)
    catch
      :exit, _ -> {:error, :process_outcome_unknown}
    end
  end

  def cancel_owner(owner, server \\ __MODULE__), do: control(server, {:cancel_owner, owner})

  def cancel_invocation(owner, invoke_id, server \\ __MODULE__),
    do: control(server, {:cancel_invocation, owner, invoke_id})

  @doc """
  Operator removal of durable receipts, preview first.

  Options: `:older_than_ms` (required, positive: receipts created at least this
  long ago), `:states` (default `["outcome_unknown"]`; any of
  #{Enum.join(@prune_states, ", ")}), `:node_id` (optional), `:dry_run`
  (default `true`) and `:confirm_token`.

  A dry run returns `%{token:, count:, process_ids:, truncated:, expires_at_ms:}`
  and deletes nothing. `dry_run: false` with that single-use token (valid for ten
  minutes, in this service process only) deletes exactly the previewed receipts
  that are still unchanged and not executing, and reports `deleted`/`skipped`.
  A pruned ID becomes admissible again: prune `outcome_unknown` only after
  reconciling that work out of band.
  """
  def prune(opts, server \\ __MODULE__) when is_list(opts) do
    try do
      GenServer.call(server, {:prune, opts}, 30_000)
    catch
      :exit, _ -> {:error, :prune_outcome_unknown}
    end
  end

  defp control(server, message) do
    try do
      GenServer.call(server, message, 5_000)
    catch
      :exit, _ -> {:error, :process_outcome_unknown}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :sweep, 60_000)

    state = %{
      store: Keyword.get(opts, :store, Store),
      receipts: %{},
      floors: %{},
      previews: %{},
      jobs: %{},
      ports: %{},
      cache: %{},
      owner_waiters: %{},
      loaded: false
    }

    {:ok, load(state)}
  end

  # Recovery never interprets a lost running owner as success or re-executes it.
  defp load(%{loaded: true} = state), do: state

  defp load(state) do
    with {:ok, entries} <- Store.fetch_all(state.store, @table),
         {:ok, receipts} <- normalize_receipts(entries),
         {:ok, floor_entries} <- Store.fetch_all(state.store, @generations),
         {:ok, floors} <- normalize_floors(floor_entries, receipts) do
      recovered =
        Enum.reduce_while(receipts, {:ok, receipts}, fn
          {key, %{state: "running"} = receipt}, {:ok, acc} ->
            unknown = %{receipt | state: "outcome_unknown", exit_code: nil}

            case persist(state, key, unknown) do
              :ok -> {:cont, {:ok, Map.put(acc, key, unknown)}}
              _ -> {:halt, :error}
            end

          _, acc ->
            {:cont, acc}
        end)

      case recovered do
        {:ok, recovered} -> %{state | loaded: true, receipts: recovered, floors: floors}
        _ -> state
      end
    else
      _ -> state
    end
  end

  defp fetch_receipt(state, key) do
    case Store.fetch(state.store, @table, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, receipt} -> normalize_receipt(key, receipt)
      _ -> {:error, :store_unavailable}
    end
  end

  defp normalize_receipts(entries) when is_list(entries) and length(entries) <= @max_retained do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, receipt}, {:ok, acc} ->
        case normalize_receipt(key, receipt) do
          {:ok, normalized} ->
            if Map.has_key?(acc, key),
              do: {:halt, {:error, :store_unavailable}},
              else: {:cont, {:ok, Map.put(acc, key, normalized)}}

          _ ->
            {:halt, {:error, :store_unavailable}}
        end

      _, _ ->
        {:halt, {:error, :store_unavailable}}
    end)
  end

  defp normalize_receipts(_), do: {:error, :store_unavailable}

  # Receipts written before the floor table existed still bound their node.
  defp normalize_floors(entries, receipts) when is_list(entries) do
    stored =
      Enum.reduce_while(entries, {:ok, %{}}, fn
        {node_id, generation}, {:ok, acc}
        when is_integer(generation) and generation >= 0 and not is_map_key(acc, node_id) ->
          if valid_text?(node_id, 256, true),
            do: {:cont, {:ok, Map.put(acc, node_id, generation)}},
            else: {:halt, {:error, :store_unavailable}}

        _, _ ->
          {:halt, {:error, :store_unavailable}}
      end)

    with {:ok, floors} <- stored do
      {:ok,
       Enum.reduce(receipts, floors, fn {{node_id, _}, receipt}, acc ->
         Map.update(acc, node_id, receipt.generation, &max(&1, receipt.generation))
       end)}
    end
  end

  defp normalize_floors(_, _), do: {:error, :store_unavailable}

  defp normalize_receipt({node_id, process_id}, receipt) when is_map(receipt) do
    keys_valid =
      Enum.all?(Map.keys(receipt), &(&1 in @receipt_fields or &1 in @receipt_field_names)) and
        Enum.all?(@required_receipt_fields, fn key ->
          Map.has_key?(receipt, key) != Map.has_key?(receipt, Atom.to_string(key))
        end) and
        not (Map.has_key?(receipt, :finished_at) and Map.has_key?(receipt, "finished_at"))

    normalized =
      Map.new(@receipt_fields, fn key ->
        {key, Map.get(receipt, key, Map.get(receipt, Atom.to_string(key)))}
      end)

    valid =
      keys_valid and valid_text?(node_id, 256, true) and valid_process_id?(process_id) and
        normalized.node_id == node_id and normalized.process_id == process_id and
        is_integer(normalized.generation) and normalized.generation >= 0 and
        valid_text?(normalized.invoke_id, 128, true) and
        normalized.state in (@unresolved ++ @terminal) and
        valid_exit?(normalized.state, normalized.exit_code) and
        is_integer(normalized.created_at) and normalized.created_at >= 0 and
        (is_nil(normalized.finished_at) or
           (is_integer(normalized.finished_at) and normalized.finished_at >= 0)) and
        valid_intent?(normalized.intent, normalized.state)

    if valid, do: {:ok, normalized}, else: {:error, :store_unavailable}
  end

  defp normalize_receipt(_, _), do: {:error, :store_unavailable}

  defp valid_exit?("completed", code), do: is_integer(code)
  defp valid_exit?("cancelled", code), do: is_nil(code) or is_integer(code)

  defp valid_exit?(state, code) when state in ["running", "outcome_unknown", "failed"],
    do: is_nil(code)

  defp valid_exit?(_, _), do: false

  defp valid_intent?(nil, state), do: state == "cancelled"
  defp valid_intent?(digest, _) when is_binary(digest), do: valid_digest?(digest)
  defp valid_intent?(_, _), do: false

  defp valid_digest?(digest) when byte_size(digest) == 44 do
    case Base.decode64(digest) do
      {:ok, bytes} -> byte_size(bytes) == 32 and Base.encode64(bytes) == digest
      _ -> false
    end
  end

  defp valid_digest?(_), do: false

  defp valid_process_id?(id) when is_binary(id),
    do: Regex.match?(~r/\A[A-Za-z0-9_:-]{1,128}\z/, id)

  defp valid_process_id?(_), do: false

  @impl true
  def handle_call({:request, method, args, opts}, from, state) do
    state = state |> load() |> sweep()

    with :ok <- if(state.loaded, do: :ok, else: {:error, :store_unavailable}),
         :ok <- validate(method, args, opts),
         true <- Process.alive?(elem(from, 0)) and Process.alive?(Keyword.fetch!(opts, :owner)) do
      key = {args["nodeId"], args["processId"]}

      case fetch_receipt(state, key) do
        {:ok, receipt} -> dispatch(method, args, opts, from, key, receipt, state)
        _ -> {:reply, {:error, :store_unavailable}, state}
      end
    else
      false -> {:reply, {:error, :process_unavailable}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:prune, opts}, _from, state) do
    state = state |> load() |> sweep()

    if state.loaded do
      {reply, state} = prune_request(opts, state)
      {:reply, reply, state}
    else
      {:reply, {:error, :store_unavailable}, state}
    end
  end

  def handle_call({:cancel_owner, owner}, from, state) do
    keys = for {key, job} <- state.jobs, job.owner == owner, do: key
    cancel_owned(keys, from, state)
  end

  def handle_call({:cancel_invocation, owner, invoke_id}, from, state) do
    keys =
      for {key, job} <- state.jobs, job.owner == owner and job.invoke_id == invoke_id, do: key

    cancel_owned(keys, from, state)
  end

  defp cancel_owned([], _from, state), do: {:reply, :ok, state}

  defp cancel_owned(keys, from, state) do
    state = Enum.reduce(keys, state, &signal_cancel/2)
    {:noreply, %{state | owner_waiters: Map.put(state.owner_waiters, from, MapSet.new(keys))}}
  end

  defp dispatch("node.process.get", args, _opts, _from, key, nil, state),
    do:
      {:reply, {:ok, dto(args, "not_found", nil)}, %{state | cache: Map.delete(state.cache, key)}}

  defp dispatch("node.process.get", _args, _opts, _from, key, receipt, state),
    do: {:reply, {:ok, view(receipt, key, state)}, state}

  defp dispatch("node.process.run", args, opts, from, key, nil, state) do
    cond do
      stale?(opts, state) ->
        {:reply, {:error, :stale_generation}, state}

      at_capacity?(state) ->
        {:reply, {:error, :process_receipt_limit}, state}

      map_size(state.jobs) >= @max_active ->
        {:reply, {:error, :process_limit}, state}

      true ->
        receipt =
          metadata(args, opts, "running")
          |> Map.put(:intent, intent(args, Keyword.fetch!(opts, :session_generation)))

        case admit(state, opts, key, receipt) do
          {:ok, state} ->
            start_job(args, opts, from, key, receipt, state)

          {:exists, state} ->
            case fetch_receipt(state, key) do
              {:ok, existing} when not is_nil(existing) ->
                dispatch("node.process.run", args, opts, from, key, existing, state)

              _ ->
                {:reply, {:error, :store_unavailable}, state}
            end

          {:error, state} ->
            {:reply, {:error, :store_unavailable}, state}
        end
    end
  end

  defp dispatch("node.process.run", args, _opts, _from, key, receipt, state) do
    expected = if receipt.intent, do: intent(args, receipt.generation)

    cond do
      receipt.intent == nil or receipt.intent == expected ->
        {:reply, {:ok, view(receipt, key, state)}, state}

      true ->
        {:reply, {:error, :process_intent_conflict}, state}
    end
  end

  defp dispatch("node.process.cancel", args, opts, from, key, nil, state) do
    cond do
      stale?(opts, state) ->
        {:reply, {:error, :stale_generation}, state}

      at_capacity?(state) ->
        {:reply, {:error, :process_receipt_limit}, state}

      true ->
        receipt = metadata(args, opts, "cancelled")

        case admit(state, opts, key, receipt) do
          {:ok, state} ->
            {:reply, {:ok, dto(args, "cancelled", nil)}, state}

          {:exists, state} ->
            case fetch_receipt(state, key) do
              {:ok, existing} when not is_nil(existing) ->
                dispatch("node.process.cancel", args, opts, from, key, existing, state)

              _ ->
                {:reply, {:error, :store_unavailable}, state}
            end

          {:error, state} ->
            {:reply, {:error, :store_unavailable}, state}
        end
    end
  end

  defp dispatch("node.process.cancel", _args, opts, from, key, receipt, state) do
    case state.jobs[key] do
      nil ->
        {:reply, {:ok, view(receipt, key, state)}, state}

      job ->
        cond do
          job.owner != Keyword.fetch!(opts, :owner) or
            receipt.generation != Keyword.fetch!(opts, :session_generation) or stale?(opts, state) ->
            {:reply, {:error, :process_owner_mismatch}, state}

          length(job.waiters) >= 32 ->
            {:reply, {:error, :process_busy}, state}

          true ->
            state = put_in(state.jobs[key].waiters, [from | job.waiters]) |> signal_cancel(key)
            {:noreply, state}
        end
    end
  end

  # The generation floor is durable before the receipt it covers, so retiring
  # receipts later can never re-admit a superseded generation.
  defp admit(state, opts, key, receipt) do
    case raise_floor(state, opts) do
      {:ok, state} ->
        case Store.put_new(state.store, @table, key, receipt, durable: true) do
          :ok -> {:ok, %{state | receipts: Map.put(state.receipts, key, receipt)}}
          {:error, :exists} -> {:exists, state}
          _ -> {:error, state}
        end

      :error ->
        {:error, state}
    end
  end

  defp raise_floor(state, opts) do
    node_id = Keyword.fetch!(opts, :node_id)
    generation = Keyword.fetch!(opts, :session_generation)

    if Map.get(state.floors, node_id, -1) >= generation do
      {:ok, state}
    else
      case Store.put(state.store, @generations, node_id, generation, durable: true) do
        :ok -> {:ok, %{state | floors: Map.put(state.floors, node_id, generation)}}
        _ -> :error
      end
    end
  end

  defp at_capacity?(state) do
    map_size(state.receipts) >= @max_retained or
      Enum.count(state.receipts, fn {_, receipt} -> receipt.state in @unresolved end) >=
        @max_unresolved
  end

  defp start_job(args, opts, from, key, receipt, state) do
    case open_port() do
      {:ok, port} ->
        request =
          Jason.encode!(%{
            "op" => "run",
            "args" => args,
            "policy" => FileService.path_policy(opts)
          })

        if byte_size(request) <= @max_frame and Port.command(port, request, [:nosuspend]) do
          job = %{
            port: port,
            owner: Keyword.fetch!(opts, :owner),
            invoke_id: Keyword.fetch!(opts, :invoke_id),
            owner_ref: Process.monitor(Keyword.fetch!(opts, :owner)),
            caller_ref: Process.monitor(elem(from, 0)),
            waiters: [from],
            timer: Process.send_after(self(), {:watchdog, key}, args["timeoutMs"] + 2_000),
            cancel_timer: nil,
            max_output: args["maxOutputBytes"]
          }

          {:noreply,
           %{state | jobs: Map.put(state.jobs, key, job), ports: Map.put(state.ports, port, key)}}
        else
          # The run frame never reached the helper: the program did not start.
          close_port(port)
          fail_before_exec(key, receipt, :process_unavailable, state)
        end

      {:error, reason} ->
        fail_before_exec(key, receipt, reason, state)
    end
  end

  defp open_port do
    case Python.executable() do
      {:error, :not_installed} ->
        {:error, :process_unavailable}

      {:ok, python} ->
        helper = Path.join(to_string(:code.priv_dir(:coding_agent)), "node_process.py")

        try do
          {:ok,
           Port.open({:spawn_executable, python}, [
             :binary,
             :exit_status,
             {:packet, 4},
             {:args, [helper]},
             {:env, LemonCore.ChildEnv.port_env()}
           ])}
        rescue
          _ -> {:error, :process_unavailable}
        end
    end
  end

  # Known non-execution is a terminal `failed` fence, not an unknown outcome. If
  # it cannot be persisted the durable receipt stays `running`, which reloads as
  # `outcome_unknown`: the in-memory view must not claim more than the Store.
  defp fail_before_exec(key, receipt, error, state) do
    failed =
      Map.merge(receipt, %{
        state: "failed",
        exit_code: nil,
        finished_at: System.system_time(:millisecond)
      })

    receipt =
      if persist(state, key, failed) == :ok,
        do: failed,
        else: %{receipt | state: "outcome_unknown", exit_code: nil}

    {:reply, {:error, error}, %{state | receipts: Map.put(state.receipts, key, receipt)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case state.ports[port] do
      nil ->
        {:noreply, state}

      key ->
        job = state.jobs[key]
        result = decode(data, state.receipts[key], job.max_output)
        {:noreply, finish(key, result, state)}
    end
  end

  def handle_info({port, {:exit_status, _}}, state) when is_port(port), do: lost(port, state)
  def handle_info({:EXIT, port, _}, state) when is_port(port), do: lost(port, state)
  def handle_info({:watchdog, key}, state), do: {:noreply, signal_cancel(key, state)}

  def handle_info({:force_close, key}, state) do
    case state.jobs[key] do
      nil ->
        {:noreply, state}

      job ->
        close_port(job.port)
        {:noreply, finish(key, {:error, :process_outcome_unknown}, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    keys = for {key, job} <- state.jobs, ref in [job.owner_ref, job.caller_ref], do: key
    {:noreply, Enum.reduce(keys, state, &signal_cancel/2)}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, 60_000)
    {:noreply, state |> load() |> sweep()}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp lost(port, state) do
    case state.ports[port] do
      nil -> {:noreply, state}
      key -> {:noreply, finish(key, {:error, :process_outcome_unknown}, state)}
    end
  end

  defp signal_cancel(%{} = state, key), do: signal_cancel(key, state)

  defp signal_cancel(key, state) do
    case state.jobs[key] do
      nil ->
        state

      %{cancel_timer: nil} = job ->
        try do
          Port.command(job.port, Jason.encode!(%{"op" => "cancel"}), [:nosuspend])
        rescue
          _ -> :ok
        end

        put_in(
          state.jobs[key].cancel_timer,
          Process.send_after(self(), {:force_close, key}, 2_000)
        )

      _ ->
        state
    end
  end

  defp finish(key, result, state) do
    job = state.jobs[key]
    receipt = state.receipts[key]

    {receipt, output, reply} =
      case result do
        {:ok, dto} ->
          {%{receipt | state: dto["state"], exit_code: dto["exitCode"]}, dto, {:ok, dto}}

        {:error, {:not_started, reason}} ->
          {%{receipt | state: "failed", exit_code: nil}, nil, {:error, reason}}

        {:error, reason} ->
          {%{receipt | state: "outcome_unknown", exit_code: nil}, nil, {:error, reason}}
      end

    receipt = Map.put(receipt, :finished_at, System.system_time(:millisecond))
    durable = persist(state, key, receipt)
    reply = if durable == :ok, do: reply, else: {:error, :store_unavailable}

    # An unpersisted `failed` is not known non-execution after a restart.
    receipt =
      if durable != :ok and receipt.state == "failed",
        do: %{receipt | state: "outcome_unknown"},
        else: receipt

    Enum.each(job.waiters, &GenServer.reply(&1, reply))
    Process.demonitor(job.owner_ref, [:flush])
    Process.demonitor(job.caller_ref, [:flush])
    Process.cancel_timer(job.timer)
    if job.cancel_timer, do: Process.cancel_timer(job.cancel_timer)
    close_port(job.port)

    cache =
      if output,
        do: Map.put(state.cache, key, {System.monotonic_time(:millisecond), output}),
        else: state.cache

    cache =
      if map_size(cache) > @max_cached do
        {oldest, _} = Enum.min_by(cache, fn {_, {time, _}} -> time end)
        Map.delete(cache, oldest)
      else
        cache
      end

    owner_waiters =
      Enum.reduce(state.owner_waiters, %{}, fn {from, keys}, acc ->
        keys = MapSet.delete(keys, key)

        if MapSet.size(keys) == 0 do
          GenServer.reply(from, :ok)
          acc
        else
          Map.put(acc, from, keys)
        end
      end)

    %{
      state
      | receipts: Map.put(state.receipts, key, receipt),
        jobs: Map.delete(state.jobs, key),
        ports: Map.delete(state.ports, job.port),
        cache: cache,
        owner_waiters: owner_waiters
    }
  end

  defp persist(state, key, receipt) do
    Store.put(state.store, @table, key, receipt, durable: true)
  end

  defp sweep(state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    now = System.system_time(:millisecond)

    %{
      state
      | cache: Map.reject(state.cache, fn {_, {time, _}} -> time < cutoff end),
        previews: Map.reject(state.previews, fn {_, preview} -> preview.expires_at_ms <= now end)
    }
    |> retire_terminal(now - @ttl_ms)
  end

  # Terminal fences retire 24 hours after they finished (cancel tombstones from
  # creation). Unresolved receipts never retire here. A failed delete keeps the
  # fence and is retried on the next sweep.
  defp retire_terminal(%{loaded: false} = state, _cutoff), do: state

  defp retire_terminal(state, cutoff) do
    Enum.reduce(state.receipts, state, fn {key, receipt}, acc ->
      if receipt.state in @terminal and not Map.has_key?(acc.jobs, key) and
           (Map.get(receipt, :finished_at) || receipt.created_at) <= cutoff do
        forget(acc, key)
      else
        acc
      end
    end)
  end

  defp forget(state, key) do
    case Store.delete(state.store, @table, key, durable: true) do
      :ok ->
        %{state | receipts: Map.delete(state.receipts, key), cache: Map.delete(state.cache, key)}

      _ ->
        state
    end
  end

  defp prune_request(opts, state) do
    filter = %{
      older_than_ms: Keyword.get(opts, :older_than_ms),
      states: Keyword.get(opts, :states, ["outcome_unknown"]),
      node_id: Keyword.get(opts, :node_id)
    }

    cond do
      not is_integer(filter.older_than_ms) or filter.older_than_ms <= 0 ->
        {{:error, :invalid_older_than_ms}, state}

      not is_list(filter.states) or filter.states == [] or
          not Enum.all?(filter.states, &(&1 in @prune_states)) ->
        {{:error, :invalid_states}, state}

      not (is_nil(filter.node_id) or valid_text?(filter.node_id, 256, true)) ->
        {{:error, :invalid_node_id}, state}

      Keyword.get(opts, :dry_run, true) != false ->
        prune_preview(filter, state)

      true ->
        prune_confirmed(filter, Keyword.get(opts, :confirm_token), state)
    end
  end

  defp prune_preview(filter, state) do
    now = System.system_time(:millisecond)

    plan =
      for {{node_id, _} = key, receipt} <- state.receipts,
          receipt.state in filter.states,
          is_nil(filter.node_id) or node_id == filter.node_id,
          receipt.created_at <= now - filter.older_than_ms,
          not Map.has_key?(state.jobs, key),
          into: %{},
          do: {key, receipt}

    ids = plan |> Map.keys() |> Enum.sort() |> Enum.map(&prune_id/1)

    {token, previews} =
      if plan == %{} do
        {nil, state.previews}
      else
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        preview = %{filter: filter, plan: plan, expires_at_ms: now + @prune_ttl_ms}

        previews =
          state.previews
          |> Enum.sort_by(fn {_, preview} -> preview.expires_at_ms end, :desc)
          |> Enum.take(@max_prune_previews - 1)
          |> Map.new()
          |> Map.put(token, preview)

        {token, previews}
      end

    report = %{
      token: token,
      count: length(ids),
      process_ids: Enum.take(ids, @prune_display_limit),
      truncated: length(ids) > @prune_display_limit,
      expires_at_ms: if(token, do: now + @prune_ttl_ms)
    }

    {{:ok, report}, %{state | previews: previews}}
  end

  defp prune_confirmed(_filter, token, state) when not is_binary(token) or token == "",
    do: {{:error, :confirmation_required}, state}

  defp prune_confirmed(filter, token, state) do
    # Single use: the token is consumed before anything is deleted.
    {preview, previews} = Map.pop(state.previews, token)
    state = %{state | previews: previews}

    if is_map(preview) and preview.filter == filter do
      preview.plan
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.reduce_while({:ok, [], [], state}, fn {key, receipt},
                                                    {:ok, deleted, skipped, acc} ->
        if acc.receipts[key] != receipt or Map.has_key?(acc.jobs, key) do
          {:cont, {:ok, deleted, [key | skipped], acc}}
        else
          next = forget(acc, key)

          if Map.has_key?(next.receipts, key),
            do: {:halt, {:partial_failure, deleted, skipped, acc}},
            else: {:cont, {:ok, [key | deleted], skipped, next}}
        end
      end)
      |> prune_reply()
    else
      {{:error, :confirmation_mismatch}, state}
    end
  end

  defp prune_reply({status, deleted, skipped, state}) do
    result = %{
      deleted: deleted |> Enum.reverse() |> Enum.map(&prune_id/1),
      skipped: skipped |> Enum.reverse() |> Enum.map(&prune_id/1)
    }

    reply = if status == :ok, do: {:ok, result}, else: {:error, {:partial_failure, result}}
    {reply, state}
  end

  defp prune_id({node_id, process_id}), do: %{"nodeId" => node_id, "processId" => process_id}

  defp metadata(args, opts, status),
    do: %{
      node_id: args["nodeId"],
      process_id: args["processId"],
      generation: Keyword.fetch!(opts, :session_generation),
      invoke_id: Keyword.fetch!(opts, :invoke_id),
      state: status,
      exit_code: nil,
      intent: nil,
      created_at: System.system_time(:millisecond)
    }

  defp intent(args, generation) do
    bytes =
      Jason.encode!([
        "lemon-node-process-intent-v1",
        args["nodeId"],
        generation,
        args["processId"],
        args["cwd"],
        args["argv"],
        args["stdinBase64"],
        args["timeoutMs"],
        args["maxOutputBytes"]
      ])

    :crypto.hash(:sha256, bytes) |> Base.encode64()
  end

  defp stale?(opts, state),
    do:
      Map.get(state.floors, Keyword.fetch!(opts, :node_id), -1) >
        Keyword.fetch!(opts, :session_generation)

  defp dto(args, status, code),
    do: %{
      "processId" => args["processId"],
      "nodeId" => args["nodeId"],
      "state" => status,
      "exitCode" => code,
      "stdoutBase64" => nil,
      "stderrBase64" => nil,
      "outputTruncated" => true
    }

  defp view(receipt, key, state) do
    receipt =
      if receipt.state == "running" and not Map.has_key?(state.jobs, key) do
        case state.receipts[key] do
          %{state: status} = known when status != "running" -> known
          _ -> %{receipt | state: "outcome_unknown", exit_code: nil}
        end
      else
        receipt
      end

    case state.cache[key] do
      {_, output} ->
        output

      nil ->
        dto(
          %{"processId" => receipt.process_id, "nodeId" => receipt.node_id},
          receipt.state,
          receipt.exit_code
        )
    end
  end

  defp decode(data, receipt, limit) when byte_size(data) <= @max_frame do
    case Jason.decode(data) do
      {:ok, %{"ok" => result}} when is_map(result) ->
        with true <-
               Enum.sort(Map.keys(result)) ==
                 Enum.sort(
                   ~w(processId nodeId state exitCode stdoutBase64 stderrBase64 outputTruncated)
                 ),
             true <-
               result["processId"] == receipt.process_id and result["nodeId"] == receipt.node_id,
             true <- result["state"] in ["completed", "cancelled"],
             true <- valid_exit?(result["state"], result["exitCode"]),
             true <- is_boolean(result["outputTruncated"]),
             {:ok, stdout} <- Base.decode64(result["stdoutBase64"]),
             {:ok, stderr} <- Base.decode64(result["stderrBase64"]),
             true <- byte_size(stdout) + byte_size(stderr) <= limit do
          {:ok, result}
        else
          _ -> {:error, :process_outcome_unknown}
        end

      {:ok, %{"error" => name} = error} ->
        reason = Enum.find(@errors, :process_failed, &(Atom.to_string(&1) == name))
        # Only the helper's explicit `started:false` proves the program never ran.
        if error["started"] == false, do: {:error, {:not_started, reason}}, else: {:error, reason}

      _ ->
        {:error, :process_outcome_unknown}
    end
  rescue
    _ -> {:error, :process_outcome_unknown}
  end

  defp decode(_, _, _), do: {:error, :process_outcome_unknown}

  defp validate(method, args, opts) do
    generation = Keyword.get(opts, :session_generation)

    valid_scope =
      is_map(args) and method in @methods and valid_text?(args["nodeId"], 256, true) and
        args["nodeId"] == Keyword.get(opts, :node_id) and is_integer(generation) and
        generation >= 0 and
        is_pid(Keyword.get(opts, :owner)) and
        valid_text?(Keyword.get(opts, :invoke_id), 128, true) and
        valid_process_id?(args["processId"])

    valid_args =
      if valid_scope and method == "node.process.run" do
        Enum.sort(Map.keys(args)) ==
          Enum.sort(~w(nodeId processId cwd argv stdinBase64 timeoutMs maxOutputBytes)) and
          valid_text?(args["cwd"], 4096, true) and valid_argv?(args["argv"], 0, 0) and
          is_integer(args["timeoutMs"]) and args["timeoutMs"] in 1000..1_800_000 and
          is_integer(args["maxOutputBytes"]) and args["maxOutputBytes"] in 1..1_048_576 and
          valid_stdin?(args["stdinBase64"])
      else
        valid_scope and Enum.sort(Map.keys(args)) == ~w(nodeId processId)
      end

    if valid_scope and valid_args, do: :ok, else: {:error, :invalid_request}
  end

  defp valid_argv?([], count, _bytes), do: count > 0

  defp valid_argv?([arg | rest], count, bytes) when count < 128 and is_binary(arg) do
    total = bytes + byte_size(arg)

    valid_text?(arg, 131_072, count == 0) and total <= 131_072 and
      valid_argv?(rest, count + 1, total)
  end

  defp valid_argv?(_, _, _), do: false

  defp valid_text?(text, max, nonempty) when is_binary(text),
    do:
      byte_size(text) <= max and (not nonempty or text != "") and String.valid?(text) and
        not String.contains?(text, <<0>>)

  defp valid_text?(_, _, _), do: false

  defp valid_stdin?(encoded) when is_binary(encoded) and byte_size(encoded) <= 1_398_104 do
    case Base.decode64(encoded) do
      {:ok, bytes} -> byte_size(bytes) <= 1_048_576 and Base.encode64(bytes) == encoded
      _ -> false
    end
  end

  defp valid_stdin?(_), do: false

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    _ -> :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :private_process_owner)
    |> Map.put(:message, :redacted)
    |> Map.put(:log, [])
  end

  @impl true
  def terminate(_, state) do
    Enum.each(state.jobs, fn {_, job} -> close_port(job.port) end)
    :ok
  end
end

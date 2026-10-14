defmodule CodingAgent.ExecutionNode.ProcessService do
  @moduledoc """
  Destination-native pipe process owner. Admission is durable before literal exec;
  fixed IDs bind exact intent and are never redispatched. Only minimal private
  metadata is stored in `node_process_receipts`; output is bounded volatile memory.
  The 1,000 durable ID fences never expire; capacity fails closed. Only the
  volatile output cache has a 24-hour TTL (and a separate 16-receipt bound).

  One packet4 Python Port owns each process group. Requests and cancellation are
  asynchronous inside this GenServer, so a long run cannot obstruct get/cancel.
  `owner` is the authenticated Worker, not the short-lived invocation task.
  """
  use GenServer

  alias LemonCore.Store
  alias CodingAgent.ExecutionNode.FileService

  @table :node_process_receipts
  @ttl_ms 86_400_000
  @max_receipts 1_000
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
         {:ok, receipts} <- normalize_receipts(entries) do
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
        {:ok, recovered} -> %{state | loaded: true, receipts: recovered}
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

  defp normalize_receipts(entries) when is_list(entries) and length(entries) <= @max_receipts do
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
        normalized.state in ["running", "completed", "cancelled", "outcome_unknown"] and
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
  defp valid_exit?(state, code) when state in ["running", "outcome_unknown"], do: is_nil(code)
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

      map_size(state.receipts) >= @max_receipts ->
        {:reply, {:error, :process_receipt_limit}, state}

      map_size(state.jobs) >= @max_active ->
        {:reply, {:error, :process_limit}, state}

      true ->
        receipt =
          metadata(args, opts, "running")
          |> Map.put(:intent, intent(args, Keyword.fetch!(opts, :session_generation)))

        case Store.put_new(state.store, @table, key, receipt) do
          :ok ->
            state = %{state | receipts: Map.put(state.receipts, key, receipt)}

            case Store.sync(state.store) do
              :ok -> start_job(args, opts, from, key, receipt, state)
              _ -> fail_admission(key, receipt, :store_unavailable, state)
            end

          {:error, :exists} ->
            case fetch_receipt(state, key) do
              {:ok, existing} when not is_nil(existing) ->
                dispatch("node.process.run", args, opts, from, key, existing, state)

              _ ->
                {:reply, {:error, :store_unavailable}, state}
            end

          _ ->
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

      map_size(state.receipts) >= @max_receipts ->
        {:reply, {:error, :process_receipt_limit}, state}

      true ->
        receipt = metadata(args, opts, "cancelled")

        case Store.put_new(state.store, @table, key, receipt) do
          :ok ->
            state = %{state | receipts: Map.put(state.receipts, key, receipt)}

            case Store.sync(state.store) do
              :ok -> {:reply, {:ok, dto(args, "cancelled", nil)}, state}
              _ -> {:reply, {:error, :store_unavailable}, state}
            end

          {:error, :exists} ->
            case fetch_receipt(state, key) do
              {:ok, existing} when not is_nil(existing) ->
                dispatch("node.process.cancel", args, opts, from, key, existing, state)

              _ ->
                {:reply, {:error, :store_unavailable}, state}
            end

          _ ->
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
          close_port(port)
          fail_admission(key, receipt, :process_unavailable, state)
        end

      {:error, reason} ->
        fail_admission(key, receipt, reason, state)
    end
  end

  defp open_port do
    case System.find_executable("python3") do
      nil ->
        {:error, :process_unavailable}

      python ->
        helper = Path.join(to_string(:code.priv_dir(:coding_agent)), "node_process.py")

        try do
          {:ok,
           Port.open({:spawn_executable, python}, [
             :binary,
             :exit_status,
             {:packet, 4},
             {:args, [helper]}
           ])}
        rescue
          _ -> {:error, :process_unavailable}
        end
    end
  end

  defp fail_admission(key, receipt, error, state) do
    receipt = %{receipt | state: "outcome_unknown", exit_code: nil}
    _ = persist(state, key, receipt)
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

        {:error, reason} ->
          {%{receipt | state: "outcome_unknown", exit_code: nil}, nil, {:error, reason}}
      end

    receipt = Map.put(receipt, :finished_at, System.system_time(:millisecond))
    durable = persist(state, key, receipt)
    reply = if durable == :ok, do: reply, else: {:error, :store_unavailable}
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
    with :ok <- Store.put(state.store, @table, key, receipt),
         :ok <- Store.sync(state.store),
         do: :ok
  end

  # Durable spent-ID fences do not expire: capacity fails closed rather than
  # permitting an old RUN (or cancelled missing ID) to execute a second time.
  defp sweep(state) do
    cutoff = System.monotonic_time(:millisecond) - @ttl_ms
    %{state | cache: Map.reject(state.cache, fn {_, {time, _}} -> time < cutoff end)}
  end

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

  defp stale?(opts, state) do
    node_id = Keyword.fetch!(opts, :node_id)
    generation = Keyword.fetch!(opts, :session_generation)

    Enum.any?(state.receipts, fn {{node, _}, receipt} ->
      node == node_id and receipt.generation > generation
    end)
  end

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

      {:ok, %{"error" => name}} ->
        {:error, Enum.find(@errors, :process_failed, &(Atom.to_string(&1) == name))}

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

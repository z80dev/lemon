defmodule LemonCli.Setup.DeviceLogin do
  @moduledoc """
  Destination-local, supervised Codex device-login lifecycle.

  The authenticated transport supplies the target and opaque owner/session
  bindings. All five request fields are compared on every operation. Provider
  polling and credentials stay here; polling this service only reads status.
  Successful OAuth remains volatile in its sensitive worker until an internal
  challenge issues a nonce with a target-local five-second monotonic deadline.
  Completion must supply that exact unused nonce. Every completion attempt,
  including non-writing settlement, is durably single-use.
  Reconciliation never blocks revocation or retries an uncertain write.
  A new login supersedes the same owner/target/provider, including another
  product session. Completion, cancellation and credential replacement serialize.
  A cancel arriving before its start consumes the fixed ID without issuing a
  grant, so a delayed start cannot reconnect it.

  At most 16 grants run and 128 public records are retained, with terminal
  records retained for 15 minutes. A durable, one-MiB conservative spent-ID filter
  prevents replay after pruning or restart. False positives return `lost` safely;
  its 100,000-ID lifetime ceiling fails closed with `busy`. It is never reset
  automatically. Only this nonsecret filter is stored in the target Store;
  pending device secrets and tokens are never stored there.

  Workers are sensitive linked processes, not Tasks. Their return values and
  caught exceptions are discarded. A completion carries only an opaque closure
  into the sensitive manager, which invokes it only for the current live grant;
  neither credentials nor that closure enter manager state or public results.
  """

  use GenServer
  import Bitwise

  alias LemonAi.Auth.OpenAICodexOAuth
  alias LemonCli.Setup.ProviderManagement

  @verification_url "https://auth.openai.com/codex/device"
  @binding_keys ~w(targetId providerId loginId ownerId sessionId)
  @active_statuses ~w(starting pending)
  @lifetime_ms 900_000
  @authorization_ttl_ms 5_000
  @retention_ms 900_000
  @max_active 16
  @max_entries 128
  @filter_bytes 1_048_576
  @max_starts 100_000
  @guard_table :provider_device_login
  @guard_key :spent_ids_v1

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def start(params, opts), do: request(:start, params, opts)
  def poll(params, opts), do: request(:poll, params, opts)
  def challenge(params, opts), do: request(:challenge, params, opts)
  def cancel(params, opts), do: request(:cancel, params, opts)

  def complete(params, opts) when is_map(params) do
    extra = ~w(completionId challengeNonce commit)

    if Enum.sort(Map.keys(params)) == Enum.sort(@binding_keys ++ extra) and
         identity?(params["completionId"]) and is_boolean(params["commit"]) and
         is_binary(params["challengeNonce"]) and
         (identity?(params["challengeNonce"]) or
            (not params["commit"] and params["challengeNonce"] == "")) do
      request(
        :authorize_completion,
        Map.take(params, @binding_keys),
        Keyword.put(opts, :completion, Map.take(params, extra))
      )
    else
      {:error, :invalid_request}
    end
  end

  def complete(_, _), do: {:error, :invalid_request}

  @doc false
  def with_cancelled(target_id, provider_id, fun, opts) do
    server = Keyword.get(opts, :device_server, __MODULE__)

    if is_pid(server) or Process.whereis(server) do
      call(server, {:mutate, target_id, provider_id, fun})
    else
      # A stopped lifecycle has no surviving linked workers to reconnect it.
      safe(fun)
    end
  end

  defp request(operation, params, opts) do
    with {:ok, binding} <- binding(params, opts) do
      call(Keyword.get(opts, :device_server, __MODULE__), {operation, binding, opts})
    end
  end

  defp call(server, message) do
    GenServer.call(server, message, 30_000)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:sensitive, true)
    Process.flag(:trap_exit, true)
    Process.send_after(self(), :sweep, 60_000)
    {:ok, %{entries: %{}, store: Keyword.get(opts, :device_store, LemonCore.Store)}}
  end

  @impl true
  def handle_call({operation, binding, opts}, _from, state)
      when operation in [:start, :poll, :cancel, :challenge] do
    state = sweep(state)

    case Map.get(state.entries, binding["loginId"]) do
      %{binding: existing} when existing != binding ->
        {:reply, {:error, :forbidden}, state}

      nil when operation == :start ->
        start_login(binding, opts, state)

      nil when operation == :cancel ->
        cancel_unknown(binding, state)

      nil ->
        result = projection(binding, "lost")

        result =
          if operation == :challenge, do: Map.put(result, :challengeNonce, nil), else: result

        {:reply, {:ok, result}, state}

      entry ->
        entry = if operation == :cancel, do: finish(entry, "cancelled"), else: entry
        entry = if operation == :challenge, do: issue_challenge(entry, opts), else: entry
        state = put_entry(state, entry)
        result = project(entry)

        result =
          if operation == :challenge,
            do: Map.put(result, :challengeNonce, challenge_nonce(entry, opts)),
            else: result

        {:reply, {:ok, result}, state}
    end
  end

  def handle_call({:authorize_completion, binding, opts}, from, state) do
    state = sweep(state)
    entry = Map.get(state.entries, binding["loginId"])

    if entry && entry.binding != binding do
      {:reply, {:error, :provider_binding_rejected}, state}
    else
      completion = Keyword.fetch!(opts, :completion)
      id = "completion:" <> completion["completionId"]

      case claim(state.store, id) do
        {:available, guard} ->
          case spend(state.store, guard, id) do
            :ok -> authorize_completion(entry, binding, opts, from, state)
            error -> {:reply, error, state}
          end

        :spent ->
          completion_reply(entry, binding, from, state)

        error ->
          {:reply, error, state}
      end
    end
  end

  def handle_call({:ready, id, ref}, {pid, _}, state) do
    case current(state, id, ref, pid) do
      %{status: "pending"} = entry ->
        {:reply, :ok, put_entry(state, %{entry | ready: true})}

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:metadata, id, ref, metadata}, {pid, _}, state) do
    case current(state, id, ref, pid) do
      %{status: "starting"} = entry ->
        case public_metadata(metadata, entry) do
          {:ok, fields, deadline} ->
            _ = Process.cancel_timer(entry.timer)
            timer = Process.send_after(self(), {:expire, id, ref}, max(deadline - now(), 0))
            entry = %{entry | status: "pending", fields: fields, deadline: deadline, timer: timer}
            {:reply, :ok, put_entry(state, entry)}

          :error ->
            {:reply, {:error, :unavailable}, put_entry(state, finish(entry, "failed"))}
        end

      _ ->
        {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:complete, id, ref, persist}, {pid, _}, state) when is_function(persist, 0) do
    case current(state, id, ref, pid) do
      %{status: "pending", completion_from: from} = entry when not is_nil(from) ->
        cond do
          entry.deadline <= now() ->
            {:reply, :ok, put_entry(state, finish(entry, "expired"))}

          entry.authorization_deadline <= entry.challenge_clock.() ->
            {:reply, :ok, put_entry(state, finish(entry, "cancelled"))}

          true ->
            status =
              case safe(persist) do
                :ok -> "completed"
                {:error, :authorization_expired} -> "cancelled"
                _ -> "failed"
              end

            {:reply, :ok, put_entry(state, finish(entry, status))}
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:mutate, target_id, provider_id, fun}, _from, state) do
    entries =
      Map.new(state.entries, fn {id, entry} ->
        if entry.binding["targetId"] == target_id and entry.binding["providerId"] == provider_id,
          do: {id, finish(entry, "cancelled")},
          else: {id, entry}
      end)

    {:reply, safe(fun), %{state | entries: entries}}
  end

  @impl true
  def handle_info({:worker_finished, id, ref, status}, state)
      when status in ["denied", "expired", "failed"] do
    case Map.get(state.entries, id) do
      %{ref: ^ref} = entry -> {:noreply, put_entry(state, finish(entry, status))}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:expire, id, ref}, state) do
    case Map.get(state.entries, id) do
      %{ref: ^ref} = entry -> {:noreply, put_entry(state, finish(entry, "expired"))}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    entries =
      Map.new(state.entries, fn {id, entry} ->
        if entry.worker == pid,
          do: {id, finish(entry, "failed")},
          else: {id, entry}
      end)

    {:noreply, %{state | entries: entries}}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, 60_000)
    {:noreply, sweep(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.entries, fn {_id, entry} -> stop_worker(entry.worker) end)
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}

  defp start_login(binding, opts, state) do
    case claim(state.store, binding["loginId"]) do
      :spent ->
        {:reply, {:ok, projection(binding, "lost")}, state}

      {:available, guard} ->
        scope = scope(binding)

        superseded =
          Enum.count(state.entries, fn {_, entry} ->
            active?(entry) and scope(entry.binding) == scope
          end)

        active = Enum.count(state.entries, fn {_, entry} -> active?(entry) end)

        if map_size(state.entries) >= @max_entries or active - superseded >= @max_active do
          {:reply, {:error, :busy}, state}
        else
          launch(binding, opts, state, guard)
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp cancel_unknown(binding, state) do
    case claim(state.store, binding["loginId"]) do
      :spent ->
        {:reply, {:ok, projection(binding, "lost")}, state}

      {:available, guard} ->
        case spend(state.store, guard, binding["loginId"]) do
          :ok ->
            entry = %{
              binding: binding,
              status: "cancelled",
              fields: nil,
              deadline: now(),
              finished_at: now(),
              worker: nil,
              ref: make_ref(),
              timer: nil
            }

            state =
              if map_size(state.entries) < @max_entries,
                do: put_entry(state, entry),
                else: state

            {:reply, {:ok, project(entry)}, state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp completion_reply(%{completion_from: from} = entry, _binding, waiter, state)
       when not is_nil(from) do
    entry = %{entry | completion_waiters: [waiter | entry.completion_waiters]}
    {:noreply, put_entry(state, entry)}
  end

  defp completion_reply(entry, binding, _from, state),
    do: {:reply, {:ok, if(entry, do: project(entry), else: projection(binding, "lost"))}, state}

  defp authorize_completion(nil, binding, _opts, _from, state),
    do: {:reply, {:ok, projection(binding, "lost")}, state}

  defp authorize_completion(entry, _binding, opts, from, state) do
    completion = Keyword.fetch!(opts, :completion)

    cond do
      completion["commit"] and Map.get(entry, :authority) != Keyword.get(opts, :authority) ->
        entry = finish(entry, "cancelled")
        {:reply, {:ok, project(entry)}, put_entry(state, entry)}

      not is_nil(Map.get(entry, :completion_from)) ->
        completion_reply(entry, entry.binding, from, state)

      not completion["commit"] ->
        entry = finish(entry, "cancelled")
        {:reply, {:ok, project(entry)}, put_entry(state, entry)}

      entry.status not in @active_statuses ->
        {:reply, {:ok, project(entry)}, state}

      not Map.get(entry, :ready, false) ->
        {:reply, {:ok, project(entry)}, state}

      is_nil(entry.challenge_nonce) or entry.challenge_used or
        completion["challengeNonce"] != entry.challenge_nonce or
          entry.challenge_deadline <= entry.challenge_clock.() ->
        entry = finish(entry, "cancelled")
        {:reply, {:ok, project(entry)}, put_entry(state, entry)}

      entry.status == "pending" and entry.ready ->
        send(entry.worker, {:persist, entry.ref, entry.challenge_deadline, entry.challenge_clock})

        entry = %{
          entry
          | completion_from: from,
            authorization_deadline: entry.challenge_deadline,
            challenge_used: true
        }

        {:noreply, put_entry(state, entry)}

      true ->
        {:reply, {:ok, project(entry)}, state}
    end
  end

  defp issue_challenge(entry, opts) do
    if entry.status == "pending" and Map.get(entry, :ready, false) and
         entry.authority == Keyword.get(opts, :authority) and
         is_nil(entry.completion_from) and
         (is_nil(entry.challenge_nonce) or entry.challenge_deadline <= entry.challenge_clock.()) do
      %{
        entry
        | challenge_nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
          challenge_deadline: entry.challenge_clock.() + @authorization_ttl_ms,
          challenge_used: false
      }
    else
      entry
    end
  end

  defp challenge_nonce(entry, opts) do
    if entry.status == "pending" and Map.get(entry, :ready, false) and
         entry.authority == Keyword.get(opts, :authority) and
         not entry.challenge_used and not is_nil(entry.challenge_deadline) and
         entry.challenge_deadline > entry.challenge_clock.(),
       do: entry.challenge_nonce,
       else: nil
  end

  defp launch(binding, opts, state, guard) do
    # Claim is flushed before launching any provider request. An uncertain write
    # consumes the ID rather than permitting a second exchange.
    case spend(state.store, guard, binding["loginId"]) do
      :ok ->
        entries =
          Map.new(state.entries, fn {id, entry} ->
            if scope(entry.binding) == scope(binding),
              do: {id, finish(entry, "cancelled")},
              else: {id, entry}
          end)

        manager = self()
        id = binding["loginId"]
        ref = make_ref()
        worker = spawn_link(fn -> run(manager, id, ref, opts) end)
        timer = Process.send_after(self(), {:expire, id, ref}, @lifetime_ms)

        entry = %{
          binding: binding,
          status: "starting",
          fields: nil,
          deadline: now() + @lifetime_ms,
          finished_at: nil,
          worker: worker,
          ref: ref,
          timer: timer,
          ready: false,
          completion_from: nil,
          completion_waiters: [],
          authorization_deadline: nil,
          challenge_nonce: nil,
          challenge_deadline: nil,
          challenge_used: false,
          challenge_clock: Keyword.get(opts, :device_monotonic_time, &now/0),
          wall_clock:
            Keyword.get(opts, :device_wall_time, fn -> System.system_time(:millisecond) end),
          authority: Keyword.get(opts, :authority)
        }

        {:reply, {:ok, project(entry)}, put_entry(%{state | entries: entries}, entry)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp run(manager, id, ref, opts) do
    Process.flag(:sensitive, true)

    result =
      safe(fn ->
        login = Keyword.get(opts, :device_login_fun, &OpenAICodexOAuth.login_device_code/1)

        login_opts =
          Keyword.get(opts, :device_oauth_opts, [])
          |> Keyword.put(:on_auth, fn _, _ -> :ok end)
          |> Keyword.put(:on_progress, fn _ -> :ok end)
          |> Keyword.put(:on_device_code, fn metadata ->
            case call(manager, {:metadata, id, ref, metadata}) do
              :ok -> :ok
              _ -> throw(:device_login_cancelled)
            end
          end)

        case login.(login_opts) do
          {:ok, secret} when is_map(secret) ->
            # Tokens remain in this sensitive worker until the product transport
            # supplies a fresh, short-lived single-use completion authorization.
            case call(manager, {:ready, id, ref}) do
              :ok ->
                receive do
                  {:persist, ^ref, deadline, clock} ->
                    persist = fn ->
                      ProviderManagement.persist_device_login(
                        secret,
                        opts
                        |> Keyword.put(:authorization_deadline, deadline)
                        |> Keyword.put(:device_monotonic_time, clock)
                      )
                    end

                    call(manager, {:complete, id, ref, persist})
                end

              _ ->
                :ok
            end

            :completed

          {:error, :access_denied} ->
            "denied"

          {:error, reason} when reason in [:device_flow_timed_out, :device_code_expired] ->
            "expired"

          _ ->
            "failed"
        end
      end)

    if result != :completed do
      status = if result in ["denied", "expired", "failed"], do: result, else: "failed"
      send(manager, {:worker_finished, id, ref, status})
    end

    :ok
  end

  defp current(state, id, ref, pid) do
    case Map.get(state.entries, id) do
      %{ref: ^ref, worker: ^pid} = entry -> entry
      _ -> nil
    end
  end

  defp public_metadata(
         %{
           verification_url: @verification_url,
           user_code: code,
           expires_at_ms: expiry,
           poll_interval_ms: interval
         },
         entry
       )
       when is_binary(code) and byte_size(code) in 1..64 and is_integer(expiry) and
              is_integer(interval) and interval in 1_000..60_000 do
    wall_time = entry.wall_clock.()
    monotonic_time = now()
    remaining = expiry - wall_time
    deadline = min(entry.deadline, monotonic_time + remaining)

    if String.match?(code, ~r/^[A-Za-z0-9-]+$/) and remaining in 1..@lifetime_ms and
         deadline > monotonic_time do
      {:ok,
       %{
         verificationUrl: @verification_url,
         userCode: code,
         expiresAtMs: min(expiry, wall_time + deadline - monotonic_time),
         pollIntervalMs: interval
       }, deadline}
    else
      :error
    end
  end

  defp public_metadata(_, _), do: :error

  defp binding(params, opts) when is_map(params) do
    target = Keyword.get(opts, :target, %{})

    cond do
      Enum.sort(Map.keys(params)) != Enum.sort(@binding_keys) -> {:error, :invalid_request}
      not Enum.all?(@binding_keys, &identity?(params[&1])) -> {:error, :invalid_request}
      params["providerId"] != "openai_codex" -> {:error, :invalid_provider}
      params["targetId"] != target[:id] -> {:error, :invalid_target}
      true -> {:ok, params}
    end
  end

  defp binding(_, _), do: {:error, :invalid_request}

  defp identity?(value) when is_binary(value),
    do:
      byte_size(value) in 1..256 and String.valid?(value) and
        not String.match?(value, ~r/[\s\x00-\x1f\x7f]/u)

  defp identity?(_), do: false
  defp scope(binding), do: {binding["ownerId"], binding["targetId"], binding["providerId"]}
  defp active?(entry), do: entry.status in @active_statuses
  defp now, do: System.monotonic_time(:millisecond)

  defp finish(entry, status) do
    if active?(entry) do
      _ = Process.cancel_timer(entry.timer)
      stop_worker(entry.worker)
      entry = %{entry | status: status, fields: nil, finished_at: now(), worker: nil, timer: nil}

      for from <- [Map.get(entry, :completion_from) | Map.get(entry, :completion_waiters, [])],
          not is_nil(from) do
        GenServer.reply(from, {:ok, project(entry)})
      end

      entry |> Map.put(:completion_from, nil) |> Map.put(:completion_waiters, [])
    else
      entry
    end
  end

  defp stop_worker(pid) when is_pid(pid), do: Process.exit(pid, :kill)
  defp stop_worker(_), do: :ok

  defp sweep(state) do
    entries =
      Enum.reduce(state.entries, %{}, fn {id, entry}, acc ->
        entry =
          if active?(entry) and entry.deadline <= now(), do: finish(entry, "expired"), else: entry

        if entry.finished_at && now() - entry.finished_at >= @retention_ms,
          do: acc,
          else: Map.put(acc, id, entry)
      end)

    %{state | entries: entries}
  end

  defp put_entry(state, entry),
    do: %{state | entries: Map.put(state.entries, entry.binding["loginId"], entry)}

  defp project(entry), do: Map.merge(projection(entry.binding, entry.status), entry.fields || %{})

  defp projection(binding, status) do
    %{
      loginId: binding["loginId"],
      targetId: binding["targetId"],
      providerId: "openai_codex",
      status: status,
      verificationUrl: nil,
      userCode: nil,
      expiresAtMs: nil,
      pollIntervalMs: nil
    }
  end

  defp claim(store, id) do
    with {:ok, guard} <- read_guard(store) do
      cond do
        spent?(guard.bits, id) -> :spent
        guard.count >= @max_starts -> {:error, :busy}
        true -> {:available, guard}
      end
    end
  end

  defp spend(store, guard, id) do
    safe(fn ->
      with :ok <-
             store.put(@guard_table, @guard_key, %{
               bits_base64: Base.encode64(mark(guard.bits, id)),
               count: guard.count + 1
             }),
           :ok <- store.sync() do
        :ok
      else
        _ -> {:error, :unavailable}
      end
    end)
  end

  defp read_guard(store) do
    safe(fn ->
      case store.fetch(@guard_table, @guard_key) do
        {:ok, nil} ->
          {:ok, %{bits: :binary.copy(<<0>>, @filter_bytes), count: 0}}

        {:ok, %{bits_base64: encoded, count: count} = stored}
        when map_size(stored) == 2 and is_binary(encoded) and
               byte_size(encoded) == div(@filter_bytes + 2, 3) * 4 and
               is_integer(count) and count in 0..@max_starts ->
          with {:ok, bits} <- Base.decode64(encoded),
               true <- byte_size(bits) == @filter_bytes,
               true <- Base.encode64(bits) == encoded do
            {:ok, %{bits: bits, count: count}}
          else
            _ -> {:error, :unavailable}
          end

        _ ->
          {:error, :unavailable}
      end
    end)
  end

  defp positions(id) do
    for <<position::unsigned-32 <- binary_part(:crypto.hash(:sha256, id), 0, 28)>>,
      do: rem(position, @filter_bytes * 8)
  end

  defp spent?(bits, id) do
    Enum.all?(positions(id), fn position ->
      band(:binary.at(bits, div(position, 8)), 1 <<< rem(position, 8)) != 0
    end)
  end

  defp mark(bits, id) do
    masks =
      Enum.reduce(positions(id), %{}, fn position, acc ->
        mask = 1 <<< rem(position, 8)
        Map.update(acc, div(position, 8), mask, &bor(&1, mask))
      end)

    {chunks, offset} =
      masks
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn {index, mask}, {chunks, offset} ->
        chunk = binary_part(bits, offset, index - offset)
        {[chunks, chunk, <<bor(:binary.at(bits, index), mask)>>], index + 1}
      end)

    IO.iodata_to_binary([chunks, binary_part(bits, offset, byte_size(bits) - offset)])
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end

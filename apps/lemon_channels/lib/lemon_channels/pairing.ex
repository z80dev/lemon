defmodule LemonChannels.Pairing do
  @moduledoc """
  Owner-approved, single-use channel pairing requests.

  Only SHA-256 code digests are persisted in `:channel_pairing_requests`.
  Plaintext codes live in memory until expiry so a sender can receive the same
  request again after ten minutes. After a runtime restart an existing request
  remains approvable, but cannot be re-displayed; it expires after one hour.
  Approval is deliberately absent here: the local operator CLI consumes a code
  before updating the canonical gateway allowlist.
  """
  use GenServer

  alias LemonCore.{Redact, Store}

  @table :channel_pairing_requests
  @alphabet "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @ttl_ms :timer.hours(1)
  @reply_interval_ms :timer.minutes(10)
  @sweep_ms :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Mint or reuse a sender's request; `:pending` means no reply is due."
  def request(platform, chat_id, user_id, display_name, opts \\ []) do
    GenServer.call(
      server(opts),
      {:request, platform, to_string(chat_id), to_string(user_id), display_name}
    )
  end

  @doc "List redacted pending requests, never codes or code digests."
  def list(opts \\ []), do: GenServer.call(server(opts), :list)

  @doc "Atomically consume a code for its platform; expired codes fail closed."
  def consume(platform, code, opts \\ []) do
    GenServer.call(server(opts), {:consume, platform, code})
  end

  @doc "Return a pairing reply only for a human DM, never a group or bot."
  def reply(platform, %{peer: %{kind: :dm}, sender: %{id: id} = sender} = inbound)
      when is_binary(id) and id != "" do
    if sender[:bot] == true do
      :ignore
    else
      case request(platform, inbound.peer.id, id, sender[:display_name] || sender[:username]) do
        {:ok, code} ->
          {:ok,
           "Pairing code: #{code}\nAsk the owner to run `lemon pairing approve #{platform} #{code}`. This code expires in one hour."}

        _ ->
          :ignore
      end
    end
  catch
    :exit, _ -> :ignore
  end

  def reply(_platform, _inbound), do: :ignore

  @impl true
  def init(opts) do
    schedule_sweep()

    {:ok,
     %{
       store: Keyword.get(opts, :store, Store),
       clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
       pairing_codes: %{}
     }}
  end

  @impl true
  def handle_call({:request, platform, chat_id, user_id, name}, _from, state) do
    now = state.clock.()

    with :ok <- validate_platform(platform),
         true <- chat_id != "" and user_id != "",
         {:ok, rows, state} <- pending(state, now) do
      existing =
        Enum.find(rows, fn {_key, row} ->
          row.platform == platform and row.chat_id == chat_id and row.user_id == user_id
        end)

      {result, state} =
        request_reply(existing, rows, platform, chat_id, user_id, name, now, state)

      {:reply, result, state}
    else
      false -> {:reply, {:error, :invalid_sender}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state) do
    now = state.clock.()

    case pending(state, now) do
      {:ok, rows, state} ->
        requests =
          Enum.map(rows, fn {_key, row} ->
            %{
              platform: row.platform,
              masked_chat_id: mask(row.chat_id),
              display_name: row.display_name,
              created_at: row.created_at,
              age_ms: max(now - row.created_at, 0)
            }
          end)

        {:reply, {:ok, Enum.sort_by(requests, & &1.created_at)}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:consume, platform, code}, _from, state) do
    with :ok <- validate_platform(platform),
         true <- is_binary(code) and Regex.match?(~r/^[A-HJ-NP-Z2-9]{8}$/, code) do
      key = digest(platform, code)

      result =
        case Store.take(state.store, @table, key) do
          %{expires_at: expires_at} = row ->
            if expires_at > state.clock.(),
              do: {:ok, Map.drop(row, [:code_hash, :last_reply_at])},
              else: {:error, :not_found}

          nil ->
            {:error, :not_found}

          {:error, _} ->
            {:error, :store_unavailable}
        end

      {:reply, result, %{state | pairing_codes: Map.delete(state.pairing_codes, key)}}
    else
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()

    case pending(state, state.clock.()) do
      {:ok, _rows, state} -> {:noreply, state}
      {:error, _} -> {:noreply, state}
    end
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: Redact.map(status.state), message: :redacted, log: []})

  defp request_reply({key, row}, _rows, _platform, _chat, _user, _name, now, state) do
    with true <- now - row.last_reply_at >= @reply_interval_ms,
         code when is_binary(code) <- state.pairing_codes[key],
         :ok <- Store.put(state.store, @table, key, %{row | last_reply_at: now}) do
      {{:ok, code}, state}
    else
      _ -> {:pending, state}
    end
  end

  defp request_reply(nil, rows, platform, chat, user, name, now, state) do
    if Enum.count(rows, fn {_key, row} -> row.platform == platform end) >= 3 do
      {{:error, :too_many_pending}, state}
    else
      code =
        for <<byte <- :crypto.strong_rand_bytes(8)>>,
          into: "",
          do: <<:binary.at(@alphabet, rem(byte, 32))>>

      key = digest(platform, code)

      row = %{
        platform: platform,
        chat_id: chat,
        user_id: user,
        display_name: safe_name(name),
        created_at: now,
        expires_at: now + @ttl_ms,
        last_reply_at: now,
        code_hash: key
      }

      case Store.put_new(state.store, @table, key, row) do
        :ok -> {{:ok, code}, %{state | pairing_codes: Map.put(state.pairing_codes, key, code)}}
        {:error, _} -> {{:error, :store_unavailable}, state}
      end
    end
  end

  defp pending(state, now) do
    with {:ok, rows} <- Store.fetch_all(state.store, @table),
         :ok <- sweep_expired(state.store, rows, now) do
      rows = Enum.filter(rows, fn {_key, row} -> row.expires_at > now end)

      {:ok, rows,
       %{state | pairing_codes: Map.take(state.pairing_codes, Enum.map(rows, &elem(&1, 0)))}}
    end
  end

  defp sweep_expired(store, rows, now) do
    Enum.reduce_while(rows, :ok, fn {key, row}, :ok ->
      if row.expires_at <= now do
        case Store.compare_and_delete(store, @table, key, row) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp digest(platform, code),
    do: :crypto.hash(:sha256, platform <> ":" <> code) |> Base.encode16(case: :lower)

  defp validate_platform(platform) when platform in ["telegram", "discord"], do: :ok
  defp validate_platform(_platform), do: {:error, :invalid_platform}
  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp mask(id), do: "***" <> String.slice(id, -4, 4)

  defp safe_name(name) when is_binary(name),
    do: name |> Redact.text() |> String.replace(~r/[[:cntrl:]]/u, " ") |> String.slice(0, 80)

  defp safe_name(_name), do: "Unknown"
end

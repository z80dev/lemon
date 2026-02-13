defmodule LemonGateway.Sms.Inbox do
  @moduledoc false

  use GenServer

  require Logger

  alias LemonGateway.Sms.Config

  @table :sms_inbox
  @cleanup_interval_ms 10 * 60 * 1000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ingest_twilio_sms(map()) :: {:ok, :stored | :duplicate} | {:error, term()}
  def ingest_twilio_sms(params) when is_map(params) do
    GenServer.call(__MODULE__, {:ingest_twilio_sms, params})
  end

  @spec list_messages(keyword()) :: [map()]
  def list_messages(opts \\ []) when is_list(opts) do
    GenServer.call(__MODULE__, {:list_messages, opts})
  end

  @spec wait_for_code(binary() | nil, keyword()) ::
          {:ok, %{code: binary(), message: map()}} | {:error, :timeout} | {:error, term()}
  def wait_for_code(session_key, opts \\ []) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)

    # Call timeout must exceed tool wait timeout slightly so we can reply cleanly.
    GenServer.call(__MODULE__, {:wait_for_code, session_key, opts}, timeout_ms + 1_500)
  end

  @spec claim_message(binary() | nil, binary()) :: :ok | {:error, term()}
  def claim_message(session_key, message_sid) when is_binary(message_sid) do
    GenServer.call(__MODULE__, {:claim_message, session_key, message_sid})
  end

  def inbox_number do
    Config.inbox_number()
  end

  @impl true
  def init(_opts) do
    state = %{
      waiters: %{}
    }

    schedule_cleanup()
    {:ok, state}
  end

  @impl true
  def handle_call({:ingest_twilio_sms, params}, _from, state) do
    case normalize_twilio_sms(params) do
      {:ok, msg} ->
        case LemonCore.Store.get(@table, msg["message_sid"]) do
          nil ->
            :ok = LemonCore.Store.put(@table, msg["message_sid"], msg)
            state = fulfill_waiters(msg, state)
            {:reply, {:ok, :stored}, state}

          _existing ->
            {:reply, {:ok, :duplicate}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  rescue
    e -> {:reply, {:error, {:exception, Exception.message(e)}}, state}
  end

  def handle_call({:list_messages, opts}, _from, state) do
    entries = read_all_messages()
    filtered = filter_messages(entries, opts)
    {:reply, filtered, state}
  rescue
    e ->
      Logger.warning(
        "Sms.Inbox list_messages failed: #{Exception.message(e)}\n" <>
          Exception.format_stacktrace(__STACKTRACE__)
      )

      {:reply, [], state}
  end

  def handle_call({:claim_message, session_key, message_sid}, _from, state) do
    session_key = normalize_session_key(session_key)

    case LemonCore.Store.get(@table, message_sid) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{} = msg ->
        claimed_by = msg["claimed_by"]

        cond do
          is_binary(claimed_by) and claimed_by != "" and claimed_by != session_key ->
            {:reply, {:error, :already_claimed}, state}

          true ->
            updated =
              msg
              |> Map.put("claimed_by", session_key)
              |> Map.put("claimed_at_ms", now_ms())

            :ok = LemonCore.Store.put(@table, message_sid, updated)
            {:reply, :ok, state}
        end
    end
  rescue
    _ -> {:reply, {:error, :claim_failed}, state}
  end

  def handle_call({:wait_for_code, session_key, opts}, from, state) do
    session_key = normalize_session_key(session_key)
    opts = normalize_wait_opts(opts)

    case find_matching_code_message(opts) do
      {:ok, %{code: code, message: msg}} ->
        {msg, state} = maybe_claim_and_persist(msg, session_key, opts, state)
        {:reply, {:ok, %{code: code, message: msg}}, state}

      :miss ->
        waiter_id = LemonCore.Id.run_id()
        caller_pid = elem(from, 0)
        mon_ref = Process.monitor(caller_pid)
        timeout_ms = opts[:timeout_ms] || 60_000
        timer_ref = Process.send_after(self(), {:wait_timeout, waiter_id}, timeout_ms)

        waiter = %{
          id: waiter_id,
          from: from,
          caller_pid: caller_pid,
          mon_ref: mon_ref,
          timer_ref: timer_ref,
          session_key: session_key,
          opts: opts
        }

        {:noreply, %{state | waiters: Map.put(state.waiters, waiter_id, waiter)}}
    end
  rescue
    e -> {:reply, {:error, {:exception, Exception.message(e)}}, state}
  end

  @impl true
  def handle_info({:wait_timeout, waiter_id}, state) do
    case Map.pop(state.waiters, waiter_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {%{from: from, mon_ref: mon_ref} = waiter, waiters} ->
        _ = Process.demonitor(mon_ref, [:flush])
        _ = cancel_timer(waiter[:timer_ref])
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    # Caller went away; drop any waiter entry that references this monitor.
    waiters =
      state.waiters
      |> Enum.reject(fn {_id, w} -> w.mon_ref == mon_ref end)
      |> Map.new()

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(:cleanup, state) do
    _ = cleanup_expired_messages()
    schedule_cleanup()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp normalize_twilio_sms(params) when is_map(params) do
    sid =
      params["MessageSid"] || params["SmsMessageSid"] || params[:MessageSid] || params[:SmsMessageSid]

    body = params["Body"] || params[:Body] || ""
    to = params["To"] || params[:To]
    from = params["From"] || params[:From]
    account_sid = params["AccountSid"] || params[:AccountSid]

    cond do
      not is_binary(sid) or String.trim(sid) == "" ->
        {:error, :missing_message_sid}

      true ->
        body = body |> to_string() |> String.trim()
        codes = extract_default_codes(body)

        msg = %{
          "message_sid" => String.trim(sid),
          "account_sid" => account_sid && to_string(account_sid),
          "to" => to && to_string(to),
          "from" => from && to_string(from),
          "body" => body,
          "codes" => codes,
          "received_at_ms" => now_ms(),
          "claimed_by" => nil,
          "claimed_at_ms" => nil,
          "raw" => stringify_keys(params)
        }

        {:ok, msg}
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key =
        cond do
          is_binary(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> inspect(k)
        end

      {key, v}
    end)
  end

  defp extract_default_codes(body) when is_binary(body) do
    Regex.scan(~r/\b\d{4,8}\b/, body)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp extract_default_codes(_), do: []

  defp read_all_messages do
    LemonCore.Store.list(@table)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.filter(&is_map/1)
  end

  defp filter_messages(messages, opts) do
    to = Keyword.get(opts, :to)
    from_contains = Keyword.get(opts, :from_contains)
    body_contains = Keyword.get(opts, :body_contains)
    since_ms = Keyword.get(opts, :since_ms)
    include_claimed = Keyword.get(opts, :include_claimed, false)
    limit = Keyword.get(opts, :limit, 20)

    messages
    |> Enum.sort_by(&(&1["received_at_ms"] || 0), :desc)
    |> Enum.filter(fn msg ->
      cond do
        not include_claimed and is_binary(msg["claimed_by"]) and msg["claimed_by"] != "" ->
          false

        is_integer(since_ms) and (msg["received_at_ms"] || 0) < since_ms ->
          false

        is_binary(to) and to != "" and msg["to"] != to ->
          false

        is_binary(from_contains) and from_contains != "" and
            not contains_ci?(msg["from"] || "", from_contains) ->
          false

        is_binary(body_contains) and body_contains != "" and
            not String.contains?(msg["body"] || "", body_contains) ->
          false

        true ->
          true
      end
    end)
    |> Enum.take(limit)
  end

  defp normalize_wait_opts(opts) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 60_000)
    since_ms = Keyword.get(opts, :since_ms)
    to = Keyword.get(opts, :to) || Config.inbox_number()
    from_contains = Keyword.get(opts, :from_contains)
    body_contains = Keyword.get(opts, :body_contains)
    regex = Keyword.get(opts, :regex)
    claim = Keyword.get(opts, :claim, true)

    [
      timeout_ms: timeout_ms,
      since_ms: since_ms,
      to: to,
      from_contains: from_contains,
      body_contains: body_contains,
      regex: regex,
      claim: claim
    ]
  end

  defp normalize_wait_opts(_), do: normalize_wait_opts([])

  defp find_matching_code_message(opts) do
    since_ms = opts[:since_ms]
    messages = read_all_messages()

    messages
    |> Enum.sort_by(&(&1["received_at_ms"] || 0), :desc)
    |> Enum.find_value(:miss, fn msg ->
      if is_integer(since_ms) and (msg["received_at_ms"] || 0) < since_ms do
        false
      else
        match_code(msg, opts)
      end
    end)
    |> case do
      :miss -> :miss
      %{code: _c, message: _m} = hit -> {:ok, hit}
      _ -> :miss
    end
  end

  defp match_code(msg, opts) when is_map(msg) do
    to = opts[:to]
    from_contains = opts[:from_contains]
    body_contains = opts[:body_contains]
    regex = opts[:regex]

    cond do
      is_binary(to) and to != "" and msg["to"] != to ->
        false

      is_binary(from_contains) and from_contains != "" and
          not contains_ci?(msg["from"] || "", from_contains) ->
        false

      is_binary(body_contains) and body_contains != "" and
          not String.contains?(msg["body"] || "", body_contains) ->
        false

      is_binary(msg["claimed_by"]) and msg["claimed_by"] != "" ->
        false

      true ->
        body = msg["body"] || ""
        code = extract_code(body, regex)

        if is_binary(code) and code != "" do
          %{code: code, message: msg}
        else
          false
        end
    end
  end

  defp extract_code(body, nil) do
    List.first(extract_default_codes(body))
  end

  defp extract_code(body, regex) when is_binary(regex) do
    case Regex.compile(regex) do
      {:ok, re} ->
        case Regex.run(re, body, capture: :first) do
          [match | _] -> match
          _ -> nil
        end

      _ ->
        List.first(extract_default_codes(body))
    end
  end

  defp extract_code(body, _regex), do: List.first(extract_default_codes(body))

  defp maybe_claim_and_persist(%{} = msg, session_key, opts, state) do
    if opts[:claim] == true do
      updated =
        msg
        |> Map.put("claimed_by", session_key)
        |> Map.put("claimed_at_ms", now_ms())

      sid = updated["message_sid"]

      if is_binary(sid) and sid != "" do
        :ok = LemonCore.Store.put(@table, sid, updated)
      end

      {updated, state}
    else
      {msg, state}
    end
  end

  defp fulfill_waiters(msg, state) do
    # Fulfill at most one waiter per message.
    waiter =
      state.waiters
      |> Map.values()
      |> Enum.find(fn w -> match_code(msg, w.opts) end)

    if is_nil(waiter) do
      state
    else
      %{code: code} = match_code(msg, waiter.opts)

      _ = cancel_timer(waiter.timer_ref)
      _ = Process.demonitor(waiter.mon_ref, [:flush])

      msg =
        if waiter.opts[:claim] == true do
          updated =
            msg
            |> Map.put("claimed_by", waiter.session_key)
            |> Map.put("claimed_at_ms", now_ms())

          :ok = LemonCore.Store.put(@table, msg["message_sid"], updated)
          updated
        else
          msg
        end

      GenServer.reply(waiter.from, {:ok, %{code: code, message: msg}})
      %{state | waiters: Map.delete(state.waiters, waiter.id)}
    end
  rescue
    _ -> state
  end

  defp cleanup_expired_messages do
    ttl_ms = Config.inbox_ttl_ms()
    cutoff = now_ms() - ttl_ms

    read_all_messages()
    |> Enum.reduce(0, fn msg, acc ->
      sid = msg["message_sid"]
      ts = msg["received_at_ms"] || 0

      if is_binary(sid) and ts < cutoff do
        _ = LemonCore.Store.delete(@table, sid)
        acc + 1
      else
        acc
      end
    end)
  rescue
    _ -> 0
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  rescue
    _ -> :ok
  end

  defp contains_ci?(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    String.contains?(String.downcase(haystack), String.downcase(needle))
  end

  defp contains_ci?(_, _), do: false

  defp normalize_session_key(session_key) when is_binary(session_key) and session_key != "",
    do: session_key

  defp normalize_session_key(_), do: "unknown"

  defp now_ms do
    System.system_time(:millisecond)
  end
end

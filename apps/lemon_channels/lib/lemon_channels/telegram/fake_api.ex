defmodule LemonChannels.Telegram.FakeAPI do
  @moduledoc """
  In-process fake of `LemonChannels.Telegram.API` for hermetic transport testing.

  Mirrors every function (name, arity, and return shape) that the Telegram
  transport actually calls through its resolved `api_mod` — `get_updates/3`,
  `get_me/1`, `delete_webhook/2`, `get_chat_member/3`, `create_forum_topic/3`,
  `send_message/5`, `edit_message_text/5`, `answer_callback_query/3`,
  `delete_message/3`, `set_message_reaction/5`, `get_file/2`,
  `download_file/2`, `send_document/4`, `send_photo/4`, and
  `send_media_group/4` — plus `delete_forum_topic/3` and `send_chat_action/3`
  for Bot API parity. No network traffic ever happens: inbound updates come
  from a local queue with real `getUpdates` offset semantics, and every
  outbound call is captured for introspection.

  State lives in a lazily started, unlinked GenServer registered under this
  module's name, so no supervision-tree change is required — the first call
  from any process (ExUnit test, transport init, or a live release) boots it.

  ## Selecting the fake

  In TOML config (a running release picks this up like any other
  `[gateway.telegram]` key — unknown keys pass through atomized):

      [gateway.telegram]
      bot_token = "fake-token"
      api_mod = "LemonChannels.Telegram.FakeAPI"

  In ExUnit, pass it straight to the transport (see
  `transport_fake_api_test.exs`):

      LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{bot_token: "fake-token", api_mod: LemonChannels.Telegram.FakeAPI}
      )

  ## Driving API

  Fabricate inbound traffic:

    * `push_update/1` — enqueue a raw Telegram update map (an `"update_id"`
      is assigned when missing).
    * `simulate_message/3` — build + enqueue a realistic message update.
      Options: `:chat_type` (`"private"` | `"supergroup"` | ...),
      `:message_thread_id` (forum topic), `:reply_to_message_id`, `:from`,
      `:user_id`, `:username`, `:first_name`, `:date`, `:entities`,
      `:message_id`, `:update_id`, `:extra` (map merged into the message).
    * `simulate_callback_query/3` — build + enqueue an inline-button press.
      Options: `:message_id`, `:message` (full map), `:from`, `:user_id`,
      `:username`, `:id`, `:chat_type`, `:message_thread_id`.

  Inspect outbound traffic (every captured call is a
  `%{fun: atom, args: list, at_ms: integer}` map; the bot token argument is
  never recorded):

    * `sent/0` / `sent/1` — all captured calls, oldest first, optionally
      filtered by function name or a predicate.
    * `await_send/2` — block until a captured call matches (function name
      atom, 1-arity predicate, or `nil` for any), with a timeout. Matches
      already-captured calls too.
    * `clear/0` — drop captured calls; `reset/0` — reset queue, captures,
      stubs, and files. Counters (update/message ids) are preserved so a
      still-running transport's advanced `getUpdates` offset never outruns
      newly simulated updates; stop the transport first if you need pristine
      ids. Capture history is bounded (oldest entries dropped past 10,000
      calls) so a long-lived polling instance cannot grow without limit.

  Extra control:

    * `stub/2` — canned return value (or 1-arity fun of the args list) for a
      named function, e.g. `stub(:get_chat_member, {:ok, %{"ok" => true,
      "result" => %{"status" => "administrator"}}})`.
    * `put_file/2` — register file bytes so `get_file/2` + `download_file/2`
      round-trip real content for file-transfer paths.

  `get_updates/3` returns queued updates with `update_id >= offset`
  immediately when any exist; otherwise it long-polls, bounded by
  `min(timeout_ms, 1000ms)`, so pollers stay responsive and never hang.

  ## Driving a live instance

  With `api_mod = "LemonChannels.Telegram.FakeAPI"` configured, a running
  node can be driven from a shell without touching Telegram:

      elixir --sname probe --cookie <cookie> \\
        --rpc-eval lemon_bot@myhost \\
        'LemonChannels.Telegram.FakeAPI.simulate_message(4242, "/status") |> inspect() |> IO.puts()'

      elixir --sname probe --cookie <cookie> \\
        --rpc-eval lemon_bot@myhost \\
        'LemonChannels.Telegram.FakeAPI.await_send(:send_message, 10_000) |> inspect() |> IO.puts()'
  """

  use GenServer

  @server __MODULE__
  @default_await_timeout_ms 5_000
  @max_poll_wait_ms 1_000
  # Bounded capture history: trim to @history_limit once the overshoot slack
  # is exceeded, so steady-state appends stay O(1).
  @history_limit 10_000
  @history_slack 256
  @bot_id 990_001
  @bot_username "lemon_fake_bot"
  @default_user_id 111_001

  # ---------------------------------------------------------------------------
  # Telegram-facing API (mirrors LemonChannels.Telegram.API)
  # ---------------------------------------------------------------------------

  @doc "getUpdates: returns queued updates with `update_id >= offset` (bounded long-poll)."
  def get_updates(_token, offset, timeout_ms) do
    record(:get_updates, [offset, timeout_ms])

    stubbed(:get_updates, [offset, timeout_ms], fn ->
      wait_ms = poll_wait_ms(timeout_ms)
      call({:get_updates, offset, wait_ms}, wait_ms + @default_await_timeout_ms)
    end)
  end

  @doc "getMe: static fake bot identity."
  def get_me(_token) do
    record(:get_me, [])

    stubbed(:get_me, [], fn ->
      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "id" => @bot_id,
           "is_bot" => true,
           "first_name" => "Lemon Fake Bot",
           "username" => @bot_username
         }
       }}
    end)
  end

  @doc "deleteWebhook: always succeeds."
  def delete_webhook(_token, opts \\ %{}) do
    record(:delete_webhook, [normalize_opts(opts)])
    stubbed(:delete_webhook, [opts], fn -> {:ok, %{"ok" => true, "result" => true}} end)
  end

  @doc "getChatMember: defaults to a plain `member` (stub for admin flows)."
  def get_chat_member(_token, chat_id, user_id) do
    record(:get_chat_member, [chat_id, user_id])

    stubbed(:get_chat_member, [chat_id, user_id], fn ->
      {:ok,
       %{
         "ok" => true,
         "result" => %{"status" => "member", "user" => %{"id" => user_id, "is_bot" => false}}
       }}
    end)
  end

  @doc "createForumTopic: allocates a fresh `message_thread_id`."
  def create_forum_topic(_token, chat_id, name) when is_binary(name) do
    record(:create_forum_topic, [chat_id, name])

    stubbed(:create_forum_topic, [chat_id, name], fn ->
      thread_id = call({:next_id, :message_id})

      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "message_thread_id" => thread_id,
           "name" => String.trim(name),
           "icon_color" => 7_322_096
         }
       }}
    end)
  end

  def create_forum_topic(_token, _chat_id, _name), do: {:error, :invalid_topic_name}

  @doc "deleteForumTopic: always succeeds (Bot API parity; no transport call site today)."
  def delete_forum_topic(_token, chat_id, message_thread_id) do
    record(:delete_forum_topic, [chat_id, message_thread_id])

    stubbed(:delete_forum_topic, [chat_id, message_thread_id], fn ->
      {:ok, %{"ok" => true, "result" => true}}
    end)
  end

  @doc "sendMessage: captures the call and returns a message map with a fresh id."
  def send_message(token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil)

  def send_message(_token, chat_id, text, reply_to_or_opts, parse_mode) do
    opts = normalize_opts(reply_to_or_opts)
    record(:send_message, [chat_id, text, opts, parse_mode])

    stubbed(:send_message, [chat_id, text, opts, parse_mode], fn ->
      {:ok, %{"ok" => true, "result" => fake_sent_message(chat_id, %{"text" => text})}}
    end)
  end

  @doc "editMessageText: captures the call and echoes the edited message."
  def edit_message_text(token, chat_id, message_id, text, parse_mode_or_opts \\ nil)

  def edit_message_text(_token, chat_id, message_id, text, parse_mode_or_opts) do
    opts = normalize_opts(parse_mode_or_opts)
    record(:edit_message_text, [chat_id, message_id, text, opts])

    stubbed(:edit_message_text, [chat_id, message_id, text, opts], fn ->
      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "message_id" => message_id,
           "chat" => %{"id" => chat_id},
           "text" => text,
           "edit_date" => now_unix()
         }
       }}
    end)
  end

  @doc "answerCallbackQuery: always succeeds."
  def answer_callback_query(_token, callback_query_id, opts \\ %{}) do
    opts = normalize_opts(opts)
    record(:answer_callback_query, [callback_query_id, opts])

    stubbed(:answer_callback_query, [callback_query_id, opts], fn ->
      {:ok, %{"ok" => true, "result" => true}}
    end)
  end

  @doc "deleteMessage: always succeeds."
  def delete_message(_token, chat_id, message_id) do
    record(:delete_message, [chat_id, message_id])

    stubbed(:delete_message, [chat_id, message_id], fn ->
      {:ok, %{"ok" => true, "result" => true}}
    end)
  end

  @doc "setMessageReaction: always succeeds."
  def set_message_reaction(_token, chat_id, message_id, emoji, opts \\ %{}) do
    opts = normalize_opts(opts)
    record(:set_message_reaction, [chat_id, message_id, emoji, opts])

    stubbed(:set_message_reaction, [chat_id, message_id, emoji, opts], fn ->
      {:ok, %{"ok" => true, "result" => true}}
    end)
  end

  @doc "sendChatAction: always succeeds (Bot API parity; no transport call site today)."
  def send_chat_action(_token, chat_id, action) do
    record(:send_chat_action, [chat_id, action])

    stubbed(:send_chat_action, [chat_id, action], fn ->
      {:ok, %{"ok" => true, "result" => true}}
    end)
  end

  @doc "getFile: resolves a `file_path` for a `file_id` (see `put_file/2`)."
  def get_file(_token, file_id) when is_binary(file_id) do
    record(:get_file, [file_id])

    stubbed(:get_file, [file_id], fn ->
      file = call({:lookup_file, file_id})

      {:ok,
       %{
         "ok" => true,
         "result" => %{
           "file_id" => file_id,
           "file_unique_id" => "u-" <> file_id,
           "file_size" => byte_size(file.content),
           "file_path" => file.file_path
         }
       }}
    end)
  end

  @doc "File download: returns the bytes registered via `put_file/2` (or stub content)."
  def download_file(_token, file_path) when is_binary(file_path) do
    record(:download_file, [file_path])

    stubbed(:download_file, [file_path], fn ->
      {:ok, call({:download_file, file_path})}
    end)
  end

  @doc "sendDocument: captures the call and returns a message with a `document` payload."
  def send_document(_token, chat_id, file, opts \\ %{}) do
    opts = normalize_opts(opts)
    record(:send_document, [chat_id, file_summary(file), opts])

    stubbed(:send_document, [chat_id, file, opts], fn ->
      document = %{
        "file_id" => "fake-doc-" <> Integer.to_string(call({:next_id, :file_seq})),
        "file_name" => file_name(file)
      }

      {:ok, %{"ok" => true, "result" => fake_sent_message(chat_id, %{"document" => document})}}
    end)
  end

  @doc "sendPhoto: captures the call and returns a message with a `photo` payload."
  def send_photo(_token, chat_id, file, opts \\ %{}) do
    opts = normalize_opts(opts)
    record(:send_photo, [chat_id, file_summary(file), opts])

    stubbed(:send_photo, [chat_id, file, opts], fn ->
      photo = [
        %{
          "file_id" => "fake-photo-" <> Integer.to_string(call({:next_id, :file_seq})),
          "width" => 1,
          "height" => 1
        }
      ]

      {:ok, %{"ok" => true, "result" => fake_sent_message(chat_id, %{"photo" => photo})}}
    end)
  end

  @doc "sendMediaGroup: captures the call and returns one message per media item."
  def send_media_group(token, chat_id, files, opts \\ %{})

  def send_media_group(_token, chat_id, files, opts) when is_list(files) do
    opts = normalize_opts(opts)
    record(:send_media_group, [chat_id, Enum.map(files, &file_summary/1), opts])

    stubbed(:send_media_group, [chat_id, files, opts], fn ->
      messages = Enum.map(files, fn _ -> fake_sent_message(chat_id, %{}) end)
      {:ok, %{"ok" => true, "result" => messages}}
    end)
  end

  def send_media_group(_token, _chat_id, _files, _opts), do: {:error, :invalid_media_group}

  # ---------------------------------------------------------------------------
  # Driving API — inbound fabrication
  # ---------------------------------------------------------------------------

  @doc "Enqueue a raw Telegram update map. Assigns `\"update_id\"` when missing."
  @spec push_update(map()) :: map()
  def push_update(update) when is_map(update) do
    call({:push_update, update})
  end

  @doc """
  Build and enqueue a realistic `message` update. Returns the update map.

  See the moduledoc for supported options. `chat_id < 0` defaults the chat
  type to `"supergroup"`, otherwise `"private"`.
  """
  @spec simulate_message(integer(), String.t(), keyword()) :: map()
  def simulate_message(chat_id, text, opts \\ []) when is_integer(chat_id) and is_binary(text) do
    message_id = Keyword.get(opts, :message_id) || call({:next_id, :message_id})

    message =
      %{
        "message_id" => message_id,
        "date" => Keyword.get(opts, :date, now_unix()),
        "chat" => chat_map(chat_id, opts),
        "from" => from_map(opts),
        "text" => text
      }
      |> maybe_put("message_thread_id", Keyword.get(opts, :message_thread_id))
      |> maybe_put("entities", Keyword.get(opts, :entities, default_entities(text)))
      |> maybe_put_reply(Keyword.get(opts, :reply_to_message_id), chat_id, opts)
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    update =
      %{"message" => message}
      |> maybe_put("update_id", Keyword.get(opts, :update_id))

    push_update(update)
  end

  @doc """
  Build and enqueue a `callback_query` update (inline button press).

  Returns the update map. See the moduledoc for supported options.
  """
  @spec simulate_callback_query(integer(), String.t(), keyword()) :: map()
  def simulate_callback_query(chat_id, data, opts \\ [])
      when is_integer(chat_id) and is_binary(data) do
    message =
      Keyword.get(opts, :message) ||
        %{
          "message_id" => Keyword.get(opts, :message_id) || call({:next_id, :message_id}),
          "date" => now_unix(),
          "chat" => chat_map(chat_id, opts),
          "from" => %{"id" => @bot_id, "is_bot" => true, "username" => @bot_username}
        }
        |> maybe_put("message_thread_id", Keyword.get(opts, :message_thread_id))

    callback =
      %{
        "id" => Keyword.get(opts, :id, "fake-cb-" <> Integer.to_string(unique_int())),
        "from" => from_map(opts),
        "chat_instance" => "fake-chat-instance",
        "data" => data,
        "message" => message
      }

    push_update(%{"callback_query" => callback})
  end

  # ---------------------------------------------------------------------------
  # Driving API — outbound introspection and control
  # ---------------------------------------------------------------------------

  @doc "All captured API calls, oldest first."
  @spec sent() :: [map()]
  def sent, do: call(:sent)

  @doc "Captured API calls matching a function name or 1-arity predicate."
  @spec sent(atom() | (map() -> boolean())) :: [map()]
  def sent(filter), do: Enum.filter(sent(), matcher(filter))

  @doc """
  Block until a captured call matches `filter` (already-captured calls match
  too). Returns `{:ok, call}` or `{:error, :timeout}`.
  """
  @spec await_send(atom() | (map() -> boolean()) | nil, non_neg_integer()) ::
          {:ok, map()} | {:error, :timeout}
  def await_send(filter \\ nil, timeout_ms \\ @default_await_timeout_ms) do
    call({:await_send, matcher(filter), timeout_ms}, timeout_ms + @default_await_timeout_ms)
  end

  @doc "Drop all captured calls (queue, counters, stubs, and files survive)."
  @spec clear() :: :ok
  def clear, do: call(:clear)

  @doc "Full reset: queue, captured calls, counters, stubs, and files."
  @spec reset() :: :ok
  def reset, do: call(:reset)

  @doc "Canned return for a named function: a value, or a 1-arity fun of the args list."
  @spec stub(atom(), term() | (list() -> term())) :: :ok
  def stub(fun_name, value) when is_atom(fun_name), do: call({:stub, fun_name, value})

  @doc "Register file bytes so `get_file/2` + `download_file/2` return them."
  @spec put_file(String.t(), binary()) :: :ok
  def put_file(file_id, content) when is_binary(file_id) and is_binary(content) do
    call({:put_file, file_id, content})
  end

  @doc "Ensure the backing server is running. Returns its pid."
  @spec ensure_started() :: pid()
  def ensure_started do
    case Process.whereis(@server) do
      pid when is_pid(pid) ->
        pid

      nil ->
        # Deliberately unlinked: the fake must survive its first caller
        # (often a transport init) and never tie crash semantics to it.
        case GenServer.start(__MODULE__, :ok, name: @server) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(:ok) do
    {:ok, initial_state()}
  end

  @impl true
  def handle_call({:get_updates, offset, wait_ms}, from, state) do
    offset = if is_integer(offset), do: offset, else: 0
    {ready, state} = take_ready_updates(state, offset)

    cond do
      ready != [] ->
        {:reply, updates_reply(ready), state}

      wait_ms <= 0 ->
        {:reply, updates_reply([]), state}

      true ->
        ref = make_ref()
        timer = Process.send_after(self(), {:poll_timeout, ref}, wait_ms)
        waiter = %{ref: ref, from: from, offset: offset, timer: timer}
        {:noreply, %{state | poll_waiters: state.poll_waiters ++ [waiter]}}
    end
  end

  def handle_call({:push_update, update}, _from, state) do
    {update, state} = assign_update_id(update, state)
    state = %{state | updates: state.updates ++ [update]}
    state = flush_poll_waiters(state)
    {:reply, update, state}
  end

  def handle_call({:record, fun_name, args}, _from, state) do
    entry = %{fun: fun_name, args: args, at_ms: System.system_time(:millisecond)}
    state = append_history(state, entry)
    state = flush_send_waiters(state, entry)
    {:reply, :ok, state}
  end

  def handle_call(:sent, _from, state), do: {:reply, Enum.reverse(state.history), state}

  def handle_call({:await_send, match_fun, timeout_ms}, from, state) do
    case Enum.find(state.history, match_fun) do
      %{} = entry ->
        {:reply, {:ok, entry}, state}

      nil ->
        ref = make_ref()
        timer = Process.send_after(self(), {:await_timeout, ref}, timeout_ms)
        waiter = %{ref: ref, from: from, match: match_fun, timer: timer}
        {:noreply, %{state | send_waiters: state.send_waiters ++ [waiter]}}
    end
  end

  def handle_call(:clear, _from, state),
    do: {:reply, :ok, %{state | history: [], history_count: 0}}

  def handle_call(:reset, _from, state) do
    fresh = initial_state()

    # Counters survive a reset: a still-running poller keeps its advanced
    # offset, and freshly simulated updates must keep sorting after it.
    {:reply, :ok,
     %{
       fresh
       | poll_waiters: state.poll_waiters,
         send_waiters: state.send_waiters,
         counters: state.counters
     }}
  end

  def handle_call({:stub, fun_name, value}, _from, state) do
    {:reply, :ok, %{state | stubs: Map.put(state.stubs, fun_name, value)}}
  end

  def handle_call({:fetch_stub, fun_name}, _from, state) do
    {:reply, Map.fetch(state.stubs, fun_name), state}
  end

  def handle_call({:put_file, file_id, content}, _from, state) do
    file = %{content: content, file_path: fake_file_path(file_id)}
    {:reply, :ok, %{state | files: Map.put(state.files, file_id, file)}}
  end

  def handle_call({:lookup_file, file_id}, _from, state) do
    file =
      Map.get(state.files, file_id) ||
        %{content: "FAKE-FILE:" <> file_id, file_path: fake_file_path(file_id)}

    {:reply, file, state}
  end

  def handle_call({:download_file, file_path}, _from, state) do
    content =
      case Enum.find(state.files, fn {_id, file} -> file.file_path == file_path end) do
        {_id, file} -> file.content
        nil -> "FAKE-FILE:" <> file_path
      end

    {:reply, content, state}
  end

  def handle_call({:next_id, counter}, _from, state) do
    next = Map.get(state.counters, counter, 1)
    {:reply, next, %{state | counters: Map.put(state.counters, counter, next + 1)}}
  end

  @impl true
  def handle_info({:poll_timeout, ref}, state) do
    {expired, remaining} = Enum.split_with(state.poll_waiters, &(&1.ref == ref))
    Enum.each(expired, &GenServer.reply(&1.from, updates_reply([])))
    {:noreply, %{state | poll_waiters: remaining}}
  end

  def handle_info({:await_timeout, ref}, state) do
    {expired, remaining} = Enum.split_with(state.send_waiters, &(&1.ref == ref))
    Enum.each(expired, &GenServer.reply(&1.from, {:error, :timeout}))
    {:noreply, %{state | send_waiters: remaining}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Server helpers
  # ---------------------------------------------------------------------------

  defp initial_state do
    %{
      updates: [],
      # Newest-first so appends are O(1); sent/0 reverses to chronological.
      history: [],
      history_count: 0,
      poll_waiters: [],
      send_waiters: [],
      stubs: %{},
      files: %{},
      counters: %{update_id: 1, message_id: 1_000, file_seq: 1}
    }
  end

  defp append_history(state, entry) do
    history = [entry | state.history]
    count = state.history_count + 1

    if count > @history_limit + @history_slack do
      %{state | history: Enum.take(history, @history_limit), history_count: @history_limit}
    else
      %{state | history: history, history_count: count}
    end
  end

  defp take_ready_updates(state, offset) do
    # Real getUpdates semantics: an offset confirms (and discards) every update
    # below it; everything at or above it is (re)delivered.
    kept = Enum.filter(state.updates, &(update_id_of(&1) >= offset))
    {kept, %{state | updates: kept}}
  end

  defp updates_reply(updates), do: {:ok, %{"ok" => true, "result" => updates}}

  defp flush_poll_waiters(state) do
    Enum.reduce(state.poll_waiters, %{state | poll_waiters: []}, fn waiter, acc ->
      ready = Enum.filter(acc.updates, &(update_id_of(&1) >= waiter.offset))

      if ready == [] do
        %{acc | poll_waiters: acc.poll_waiters ++ [waiter]}
      else
        _ = Process.cancel_timer(waiter.timer)
        GenServer.reply(waiter.from, updates_reply(ready))
        acc
      end
    end)
  end

  defp flush_send_waiters(state, entry) do
    Enum.reduce(state.send_waiters, %{state | send_waiters: []}, fn waiter, acc ->
      if waiter.match.(entry) do
        _ = Process.cancel_timer(waiter.timer)
        GenServer.reply(waiter.from, {:ok, entry})
        acc
      else
        %{acc | send_waiters: acc.send_waiters ++ [waiter]}
      end
    end)
  end

  defp assign_update_id(update, state) do
    case update["update_id"] do
      id when is_integer(id) ->
        next = max(Map.get(state.counters, :update_id, 1), id + 1)
        {update, %{state | counters: Map.put(state.counters, :update_id, next)}}

      _ ->
        id = Map.get(state.counters, :update_id, 1)
        state = %{state | counters: Map.put(state.counters, :update_id, id + 1)}
        {Map.put(update, "update_id", id), state}
    end
  end

  defp update_id_of(update), do: update["update_id"] || 0

  # ---------------------------------------------------------------------------
  # Client helpers
  # ---------------------------------------------------------------------------

  defp call(request, timeout \\ @default_await_timeout_ms) do
    _ = ensure_started()
    GenServer.call(@server, request, timeout)
  end

  defp record(fun_name, args), do: call({:record, fun_name, args})

  defp stubbed(fun_name, args, default_fun) do
    case call({:fetch_stub, fun_name}) do
      {:ok, fun} when is_function(fun, 1) -> fun.(args)
      {:ok, value} -> value
      :error -> default_fun.()
    end
  end

  defp poll_wait_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    min(timeout_ms, @max_poll_wait_ms)
  end

  defp poll_wait_ms(_), do: 0

  defp matcher(nil), do: fn _ -> true end
  defp matcher(fun_name) when is_atom(fun_name), do: fn entry -> entry.fun == fun_name end
  defp matcher(fun) when is_function(fun, 1), do: fun

  defp fake_sent_message(chat_id, extra) do
    Map.merge(
      %{
        "message_id" => call({:next_id, :message_id}),
        "chat" => %{"id" => chat_id},
        "from" => %{"id" => @bot_id, "is_bot" => true, "username" => @bot_username},
        "date" => now_unix()
      },
      extra
    )
  end

  defp chat_map(chat_id, opts) do
    type = Keyword.get(opts, :chat_type) || if chat_id < 0, do: "supergroup", else: "private"
    type = to_string(type)

    %{"id" => chat_id, "type" => type}
    |> maybe_put("is_forum", forum_flag(type, opts))
    |> maybe_put("title", if(type == "private", do: nil, else: "Fake Chat"))
  end

  defp forum_flag(type, opts) do
    cond do
      Keyword.has_key?(opts, :is_forum) -> Keyword.get(opts, :is_forum)
      type == "supergroup" and Keyword.get(opts, :message_thread_id) != nil -> true
      true -> nil
    end
  end

  defp from_map(opts) do
    case Keyword.get(opts, :from) do
      %{} = from ->
        from

      _ ->
        %{
          "id" => Keyword.get(opts, :user_id, @default_user_id),
          "is_bot" => false,
          "first_name" => Keyword.get(opts, :first_name, "Fake"),
          "username" => Keyword.get(opts, :username, "fake_user")
        }
    end
  end

  defp default_entities("/" <> _ = text) do
    command_length =
      text
      |> String.split(~r/\s/, parts: 2)
      |> hd()
      |> String.length()

    [%{"type" => "bot_command", "offset" => 0, "length" => command_length}]
  end

  defp default_entities(_text), do: nil

  defp maybe_put_reply(message, nil, _chat_id, _opts), do: message

  defp maybe_put_reply(message, reply_to_message_id, chat_id, opts) do
    Map.put(message, "reply_to_message", %{
      "message_id" => reply_to_message_id,
      "date" => now_unix(),
      "chat" => chat_map(chat_id, opts)
    })
  end

  defp file_summary({:path, path}), do: {:path, path}

  defp file_summary({:binary, name, content_type, bytes}),
    do: {:binary, name, content_type, byte_size(bytes)}

  defp file_summary(%{} = file), do: Map.take(file, [:path, :caption, "path", "caption"])
  defp file_summary(other), do: other

  defp file_name({:path, path}), do: Path.basename(path)
  defp file_name({:binary, name, _ct, _bytes}), do: name
  defp file_name(_), do: "file.bin"

  defp fake_file_path(file_id), do: "fake/files/" <> file_id

  # Keyword lists become maps (mirroring the real API module); integers pass
  # through untouched (`send_message/5` accepts a bare reply_to_message_id).
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp normalize_opts(other), do: other

  defp now_unix, do: System.system_time(:second)

  defp unique_int, do: System.unique_integer([:positive, :monotonic])

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defmodule LemonGateway.Telegram.StartupNotifier do
  @moduledoc """
  Sends a startup notification message to bound Telegram chats on boot.

  Runs as a temporary task that resolves the configured bindings and allowed
  chat IDs, then delivers a configurable greeting (or a default timestamp
  message) to each destination chat and topic.
  """

  require Logger

  alias LemonGateway.Telegram.{API, Formatter}

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> run() end]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def run do
    try do
      do_run()
    rescue
      e ->
        Logger.warning("Telegram startup notifier crashed: #{Exception.message(e)}")
        :ok
    catch
      kind, reason ->
        Logger.warning("Telegram startup notifier failed: #{inspect({kind, reason})}")
        :ok
    end
  end

  defp do_run do
    %{enable_telegram: enable_telegram, telegram: base_tg, bindings: bindings} =
      fetch_gateway_config()

    tg =
      base_tg
      |> merge_config(Application.get_env(:lemon_gateway, :telegram))

    with true <- enable_telegram == true,
         text when is_binary(text) <- startup_text(tg[:startup_message] || tg["startup_message"]),
         token when is_binary(token) and token != "" <- tg[:bot_token] || tg["bot_token"] do
      api_mod = tg[:api_mod] || API
      destinations = destinations(bindings, tg[:allowed_chat_ids] || tg["allowed_chat_ids"])

      if destinations == [] do
        :ok
      else
        use_markdown? = default_true(tg[:use_markdown] || tg["use_markdown"])

        {rendered, opts0} =
          if use_markdown?, do: Formatter.prepare_for_telegram(text), else: {text, nil}

        base_opts = opts0 || %{}

        Enum.each(destinations, fn {chat_id, thread_id} ->
          opts =
            if is_integer(thread_id) do
              Map.put(base_opts, :message_thread_id, thread_id)
            else
              base_opts
            end

          case api_mod.send_message(token, chat_id, rendered, opts, nil) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "Failed to send Telegram startup message (chat_id=#{inspect(chat_id)}): #{inspect(reason)}"
              )

            other ->
              Logger.warning(
                "Unexpected response sending Telegram startup message (chat_id=#{inspect(chat_id)}): #{inspect(other)}"
              )
          end
        end)
      end
    else
      _ -> :ok
    end
  end

  defp fetch_gateway_config do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      %{
        enable_telegram: LemonGateway.Config.get(:enable_telegram),
        telegram: LemonGateway.Config.get(:telegram) || %{},
        bindings: LemonGateway.Config.get_bindings()
      }
    else
      cfg = LemonGateway.ConfigLoader.load()

      %{
        enable_telegram: Map.get(cfg, :enable_telegram),
        telegram: Map.get(cfg, :telegram, %{}) || %{},
        bindings: Map.get(cfg, :bindings, []) |> List.wrap()
      }
    end
  rescue
    _ -> %{enable_telegram: false, telegram: %{}, bindings: []}
  end

  defp startup_text(true), do: default_startup_text()

  defp startup_text(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp startup_text(_), do: nil

  defp default_startup_text do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    node_name = node() |> to_string()
    "Lemon gateway online (#{node_name}, #{ts})"
  end

  defp destinations(bindings, allowed_chat_ids) do
    binding_dests = binding_destinations(bindings)

    cond do
      binding_dests != [] ->
        binding_dests

      true ->
        allowed_chat_ids
        |> normalize_int_list()
        |> Enum.map(&{&1, nil})
        |> Enum.uniq()
    end
  end

  defp binding_destinations(bindings) when is_list(bindings) do
    telegram_bindings =
      Enum.filter(bindings, fn
        %LemonGateway.Binding{transport: :telegram} -> true
        %{transport: :telegram} -> true
        %{"transport" => "telegram"} -> true
        _ -> false
      end)

    per_chat =
      Enum.reduce(telegram_bindings, %{}, fn b, acc ->
        chat_id = normalize_int(Map.get(b, :chat_id) || Map.get(b, "chat_id"))
        topic_id = normalize_int(Map.get(b, :topic_id) || Map.get(b, "topic_id"))

        if is_integer(chat_id) do
          Map.update(acc, chat_id, %{topics: MapSet.new(), has_chat_binding: false}, fn st ->
            st
          end)
          |> then(fn acc2 ->
            if is_integer(topic_id) do
              update_in(acc2[chat_id].topics, &MapSet.put(&1, topic_id))
            else
              put_in(acc2[chat_id].has_chat_binding, true)
            end
          end)
        else
          acc
        end
      end)

    per_chat
    |> Enum.flat_map(fn {chat_id, st} ->
      topics = st.topics |> MapSet.to_list() |> Enum.sort()

      cond do
        topics != [] ->
          Enum.map(topics, &{chat_id, &1})

        st.has_chat_binding ->
          [{chat_id, nil}]

        true ->
          []
      end
    end)
    |> Enum.uniq()
  end

  defp binding_destinations(_), do: []

  defp normalize_int_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_int/1)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp normalize_int_list(_), do: []

  defp normalize_int(i) when is_integer(i), do: i

  defp normalize_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  defp default_true(nil), do: true
  defp default_true(v), do: v

  defp merge_config(config, nil), do: config
  defp merge_config(config, opts) when is_map(opts), do: Map.merge(config, opts)

  defp merge_config(config, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Map.merge(config, Enum.into(opts, %{}))
    else
      config
    end
  end

  defp merge_config(config, _opts), do: config
end

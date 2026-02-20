defmodule LemonGateway.Transports.Discord do
  @moduledoc false

  use GenServer
  use LemonGateway.Transport

  require Logger

  alias LemonGateway.{BindingResolver, Runtime, Store}
  alias LemonGateway.Discord.{Commands, Formatter}
  alias LemonGateway.Types.{ChatScope, Job}
  alias Nostrum.Api.Message

  @impl LemonGateway.Transport
  def id, do: "discord"

  @impl LemonGateway.Transport
  def start_link(opts) do
    cond do
      not enabled?() ->
        Logger.info("discord transport disabled")
        :ignore

      not token_available?() ->
        Logger.warning(
          "discord transport enabled but no DISCORD_BOT_TOKEN/discord.bot_token configured"
        )

        :ignore

      true ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  defp token_available? do
    case discord_config()[:bot_token] || System.get_env("DISCORD_BOT_TOKEN") do
      token when is_binary(token) -> String.trim(token) != ""
      _ -> false
    end
  end

  @impl true
  def init(_opts) do
    case ensure_nostrum_started() do
      :ok ->
        consumer_pid = start_consumer()
        {:ok, %{consumer_pid: consumer_pid}}

      {:error, reason} ->
        Logger.warning("discord transport disabled: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:discord_event, {:READY, _payload, _ws_state}}, state) do
    Commands.register_slash_commands()
    {:noreply, state}
  end

  def handle_info({:discord_event, {:MESSAGE_CREATE, message, _ws_state}}, state) do
    maybe_handle_message(message)
    {:noreply, state}
  end

  def handle_info({:discord_event, {:INTERACTION_CREATE, interaction, _ws_state}}, state) do
    Commands.handle_interaction(interaction, __MODULE__)
    {:noreply, state}
  end

  def handle_info({:lemon_gateway_run_completed, %Job{} = job, completed}, state) do
    reply_fun = get_in(job.meta || %{}, [:reply])

    if is_function(reply_fun, 1) do
      reply_fun.(completed)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @spec submit_slash_prompt(map(), String.t() | nil, String.t() | nil) :: :ok
  def submit_slash_prompt(interaction, prompt, engine) do
    normalized = normalize_interaction(interaction, prompt)

    if String.trim(normalized.prompt) == "" do
      Commands.reply(interaction, "Prompt cannot be empty.", ephemeral: true)
      :ok
    else
      Commands.reply(interaction, "Queued ✅", ephemeral: true)
      submit_prompt(normalized, engine)
    end
  end

  @spec handle_session_new(map()) :: :ok
  def handle_session_new(interaction) do
    normalized = normalize_interaction(interaction, "")
    Store.delete_chat_state(normalized.session_key)
    Commands.reply(interaction, "Started a fresh session for this channel/user.", ephemeral: true)
  end

  @spec handle_session_info(map()) :: :ok
  def handle_session_info(interaction) do
    normalized = normalize_interaction(interaction, "")
    Commands.reply(interaction, "Session: `#{normalized.session_key}`", ephemeral: true)
  end

  defp maybe_handle_message(message) do
    if user_message?(message) do
      {engine_hint, prompt} = extract_engine_directive(message_content(message))
      normalized = normalize_message(message, prompt)

      submit_prompt(normalized, engine_hint)
    end
  rescue
    error -> Logger.warning("discord message handling error: #{inspect(error)}")
  end

  defp submit_prompt(normalized, engine_hint) do
    scope = normalized.scope
    engine_id = BindingResolver.resolve_engine(scope, engine_hint, nil)

    job = %Job{
      session_key: normalized.session_key,
      prompt: normalized.prompt,
      engine_id: engine_id,
      cwd: BindingResolver.resolve_cwd(scope),
      queue_mode: BindingResolver.resolve_queue_mode(scope) || :collect,
      meta: %{
        notify_pid: self(),
        origin: :discord,
        discord: normalized,
        reply: build_reply_fn(normalized)
      }
    }

    Runtime.submit(job)
  end

  defp build_reply_fn(normalized) do
    fn completed ->
      base =
        cond do
          Map.get(completed, :ok) == true -> Map.get(completed, :answer) || "✅ Done"
          true -> Formatter.format_error(Map.get(completed, :error) || "Request failed")
        end

      text_chunks = Formatter.chunk_text(base)
      Enum.each(text_chunks, &send_text(normalized.channel_id, &1))

      completed
      |> Map.get(:meta, %{})
      |> maybe_send_file_urls(normalized.channel_id)
    end
  end

  defp maybe_send_file_urls(%{files: files}, channel_id) when is_list(files) do
    files
    |> Enum.map(&extract_file_url/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :ok
      urls -> send_text(channel_id, "📎 Files:\n" <> Enum.join(urls, "\n"))
    end
  end

  defp maybe_send_file_urls(_, _), do: :ok

  defp extract_file_url(%{url: url}) when is_binary(url), do: url
  defp extract_file_url(%{"url" => url}) when is_binary(url), do: url
  defp extract_file_url(url) when is_binary(url), do: url
  defp extract_file_url(_), do: nil

  defp send_text(channel_id, content) when is_binary(content) do
    case Message.create(channel_id, %{content: content}) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("discord send failed: #{inspect(reason)}")
      _ -> :ok
    end
  rescue
    error ->
      Logger.warning("discord send crashed: #{inspect(error)}")
      :ok
  end

  defp normalize_message(message, prompt_override) do
    channel_id = fetch_id(message, :channel_id)
    author_id = message |> Map.get(:author, %{}) |> fetch_id(:id)
    guild_id = fetch_id(message, :guild_id)
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: nil}
    binding = BindingResolver.resolve_binding(scope)
    project = if binding && is_binary(binding.project), do: binding.project, else: "default"

    %{
      scope: scope,
      guild_id: guild_id,
      channel_id: channel_id,
      user_id: author_id,
      prompt: enrich_prompt(prompt_override, message_attachments(message)),
      attachments: message_attachments(message),
      session_key: build_session_key(guild_id, channel_id, author_id, project),
      source: :message
    }
  end

  defp normalize_interaction(interaction, prompt) do
    channel_id = fetch_id(interaction, :channel_id)
    guild_id = fetch_id(interaction, :guild_id)

    user_id =
      interaction
      |> Map.get(:member, %{})
      |> Map.get(:user, %{})
      |> fetch_id(:id)
      |> case do
        nil -> interaction |> Map.get(:user, %{}) |> fetch_id(:id)
        id -> id
      end

    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: nil}
    binding = BindingResolver.resolve_binding(scope)
    project = if binding && is_binary(binding.project), do: binding.project, else: "default"

    %{
      scope: scope,
      guild_id: guild_id,
      channel_id: channel_id,
      user_id: user_id,
      prompt: to_string(prompt || ""),
      attachments: [],
      session_key: build_session_key(guild_id, channel_id, user_id, project),
      source: :slash
    }
  end

  defp enrich_prompt(prompt, []), do: to_string(prompt || "")

  defp enrich_prompt(prompt, attachments) do
    list =
      attachments
      |> Enum.map(&extract_file_url/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&"- #{&1}")

    [to_string(prompt || ""), "", "Attachments:", Enum.join(list, "\n")]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp message_attachments(message) do
    Map.get(message, :attachments) || Map.get(message, "attachments") || []
  end

  defp message_content(message) do
    Map.get(message, :content) || Map.get(message, "content") || ""
  end

  defp user_message?(message) do
    author = Map.get(message, :author) || Map.get(message, "author") || %{}
    bot? = author[:bot] || author["bot"] || false

    not bot?
  end

  defp extract_engine_directive(text) do
    LemonGateway.Telegram.Transport.strip_engine_directive(text)
  end

  defp build_session_key(nil, channel_id, user_id, project) do
    "discord:dm:#{channel_id}:#{user_id}:#{project}"
  end

  defp build_session_key(guild_id, channel_id, user_id, project) do
    "discord:guild:#{guild_id}:#{channel_id}:#{user_id}:#{project}"
  end

  defp fetch_id(map, key) do
    value = Map.get(map, key) || Map.get(map, to_string(key))

    cond do
      is_integer(value) ->
        value

      is_binary(value) ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> nil
        end

      true ->
        nil
    end
  end

  defp configure_nostrum_token do
    token = discord_config()[:bot_token] || System.get_env("DISCORD_BOT_TOKEN")

    if is_binary(token) and token != "" do
      Application.put_env(:nostrum, :token, token)
    end

    token
  end

  defp ensure_nostrum_started do
    case configure_nostrum_token() do
      token when is_binary(token) and token != "" ->
        case Application.ensure_all_started(:nostrum) do
          {:ok, _apps} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_discord_bot_token}
    end
  end

  defp enabled? do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:enable_discord) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      cond do
        is_list(cfg) -> Keyword.get(cfg, :enable_discord, false)
        is_map(cfg) -> Map.get(cfg, :enable_discord, false)
        true -> false
      end
    end
  end

  defp discord_config do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(:discord) || %{}
      else
        Application.get_env(:lemon_gateway, :discord, %{})
      end

    cond do
      is_list(cfg) -> Enum.into(cfg, %{})
      is_map(cfg) -> cfg
      true -> %{}
    end
  end

  defp start_consumer do
    case safe_start_consumer() do
      {:ok, pid} ->
        pid

      :ok ->
        nil

      {:error, reason} ->
        Logger.warning("discord consumer failed to start: #{inspect(reason)}")
        nil
    end
  end

  defp safe_start_consumer do
    __MODULE__.Consumer.start_link([])
  rescue
    error -> {:error, error}
  end

  defmodule Consumer do
    @moduledoc false
    use Nostrum.Consumer

    @transport LemonGateway.Transports.Discord

    def handle_event(event) do
      if pid = Process.whereis(@transport) do
        send(pid, {:discord_event, event})
      end
    end
  end
end

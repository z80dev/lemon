defmodule LemonChannels.ScriptSend do
  @moduledoc """
  Script-friendly outbound notifications for Telegram and Discord.
  """

  alias LemonChannels.Adapters
  alias LemonChannels.Discord.KnownTargetStore, as: DiscordKnownTargetStore
  alias LemonChannels.OutboundPayload
  alias LemonChannels.Telegram.KnownTargetStore, as: TelegramKnownTargetStore

  @supported_platforms ~w(discord telegram)
  @default_account_id "script"
  @known_target_list_limit 25
  @max_attachments 10

  @type result :: %{
          platform: String.t(),
          target: String.t(),
          thread_id: String.t() | nil,
          content_bytes: non_neg_integer(),
          attachment_filename: String.t() | nil,
          attachment_filenames: [String.t()],
          attachment_count: non_neg_integer(),
          attachment_bytes: non_neg_integer() | nil,
          subject: String.t() | nil,
          account_id: String.t(),
          reply_to: String.t() | nil,
          message_id: term(),
          extra_message_ids: [term()],
          dry_run: boolean(),
          delivery: term()
        }

  @doc """
  Send a script notification from CLI-style arguments.
  """
  @spec run([String.t()], keyword()) :: {:ok, result() | map()} | {:error, term()}
  def run(args, opts \\ []) do
    env = Keyword.get(opts, :env, System.get_env())

    case parse_args(args, env) do
      {:ok, %{help: true}} ->
        {:ok, %{help: usage()}}

      {:ok, %{list: true, targets: targets}} ->
        {:ok, %{targets: targets}}

      {:ok, parsed} ->
        with {:ok, body} <- resolve_body(parsed, opts),
             {:ok, payload} <- build_payload(parsed, body, opts),
             {:ok, delivery} <- maybe_deliver(payload, parsed, opts) do
          {:ok,
           %{
             platform: parsed.target.platform,
             target: parsed.target.id,
             thread_id: parsed.target.thread_id,
             content_bytes: content_bytes(payload),
             attachment_filename: attachment_filename(payload),
             attachment_filenames: attachment_filenames(payload),
             attachment_count: attachment_count(payload),
             attachment_bytes: attachment_bytes(payload),
             subject: parsed.subject,
             account_id: payload.account_id,
             reply_to: payload.reply_to,
             message_id: delivery_message_id(delivery),
             extra_message_ids: delivery_extra_message_ids(delivery),
             dry_run: parsed.dry_run?,
             delivery: delivery
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_args([String.t()], map()) :: {:ok, map()} | {:error, term()}
  def parse_args(args, env \\ System.get_env()) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          to: :string,
          file: :string,
          attach: :keep,
          subject: :string,
          account: :string,
          thread: :string,
          topic: :string,
          reply_to: :string,
          dry_run: :boolean,
          json: :boolean,
          quiet: :boolean,
          list: :boolean,
          help: :boolean
        ],
        aliases: [
          t: :to,
          f: :file,
          a: :attach,
          s: :subject,
          l: :list,
          h: :help
        ]
      )

    cond do
      invalid != [] ->
        {:error, {:invalid_options, invalid}}

      opts[:help] ->
        {:ok, %{help: true, json?: opts[:json] || false, quiet?: opts[:quiet] || false}}

      opts[:list] ->
        with {:ok, account_id} <- normalize_account_option(opts[:account]),
             {:ok, targets} <- filtered_targets(rest, env, account_id) do
          {:ok,
           %{
             list: true,
             json?: opts[:json] || false,
             quiet?: opts[:quiet] || false,
             account_id: account_id,
             targets: targets
           }}
        end

      is_nil(opts[:to]) ->
        {:error, :missing_target}

      true ->
        with {:ok, account_id} <- resolve_account_option(opts[:account], opts[:to], env),
             {:ok, thread_id} <- normalize_thread_option(opts[:thread], opts[:topic]),
             {:ok, reply_to} <- normalize_reply_to(opts[:reply_to]),
             {:ok, target} <- parse_target(opts[:to], env, account_id, thread_id) do
          {:ok,
           %{
             target: target,
             account_id: account_id,
             reply_to: reply_to,
             body_args: rest,
             file: opts[:file],
             attachments: Keyword.get_values(opts, :attach),
             subject: opts[:subject],
             dry_run?: opts[:dry_run] || false,
             json?: opts[:json] || false,
             quiet?: opts[:quiet] || false,
             list: false
           }}
        end
    end
  end

  @spec parse_target(String.t(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def parse_target(target, env \\ System.get_env(), account_id \\ nil, thread_override \\ nil)
      when is_binary(target) do
    case String.split(target, ":", parts: 3) do
      [platform] ->
        parse_default_target(platform, env, thread_override)

      [platform, id] ->
        normalize_target(platform, id, thread_override, account_id)

      [_platform, _id, _thread_id] when is_binary(thread_override) ->
        {:error, :conflicting_thread_target}

      [platform, id, thread_id] ->
        normalize_target(platform, id, empty_to_nil(thread_id), account_id)
    end
  end

  defp normalize_account_option(nil), do: {:ok, nil}

  defp normalize_account_option(account_id) when is_binary(account_id) do
    case String.trim(account_id) do
      "" -> {:error, :missing_account_id}
      account_id -> {:ok, account_id}
    end
  end

  defp resolve_account_option(account_id, _target, _env) when is_binary(account_id),
    do: normalize_account_option(account_id)

  defp resolve_account_option(nil, target, env) do
    platform =
      target
      |> to_string()
      |> String.split(":", parts: 2)
      |> List.first()

    {:ok, default_account_id(platform, env)}
  end

  defp payload_account_id(parsed, opts) do
    Map.get(parsed, :account_id) || Keyword.get(opts, :account_id, @default_account_id)
  end

  defp normalize_thread_option(nil, nil), do: {:ok, nil}
  defp normalize_thread_option(thread_id, nil), do: normalize_thread_value(thread_id)
  defp normalize_thread_option(nil, topic_id), do: normalize_thread_value(topic_id)
  defp normalize_thread_option(_thread_id, _topic_id), do: {:error, :conflicting_thread_options}

  defp normalize_thread_value(thread_id) when is_binary(thread_id) do
    case String.trim(thread_id) do
      "" -> {:error, :missing_thread_id}
      thread_id -> {:ok, thread_id}
    end
  end

  defp normalize_reply_to(nil), do: {:ok, nil}

  defp normalize_reply_to(reply_to) when is_binary(reply_to) do
    case String.trim(reply_to) do
      "" -> {:error, :missing_reply_to}
      reply_to -> {:ok, reply_to}
    end
  end

  @spec resolve_body(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_body(%{help: true}, _opts), do: {:ok, ""}

  def resolve_body(%{list: true}, _opts), do: {:ok, ""}

  def resolve_body(%{body_args: [_ | _] = body_args, subject: subject}, _opts) do
    {:ok, format_subject(subject, Enum.join(body_args, " "))}
  end

  def resolve_body(%{file: path, subject: subject}, opts) when is_binary(path) do
    read_body_from_file(path, subject, opts)
  end

  def resolve_body(%{attachments: [_ | _], subject: subject}, opts) do
    stdin_reader = Keyword.get(opts, :stdin_reader, &read_stdin/0)

    if Keyword.get(opts, :stdin_available?, stdin_available?()) do
      case stdin_reader.() do
        body when is_binary(body) and body != "" -> {:ok, format_subject(subject, body)}
        _ -> {:ok, format_subject(subject, "")}
      end
    else
      {:ok, format_subject(subject, "")}
    end
  end

  def resolve_body(%{subject: subject}, opts) do
    stdin_reader = Keyword.get(opts, :stdin_reader, &read_stdin/0)

    if Keyword.get(opts, :stdin_available?, stdin_available?()) do
      case stdin_reader.() do
        body when is_binary(body) and body != "" -> {:ok, format_subject(subject, body)}
        _ -> {:error, :empty_body}
      end
    else
      {:error, :missing_body}
    end
  end

  @spec build_payload(map(), String.t(), keyword()) ::
          {:ok, OutboundPayload.t()} | {:error, term()}
  def build_payload(
        %{target: target, attachments: [_ | _] = attachments, subject: subject} = parsed,
        body,
        opts
      )
      when is_binary(body) do
    with {:ok, attachments} <- normalize_attachments(attachments) do
      account_id = payload_account_id(parsed, opts)

      payload =
        OutboundPayload.new(
          channel_id: target.platform,
          account_id: account_id,
          peer: %{kind: :channel, id: target.id, thread_id: target.thread_id},
          kind: :file,
          content: attachment_content(attachments.files, body),
          idempotency_key: idempotency_key(target),
          reply_to: parsed.reply_to,
          meta: %{
            source: "lemon.send",
            subject: subject,
            attachment_filenames: attachments.filenames,
            attachment_count: attachments.count
          }
        )

      {:ok, payload}
    end
  end

  def build_payload(%{target: target, subject: subject} = parsed, body, opts)
      when is_binary(body) do
    account_id = payload_account_id(parsed, opts)

    payload =
      OutboundPayload.text(
        target.platform,
        account_id,
        %{kind: :channel, id: target.id, thread_id: target.thread_id},
        body,
        idempotency_key: idempotency_key(target),
        reply_to: parsed.reply_to,
        meta: %{source: "lemon.send", subject: subject}
      )

    {:ok, payload}
  end

  def list_targets(env \\ System.get_env(), platform_filter \\ nil, account_id \\ nil) do
    @supported_platforms
    |> Enum.filter(fn platform -> is_nil(platform_filter) or platform == platform_filter end)
    |> Enum.map(fn platform ->
      known_targets = known_targets(platform, account_id)

      %{
        platform: platform,
        target_format: "#{platform}:<chat_or_channel_id>[:thread_id]",
        account_id: account_id,
        default_target: default_target(platform, env),
        known_targets: Enum.take(known_targets, @known_target_list_limit),
        known_target_count: length(known_targets),
        known_targets_truncated: length(known_targets) > @known_target_list_limit
      }
    end)
  end

  def usage do
    """
    Usage:
      mix lemon.send --to telegram:<chat_id> "deploy finished"
      echo "RAM 92%" | mix lemon.send --to telegram:<chat_id>
      mix lemon.send --to telegram:<chat_id>:<thread_id> --subject "[CI]" --file report.txt
      mix lemon.send --to telegram:@username "deploy finished"
      mix lemon.send --to discord:<channel_id> "deploy finished"
      mix lemon.send --to discord:<channel_id> --attach report.txt "artifact ready"
      mix lemon.send --dry-run --to discord:<channel_id> --attach report.txt "artifact ready"
      mix lemon.send --account work --list [telegram|discord]

    Options:
      -t, --to TARGET       telegram:<chat_id>[:thread_id] or discord:<channel_id>[:thread_id]
          --thread ID       thread/topic id or known thread/topic name
          --topic ID        Telegram-friendly alias for --thread
          --reply-to ID     reply to an existing platform message id
      -f, --file PATH       read body from a file; use - to force stdin
      -a, --attach PATH     upload a file; repeat up to 10 times
      -s, --subject LINE    prepend a subject/header line
          --account ID      channel account id for delivery and known-target resolution
          --dry-run         validate and summarize without sending
      -l, --list            list supported targets, optionally filtered by platform
      -q, --quiet           no stdout on success
          --json            machine-readable output
      -h, --help            show this help
    """
  end

  defp parse_default_target(platform, env, thread_override) do
    with :ok <- supported_platform(platform),
         id when is_binary(id) and id != "" <- default_target_id(platform, env) do
      normalize_target(platform, id, thread_override || default_thread_id(platform, env))
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, {:missing_default_target, platform}}
    end
  end

  defp normalize_target(platform, id, thread_id),
    do: normalize_target(platform, id, thread_id, nil)

  defp normalize_target("telegram", id, thread_id, account_id) do
    cond do
      named_telegram_selector?(id) ->
        resolve_telegram_named_target(id, thread_id, account_id)

      named_thread_selector?(thread_id) ->
        resolve_telegram_topic_target(id, thread_id, account_id)

      true ->
        normalize_numeric_target("telegram", id, thread_id)
    end
  end

  defp normalize_target("discord", id, thread_id, account_id) do
    cond do
      named_discord_selector?(id) ->
        resolve_discord_named_target(id, thread_id, account_id)

      named_thread_selector?(thread_id) ->
        resolve_discord_thread_target(id, thread_id, account_id)

      true ->
        normalize_numeric_target("discord", id, thread_id)
    end
  end

  defp normalize_target(platform, id, thread_id, _account_id) do
    normalize_numeric_target(platform, id, thread_id)
  end

  defp normalize_numeric_target(platform, id, thread_id) do
    with :ok <- supported_platform(platform),
         {:ok, normalized_id} <- normalize_id(id) do
      {:ok, %{platform: platform, id: normalized_id, thread_id: thread_id}}
    end
  end

  defp supported_platform(platform) when platform in @supported_platforms, do: :ok
  defp supported_platform(platform), do: {:error, {:unsupported_platform, platform}}

  defp normalize_id(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "" -> {:error, :missing_target_id}
      String.starts_with?(id, "#") -> {:error, :named_channel_not_supported}
      true -> {:ok, id}
    end
  end

  defp filtered_targets([], env, account_id), do: {:ok, list_targets(env, nil, account_id)}

  defp filtered_targets([platform], env, account_id) do
    with :ok <- supported_platform(platform) do
      {:ok, list_targets(env, platform, account_id)}
    end
  end

  defp filtered_targets(_platforms, _env, _account_id), do: {:error, :too_many_list_filters}

  defp read_body_from_file("-", subject, opts) do
    stdin_reader = Keyword.get(opts, :stdin_reader, &read_stdin/0)

    case stdin_reader.() do
      body when is_binary(body) and body != "" -> {:ok, format_subject(subject, body)}
      _ -> {:error, :empty_body}
    end
  end

  defp read_body_from_file(path, subject, _opts) do
    case File.read(path) do
      {:ok, body} -> {:ok, format_subject(subject, body)}
      {:error, reason} -> {:error, {:file_read_failed, path, reason}}
    end
  end

  defp delivery_message_id(delivery), do: delivery |> delivery_message_ids() |> List.first()

  defp delivery_extra_message_ids(%{extra_message_ids: ids}) when is_list(ids), do: ids
  defp delivery_extra_message_ids(%{"extra_message_ids" => ids}) when is_list(ids), do: ids

  defp delivery_extra_message_ids(delivery),
    do: delivery |> delivery_message_ids() |> Enum.drop(1)

  defp delivery_message_ids(delivery) when is_list(delivery) do
    delivery
    |> Enum.flat_map(&delivery_message_ids/1)
    |> Enum.reject(&is_nil/1)
  end

  defp delivery_message_ids(%{message_id: message_id}), do: [message_id]
  defp delivery_message_ids(%{"message_id" => message_id}), do: [message_id]
  defp delivery_message_ids(%{"result" => %{"message_id" => message_id}}), do: [message_id]
  defp delivery_message_ids(%{result: %{message_id: message_id}}), do: [message_id]
  defp delivery_message_ids(_delivery), do: []

  defp content_bytes(%OutboundPayload{kind: :file, content: %{caption: caption}})
       when is_binary(caption),
       do: byte_size(caption)

  defp content_bytes(%OutboundPayload{content: content}) when is_binary(content),
    do: byte_size(content)

  defp content_bytes(_payload), do: 0

  defp attachment_filename(payload), do: payload |> attachment_filenames() |> List.first()

  defp attachment_filenames(%OutboundPayload{kind: :file, content: %{filename: filename}})
       when is_binary(filename),
       do: [filename]

  defp attachment_filenames(%OutboundPayload{kind: :file, content: %{files: files}})
       when is_list(files) do
    Enum.map(files, fn
      %{filename: filename} when is_binary(filename) -> filename
      %{"filename" => filename} when is_binary(filename) -> filename
      %{path: path} when is_binary(path) -> Path.basename(path)
      %{"path" => path} when is_binary(path) -> Path.basename(path)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp attachment_filenames(_payload), do: []

  defp attachment_count(%OutboundPayload{kind: :file, content: %{files: files}})
       when is_list(files),
       do: length(files)

  defp attachment_count(%OutboundPayload{kind: :file, content: %{path: path}})
       when is_binary(path),
       do: 1

  defp attachment_count(_payload), do: 0

  defp attachment_bytes(%OutboundPayload{kind: :file, content: %{path: path}})
       when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> nil
    end
  end

  defp attachment_bytes(%OutboundPayload{kind: :file, content: %{files: files}})
       when is_list(files) do
    Enum.reduce(files, 0, fn
      %{path: path}, acc when is_binary(path) -> acc + file_size(path)
      %{"path" => path}, acc when is_binary(path) -> acc + file_size(path)
      _file, acc -> acc
    end)
  end

  defp attachment_bytes(_payload), do: nil

  defp normalize_attachments(paths) when length(paths) > @max_attachments,
    do: {:error, {:too_many_attachments, @max_attachments}}

  defp normalize_attachments(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case normalize_attachment(path) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attachments} ->
        files = Enum.reverse(attachments)

        {:ok,
         %{
           files: files,
           filenames: Enum.map(files, & &1.filename),
           count: length(files)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_attachment(path) when is_binary(path) do
    path = String.trim(path)

    cond do
      path == "" ->
        {:error, :missing_attachment}

      not File.regular?(path) ->
        {:error, {:attachment_not_found, path}}

      true ->
        {:ok, %{path: path, filename: Path.basename(path)}}
    end
  end

  defp normalize_attachment(_path), do: {:error, :missing_attachment}

  defp attachment_content([attachment], body) do
    %{
      path: attachment.path,
      filename: attachment.filename,
      caption: empty_to_nil(body)
    }
  end

  defp attachment_content([first | rest], body) do
    caption = empty_to_nil(body)

    files =
      [
        %{path: first.path, filename: first.filename, caption: caption}
        | Enum.map(rest, &%{path: &1.path, filename: &1.filename, caption: nil})
      ]

    %{files: files, caption: caption}
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp deliver(%OutboundPayload{channel_id: "telegram"} = payload, _parsed, opts) do
    deliverer = Keyword.get(opts, :telegram_deliverer, Adapters.Telegram.Outbound)
    deliverer.deliver(payload)
  end

  defp deliver(%OutboundPayload{channel_id: "discord"} = payload, _parsed, opts) do
    deliverer = Keyword.get(opts, :discord_deliverer, Adapters.Discord.Outbound)
    deliverer.deliver(payload)
  end

  defp maybe_deliver(payload, %{dry_run?: true}, _opts),
    do: {:ok, %{dry_run: true, channel_id: payload.channel_id, kind: payload.kind}}

  defp maybe_deliver(payload, parsed, opts), do: deliver(payload, parsed, opts)

  defp default_target(platform, env) do
    case default_target_id(platform, env) do
      nil -> nil
      "" -> nil
      id -> "#{platform}:#{id}#{default_thread_suffix(platform, env)}"
    end
  end

  defp default_target_id("telegram", env) do
    env_value(env, "LEMON_TELEGRAM_DEFAULT_CHAT_ID") ||
      gateway_section_value(:telegram, [:default_chat_id])
  end

  defp default_target_id("discord", env) do
    env_value(env, "LEMON_DISCORD_DEFAULT_CHANNEL_ID") ||
      gateway_section_value(:discord, [:default_channel_id])
  end

  defp default_target_id(_, _env), do: nil

  defp default_account_id("telegram", env) do
    env_value(env, "LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID") ||
      gateway_section_value(:telegram, [:default_account_id])
  end

  defp default_account_id("discord", env) do
    env_value(env, "LEMON_DISCORD_DEFAULT_ACCOUNT_ID") ||
      gateway_section_value(:discord, [:default_account_id])
  end

  defp default_account_id(_platform, _env), do: nil

  defp default_thread_id("telegram", env),
    do:
      env_value(env, "LEMON_TELEGRAM_DEFAULT_THREAD_ID") ||
        gateway_section_value(:telegram, [:default_thread_id, :default_topic_id])

  defp default_thread_id("discord", env) do
    env_value(env, "LEMON_DISCORD_DEFAULT_THREAD_ID") ||
      gateway_section_value(:discord, [:default_thread_id])
  end

  defp default_thread_id(_, _env), do: nil

  defp default_thread_suffix(platform, env) do
    case default_thread_id(platform, env) do
      nil -> ""
      thread_id -> ":#{thread_id}"
    end
  end

  defp env_value(env, key), do: to_nonempty_string(Map.get(env, key))

  defp gateway_section_value(section, keys) do
    section
    |> LemonChannels.GatewayConfig.get(%{})
    |> find_section_value(keys)
    |> to_nonempty_string()
  rescue
    _ -> nil
  end

  defp find_section_value(section, keys) when is_map(section) do
    Enum.find_value(keys, fn key ->
      Map.get(section, key) || Map.get(section, Atom.to_string(key))
    end)
  end

  defp find_section_value(_section, _keys), do: nil

  defp to_nonempty_string(value) when is_binary(value), do: empty_to_nil(value)
  defp to_nonempty_string(value) when is_integer(value), do: Integer.to_string(value)
  defp to_nonempty_string(_value), do: nil

  defp known_targets("telegram", account_id) do
    TelegramKnownTargetStore.list_available()
    |> Enum.map(&format_telegram_known_target/1)
    |> Enum.reject(&is_nil/1)
    |> filter_known_targets_by_account(account_id)
    |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
  end

  defp known_targets("discord", account_id) do
    DiscordKnownTargetStore.list_available()
    |> Enum.map(&format_discord_known_target/1)
    |> Enum.reject(&is_nil/1)
    |> filter_known_targets_by_account(account_id)
    |> Enum.sort_by(&(&1.updated_at_ms || 0), :desc)
  end

  defp known_targets(_platform, _account_id), do: []

  defp filter_known_targets_by_account(targets, nil), do: targets

  defp filter_known_targets_by_account(targets, account_id) do
    Enum.filter(targets, &(&1.account_id == account_id))
  end

  defp resolve_telegram_named_target(chat_selector, nil, account_id) do
    selector = strip_telegram_name(chat_selector)
    candidates = telegram_named_chat_candidates(selector, account_id)
    unique_telegram_candidate(candidates, selector)
  end

  defp resolve_telegram_named_target(chat_selector, topic_selector, account_id) do
    chat_selector = strip_telegram_name(chat_selector)
    topic_selector = strip_telegram_name(topic_selector)

    candidates =
      telegram_known_targets(account_id)
      |> Enum.filter(fn target ->
        telegram_chat_matches?(target, chat_selector) and
          telegram_name_matches?(target.topic_name, topic_selector)
      end)

    unique_telegram_candidate(candidates, "#{chat_selector}:#{topic_selector}")
  end

  defp resolve_telegram_topic_target(chat_id, topic_selector, account_id) do
    with {:ok, peer_id} <- normalize_id(chat_id) do
      topic_selector = strip_telegram_name(topic_selector)

      candidates =
        telegram_known_targets(account_id)
        |> Enum.filter(fn target ->
          target.peer_id == peer_id and telegram_name_matches?(target.topic_name, topic_selector)
        end)

      unique_telegram_candidate(candidates, "#{peer_id}:#{topic_selector}")
    end
  end

  defp telegram_named_chat_candidates(selector, account_id) do
    targets = telegram_known_targets(account_id)

    direct_chat_matches =
      Enum.filter(targets, fn target ->
        is_nil(target.thread_id) and telegram_chat_matches?(target, selector)
      end)

    if direct_chat_matches == [] do
      Enum.filter(targets, fn target ->
        telegram_name_matches?(target.topic_name, selector) or
          telegram_name_matches?(target.label, selector)
      end)
    else
      direct_chat_matches
    end
  end

  defp telegram_known_targets(account_id), do: known_targets("telegram", account_id)

  defp unique_telegram_candidate([], selector), do: {:error, {:named_channel_not_found, selector}}

  defp unique_telegram_candidate([target], _selector) do
    {:ok, %{platform: "telegram", id: target.peer_id, thread_id: target.thread_id}}
  end

  defp unique_telegram_candidate(_targets, selector),
    do: {:error, {:ambiguous_named_channel, selector}}

  defp resolve_discord_named_target(channel_selector, nil, account_id) do
    selector = strip_discord_name(channel_selector)
    candidates = discord_named_channel_candidates(selector, account_id)
    unique_discord_candidate(candidates, selector)
  end

  defp resolve_discord_named_target(channel_selector, thread_selector, account_id) do
    channel_selector = strip_discord_name(channel_selector)
    thread_selector = strip_discord_name(thread_selector)

    candidates =
      discord_known_targets(account_id)
      |> Enum.filter(fn target ->
        name_matches?(target.channel_name, channel_selector) and
          name_matches?(target.thread_name, thread_selector)
      end)

    unique_discord_candidate(candidates, "#{channel_selector}:#{thread_selector}")
  end

  defp resolve_discord_thread_target(channel_id, thread_selector, account_id) do
    with {:ok, peer_id} <- normalize_id(channel_id) do
      thread_selector = strip_discord_name(thread_selector)

      candidates =
        discord_known_targets(account_id)
        |> Enum.filter(fn target ->
          target.peer_id == peer_id and name_matches?(target.thread_name, thread_selector)
        end)

      unique_discord_candidate(candidates, "#{peer_id}:#{thread_selector}")
    end
  end

  defp discord_named_channel_candidates(selector, account_id) do
    targets = discord_known_targets(account_id)

    direct_channel_matches =
      Enum.filter(targets, fn target ->
        is_nil(target.thread_id) and name_matches?(target.channel_name, selector)
      end)

    if direct_channel_matches == [] do
      Enum.filter(targets, fn target ->
        name_matches?(target.thread_name, selector) or name_matches?(target.label, selector)
      end)
    else
      direct_channel_matches
    end
  end

  defp discord_known_targets(account_id), do: known_targets("discord", account_id)

  defp unique_discord_candidate([], selector), do: {:error, {:named_channel_not_found, selector}}

  defp unique_discord_candidate([target], _selector) do
    {:ok, %{platform: "discord", id: target.peer_id, thread_id: target.thread_id}}
  end

  defp unique_discord_candidate(_targets, selector),
    do: {:error, {:ambiguous_named_channel, selector}}

  defp named_discord_selector?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.starts_with?("#")
  end

  defp named_discord_selector?(_value), do: false

  defp named_telegram_selector?(value) when is_binary(value) do
    value = String.trim(value)
    String.starts_with?(value, "#") or String.starts_with?(value, "@")
  end

  defp named_telegram_selector?(_value), do: false

  defp named_thread_selector?(nil), do: false

  defp named_thread_selector?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {_id, ""} -> false
      _ -> true
    end
  end

  defp named_thread_selector?(_value), do: false

  defp strip_discord_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
  end

  defp strip_telegram_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim_leading("@")
  end

  defp telegram_chat_matches?(target, selector) do
    telegram_name_matches?(target.chat_title, selector) or
      telegram_name_matches?(target.chat_username, selector) or
      telegram_name_matches?(target.chat_display_name, selector)
  end

  defp telegram_name_matches?(value, selector) when is_binary(value) and is_binary(selector) do
    normalize_telegram_name(value) == normalize_telegram_name(selector)
  end

  defp telegram_name_matches?(_value, _selector), do: false

  defp normalize_telegram_name(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp name_matches?(value, selector) when is_binary(value) and is_binary(selector) do
    normalize_discord_name(value) == normalize_discord_name(selector)
  end

  defp name_matches?(_value, _selector), do: false

  defp normalize_discord_name(value) do
    value
    |> String.trim()
    |> String.trim_leading("#")
    |> String.downcase()
  end

  defp format_discord_known_target({key, entry}) when is_map(entry) do
    with {account_id, channel_id, thread_id} <- normalize_discord_known_target_key(key),
         peer_id when is_binary(peer_id) <- target_peer_id(entry, channel_id) do
      thread_id = target_thread_id(entry, thread_id)

      %{
        target: "discord:#{peer_id}#{target_thread_suffix(thread_id)}",
        account_id: account_id,
        peer_kind: field(entry, :peer_kind),
        peer_id: peer_id,
        thread_id: thread_id,
        label: discord_target_label(entry),
        channel_name: field(entry, :channel_name),
        thread_name: field(entry, :thread_name),
        guild_id: field(entry, :guild_id),
        updated_at_ms: field(entry, :updated_at_ms),
        source: "discord_known_targets",
        aliases: discord_target_aliases(peer_id, thread_id, entry)
      }
    else
      _ -> nil
    end
  end

  defp format_discord_known_target(_entry), do: nil

  defp format_telegram_known_target({key, entry}) when is_map(entry) do
    with {account_id, chat_id, topic_id} <- normalize_telegram_known_target_key(key),
         peer_id when is_binary(peer_id) <- target_peer_id(entry, chat_id) do
      thread_id = target_thread_id(entry, topic_id)

      %{
        target: "telegram:#{peer_id}#{target_thread_suffix(thread_id)}",
        account_id: account_id,
        peer_kind: field(entry, :peer_kind),
        peer_id: peer_id,
        thread_id: thread_id,
        label: telegram_target_label(entry),
        chat_display_name: field(entry, :chat_display_name),
        chat_title: field(entry, :chat_title),
        chat_username: field(entry, :chat_username),
        topic_name: field(entry, :topic_name),
        updated_at_ms: field(entry, :updated_at_ms),
        source: "telegram_known_targets",
        aliases: telegram_target_aliases(peer_id, thread_id, entry)
      }
    else
      _ -> nil
    end
  end

  defp format_telegram_known_target(_entry), do: nil

  defp normalize_telegram_known_target_key({account_id, chat_id, topic_id}) do
    {to_string(account_id), chat_id, topic_id}
  end

  defp normalize_telegram_known_target_key(_key), do: nil

  defp normalize_discord_known_target_key({account_id, channel_id, thread_id}) do
    {to_string(account_id), channel_id, thread_id}
  end

  defp normalize_discord_known_target_key(_key), do: nil

  defp target_peer_id(entry, chat_id) do
    case field(entry, :peer_id) do
      value when is_binary(value) and value != "" -> value
      _ when is_integer(chat_id) -> to_string(chat_id)
      _ -> nil
    end
  end

  defp target_thread_id(entry, topic_id) do
    case field(entry, :thread_id) do
      value when is_binary(value) and value != "" -> value
      _ when is_integer(topic_id) -> to_string(topic_id)
      _ -> nil
    end
  end

  defp target_thread_suffix(nil), do: ""
  defp target_thread_suffix(""), do: ""
  defp target_thread_suffix(thread_id), do: ":#{thread_id}"

  defp telegram_target_label(entry) do
    [field(entry, :chat_display_name), field(entry, :chat_title), field(entry, :chat_username)]
    |> Enum.find(&present?/1)
    |> case do
      nil -> field(entry, :topic_name)
      label -> Enum.reject([label, field(entry, :topic_name)], &is_nil/1) |> Enum.join(" / ")
    end
  end

  defp discord_target_label(entry) do
    [field(entry, :channel_name), field(entry, :thread_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
    |> case do
      "" -> nil
      label -> label
    end
  end

  defp telegram_target_aliases(peer_id, thread_id, entry) do
    chat_names = [
      field(entry, :chat_title),
      telegram_username_alias_name(entry),
      field(entry, :chat_display_name)
    ]

    aliases =
      if present?(thread_id) do
        topic_name = field(entry, :topic_name)

        Enum.map(chat_names, &qualified_telegram_alias(&1, topic_name)) ++
          [telegram_numeric_topic_alias(peer_id, topic_name)]
      else
        Enum.map(chat_names, &telegram_chat_alias/1)
      end

    compact_aliases(aliases)
  end

  defp discord_target_aliases(peer_id, thread_id, entry) do
    channel_name = field(entry, :channel_name)
    thread_name = field(entry, :thread_name)

    aliases =
      if present?(thread_id) do
        [
          qualified_discord_alias(channel_name, thread_name),
          discord_numeric_thread_alias(peer_id, thread_name)
        ]
      else
        [discord_channel_alias(channel_name)]
      end

    compact_aliases(aliases)
  end

  defp telegram_chat_alias(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.starts_with?(value, "@") -> "telegram:#{value}"
      true -> "telegram:##{value}"
    end
  end

  defp telegram_chat_alias(_value), do: nil

  defp telegram_username_alias_name(entry) do
    case field(entry, :chat_username) do
      username when is_binary(username) ->
        username = String.trim(username)
        if username == "", do: nil, else: "@#{String.trim_leading(username, "@")}"

      _ ->
        nil
    end
  end

  defp qualified_telegram_alias(chat_name, topic_name)
       when is_binary(chat_name) and is_binary(topic_name) do
    case telegram_chat_alias(chat_name) do
      nil -> nil
      alias -> "#{alias}:#{String.trim(topic_name)}"
    end
  end

  defp qualified_telegram_alias(_chat_name, _topic_name), do: nil

  defp telegram_numeric_topic_alias(peer_id, topic_name)
       when is_binary(peer_id) and is_binary(topic_name) do
    "telegram:#{String.trim(peer_id)}:#{String.trim(topic_name)}"
  end

  defp telegram_numeric_topic_alias(_peer_id, _topic_name), do: nil

  defp discord_channel_alias(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.starts_with?(value, "#") -> "discord:#{value}"
      true -> "discord:##{value}"
    end
  end

  defp discord_channel_alias(_value), do: nil

  defp qualified_discord_alias(channel_name, thread_name)
       when is_binary(channel_name) and is_binary(thread_name) do
    case discord_channel_alias(channel_name) do
      nil -> nil
      alias -> "#{alias}:#{String.trim(thread_name)}"
    end
  end

  defp qualified_discord_alias(_channel_name, _thread_name), do: nil

  defp discord_numeric_thread_alias(peer_id, thread_name)
       when is_binary(peer_id) and is_binary(thread_name) do
    "discord:#{String.trim(peer_id)}:#{String.trim(thread_name)}"
  end

  defp discord_numeric_thread_alias(_peer_id, _thread_name), do: nil

  defp compact_aliases(aliases) do
    aliases
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.uniq()
  end

  defp field(entry, key) do
    Map.get(entry, key) || Map.get(entry, to_string(key))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp format_subject(nil, body), do: body
  defp format_subject("", body), do: body
  defp format_subject(subject, body), do: "#{subject}\n\n#{body}"

  defp idempotency_key(target) do
    unique = System.unique_integer([:positive, :monotonic])
    "lemon.send:#{target.platform}:#{target.id}:#{target.thread_id}:#{unique}"
  end

  defp empty_to_nil(nil), do: nil

  defp empty_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp stdin_available? do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) == false
      _ -> false
    end
  end

  defp read_stdin, do: IO.read(:stdio, :all)
end

defmodule LemonCli.Setup.Gateway.Telegram do
  @moduledoc """
  Gateway setup adapter for the Telegram transport, with owner pairing.

  Steps:

  1. Secrets readiness — aborts with `lemon secrets init` guidance when
     encrypted secrets are not configured.
  2. Bot token — `--token` is validated and stored under the secret key
     (default `telegram_bot_token`); otherwise the stored secret is used, or
     the user is prompted for it.
  3. Verification — `getMe` confirms the token and reports the bot username
     (skip with `--skip-smoke`).
  4. Owner pairing — `--chat-id` (repeatable) supplies allowed chats directly;
     otherwise the user sends `/start` to the bot and setup polls `getUpdates`
     for a bounded time (`--pair-timeout`, seconds) to capture the chat id.
  5. Config — writes `enable_telegram = true`, `bot_token_secret`, and
     `allowed_chat_ids` to the canonical config via `TomlPatch`. The raw token
     is never written to config or printed.

  ## Non-interactive mode

  `--non-interactive` (or `-n`) never prompts or waits for `/start`; pass
  `--token` (or pre-store the secret) and at least one `--chat-id`.
  """

  @behaviour LemonCli.Setup.Gateway.Adapter

  alias LemonCli.Setup.Gateway.AllowlistConfig
  alias LemonCore.Config.{Modular, TomlPatch}
  alias LemonCore.Httpc
  alias LemonCore.Secrets

  # Telegram token format: <numeric_id>:<35-100 char alphanumeric/dash>
  @token_regex ~r/^\d+:[\w-]{35,100}$/

  @telegram_api "https://api.telegram.org"
  @default_secret_key "telegram_bot_token"
  @default_pair_timeout_s 120
  # Long-poll window per getUpdates call while waiting for /start.
  @poll_window_s 10

  @impl true
  def name, do: "telegram"

  @impl true
  def description, do: "Telegram bot — paired to your chat"

  @impl true
  def run(args, io) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          non_interactive: :boolean,
          secret_key: :string,
          token: :string,
          chat_id: :keep,
          pair_timeout: :integer,
          skip_smoke: :boolean
        ],
        aliases: [n: :non_interactive]
      )

    non_interactive? = opts[:non_interactive] || false
    secret_key = opts[:secret_key] || @default_secret_key
    skip_smoke? = opts[:skip_smoke] || false
    pair_timeout_s = max(opts[:pair_timeout] || @default_pair_timeout_s, 1)

    io.info.("")
    io.info.("Telegram Gateway Setup")
    io.info.("──────────────────────")

    with :ok <- check_secrets_ready(io),
         {:ok, token} <- ensure_bot_token(opts[:token], secret_key, non_interactive?, io),
         {:ok, bot_username} <- maybe_verify_token(token, skip_smoke?, io),
         {:ok, chat_ids} <-
           ensure_chat_ids(opts, token, bot_username, non_interactive?, pair_timeout_s, io),
         :ok <- patch_config(secret_key, chat_ids, io) do
      io.info.("")
      io.info.("Telegram is paired with chat(s): #{Enum.join(chat_ids, ", ")}.")
      io.info.("Restart Lemon (`lemon restart`) for the change to take effect.")
      :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Secrets and token
  # ──────────────────────────────────────────────────────────────────────────

  defp check_secrets_ready(io) do
    if secrets_status(io).configured do
      :ok
    else
      io.error.("Encrypted secrets are not configured.")
      io.info.("")
      io.info.("Run this first, then retry:")
      io.info.("  lemon secrets init")
      io.info.("")
      {:error, :secrets_not_configured}
    end
  end

  defp ensure_bot_token(token, secret_key, _non_interactive?, io)
       when is_binary(token) and token != "" do
    with :ok <- validate_token_format(token, io),
         :ok <- store_token(secret_key, token, io) do
      {:ok, token}
    end
  end

  defp ensure_bot_token(_token, secret_key, non_interactive?, io) do
    case secret_get(io, secret_key) do
      {:ok, token} ->
        io.info.("Bot token found in encrypted secrets (key: #{secret_key}).")

        with :ok <- validate_token_format(token, io) do
          {:ok, token}
        end

      {:error, _reason} when non_interactive? ->
        io.error.("Bot token not found in encrypted secrets (key: #{secret_key}).")
        io.info.("Pass --token or store it first with:")
        io.info.("  lemon secrets set #{secret_key}")
        {:error, :token_not_found}

      {:error, _reason} ->
        prompt_and_store_token(secret_key, io)
    end
  end

  defp prompt_and_store_token(secret_key, io) do
    io.info.("Bot token not found in encrypted secrets (key: #{secret_key}).")
    io.info.("Create a bot with @BotFather on Telegram if you don't have one yet.")
    io.info.("")

    token = normalize_input(io.secret.("Paste your Telegram bot token: "))

    with :ok <- validate_token_format(token, io),
         :ok <- store_token(secret_key, token, io) do
      {:ok, token}
    end
  end

  defp store_token(secret_key, token, io) do
    case secret_set(io, secret_key, token) do
      {:ok, _} ->
        io.info.("Bot token stored under key \"#{secret_key}\".")
        :ok

      {:error, _reason} ->
        io.error.("Could not store the bot token in encrypted secrets.")
        {:error, :secret_store_failed}
    end
  end

  defp validate_token_format(token, io) when is_binary(token) and token != "" do
    if Regex.match?(@token_regex, token) do
      :ok
    else
      io.error.("Token format is invalid (expected `<bot_id>:<secret>` from @BotFather).")
      io.info.("Copy the token from @BotFather and try again.")
      {:error, :invalid_token_format}
    end
  end

  defp validate_token_format(_token, io) do
    io.error.("No bot token provided. Aborting.")
    {:error, :no_token}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # getMe verification
  # ──────────────────────────────────────────────────────────────────────────

  defp maybe_verify_token(_token, true, io) do
    io.info.("Skipping connectivity check (--skip-smoke).")
    {:ok, nil}
  end

  defp maybe_verify_token(token, false, io) do
    io.info.("")
    io.info.("Testing connectivity to Telegram API ...")

    case get_me(io, token) do
      {:ok, username} ->
        io.info.("Connected! Bot username: @#{username}")
        io.info.("Open your bot: https://t.me/#{username}")
        {:ok, username}

      {:error, :unauthorized} ->
        io.error.("Telegram returned 401 — the bot token is invalid or revoked.")
        io.info.("Generate a new token via @BotFather and re-run setup.")
        {:error, :unauthorized}

      {:error, {:http_error, status}} ->
        io.error.("Telegram API returned HTTP #{status} while validating the bot token.")
        io.info.("Check Telegram's service status, then re-run with --skip-smoke if needed.")
        {:error, {:http_error, status}}

      {:error, _reason} ->
        io.error.("Could not reach Telegram API to validate the bot token.")
        io.info.("Check your internet connection, then re-run with --skip-smoke if needed.")
        {:error, :telegram_unreachable}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Owner pairing
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_chat_ids(opts, token, bot_username, non_interactive?, pair_timeout_s, io) do
    case Keyword.get_values(opts, :chat_id) do
      [_ | _] = values ->
        parse_chat_ids(values, io)

      [] when non_interactive? ->
        io.error.("A chat id is required to pair the bot (--chat-id).")
        io.info.("Send /whoami to the bot while Lemon is running to see your chat id,")
        io.info.("or re-run without --non-interactive to pair by sending /start.")
        {:error, :missing_chat_id}

      [] ->
        pair_via_start(token, bot_username, pair_timeout_s, io)
    end
  end

  defp parse_chat_ids(values, io) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case Integer.parse(String.trim(value)) do
        {id, ""} when id != 0 ->
          {:cont, {:ok, [id | ids]}}

        _ ->
          io.error.("Chat id #{inspect(value)} is not a Telegram chat id (an integer).")
          {:halt, {:error, :invalid_chat_id}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp pair_via_start(token, bot_username, pair_timeout_s, io) do
    target = if bot_username, do: "@#{bot_username}", else: "your bot"

    io.info.("")
    io.info.("Pairing: open Telegram and send /start to #{target} from the chat you want to use.")
    io.info.("Waiting up to #{pair_timeout_s}s ...")

    deadline = System.monotonic_time(:millisecond) + pair_timeout_s * 1_000

    case await_start(io, token, 0, deadline) do
      {:ok, %{chat_id: chat_id} = pairing} ->
        io.info.("Received /start from #{describe_sender(pairing)} in chat #{chat_id}.")
        {:ok, [chat_id]}

      {:error, :timeout} ->
        io.error.("No /start message arrived within #{pair_timeout_s}s.")
        io.info.("If Lemon is already running with this bot it consumes updates first:")
        io.info.("send /whoami to the bot, then re-run with --chat-id <id>.")
        {:error, :pairing_timeout}

      {:error, _reason} ->
        io.error.("Could not read updates from the Telegram API while pairing.")
        io.info.("Check your connection, or re-run with --chat-id <id>.")
        {:error, :pairing_failed}
    end
  end

  defp await_start(io, token, offset, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :timeout}
    else
      window_s = remaining_ms |> div(1_000) |> max(1) |> min(@poll_window_s)

      case get_updates(io, token, offset, window_s) do
        {:ok, updates} ->
          next_offset = next_offset(updates, offset)

          case Enum.find_value(updates, &start_pairing/1) do
            nil ->
              await_start(io, token, next_offset, deadline)

            pairing ->
              # Acknowledge the consumed updates so a running transport does not
              # later replay /start to the agent as a prompt.
              _ = get_updates(io, token, next_offset, 0)
              {:ok, pairing}
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp next_offset(updates, offset) do
    Enum.reduce(updates, offset, fn update, acc ->
      case update["update_id"] do
        id when is_integer(id) -> max(acc, id + 1)
        _ -> acc
      end
    end)
  end

  defp start_pairing(%{"message" => %{"chat" => %{"id" => chat_id}} = message})
       when is_integer(chat_id) do
    if start_command?(message["text"]) do
      from = message["from"] || %{}
      %{chat_id: chat_id, user_id: from["id"], username: from["username"]}
    end
  end

  defp start_pairing(_update), do: nil

  defp start_command?(text) when is_binary(text),
    do: Regex.match?(~r/^\/start(?:@[\w_]+)?(?:\s|$)/i, String.trim_leading(text))

  defp start_command?(_text), do: false

  defp describe_sender(%{username: username}) when is_binary(username) and username != "",
    do: "@#{username}"

  defp describe_sender(%{user_id: user_id}) when not is_nil(user_id), do: "user #{user_id}"
  defp describe_sender(_pairing), do: "an unknown user"

  # ──────────────────────────────────────────────────────────────────────────
  # Config
  # ──────────────────────────────────────────────────────────────────────────

  defp patch_config(secret_key, chat_ids, io) do
    path = Map.get(io, :config_path, Modular.global_path()) |> Path.expand()

    with {:ok, content} <- read_config(path, io),
         patched = patch_gateway_config(content, secret_key, chat_ids),
         :ok <- write_config(path, patched, io) do
      io.info.("Updated gateway config: #{path}")
      :ok
    else
      {:error, :config_read_failed} ->
        io.error.("Could not read the canonical Lemon config file.")
        {:error, :config_read_failed}

      {:error, :config_write_failed} ->
        io.error.("Could not update the canonical Lemon config file.")
        {:error, :config_write_failed}
    end
  end

  defp read_config(path, io) do
    case Map.get(io, :read_file, &File.read/1).(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, _reason} -> {:error, :config_read_failed}
    end
  end

  defp patch_gateway_config(content, secret_key, chat_ids) do
    content
    |> TomlPatch.upsert_raw_line("gateway", "enable_telegram", "enable_telegram = true")
    |> TomlPatch.upsert_string("gateway.telegram", "bot_token_secret", secret_key)
    |> AllowlistConfig.patch("telegram", chat_ids)
  end

  defp write_config(path, content, io) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Map.get(io, :write_file, &File.write/2).(path, content) do
      :ok
    else
      {:error, _reason} -> {:error, :config_write_failed}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Telegram Bot API (injectable through `io` for tests)
  # ──────────────────────────────────────────────────────────────────────────

  defp secrets_status(io), do: Map.get(io, :secrets_status, &Secrets.status/0).()
  defp secret_get(io, key), do: Map.get(io, :secret_get, &Secrets.get/1).(key)

  defp secret_set(io, key, token),
    do: Map.get(io, :secret_set, &Secrets.set(&1, &2, [])).(key, token)

  defp get_me(io, token), do: Map.get(io, :telegram_get_me, &api_get_me/1).(token)

  defp get_updates(io, token, offset, timeout_s),
    do: Map.get(io, :telegram_get_updates, &api_get_updates/3).(token, offset, timeout_s)

  defp api_get_me(token) do
    case api_request(token, "getMe", 5_000) do
      {:ok, %{"ok" => true, "result" => %{"username" => username}}} when is_binary(username) ->
        {:ok, username}

      {:ok, _body} ->
        {:ok, "unknown"}

      error ->
        error
    end
  end

  defp api_get_updates(token, offset, timeout_s) do
    query = URI.encode_query(%{"offset" => offset, "timeout" => timeout_s})

    case api_request(token, "getUpdates?" <> query, (timeout_s + 10) * 1_000) do
      {:ok, %{"ok" => true, "result" => updates}} when is_list(updates) -> {:ok, updates}
      {:ok, _body} -> {:error, :unexpected_response}
      error -> error
    end
  end

  defp api_request(token, method, timeout_ms) do
    url = ~c"#{@telegram_api}/bot#{token}/#{method}"
    ssl_opts = [verify: :verify_peer] |> maybe_put_cacerts()

    case Httpc.request(:get, {url, []}, [{:ssl, ssl_opts}, {:timeout, timeout_ms}], []) do
      {:ok, {{_vsn, 200, _}, _headers, body}} -> decode_body(body)
      {:ok, {{_vsn, 401, _}, _headers, _body}} -> {:error, :unauthorized}
      {:ok, {{_vsn, status, _}, _headers, _body}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_body(body) when is_list(body), do: decode_body(List.to_string(body))

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp maybe_put_cacerts(ssl_opts) do
    if function_exported?(:public_key, :cacerts_get, 0) do
      case apply(:public_key, :cacerts_get, []) do
        cacerts when is_list(cacerts) and cacerts != [] ->
          Keyword.put(ssl_opts, :cacerts, cacerts)

        _ ->
          ssl_opts
      end
    else
      ssl_opts
    end
  end

  defp normalize_input(nil), do: ""
  defp normalize_input(:eof), do: ""
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()
end

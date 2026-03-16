defmodule LemonCore.Setup.Gateway.Telegram do
  @moduledoc """
  Gateway setup adapter for the Telegram transport.

  Guides the user through:

  1. Secrets readiness check — aborts with guidance if secrets are not
     initialized.
  2. Bot-token secret bootstrap — checks whether `telegram_bot_token` (or the
     user-specified key) is already in the keychain; if not, prompts for the
     raw token and stores it.
  3. Token format validation — `<bot_id>:<secret>` (Telegram's canonical
     format).
  4. Connectivity smoke test — calls `getMe` on the Telegram Bot API using
     Erlang's built-in `:httpc` to verify the token works.
  5. Config snippet output — prints a minimal `[gateway.telegram]` stanza
     the user can paste into their config.toml and the flag to enable it.

  ## Non-interactive mode

  Pass `--non-interactive` (or `-n`) to skip all prompts.  In this mode the
  adapter only validates what already exists — it does not prompt for a token
  or attempt to write any secrets.
  """

  @behaviour LemonCore.Setup.Gateway.Adapter

  alias LemonCore.Secrets

  # Telegram token format: <numeric_id>:<35-100 char alphanumeric/dash>
  @token_regex ~r/^\d+:[\w-]{35,100}$/

  @telegram_api "https://api.telegram.org"

  @impl true
  def name, do: "telegram"

  @impl true
  def description, do: "Telegram bot — polling or webhook"

  @impl true
  def run(args, io) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          non_interactive: :boolean,
          secret_key: :string,
          skip_smoke: :boolean
        ],
        aliases: [n: :non_interactive]
      )

    non_interactive? = opts[:non_interactive] || false
    secret_key = opts[:secret_key] || "telegram_bot_token"
    skip_smoke? = opts[:skip_smoke] || false

    io.info.("")
    io.info.("Telegram Gateway Setup")
    io.info.("──────────────────────")

    with :ok <- check_secrets_ready(io),
         {:ok, token} <- ensure_bot_token(secret_key, non_interactive?, io),
         :ok <- validate_token_format(token, io),
         :ok <- maybe_smoke_test(token, skip_smoke?, io) do
      print_config_snippet(secret_key, io)
      :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step 1: secrets readiness
  # ──────────────────────────────────────────────────────────────────────────

  defp check_secrets_ready(io) do
    status = Secrets.status()

    if status.configured do
      :ok
    else
      io.error.("Encrypted secrets are not configured.")
      io.info.("")
      io.info.("Run this first, then retry:")
      io.info.("  mix lemon.secrets.init")
      io.info.("")
      {:error, :secrets_not_configured}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step 2: bot token bootstrap
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_bot_token(secret_key, non_interactive?, io) do
    case Secrets.get(secret_key) do
      {:ok, token} ->
        io.info.("Bot token found in keychain (key: #{secret_key}).")
        {:ok, token}

      {:error, _reason} when non_interactive? ->
        io.error.("Bot token not found in keychain (key: #{secret_key}).")
        io.info.("Store it first with:")
        io.info.("  mix lemon.secrets.set #{secret_key}")
        {:error, :token_not_found}

      {:error, _reason} ->
        prompt_and_store_token(secret_key, io)
    end
  end

  defp prompt_and_store_token(secret_key, io) do
    io.info.("Bot token not found in keychain (key: #{secret_key}).")
    io.info.("Get one from @BotFather on Telegram if you don't have one yet.")
    io.info.("")

    raw = normalize_input(io.secret.("Paste your Telegram bot token: "))

    cond do
      raw == "" ->
        io.error.("No token provided. Aborting.")
        {:error, :no_token}

      not Regex.match?(@token_regex, raw) ->
        io.error.("Token format looks wrong (expected `<id>:<secret>`).")
        io.info.("Double-check the token from BotFather and try again.")
        {:error, :invalid_token_format}

      true ->
        case Secrets.set(secret_key, raw, []) do
          {:ok, _} ->
            io.info.("Token stored under key \"#{secret_key}\".")
            {:ok, raw}

          {:error, reason} ->
            io.error.("Could not store token: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step 3: token format validation
  # ──────────────────────────────────────────────────────────────────────────

  defp validate_token_format(token, io) do
    if Regex.match?(@token_regex, token) do
      :ok
    else
      io.error.("Token format is invalid (expected `<id>:<secret>`).")
      io.info.("The token may have been stored incorrectly. Re-run with the correct value.")
      {:error, :invalid_token_format}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step 4: connectivity smoke test
  # ──────────────────────────────────────────────────────────────────────────

  defp maybe_smoke_test(_token, true = _skip?, io) do
    io.info.("Skipping connectivity check (--skip-smoke).")
    :ok
  end

  defp maybe_smoke_test(token, false, io) do
    io.info.("")
    io.info.("Testing connectivity to Telegram API ...")

    case get_me(token) do
      {:ok, username} ->
        io.info.("Connected! Bot username: @#{username}")
        :ok

      {:error, :unauthorized} ->
        io.error.("API returned 401 — token is invalid or revoked.")
        io.info.("Generate a new token via @BotFather and re-run setup.")
        {:error, :unauthorized}

      {:error, reason} ->
        io.error.("Could not reach Telegram API: #{inspect(reason)}")
        io.info.("Check your internet connection. Re-run with --skip-smoke to bypass.")
        {:error, reason}
    end
  end

  # Calls getMe via :httpc (no extra deps required).
  defp get_me(token) do
    url = ~c"#{@telegram_api}/bot#{token}/getMe"

    :ok = Application.ensure_started(:inets)
    :ok = Application.ensure_started(:ssl)

    ssl_opts = [verify: :verify_peer, cacerts: :public_key.cacerts_get()]

    case :httpc.request(:get, {url, []}, [{:ssl, ssl_opts}, {:timeout, 5_000}], []) do
      {:ok, {{_vsn, 200, _}, _headers, body}} ->
        parse_username(body)

      {:ok, {{_vsn, 401, _}, _headers, _body}} ->
        {:error, :unauthorized}

      {:ok, {{_vsn, status, _}, _headers, _body}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_username(body) when is_list(body), do: parse_username(List.to_string(body))

  defp parse_username(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"ok" => true, "result" => %{"username" => username}}} ->
        {:ok, username}

      _ ->
        {:ok, "unknown"}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Step 5: config snippet
  # ──────────────────────────────────────────────────────────────────────────

  defp print_config_snippet(secret_key, io) do
    io.info.("")
    io.info.("Add this to your config.toml to enable the Telegram gateway:")
    io.info.("")
    io.info.("  [gateway]")
    io.info.("  enable_telegram = true")
    io.info.("")
    io.info.("  [gateway.telegram]")
    io.info.("  bot_token_secret = \"#{secret_key}\"")
    io.info.("")
    io.info.("Then restart Lemon for the changes to take effect.")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # IO helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp normalize_input(nil), do: ""
  defp normalize_input(:eof), do: ""
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()
end

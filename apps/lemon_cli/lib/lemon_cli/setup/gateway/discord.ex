defmodule LemonCli.Setup.Gateway.Discord do
  @moduledoc """
  Gateway setup adapter for Discord.

  The adapter stores the bot token in encrypted secrets, writes only the secret
  reference and a restricted channel scope to the canonical gateway config, and
  verifies the token with Discord's `GET /users/@me` bot identity endpoint.
  """

  @behaviour LemonCli.Setup.Gateway.Adapter

  alias LemonCore.Config.{Modular, TomlPatch}
  alias LemonCore.Httpc
  alias LemonCore.Secrets

  @discord_api ~c"https://discord.com/api/v10/users/@me"
  @default_secret_key "discord_bot_token"

  @impl true
  def name, do: "discord"

  @impl true
  def description, do: "Discord bot — restricted to an allowed channel"

  @impl true
  def run(args, io) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          non_interactive: :boolean,
          secret_key: :string,
          token: :string,
          default_channel_id: :string,
          allowed_channel_id: :keep,
          allowed_guild_id: :keep,
          skip_smoke: :boolean
        ],
        aliases: [n: :non_interactive]
      )

    non_interactive? = opts[:non_interactive] || false
    secret_key = opts[:secret_key] || @default_secret_key
    skip_smoke? = opts[:skip_smoke] || false

    io.info.("")
    io.info.("Discord Gateway Setup")
    io.info.("────────────────────")

    with :ok <- check_secrets_ready(io),
         {:ok, token} <- ensure_bot_token(opts[:token], secret_key, non_interactive?, io),
         {:ok, scope} <- ensure_channel_scope(opts, non_interactive?, io),
         :ok <- maybe_smoke_test(token, skip_smoke?, io),
         :ok <- patch_config(secret_key, scope, io) do
      io.info.("Discord gateway configured for the selected channel.")
      :ok
    end
  end

  defp check_secrets_ready(io) do
    status = secrets_status(io)

    if status.configured do
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
    io.info.("Create one in the Discord Developer Portal if you do not have one yet.")
    io.info.("")

    token = normalize_input(io.secret.("Paste your Discord bot token: "))

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

  defp validate_token_format(token, io) when is_binary(token) do
    case String.split(token, ".") do
      [user_id, timestamp, signature]
      when byte_size(user_id) >= 10 and byte_size(timestamp) >= 5 and byte_size(signature) >= 5 ->
        :ok

      _ ->
        io.error.("Token format is invalid (expected a Discord bot token).")
        io.info.("Copy the token from the Discord Developer Portal and try again.")
        {:error, :invalid_token_format}
    end
  end

  defp validate_token_format(_token, io) do
    io.error.("No bot token provided. Aborting.")
    {:error, :no_token}
  end

  defp ensure_channel_scope(opts, non_interactive?, io) do
    default_channel_id =
      opts[:default_channel_id] ||
        if(non_interactive?,
          do: nil,
          else: normalize_input(io.prompt.("Discord channel ID to allow (snowflake): "))
        )

    with {:ok, default_channel_id} <-
           parse_snowflake(default_channel_id, "default channel ID", io),
         {:ok, allowed_channel_ids} <-
           parse_snowflakes(
             Keyword.get_values(opts, :allowed_channel_id),
             "allowed channel ID",
             io
           ),
         {:ok, allowed_guild_ids} <-
           parse_snowflakes(Keyword.get_values(opts, :allowed_guild_id), "allowed guild ID", io) do
      {:ok,
       %{
         default_channel_id: default_channel_id,
         allowed_channel_ids: [default_channel_id | allowed_channel_ids] |> Enum.uniq(),
         allowed_guild_ids: allowed_guild_ids
       }}
    end
  end

  defp parse_snowflakes(values, label, io) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case parse_snowflake(value, label, io) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp parse_snowflake(value, label, io) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {id, ""} when id > 0 and byte_size(value) >= 10 ->
        {:ok, id}

      _ ->
        io.error.("#{String.capitalize(label)} must be a Discord snowflake ID.")
        io.info.("Use the numeric channel or guild ID from Discord Developer Mode.")
        {:error, :invalid_snowflake}
    end
  end

  defp parse_snowflake(_value, label, io) do
    io.error.("#{String.capitalize(label)} is required for a safe Discord setup.")
    io.info.("Pass --default-channel-id <id> or provide it when prompted.")
    {:error, :missing_default_channel_id}
  end

  defp maybe_smoke_test(_token, true, io) do
    io.info.("Skipping connectivity check (--skip-smoke).")
    :ok
  end

  defp maybe_smoke_test(token, false, io) do
    io.info.("")
    io.info.("Testing connectivity to Discord API ...")

    case http_get(io, token) do
      {:ok, username} ->
        io.info.("Connected! Bot username: #{username}")
        :ok

      {:error, :unauthorized} ->
        io.error.("Discord returned 401 — the bot token is invalid or revoked.")
        io.info.("Create a new bot token in the Discord Developer Portal and re-run setup.")
        {:error, :unauthorized}

      {:error, {:http_error, status}} ->
        io.error.("Discord API returned HTTP #{status} while validating the bot token.")
        io.info.("Check Discord's service status, then re-run with --skip-smoke if needed.")
        {:error, {:http_error, status}}

      {:error, _reason} ->
        io.error.("Could not reach Discord API to validate the bot token.")
        io.info.("Check your internet connection, then re-run with --skip-smoke if needed.")
        {:error, :discord_unreachable}
    end
  end

  defp patch_config(secret_key, scope, io) do
    path = Map.get(io, :config_path, Modular.global_path()) |> Path.expand()

    with {:ok, content} <- read_config(path, io),
         {:ok, patched} <- patch_gateway_config(content, secret_key, scope),
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

  defp patch_gateway_config(content, secret_key, scope) do
    allowed_channel_ids = Enum.join(scope.allowed_channel_ids, ", ")

    content
    |> ensure_gateway_table()
    |> TomlPatch.upsert_raw_line("gateway", "enable_discord", "enable_discord = true")
    |> TomlPatch.upsert_string("gateway.discord", "bot_token_secret", secret_key)
    |> TomlPatch.upsert_raw_line(
      "gateway.discord",
      "default_channel_id",
      "default_channel_id = #{scope.default_channel_id}"
    )
    |> TomlPatch.upsert_raw_line(
      "gateway.discord",
      "allowed_channel_ids",
      "allowed_channel_ids = [#{allowed_channel_ids}]"
    )
    |> TomlPatch.upsert_raw_line(
      "gateway.discord",
      "deny_unbound_channels",
      "deny_unbound_channels = true"
    )
    |> maybe_patch_allowed_guild_ids(scope.allowed_guild_ids)
    |> then(&{:ok, &1})
  end

  defp ensure_gateway_table(content) do
    if Regex.match?(~r/^\s*\[gateway\]\s*$/m, content) do
      content
    else
      case Regex.run(~r/^\s*\[gateway\.[^\]]+\]\s*$/m, content, return: :index) do
        [{index, _length}] ->
          String.slice(content, 0, index) <>
            "[gateway]\nenable_discord = true\n\n" <>
            String.slice(content, index, String.length(content) - index)

        _ ->
          content
      end
    end
  end

  defp maybe_patch_allowed_guild_ids(content, []), do: content

  defp maybe_patch_allowed_guild_ids(content, allowed_guild_ids) do
    TomlPatch.upsert_raw_line(
      content,
      "gateway.discord",
      "allowed_guild_ids",
      "allowed_guild_ids = [#{Enum.join(allowed_guild_ids, ", ")}]"
    )
  end

  defp write_config(path, content, io) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- Map.get(io, :write_file, &File.write/2).(path, content) do
      :ok
    else
      {:error, _reason} -> {:error, :config_write_failed}
    end
  end

  defp http_get(io, token), do: Map.get(io, :http_get, &get_me/1).(token)
  defp secrets_status(io), do: Map.get(io, :secrets_status, &Secrets.status/0).()
  defp secret_get(io, key), do: Map.get(io, :secret_get, &Secrets.get/1).(key)

  defp secret_set(io, key, token),
    do: Map.get(io, :secret_set, &Secrets.set(&1, &2, [])).(key, token)

  defp get_me(token) do
    ssl_opts = [verify: :verify_peer] |> maybe_put_cacerts()
    headers = [{~c"authorization", ~c"Bot #{token}"}]

    case Httpc.request(:get, {@discord_api, headers}, [{:ssl, ssl_opts}, {:timeout, 5_000}], []) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> parse_username(body)
      {:ok, {{_version, 401, _reason}, _headers, _body}} -> {:error, :unauthorized}
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_username(body) when is_list(body), do: parse_username(List.to_string(body))

  defp parse_username(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"username" => username}} when is_binary(username) -> {:ok, username}
      _ -> {:ok, "unknown"}
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

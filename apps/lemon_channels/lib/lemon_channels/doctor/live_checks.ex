defmodule LemonChannels.Doctor.LiveChecks do
  @moduledoc "Non-mutating bot identity probes; no message is sent to a channel."

  alias LemonCore.Config
  alias LemonCore.Doctor.{Check, Connectivity}
  alias LemonCore.Secrets

  @spec jobs(keyword()) :: [LemonCore.Doctor.LiveChecks.job()]
  def jobs(opts) do
    [
      {"channels.live",
       fn ->
         Check.skip("channels.live", "Other channels skipped (no non-generating endpoint).")
       end}
      | Enum.map([:telegram, :discord], fn channel ->
          {"channels.#{channel}.live", fn -> check(channel, opts) end}
        end)
    ]
  end

  defp check(channel, opts) do
    config =
      Keyword.get(opts, :config) ||
        Config.load(Keyword.get(opts, :project_dir, File.cwd!()), cache: false)

    gateway = config.gateway || %{}
    settings = Map.get(gateway, channel, %{}) || %{}
    name = "channels.#{channel}.live"

    if Map.get(gateway, enabled_key(channel)) == true do
      case token(settings, channel) do
        token when is_binary(token) and token != "" -> probe(channel, token, name, opts)
        _ -> Check.skip(name, "Skipped (no usable bot credential).")
      end
    else
      Check.skip(name, "Skipped (channel is disabled).")
    end
  rescue
    _ -> Check.fail("channels.#{channel}.live", "Channel live check could not complete.")
  end

  defp enabled_key(:telegram), do: :enable_telegram
  defp enabled_key(:discord), do: :enable_discord

  defp token(settings, channel) do
    settings[:bot_token] || settings[:token] ||
      secret(settings[:bot_token_secret]) || ambient_token(channel)
  end

  defp secret(name) when is_binary(name) and name != "", do: Secrets.fetch_value(name)
  defp secret(_), do: nil
  defp ambient_token(:discord), do: Secrets.fetch_value("DISCORD_BOT_TOKEN")
  defp ambient_token(:telegram), do: nil

  defp probe(channel, token, name, opts) do
    {url, headers} = endpoint(channel, token)

    case Connectivity.get(url, headers, opts) do
      {:ok, %{body: body}} -> identity(channel, body, name, token)
      {:error, reason} -> Check.fail(name, failure_message(reason))
    end
  end

  defp endpoint(:telegram, token), do: {"https://api.telegram.org/bot#{token}/getMe", %{}}

  defp endpoint(:discord, token),
    do: {"https://discord.com/api/v10/users/@me", %{"authorization" => "Bot " <> token}}

  defp identity(channel, body, name, token) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(body),
         %{"username" => username} <- identity_payload(channel, decoded),
         true <- is_binary(username) and Regex.match?(~r/\A[A-Za-z0-9_.]{1,64}\z/, username) do
      username = String.replace(username, token, "[REDACTED]")
      Check.pass(name, "Bot identity verified: @#{username}")
    else
      _ -> Check.fail(name, "Unexpected bot identity response.")
    end
  end

  defp identity_payload(:telegram, %{"ok" => true, "result" => result}), do: result
  defp identity_payload(:telegram, _), do: nil
  defp identity_payload(:discord, decoded), do: decoded

  defp failure_message(:unauthorized),
    do: "The channel rejected the bot credential (HTTP 401/403)."

  defp failure_message(:timeout), do: "The channel identity endpoint timed out."
  defp failure_message(:unreachable), do: "Could not reach the channel identity endpoint."

  defp failure_message({:http_status, status}),
    do: "The channel identity endpoint returned HTTP #{status}."
end

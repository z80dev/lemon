defmodule LemonChannels.Adapters.Discord.Supervisor do
  @moduledoc """
  Supervisor for Discord adapter processes.

  Nostrum 0.10.x reads token and intents only from application configuration.
  Configure it once here at adapter boot, then supervise its included-application
  tree directly. Discord supports one account per node with this version;
  upstream `Nostrum.Bot` would remove that limitation.
  """

  use Supervisor

  require Logger

  alias LemonCore.Secrets

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    explicit = Keyword.get(opts, :config)
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}
    config = merge_config(base, explicit)

    token = config[:bot_token] || config["bot_token"] || secret_or_ambient_token(config)

    children =
      if is_binary(token) and String.trim(token) != "" do
        Application.put_env(:nostrum, :token, token)

        Application.put_env(:nostrum, :gateway_intents, [
          :guilds,
          :guild_messages,
          :guild_message_reactions,
          :direct_messages,
          :direct_message_reactions,
          :message_content
        ])

        [
          Nostrum.Application,
          LemonCore.TaskSupervisor.child_spec(
            name: LemonChannels.Adapters.Discord.AsyncSupervisor
          ),
          # Read persisted allowlists afresh on every transport restart.
          {LemonChannels.Adapters.Discord.Transport, [config: merge_config(%{}, explicit)]},
          LemonChannels.Adapters.Discord.Transport.Consumer
        ]
      else
        []
      end

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp merge_config(base, opts), do: LemonCore.MapHelpers.merge_config(base, opts)

  # Only a definite miss (or no configured secret) may fall through to the
  # ambient DISCORD_BOT_TOKEN; any other resolution failure yields no token.
  defp secret_or_ambient_token(config) do
    case resolve_bot_token_secret(config) do
      {:ok, token} ->
        token

      :not_found ->
        resolve_token()

      {:error, reason} ->
        Logger.error("discord bot_token_secret could not be resolved: #{inspect(reason)}")
        nil
    end
  end

  defp resolve_bot_token_secret(config) do
    secret_name = config[:bot_token_secret] || config["bot_token_secret"]

    if is_binary(secret_name) and secret_name != "" do
      case Secrets.resolve(secret_name) do
        {:ok, value, _source} -> {:ok, value}
        {:error, :not_found} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    else
      :not_found
    end
  rescue
    error -> {:error, {:exception, error.__struct__}}
  catch
    :exit, _ -> {:error, :resolution_exit}
  end

  defp resolve_token do
    # Store, then external sources, then the DISCORD_BOT_TOKEN env var; a
    # store or source failure yields no token rather than the env value.
    Secrets.fetch_value("DISCORD_BOT_TOKEN")
  end
end

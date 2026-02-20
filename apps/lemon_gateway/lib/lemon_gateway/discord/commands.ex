defmodule LemonGateway.Discord.Commands do
  @moduledoc false

  require Logger
  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Api.Interaction

  @lemon_command %{
    name: "lemon",
    description: "Run a Lemon prompt",
    type: 1,
    options: [
      %{
        type: 3,
        name: "prompt",
        description: "Prompt text",
        required: true
      },
      %{
        type: 3,
        name: "engine",
        description: "Optional engine override",
        required: false
      }
    ]
  }

  @session_command %{
    name: "session",
    description: "Session controls",
    type: 1,
    options: [
      %{
        type: 1,
        name: "new",
        description: "Start a new session"
      },
      %{
        type: 1,
        name: "info",
        description: "Show session key"
      }
    ]
  }

  @spec register_slash_commands() :: :ok
  def register_slash_commands do
    for command <- [@lemon_command, @session_command] do
      case safe_create_command(command) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("discord command registration failed: #{inspect(reason)}")
      end
    end

    :ok
  end

  @spec handle_interaction(map(), module()) :: :ok
  def handle_interaction(interaction, transport_mod) when is_map(interaction) do
    name = get_in(interaction, [:data, :name]) || get_in(interaction, ["data", "name"])

    case name do
      "lemon" ->
        prompt = option_value(interaction, "prompt")
        engine = option_value(interaction, "engine")

        transport_mod.submit_slash_prompt(interaction, prompt, engine)

      "session" ->
        case session_subcommand(interaction) do
          "new" -> transport_mod.handle_session_new(interaction)
          "info" -> transport_mod.handle_session_info(interaction)
          _ -> reply(interaction, "Unknown /session subcommand", ephemeral: true)
        end

      _ ->
        reply(interaction, "Unknown command", ephemeral: true)
    end

    :ok
  end

  @spec reply(map(), String.t(), keyword()) :: :ok
  def reply(interaction, content, opts \\ []) do
    data = %{
      content: content,
      flags: if(Keyword.get(opts, :ephemeral, false), do: 64, else: 0)
    }

    payload = %{type: 4, data: data}

    case Interaction.create_response(interaction, payload) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("discord interaction response failed: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("discord interaction response crashed: #{inspect(error)}")
      :ok
  end

  defp safe_create_command(command) do
    case ApplicationCommand.create_global_command(command) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  rescue
    error -> {:error, error}
  end

  defp option_value(interaction, option_name) do
    options =
      get_in(interaction, [:data, :options]) || get_in(interaction, ["data", "options"]) || []

    options
    |> Enum.find(fn option ->
      (option[:name] || option["name"]) == option_name
    end)
    |> case do
      nil -> nil
      option -> option[:value] || option["value"]
    end
  end

  defp session_subcommand(interaction) do
    options =
      get_in(interaction, [:data, :options]) || get_in(interaction, ["data", "options"]) || []

    case List.first(options) do
      nil -> nil
      option -> option[:name] || option["name"]
    end
  end
end

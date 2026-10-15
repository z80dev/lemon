defmodule CodingAgent.Tools.Checkpoint do
  @moduledoc "Conversation-only exploration checkpoints, paired with `rewind`."

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  def available?(opts) do
    settings =
      Keyword.get(opts, :settings_manager) ||
        CodingAgent.SettingsManager.load(Keyword.get(opts, :cwd, File.cwd!()))

    tools = Map.get(settings, :tools, %{})
    section = Map.get(tools, :checkpoint, Map.get(tools, "checkpoint", %{}))
    enabled = Map.get(section, :enabled, Map.get(section, "enabled", false))
    requested = Keyword.get(opts, :enabled_only) || []

    enabled == true and is_pid(Keyword.get(opts, :session_pid)) and
      (Keyword.get(opts, :session_scope, :main) == :main or
         Enum.any?(requested, &(&1 in ["checkpoint", "rewind"])))
  end

  def tool(_cwd, opts \\ []) do
    definition(
      "checkpoint",
      "goal",
      "Mark the current conversation before exploration. Finish with rewind(report); this does not snapshot files.",
      opts
    )
  end

  def definition(name, argument, description, opts) do
    %AgentTool{
      name: name,
      label: String.capitalize(name),
      description: description,
      parameters: %{
        "type" => "object",
        "properties" => %{argument => %{"type" => "string"}},
        "required" => [argument]
      },
      execute: fn id, params, signal, _on_update ->
        if LemonAgent.AbortSignal.aborted?(signal) do
          {:error, "Canceled"}
        else
          execute(name, id, params[argument], opts)
        end
      end
    }
  end

  defp execute(name, id, value, opts) when is_binary(value) do
    case Keyword.get(opts, :session_pid) do
      pid when is_pid(pid) ->
        case GenServer.call(pid, {:context_checkpoint, name, id, value}, :infinity) do
          {:ok, details} ->
            text =
              if name == "checkpoint",
                do:
                  "Checkpoint: #{value}\nFinish exploration, then call rewind with your findings.",
                else:
                  "Rewind requested. Continue from the retained report; do not rewind this checkpoint again."

            %AgentToolResult{content: [%TextContent{text: text}], details: details}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, "No session is bound to this tool."}
    end
  end

  defp execute(_name, _id, _value, _opts), do: {:error, "Expected a string."}
end

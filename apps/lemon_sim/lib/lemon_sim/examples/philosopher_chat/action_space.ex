defmodule LemonSim.Examples.PhilosopherChat.ActionSpace do
  @moduledoc false

  @behaviour LemonSim.Kernel.ActionSpace

  import LemonSim.Examples.Helpers

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Examples.PhilosopherChat.{Events, Persona}
  alias LemonSim.Kernel.State
  alias LemonSim.LLM.Memory.Tools, as: MemoryTools

  @max_message_chars 1400

  @impl true
  def tools(%State{} = state, opts) do
    world = state.world
    actor_id = get(world, :active_actor_id)
    status = get(world, :status, "active")
    members = get(world, :members, [])

    cond do
      status != "active" ->
        {:ok, []}

      not is_binary(actor_id) or actor_id == "you" or actor_id not in members ->
        {:ok, []}

      true ->
        speak = speak_tool(actor_id, members)
        memory = memory_tools(opts, world, actor_id)
        {:ok, [speak | memory]}
    end
  end

  defp speak_tool(actor_id, members) do
    others =
      members
      |> Enum.reject(&(&1 in ["you", actor_id]))
      |> Enum.map(&display_name/1)
      |> Enum.join(", ")

    %AgentTool{
      name: "speak",
      label: "Speak",
      description:
        "Say something in the group conversation. React to what was just said, " <>
          "address someone by name, or raise a new thought. Keep it conversational: " <>
          "typically 1-4 sentences, in your own voice. This is how you post a visible " <>
          "message to the thread - every turn should end with a speak call." <>
          if(others != "", do: " Others present: #{others}.", else: ""),
      parameters: %{
        "type" => "object",
        "properties" => %{
          "message" => %{
            "type" => "string",
            "description" =>
              "Your message text (max #{@max_message_chars} characters). 1-4 sentences."
          }
        },
        "required" => ["message"],
        "additionalProperties" => false
      },
      execute: fn _tool_call_id, params, _signal, _on_update ->
        message = Map.get(params, "message", Map.get(params, :message, ""))

        cond do
          not is_binary(message) or String.trim(message) == "" ->
            {:error, "Message must not be empty"}

          true ->
            # Truncate instead of failing the whole turn. Byte-budget-aware so
            # the updater's :message_too_long backstop never trips on the
            # truncated text (the "…" must fit inside the limit).
            message = truncate_message(message)

            {:ok,
             %AgentToolResult{
               content: [LemonAgent.text_content("You said: #{message}")],
               details: %{"event" => Events.message_posted(actor_id, message)},
               trust: :trusted
             }}
        end
      end
    }
  end

  defp truncate_message(message) when byte_size(message) <= @max_message_chars, do: message

  defp truncate_message(message) do
    ellipsis = "…"
    budget = @max_message_chars - byte_size(ellipsis)

    {kept, _size} =
      message
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn cp, {acc, size} ->
        cp_size = byte_size(cp)

        if size + cp_size <= budget do
          {:cont, {[cp | acc], size + cp_size}}
        else
          {:halt, {acc, size}}
        end
      end)

    kept |> Enum.reverse() |> IO.iodata_to_binary() |> Kernel.<>(ellipsis)
  end

  defp memory_tools(opts, world, actor_id) do
    thread_id = get(world, :thread_id, "thread")
    memory_root = Keyword.get(opts, :memory_root)
    base_namespace = Keyword.get(opts, :memory_namespace, "")

    cond do
      is_nil(memory_root) ->
        []

      base_namespace != "" ->
        MemoryTools.build(
          memory_root: memory_root,
          memory_namespace: "#{base_namespace}/#{actor_id}"
        )

      true ->
        MemoryTools.build(memory_root: memory_root, memory_namespace: "#{thread_id}/#{actor_id}")
    end
  end

  defp display_name(id) do
    case Persona.get(id) do
      %Persona{name: name} -> name
      nil -> id
    end
  end
end

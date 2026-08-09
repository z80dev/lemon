defmodule LemonSim.Examples.PhilosopherChat.Updater do
  @moduledoc false

  @behaviour LemonSim.Kernel.Updater

  import LemonSim.Examples.Helpers

  alias LemonSim.Examples.PhilosopherChat, as: Domain
  alias LemonSim.Kernel.State

  @max_message_chars 1400
  @max_world_messages 2_000

  @impl true
  def apply_event(%State{} = state, event, _opts) do
    case event.kind do
      "message_posted" -> apply_message_posted(state, event)
      "status_changed" -> apply_status_changed(state, event)
      _ -> {:error, {:unknown_event, event.kind}}
    end
  end

  defp apply_message_posted(state, event) do
    author = fetch(event.payload, :author, "author", "")
    text = fetch(event.payload, :text, "text", "")
    world = state.world
    members = get(world, :members, [])
    status = get(world, :status, "active")

    with :ok <- ensure_status(status),
         :ok <- ensure_member(author, members),
         :ok <- ensure_text(text) do
      seq = get(world, :next_seq, 1)
      messages = get(world, :messages, [])

      at_ms = event.ts_ms

      message = %{
        seq: seq,
        author: author,
        text: text,
        at_ms: at_ms
      }

      world =
        world
        |> Map.put(:messages, Enum.take(messages ++ [message], -@max_world_messages))
        |> Map.put(:next_seq, seq + 1)
        |> Map.put(:last_author, author)

      world =
        if author != Domain.user_id() do
          Map.put(world, :last_agent_at_ms, at_ms)
        else
          world
        end

      next_state = state |> State.put_world(world) |> State.append_event(event)
      {:ok, next_state, :skip}
    end
  end

  defp apply_status_changed(state, event) do
    status = fetch(event.payload, :status, "status", "active")

    if status in ["active", "paused", "closed"] do
      world = Map.put(state.world, :status, status)
      next_state = state |> State.put_world(world) |> State.append_event(event)
      {:ok, next_state, :skip}
    else
      {:error, {:invalid_status, status}}
    end
  end

  defp ensure_status("active"), do: :ok
  defp ensure_status(_), do: {:error, :thread_not_active}

  defp ensure_member(author, members) when is_list(members) do
    if author in members or author == Domain.user_id(), do: :ok, else: {:error, :not_a_member}
  end

  defp ensure_member(_, _), do: {:error, :not_a_member}

  defp ensure_text(text) when is_binary(text) do
    cond do
      String.trim(text) == "" -> {:error, :empty_message}
      byte_size(text) > @max_message_chars -> {:error, :message_too_long}
      true -> :ok
    end
  end

  defp ensure_text(_), do: {:error, :invalid_message}
end

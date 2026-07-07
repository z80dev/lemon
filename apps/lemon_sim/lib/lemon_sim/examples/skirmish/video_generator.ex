defmodule LemonSim.Examples.Skirmish.VideoGenerator do
  @moduledoc false

  alias LemonSim.Examples.Skirmish.{FrameRenderer, GameLog}

  use LemonSim.Examples.Rendering.DomainVideoGenerator,
    frame_renderer: FrameRenderer,
    dir_name: "lemon_replay",
    read_entries: &GameLog.read_log/1

  defp hold_count_for(entry, base_hold) do
    type = entry_type(entry)

    multiplier =
      cond do
        type == "init" -> 3
        type == "game_over" -> 5
        has_attack_or_kill?(entry) -> 2
        true -> 1
      end

    base_hold * multiplier
  end

  defp entry_type(%{"type" => type}), do: type
  defp entry_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp entry_type(%{type: type}) when is_binary(type), do: type
  defp entry_type(_), do: "step"

  defp has_attack_or_kill?(%{"events" => events}) when is_list(events) do
    Enum.any?(events, fn
      %{"type" => type} -> type in ["attack", "kill"]
      %{type: type} when is_atom(type) -> type in [:attack, :kill]
      %{type: type} when is_binary(type) -> type in ["attack", "kill"]
      _ -> false
    end)
  end

  defp has_attack_or_kill?(%{events: events}) when is_list(events) do
    has_attack_or_kill?(%{"events" => events})
  end

  defp has_attack_or_kill?(_), do: false
end

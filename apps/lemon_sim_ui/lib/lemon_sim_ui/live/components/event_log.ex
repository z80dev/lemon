defmodule LemonSimUi.Live.Components.EventLog do
  use Phoenix.Component

  attr :events, :list, required: true

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <h3 class="text-sm font-semibold text-gray-300 mb-2">Event Log</h3>
      <div id="event-log-scroll" phx-hook="ScrollBottom" class="scroll-bottom flex-1 space-y-1 max-h-80 pr-1">
        <div :if={@events == []} class="text-xs text-gray-600 italic">No events yet</div>
        <%= for {event, idx} <- Enum.with_index(@events) do %>
          <div class={["text-xs rounded px-2 py-1 font-mono", event_class(event.kind)]}>
            <span class="text-gray-600">{idx + 1}.</span>
            <span class="font-semibold">{format_kind(event.kind)}</span>
            <span :if={event.payload != %{}} class="text-gray-500 ml-1">
              {format_payload(event.payload)}
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp format_kind(kind) when is_binary(kind), do: kind
  defp format_kind(_), do: "event"

  defp format_payload(payload) when map_size(payload) == 0, do: ""

  defp format_payload(payload) do
    payload
    |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
    |> Enum.join(" ")
    |> String.slice(0, 120)
  end

  defp event_class(kind) do
    kind_str = if is_atom(kind), do: Atom.to_string(kind), else: to_string(kind)

    cond do
      String.contains?(kind_str, "move") -> "bg-emerald-950/50 text-emerald-300"
      String.contains?(kind_str, "attack") -> "bg-red-950/50 text-red-300"
      String.contains?(kind_str, "damage") -> "bg-orange-950/50 text-orange-300"
      String.contains?(kind_str, "died") or String.contains?(kind_str, "dead") -> "bg-red-950/70 text-red-200"
      String.contains?(kind_str, "rejected") -> "bg-amber-950/50 text-amber-300"
      String.contains?(kind_str, "cover") -> "bg-sky-950/50 text-sky-300"
      String.contains?(kind_str, "turn") or String.contains?(kind_str, "round") -> "bg-gray-800/50 text-gray-400"
      String.contains?(kind_str, "game_over") -> "bg-purple-950/50 text-purple-300"
      String.contains?(kind_str, "place_mark") -> "bg-blue-950/50 text-blue-300"
      true -> "bg-gray-800/30 text-gray-400"
    end
  end
end

defmodule LemonSimUi.Live.Components.EventLog do
  use Phoenix.Component

  attr :events, :list, required: true

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full font-mono">
      <div id="event-log-scroll" phx-hook="ScrollBottom" class="scroll-bottom flex-1 space-y-1.5 max-h-80 pr-2">
        <div :if={@events == []} class="text-xs text-slate-600 italic px-3 pt-2">No events generated</div>
        <%= for {event, idx} <- Enum.with_index(@events) do %>
          <div class={["text-[11px] rounded border px-3 py-2 flex gap-2 items-start stagger-enter backdrop-blur-sm", event_class(event.kind)]}>
            <span class="text-slate-600 font-bold opacity-50 shrink-0 w-6">[{idx + 1}]</span>
            <div class="flex items-center gap-1.5 flex-wrap">
              <span :if={event_icon(event.kind)} class="text-sm shrink-0">{event_icon(event.kind)}</span>
              <span class="font-extrabold tracking-wide uppercase drop-shadow-sm">{format_kind(event.kind)}</span>
              <span :if={event.payload != %{}} class="opacity-80">
                {format_payload(event.kind, event.payload)}
              </span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp format_kind(kind) when is_binary(kind), do: kind
  defp format_kind(_), do: "event"

  # Werewolf-specific formatting
  defp format_payload(kind, payload) do
    kind_str = if is_atom(kind), do: Atom.to_string(kind), else: to_string(kind)

    formatted =
      case kind_str do
        "make_statement" ->
          player = Map.get(payload, "player_id") || Map.get(payload, :player_id, "?")
          stmt = Map.get(payload, "statement") || Map.get(payload, :statement, "")
          "#{player}: \"#{String.slice(stmt, 0, 80)}#{if String.length(stmt) > 80, do: "...", else: ""}\""

        "cast_vote" ->
          voter = Map.get(payload, "player_id") || Map.get(payload, :player_id, "?")
          target = Map.get(payload, "target_id") || Map.get(payload, :target_id, "?")
          "#{voter} -> #{target}"

        "choose_victim" ->
          wolf = Map.get(payload, "player_id") || Map.get(payload, :player_id, "?")
          victim = Map.get(payload, "victim_id") || Map.get(payload, :victim_id, "?")
          "#{wolf} targets #{victim}"

        "night_resolved" ->
          Map.get(payload, "message") || Map.get(payload, :message, "")

        "player_eliminated" ->
          Map.get(payload, "message") || Map.get(payload, :message, "")

        "vote_result" ->
          Map.get(payload, "message") || Map.get(payload, :message, "")

        "phase_changed" ->
          Map.get(payload, "message") || Map.get(payload, :message, "")

        "game_over" ->
          Map.get(payload, "message") || Map.get(payload, :message, "")

        "investigate_player" ->
          seer = Map.get(payload, "player_id") || Map.get(payload, :player_id, "?")
          target = Map.get(payload, "target_id") || Map.get(payload, :target_id, "?")
          "#{seer} investigates #{target}"

        "investigation_result" ->
          target = Map.get(payload, "target_id") || Map.get(payload, :target_id, "?")
          role = Map.get(payload, "role") || Map.get(payload, :role, "?")
          "#{target} is #{role}"

        "protect_player" ->
          doc = Map.get(payload, "player_id") || Map.get(payload, :player_id, "?")
          target = Map.get(payload, "target_id") || Map.get(payload, :target_id, "?")
          "#{doc} protects #{target}"

        _ ->
          payload
          |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
          |> Enum.join(" ")
          |> String.slice(0, 120)
      end

    formatted
  end

  defp event_icon(kind) do
    kind_str = if is_atom(kind), do: Atom.to_string(kind), else: to_string(kind)

    case kind_str do
      "choose_victim" -> nil
      "investigate_player" -> nil
      "investigation_result" -> nil
      "protect_player" -> nil
      "sleep" -> nil
      "make_statement" -> nil
      "cast_vote" -> nil
      "night_resolved" -> nil
      "player_eliminated" -> nil
      "vote_result" -> nil
      "phase_changed" -> nil
      "game_over" -> nil
      _ -> nil
    end
  end

  defp event_class(kind) do
    kind_str = if is_atom(kind), do: Atom.to_string(kind), else: to_string(kind)

    case kind_str do
      # Werewolf events
      "choose_victim" -> "text-red-400 border-red-500/30 bg-red-950/20"
      "investigate_player" -> "text-purple-300 border-purple-500/30 bg-purple-950/20"
      "investigation_result" -> "text-purple-400 border-purple-500/40 bg-purple-950/30"
      "protect_player" -> "text-emerald-300 border-emerald-500/30 bg-emerald-950/20"
      "sleep" -> "text-slate-500 border-slate-700 bg-slate-900/30"
      "make_statement" -> "text-amber-300 border-amber-500/20 bg-amber-950/10"
      "cast_vote" -> "text-rose-300 border-rose-500/30 bg-rose-950/20"
      "night_resolved" -> "text-blue-300 border-blue-500/30 bg-blue-950/20"
      "player_eliminated" -> "text-red-500 border-red-600/50 bg-red-950/30"
      "vote_result" -> "text-rose-400 border-rose-500/40 bg-rose-950/20"
      "phase_changed" -> "text-cyan-300 border-cyan-500/30 bg-cyan-950/10"
      "game_over" -> "text-fuchsia-400 border-fuchsia-500/40 bg-fuchsia-950/20"
      "action_rejected" -> "text-amber-500 border-amber-600/40 bg-amber-950/20"
      # Generic fallbacks
      _ ->
        cond do
          String.contains?(kind_str, "move") -> "text-emerald-300 border-emerald-500/30"
          String.contains?(kind_str, "attack") -> "text-red-400 border-red-500/40 bg-red-950/20"
          String.contains?(kind_str, "damage") -> "text-amber-400 border-amber-500/30"
          String.contains?(kind_str, "died") or String.contains?(kind_str, "dead") -> "text-red-500 border-red-600/50 bg-red-950/40"
          String.contains?(kind_str, "rejected") -> "text-amber-500 border-amber-600/40"
          String.contains?(kind_str, "cover") -> "text-cyan-300 border-cyan-500/30"
          String.contains?(kind_str, "turn") or String.contains?(kind_str, "round") -> "text-slate-400 border-slate-700"
          String.contains?(kind_str, "game_over") -> "text-purple-400 border-purple-500/40 bg-purple-950/20"
          String.contains?(kind_str, "place_mark") -> "text-blue-300 border-blue-500/30"
          true -> "text-slate-400 border-glass-border bg-slate-900/60"
        end
    end
  end
end

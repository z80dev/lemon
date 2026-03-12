defmodule LemonSimUi.Live.Components.PlanHistory do
  use Phoenix.Component

  attr :plan_history, :list, required: true

  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full font-sans">
      <div :if={@plan_history == []} class="text-xs text-slate-600 italic">No plans recorded</div>
      <div class="space-y-2 max-h-60 overflow-y-auto pr-2 custom-scrollbar p-1">
        <%= for {step, idx} <- Enum.with_index(@plan_history) do %>
          <details class="group glass-card rounded-lg overflow-hidden border border-glass-border">
            <summary class="text-[11px] px-3 py-2 bg-slate-900/60 text-slate-300 cursor-pointer hover:bg-slate-800/80 hover:text-cyan-300 transition-colors font-semibold flex items-start gap-2 list-none">
              <span class="text-cyan-600 font-mono mt-0.5">[{idx + 1}]</span>
              <span class="flex-1 leading-snug">{format_summary(step)}</span>
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 text-slate-500 transform group-open:rotate-90 transition-transform flex-shrink-0" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M7.293 14.707a1 1 0 010-1.414L10.586 10 7.293 6.707a1 1 0 011.414-1.414l4 4a1 1 0 010 1.414l-4 4a1 1 0 01-1.414 0z" clip-rule="evenodd" />
              </svg>
            </summary>
            <div :if={format_rationale(step)} class="text-[11px] px-4 py-3 text-slate-400 bg-slate-950/80 border-t border-glass-border leading-relaxed font-mono">
              <div class="text-[9px] text-cyan-600 uppercase tracking-widest mb-1 font-bold">RATIONALE</div>
              {format_rationale(step)}
            </div>
          </details>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_summary(%{summary: s}) when is_binary(s) and s != "", do: s
  defp format_summary(%{"summary" => s}) when is_binary(s) and s != "", do: s
  defp format_summary(_), do: "Step"

  defp format_rationale(%{rationale: r}) when is_binary(r) and r != "", do: r
  defp format_rationale(%{"rationale" => r}) when is_binary(r) and r != "", do: r
  defp format_rationale(_), do: nil
end

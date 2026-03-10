defmodule LemonSimUi.Live.Components.PlanHistory do
  use Phoenix.Component

  attr :plan_history, :list, required: true

  def render(assigns) do
    ~H"""
    <div class="flex flex-col">
      <h3 class="text-sm font-semibold text-gray-300 mb-2">Plan History</h3>
      <div :if={@plan_history == []} class="text-xs text-gray-600 italic">No plans recorded</div>
      <div class="space-y-1 max-h-60 overflow-y-auto pr-1">
        <%= for {step, idx} <- Enum.with_index(@plan_history) do %>
          <details class="group">
            <summary class="text-xs px-2 py-1 rounded bg-gray-800/50 text-gray-300 cursor-pointer hover:bg-gray-700/50 transition">
              <span class="text-gray-600">{idx + 1}.</span>
              {format_summary(step)}
            </summary>
            <div :if={format_rationale(step)} class="text-xs px-3 py-1 text-gray-500 ml-4 border-l border-gray-800">
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

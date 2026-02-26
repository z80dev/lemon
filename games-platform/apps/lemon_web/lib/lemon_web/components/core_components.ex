defmodule LemonWeb.CoreComponents do
  @moduledoc """
  Shared, minimal function components.
  """

  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      class="inline-flex items-center justify-center rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-slate-700 disabled:cursor-not-allowed disabled:opacity-50"
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :type, :string, default: "text"
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      value={@value}
      class="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 outline-none ring-offset-1 transition focus:border-slate-500 focus:ring"
      {@rest}
    />
    """
  end

  attr :flash, :map, default: %{}

  def flash_group(assigns) do
    ~H"""
    <div class="space-y-2" role="status" aria-live="polite">
      <%= for {kind, msg} <- @flash do %>
        <p class={flash_class(kind)}>{msg}</p>
      <% end %>
    </div>
    """
  end

  defp flash_class(:error),
    do: "rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"

  defp flash_class(_),
    do: "rounded-lg border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-700"
end

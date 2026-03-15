defmodule LemonSimUi.CoreComponents do
  @moduledoc """
  Shared function components for LemonSim UI.
  """

  use Phoenix.Component

  attr :rest, :global
  attr :variant, :string, default: "primary"
  attr :size, :string, default: "md"
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      class={[
        "inline-flex items-center justify-center rounded-lg font-medium transition disabled:cursor-not-allowed disabled:opacity-50",
        button_variant(@variant),
        button_size(@size)
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_variant("primary"), do: "bg-blue-600 text-white hover:bg-blue-500"
  defp button_variant("danger"), do: "bg-red-600 text-white hover:bg-red-500"
  defp button_variant("ghost"), do: "bg-gray-800 text-gray-300 hover:bg-gray-700 hover:text-white"
  defp button_variant(_), do: "bg-gray-700 text-gray-200 hover:bg-gray-600"

  defp button_size("sm"), do: "px-3 py-1.5 text-xs"
  defp button_size("md"), do: "px-4 py-2 text-sm"
  defp button_size("lg"), do: "px-5 py-2.5 text-base"
  defp button_size(_), do: "px-4 py-2 text-sm"

  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :type, :string, default: "text"
  attr :label, :string, default: nil
  attr :min, :any, default: nil
  attr :max, :any, default: nil
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div>
      <label :if={@label} class="block text-xs font-medium text-gray-400 mb-1">{@label}</label>
      <input
        type={@type}
        name={@name}
        value={@value}
        min={@min}
        max={@max}
        class="w-full rounded-lg border border-gray-700 bg-gray-800 px-3 py-2 text-sm text-gray-100 outline-none transition focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        {@rest}
      />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :string, default: ""
  attr :options, :list, required: true
  attr :label, :string, default: nil
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <div>
      <label :if={@label} class="block text-xs font-medium text-gray-400 mb-1">{@label}</label>
      <select
        name={@name}
        class="w-full rounded-lg border border-gray-700 bg-gray-800 px-3 py-2 text-sm text-gray-100 outline-none transition focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
        {@rest}
      >
        <%= for {label, val} <- @options do %>
          <option value={val} selected={val == @value}>{label}</option>
        <% end %>
      </select>
    </div>
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
    do: "rounded-lg border border-red-800 bg-red-950 px-3 py-2 text-sm text-red-300"

  defp flash_class(_),
    do: "rounded-lg border border-emerald-800 bg-emerald-950 px-3 py-2 text-sm text-emerald-300"
end

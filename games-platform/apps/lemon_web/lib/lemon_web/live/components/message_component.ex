defmodule LemonWeb.Live.Components.MessageComponent do
  @moduledoc false

  use Phoenix.Component

  alias LemonWeb.Live.Components.ToolCallComponent

  attr :message, :map, required: true

  def message(assigns) do
    assigns =
      assigns
      |> assign(:container_class, container_class(assigns.message))
      |> assign(:bubble_class, bubble_class(assigns.message))

    ~H"""
    <div class={@container_class}>
      <%= if @message.kind == :tool_call do %>
        <ToolCallComponent.tool_call event={@message.event} />
      <% else %>
        <div class={@bubble_class}>
          <p class="whitespace-pre-wrap break-words text-sm leading-relaxed">{@message.content}</p>
          <%= if @message.kind == :assistant and Map.get(@message, :pending, false) do %>
            <p class="mt-2 text-[11px] uppercase tracking-wide text-slate-400">streaming</p>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp container_class(%{kind: :user}), do: "flex justify-end"
  defp container_class(%{kind: :assistant}), do: "flex justify-start"
  defp container_class(%{kind: :tool_call}), do: "flex justify-start"
  defp container_class(_), do: "flex justify-center"

  defp bubble_class(%{kind: :user}) do
    "max-w-[90%] rounded-2xl rounded-br-md bg-slate-900 px-4 py-3 text-slate-100 shadow sm:max-w-[75%]"
  end

  defp bubble_class(%{kind: :assistant}) do
    "max-w-[90%] rounded-2xl rounded-bl-md border border-slate-200 bg-white px-4 py-3 text-slate-900 shadow-sm sm:max-w-[75%]"
  end

  defp bubble_class(_) do
    "max-w-full rounded-xl border border-slate-200 bg-slate-50 px-3 py-2 text-slate-700"
  end
end

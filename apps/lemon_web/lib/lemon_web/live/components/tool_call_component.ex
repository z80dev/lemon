defmodule LemonWeb.Live.Components.ToolCallComponent do
  @moduledoc false

  use Phoenix.Component

  alias LemonCore.MapHelpers

  attr(:event, :map, required: true)

  def tool_call(assigns) do
    action = read(assigns.event, :action) || %{}
    phase = read(assigns.event, :phase) || "updated"

    assigns =
      assigns
      |> assign(:title, read(action, :title) || read(action, :kind) || "Tool call")
      |> assign(:detail, format_payload(read(action, :detail)))
      |> assign(:phase, phase)
      |> assign(:phase_label, to_string(phase))
      |> assign(:ok, read(assigns.event, :ok))
      |> assign(:message, format_payload(read(assigns.event, :message)))
      |> assign(:open?, phase in ["started", :started, "updated", :updated])

    ~H"""
    <details class="rounded-xl border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900" open={@open?}>
      <summary class="cursor-pointer list-none">
        <div class="flex items-center justify-between gap-2">
          <p class="font-semibold">{@title}</p>
          <p class="text-xs uppercase tracking-wide text-amber-700">{@phase_label}</p>
        </div>
      </summary>
      <%= if is_binary(@detail) and @detail != "" do %>
        <pre class="mt-2 overflow-x-auto whitespace-pre-wrap rounded-lg bg-white/70 p-2 text-xs text-amber-950">{@detail}</pre>
      <% end %>
      <%= if is_binary(@message) and @message != "" do %>
        <pre class="mt-2 overflow-x-auto whitespace-pre-wrap rounded-lg bg-white/60 p-2 text-xs text-amber-900">{@message}</pre>
      <% end %>
      <%= if is_boolean(@ok) do %>
        <p class="mt-2 text-xs text-amber-700">status: <%= if @ok, do: "ok", else: "failed" %></p>
      <% end %>
    </details>
    """
  end

  defp read(map, key), do: MapHelpers.get_key(map, key)

  defp format_payload(nil), do: nil
  defp format_payload(value) when is_binary(value), do: value

  defp format_payload(value) when is_map(value) or is_list(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} ->
        encoded

      {:error, _reason} ->
        inspect(value, pretty: true, printable_limit: :infinity)
    end
  end

  defp format_payload(value), do: inspect(value, pretty: true, printable_limit: :infinity)
end

defmodule LemonWeb.Live.Components.FileUploadComponent do
  @moduledoc false

  use Phoenix.Component

  attr(:upload, :map, required: true)

  def file_upload(assigns) do
    ~H"""
    <div class="rounded-xl border border-slate-200 bg-slate-50 p-3">
      <p class="text-xs font-medium uppercase tracking-wide text-slate-500">Attachments</p>
      <div class="mt-2 rounded-lg border border-dashed border-slate-300 bg-white p-3">
        <.live_file_input upload={@upload} class="w-full text-sm text-slate-700" />
      </div>

      <%= if @upload.entries != [] do %>
        <ul class="mt-3 space-y-2">
          <%= for entry <- @upload.entries do %>
            <li class="rounded-lg border border-slate-200 bg-white px-3 py-2">
              <div class="flex items-center justify-between gap-3 text-xs text-slate-600">
                <span class="truncate">{entry.client_name}</span>
                <div class="flex items-center gap-3">
                  <span>{entry.progress}%</span>
                  <button
                    type="button"
                    phx-click="cancel-upload"
                    phx-value-ref={entry.ref}
                    class="rounded border border-slate-300 px-2 py-0.5 text-[11px] text-slate-700 transition hover:bg-slate-100"
                  >
                    Cancel
                  </button>
                </div>
              </div>
              <progress class="mt-2 h-1 w-full" max="100" value={entry.progress}>{entry.progress}%</progress>
              <%= for error <- upload_errors(@upload, entry) do %>
                <p class="mt-1 text-xs text-rose-600">{error_to_string(error)}</p>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>

      <%= for error <- upload_errors(@upload) do %>
        <p class="mt-2 text-xs text-rose-600">{error_to_string(error)}</p>
      <% end %>
    </div>
    """
  end

  defp error_to_string(:too_large), do: "File is too large"
  defp error_to_string(:too_many_files), do: "Too many files selected"
  defp error_to_string(:not_accepted), do: "File type is not accepted"
  defp error_to_string(other), do: "Upload failed: #{inspect(other)}"
end

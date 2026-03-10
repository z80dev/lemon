defmodule LemonSimUi.Live.Components.MemoryViewer do
  use Phoenix.Component

  attr :sim_id, :string, required: true

  def render(assigns) do
    root = LemonSim.Memory.Tools.memory_root(memory_namespace: assigns.sim_id)
    files = list_memory_files(root)

    assigns = assign(assigns, :files, files)

    ~H"""
    <div class="flex flex-col">
      <h3 class="text-sm font-semibold text-gray-300 mb-2">Memory Files</h3>
      <div :if={@files == []} class="text-xs text-gray-600 italic">No memory files</div>
      <div class="space-y-2 max-h-60 overflow-y-auto pr-1">
        <%= for {path, content} <- @files do %>
          <details class="group">
            <summary class="text-xs px-2 py-1 rounded bg-gray-800/50 text-gray-300 cursor-pointer hover:bg-gray-700/50 transition font-mono">
              {path}
            </summary>
            <pre class="text-xs px-3 py-2 text-gray-500 bg-gray-900/50 rounded-b overflow-x-auto max-h-32 overflow-y-auto">{content}</pre>
          </details>
        <% end %>
      </div>
    </div>
    """
  end

  defp list_memory_files(root) do
    if File.dir?(root) do
      root
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.take(20)
      |> Enum.map(fn abs_path ->
        rel_path = Path.relative_to(abs_path, root)
        content = File.read!(abs_path) |> String.slice(0, 4096)
        {rel_path, content}
      end)
    else
      []
    end
  end
end

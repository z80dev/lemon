defmodule LemonSimUi.Live.Components.MemoryViewer do
  use Phoenix.Component

  attr :sim_id, :string, required: true

  def render(assigns) do
    root = LemonSim.Memory.Tools.memory_root(memory_namespace: assigns.sim_id)
    files = list_memory_files(root)

    assigns = assign(assigns, :files, files)

    ~H"""
    <div class="flex flex-col h-full">
      <div :if={@files == []} class="text-xs text-slate-600 italic font-mono">NO_MEMORY_BANKS_FOUND</div>
      <div class="space-y-2 max-h-60 overflow-y-auto pr-2 custom-scrollbar p-1">
        <%= for {path, content} <- @files do %>
          <details class="group glass-card rounded-lg overflow-hidden border border-glass-border">
            <summary class="text-[11px] px-3 py-2 bg-slate-900/60 text-purple-300 cursor-pointer hover:bg-slate-800/80 transition-colors font-mono flex items-center justify-between list-none">
              <div class="flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-3.5 w-3.5 text-slate-500" viewBox="0 0 20 20" fill="currentColor">
                  <path fill-rule="evenodd" d="M4 4a2 2 0 012-2h4.586A2 2 0 0112 2.586L15.414 6A2 2 0 0116 7.414V16a2 2 0 01-2 2H6a2 2 0 01-2-2V4zm2 6a1 1 0 011-1h6a1 1 0 110 2H7a1 1 0 01-1-1zm1 3a1 1 0 100 2h6a1 1 0 100-2H7z" clip-rule="evenodd" />
                </svg>
                {path}
              </div>
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 text-slate-500 transform group-open:rotate-180 transition-transform flex-shrink-0" viewBox="0 0 20 20" fill="currentColor">
                <path fill-rule="evenodd" d="M5.293 7.293a1 1 0 011.414 0L10 10.586l3.293-3.293a1 1 0 111.414 1.414l-4 4a1 1 0 01-1.414 0l-4-4a1 1 0 010-1.414z" clip-rule="evenodd" />
              </svg>
            </summary>
            <pre class="text-[10px] px-4 py-3 text-slate-400 bg-slate-950/90 border-t border-glass-border overflow-x-auto max-h-48 overflow-y-auto custom-scrollbar font-mono leading-relaxed">{content}</pre>
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

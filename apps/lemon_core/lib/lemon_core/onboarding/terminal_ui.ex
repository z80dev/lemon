defmodule LemonCore.Onboarding.TerminalUI do
  @moduledoc false

  alias TermUI.Event
  alias TermUI.Renderer.Style
  alias TermUI.Runtime
  alias TermUI.Terminal

  @type option :: %{
          required(:label) => String.t(),
          required(:value) => term()
        }

  @type select_params :: %{
          required(:title) => String.t(),
          optional(:subtitle) => String.t() | nil,
          required(:options) => [option()]
        }

  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Runtime) and
      not test_env?() and
      interactive_env?()
  end

  @spec select(select_params()) :: {:ok, term()} | :cancel | {:error, term()}
  def select(%{title: title, options: options} = params)
      when is_binary(title) and is_list(options) do
    cond do
      options == [] ->
        {:error, :no_options}

      not available?() ->
        {:error, :not_available}

      true ->
        # Drain any stale bytes left in stdin from the previous cooked-mode
        # prompt (e.g. IO.gets for the API key).  Without this, the first
        # arrow-key press in the TUI can be mis-parsed: the Erlang IO group
        # leader may still hold partial data that splits the escape sequence,
        # causing e.g. "\e[B" (down-arrow) to arrive as a bare "B" character.
        flush_stdin()

        owner = self()
        ref = make_ref()

        runtime_opts = [
          root: __MODULE__.Root,
          owner: owner,
          ref: ref,
          title: title,
          subtitle: Map.get(params, :subtitle),
          options: options
        ]

        case Runtime.run(runtime_opts) do
          :ok ->
            receive do
              {^ref, {:selected, value}} -> {:ok, value}
              {^ref, :cancel} -> :cancel
            after
              100 -> {:error, :no_selection}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def select(_), do: {:error, :invalid_selector_params}

  # Under Mix/BEAM, stdio introspection is unreliable: real interactive terminals
  # often report `terminal: false`, and subprocess `test -t` checks see pipes.
  # Treat obvious non-interactive environments as unavailable and otherwise let
  # TermUI attempt startup; `select/1` will fall back on actual runtime errors.
  defp interactive_env?,
    do: System.get_env("TERM") not in [nil, "", "dumb"]

  defp test_env?,
    do: Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test

  # After a cooked-mode IO prompt (IO.gets for the API key), the Erlang IO
  # group leader may hold residual state that causes the first escape sequence
  # in the subsequent raw-mode TUI to be mis-parsed.  For example, pressing
  # the down arrow sends "\e[B", but the ESC and "[" bytes get swallowed by
  # the group leader's stale cooked-mode handler, leaving only "B" to arrive
  # as a printable character.
  #
  # Resetting the group leader with :io.setopts forces it to drop any
  # buffered line-editing state, and a brief yield lets the IO system
  # complete the transition before the TUI's InputReader starts reading.
  defp flush_stdin do
    :io.setopts(:standard_io, binary: true)
    Process.sleep(10)
  rescue
    _ -> :ok
  end

  defmodule Root do
    @moduledoc false

    use TermUI.Elm

    alias TermUI.Component.RenderNode
    alias TermUI.Event
    alias TermUI.Renderer.Style
    alias TermUI.Terminal

    @header_height 5
    @box_padding 4
    @min_width 46
    @max_width 92
    @min_height 10
    @min_render_width 8
    @min_render_height 6
    @empty_label "(No matches)"

    @impl true
    def init(opts) do
      options = Keyword.fetch!(opts, :options)
      title = Keyword.fetch!(opts, :title)
      subtitle = Keyword.get(opts, :subtitle)
      {width, height} = terminal_size()

      labels = Enum.map(options, & &1.label)

      %{
        owner: Keyword.fetch!(opts, :owner),
        ref: Keyword.fetch!(opts, :ref),
        title: title,
        subtitle: subtitle,
        value_by_label: Map.new(options, &{&1.label, &1.value}),
        all_labels: labels,
        filtered_labels: labels,
        filter_text: "",
        selected_index: 0,
        scroll_offset: 0,
        terminal_width: width,
        terminal_height: height
      }
    end

    @impl true
    def event_to_msg(%Event.Resize{width: width, height: height}, _state),
      do: {:msg, {:resize, width, height}}

    def event_to_msg(%Event.Key{} = event, _state), do: {:msg, {:key, event}}
    def event_to_msg(_, _state), do: :ignore

    @impl true
    def update({:resize, width, height}, state) do
      {
        state
        |> Map.put(:terminal_width, width)
        |> Map.put(:terminal_height, height)
        |> clamp_selection()
      }
    end

    def update({:key, %Event.Key{key: :enter}}, state) do
      case Enum.at(state.filtered_labels, state.selected_index) do
        nil ->
          {state}

        label ->
          send(state.owner, {state.ref, {:selected, Map.fetch!(state.value_by_label, label)}})
          {state, [:quit]}
      end
    end

    def update({:key, %Event.Key{key: :escape}}, state) do
      send(state.owner, {state.ref, :cancel})
      {state, [:quit]}
    end

    def update({:key, %Event.Key{key: :up}}, state), do: {move_selection(state, -1)}
    def update({:key, %Event.Key{key: :down}}, state), do: {move_selection(state, 1)}

    def update({:key, %Event.Key{key: :page_up}}, state),
      do: {move_selection(state, -page_size(state))}

    def update({:key, %Event.Key{key: :page_down}}, state),
      do: {move_selection(state, page_size(state))}

    def update({:key, %Event.Key{key: :home}}, state), do: {set_selection(state, 0)}

    def update({:key, %Event.Key{key: :end}}, state),
      do: {set_selection(state, length(state.filtered_labels) - 1)}

    def update({:key, %Event.Key{key: :backspace}}, state) do
      next_filter =
        state.filter_text
        |> String.graphemes()
        |> Enum.drop(-1)
        |> Enum.join()

      {apply_filter(state, next_filter)}
    end

    def update({:key, %Event.Key{char: char}}, state) when is_binary(char) and char != "" do
      if String.match?(char, ~r/^[[:print:]]$/u) do
        {apply_filter(state, state.filter_text <> char)}
      else
        {state}
      end
    end

    def update({:key, %Event.Key{}}, state), do: {state}

    @impl true
    def view(state) do
      area = %{
        x: 0,
        y: 0,
        width: state.terminal_width,
        height: state.terminal_height
      }

      cond do
        area.width < @min_render_width or area.height < @min_render_height ->
          render_too_small(area)

        true ->
          header = render_header(state, area)
          picker_cells = render_picker(state, area)
          RenderNode.cells(header ++ picker_cells, width: area.width, height: area.height)
      end
    end

    defp render_header(state, area) do
      title_style =
        Style.new()
        |> Style.fg(:bright_yellow)
        |> Style.bold()

      subtitle_style = Style.new(fg: :bright_green)
      hint_style = Style.new(fg: :bright_black)

      title = "LEMON ONBOARDING"
      prompt = state.title
      subtitle = state.subtitle || "Use arrows to move, Enter to select, type to filter"
      hint = "Esc cancels"

      [
        centered_cells(area.width, 1, title, title_style),
        centered_cells(area.width, 2, prompt, subtitle_style),
        centered_cells(area.width, 3, subtitle, subtitle_style),
        centered_cells(area.width, 4, hint, hint_style)
      ]
      |> List.flatten()
    end

    defp centered_cells(width, row, text, style) do
      text = truncate(text, max(0, width - 2))
      start_x = max(0, div(width - String.length(text), 2))

      text
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {char, idx} ->
        %{x: start_x + idx, y: row, cell: Style.to_cell(style, char)}
      end)
    end

    defp render_too_small(area) do
      style =
        Style.new()
        |> Style.fg(:bright_yellow)
        |> Style.bold()

      cells =
        centered_cells(area.width, 1, "Expand terminal to continue", style)

      RenderNode.cells(cells, width: max(area.width, 1), height: max(area.height, 1))
    end

    defp render_picker(state, area) do
      box_width = modal_width_from_state(state, area.width)
      box_height = modal_height_from_state(state, area.height)
      box_x = max(0, div(area.width - box_width, 2))
      box_y = @header_height

      border_style =
        Style.new()
        |> Style.fg(:bright_green)
        |> Style.bold()

      selected_style =
        Style.new()
        |> Style.fg(:black)
        |> Style.bg(:bright_yellow)
        |> Style.bold()

      text_style = Style.new(fg: :bright_green)
      muted_style = Style.new(fg: :bright_black)

      border_cells = render_box_border(box_x, box_y, box_width, box_height, border_style)
      filter_cells = render_filter_line(state, box_x, box_y, box_width, text_style, muted_style)

      content_y = box_y + 2
      content_height = max(1, box_height - 4)
      inner_width = max(1, box_width - 2)

      item_cells =
        render_items(
          state.filtered_labels,
          state.selected_index,
          state.scroll_offset,
          box_x + 1,
          content_y,
          inner_width,
          content_height,
          text_style,
          selected_style,
          muted_style
        )

      status_cells =
        render_status_line(state, box_x + 1, box_y + box_height - 2, inner_width, muted_style)

      border_cells ++ filter_cells ++ item_cells ++ status_cells
    end

    defp render_box_border(x, y, width, height, style) do
      top =
        [%{x: x, y: y, cell: Style.to_cell(style, "┌")}] ++
          horizontal_cells(x + 1, y, width - 2, "─", style) ++
          [%{x: x + width - 1, y: y, cell: Style.to_cell(style, "┐")}]

      sides =
        for row <- 1..max(1, height - 2), pos <- [x, x + width - 1] do
          %{x: pos, y: y + row, cell: Style.to_cell(style, "│")}
        end

      bottom =
        [%{x: x, y: y + height - 1, cell: Style.to_cell(style, "└")}] ++
          horizontal_cells(x + 1, y + height - 1, width - 2, "─", style) ++
          [%{x: x + width - 1, y: y + height - 1, cell: Style.to_cell(style, "┘")}]

      top ++ sides ++ bottom
    end

    defp horizontal_cells(start_x, y, count, char, style) do
      for offset <- 0..max(0, count - 1) do
        %{x: start_x + offset, y: y, cell: Style.to_cell(style, char)}
      end
    end

    defp render_filter_line(state, x, y, width, style, muted_style) do
      inner_width = max(1, width - 2)
      prefix = "Filter: "
      value = if state.filter_text == "", do: "type to search", else: state.filter_text
      line = String.slice(prefix <> value, 0, inner_width)
      padded = String.pad_trailing(line, inner_width)
      dim_prefix? = state.filter_text == ""

      padded
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {char, idx} ->
        cell_style =
          if dim_prefix? and idx >= String.length(prefix) do
            muted_style
          else
            style
          end

        %{x: x + 1 + idx, y: y + 1, cell: Style.to_cell(cell_style, char)}
      end)
    end

    defp render_items(
           items,
           selected_index,
           scroll_offset,
           x,
           y,
           width,
           height,
           style,
           selected_style,
           muted_style
         ) do
      visible_items =
        items
        |> Enum.drop(scroll_offset)
        |> Enum.take(height)

      rows =
        if visible_items == [] do
          [truncate(@empty_label, width)]
        else
          visible_items
        end

      rows
      |> Enum.with_index()
      |> Enum.flat_map(fn {label, row_idx} ->
        absolute_index = scroll_offset + row_idx

        item_style =
          cond do
            visible_items == [] -> muted_style
            absolute_index == selected_index -> selected_style
            true -> style
          end

        line =
          label
          |> truncate(width)
          |> String.pad_trailing(width)

        line
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.map(fn {char, col_idx} ->
          %{x: x + col_idx, y: y + row_idx, cell: Style.to_cell(item_style, char)}
        end)
      end)
    end

    defp render_status_line(state, x, y, width, style) do
      status =
        cond do
          state.filtered_labels == [] and state.filter_text != "" ->
            "No matches"

          state.filtered_labels == [] ->
            "Empty list"

          true ->
            "Item #{state.selected_index + 1} of #{length(state.filtered_labels)}"
        end

      status
      |> String.slice(0, width)
      |> String.pad_leading(div(width + min(String.length(status), width), 2))
      |> String.pad_trailing(width)
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.map(fn {char, idx} ->
        %{x: x + idx, y: y, cell: Style.to_cell(style, char)}
      end)
    end

    defp terminal_size do
      case Terminal.get_terminal_size() do
        {:ok, {rows, cols}} -> {cols, rows}
        {:error, _} -> {80, 24}
      end
    end

    defp modal_width(options, terminal_width) do
      longest =
        options
        |> Enum.map(&String.length(&1.label))
        |> Enum.max(fn -> @min_width end)

      longest
      |> Kernel.+(@box_padding)
      |> max(@min_width)
      |> min(@max_width)
      |> min(max(@min_render_width, terminal_width - 4))
    end

    defp modal_height(options, terminal_height, subtitle) do
      subtitle_rows = if subtitle in [nil, ""], do: 0, else: 1

      desired =
        min(length(options), max(4, terminal_height - @header_height - 4)) + 4 + subtitle_rows

      desired
      |> max(@min_height)
      |> min(max(@min_render_height, terminal_height - @header_height - 1))
    end

    defp modal_width_from_state(state, terminal_width) do
      labels =
        state.all_labels ++
          ["Filter: " <> state.filter_text, "Item 99 of 99", @empty_label]

      labels
      |> Enum.map(&%{label: &1})
      |> modal_width(terminal_width)
    end

    defp modal_height_from_state(state, terminal_height) do
      count = length(state.filtered_labels)
      modal_height(List.duplicate(%{}, count), terminal_height, state.subtitle)
    end

    defp truncate(text, max_width) when is_binary(text) do
      if String.length(text) <= max_width do
        text
      else
        String.slice(text, 0, max(0, max_width - 1)) <> "…"
      end
    end

    defp apply_filter(state, filter_text) do
      filtered =
        if filter_text == "" do
          state.all_labels
        else
          filter = String.downcase(filter_text)

          Enum.filter(state.all_labels, fn label ->
            String.contains?(String.downcase(label), filter)
          end)
        end

      state
      |> Map.put(:filter_text, filter_text)
      |> Map.put(:filtered_labels, filtered)
      |> Map.put(:selected_index, 0)
      |> Map.put(:scroll_offset, 0)
      |> clamp_selection()
    end

    defp move_selection(state, delta) do
      set_selection(state, state.selected_index + delta)
    end

    defp set_selection(state, index) do
      max_index = max(length(state.filtered_labels) - 1, 0)
      next_index = index |> max(0) |> min(max_index)
      visible = page_size(state)
      next_scroll = adjust_scroll(next_index, state.scroll_offset, visible)

      state
      |> Map.put(:selected_index, next_index)
      |> Map.put(:scroll_offset, next_scroll)
    end

    defp clamp_selection(state), do: set_selection(state, state.selected_index)

    defp page_size(state) do
      modal_height_from_state(state, state.terminal_height)
      |> Kernel.-(4)
      |> max(1)
    end

    defp adjust_scroll(selected_index, current_scroll, visible_height) do
      cond do
        selected_index < current_scroll ->
          selected_index

        selected_index >= current_scroll + visible_height ->
          selected_index - visible_height + 1

        true ->
          current_scroll
      end
    end
  end
end

defmodule LemonSim.Examples.Rendering.FrameChrome do
  @moduledoc """
  Shared SVG chrome for scenario frame renderers: header, background, footer
  bar, and the string/atom-key access + escape helpers every renderer needs.

  Scenario frame renderers keep their board-specific center content and
  delegate the stable shell to this module. Output must stay byte-identical
  to the per-scenario implementations this replaced — replay videos are
  regenerated from persisted logs and byte drift here shows up as visual
  diffs across historical replays.
  """

  def svg_header(%{w: w, h: h}) do
    ~s[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{w} #{h}" ] <>
      ~s[width="#{w}" height="#{h}">\n]
  end

  def render_background(%{w: w, h: h}, bg) do
    ~s[<rect width="#{w}" height="#{h}" fill="#{bg}"/>\n]
  end

  def render_footer_bar(%{w: w, h: h}, opts) do
    footer_h = Keyword.fetch!(opts, :footer_h)
    panel_bg = Keyword.fetch!(opts, :panel_bg)
    panel_border = Keyword.fetch!(opts, :panel_border)
    text_primary = Keyword.fetch!(opts, :text_primary)
    event_text = Keyword.fetch!(opts, :event_text)
    bar_y = h - footer_h

    [
      ~s[<rect x="0" y="#{bar_y}" width="#{w}" height="#{footer_h}" fill="#{panel_bg}"/>\n],
      ~s[<line x1="0" y1="#{bar_y}" x2="#{w}" y2="#{bar_y}" stroke="#{panel_border}" stroke-width="1"/>\n],
      ~s[<text x="#{div(w, 2)}" y="#{bar_y + div(footer_h, 2) + 5}" text-anchor="middle" ] <>
        ~s[class="event-text" font-size="16" fill="#{text_primary}">#{esc(event_text)}</text>\n]
    ]
  end

  @doc """
  True when any event in the list has the given `"kind"`.

  Matches only the `"kind"`/`:kind` key, exactly like the per-scenario
  implementations this replaced — widening the match (e.g. to `"type"`)
  would silently change hold-frame pacing in generated videos.
  """
  def has_event?(events, kind) when is_list(events) do
    Enum.any?(events, fn
      %{"kind" => k} -> k == kind
      %{kind: k} -> to_string(k) == kind
      _ -> false
    end)
  end

  def has_event?(_, _), do: false

  def get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      nil ->
        try do
          Map.get(map, String.to_existing_atom(key), default)
        rescue
          ArgumentError -> default
        end

      val ->
        val
    end
  end

  def get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def get(_, _, default), do: default

  def esc(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s["], "&quot;")
  end

  def esc(other), do: esc(to_string(other))
end

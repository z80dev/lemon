defmodule LemonSim.Examples.Rendering.FrameChromeTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Rendering.FrameChrome

  test "renders shared SVG shell helpers byte-stably" do
    ctx = %{w: 100, h: 50}

    assert FrameChrome.svg_header(ctx) ==
             ~s[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 50" width="100" height="50">\n]

    assert FrameChrome.render_background(ctx, "#000") ==
             ~s[<rect width="100" height="50" fill="#000"/>\n]
  end

  test "footer bar escapes event text" do
    ctx = %{w: 100, h: 50}

    assert IO.iodata_to_binary(
             FrameChrome.render_footer_bar(ctx,
               footer_h: 10,
               panel_bg: "#111",
               panel_border: "#222",
               text_primary: "#eee",
               event_text: ~s[<A&B>]
             )
           ) =~ "&lt;A&amp;B&gt;"
  end

  test "has_event? matches only the kind key, string or atom" do
    assert FrameChrome.has_event?([%{"kind" => "vote"}], "vote")
    assert FrameChrome.has_event?([%{kind: :vote}], "vote")
    refute FrameChrome.has_event?([%{"kind" => "other"}], "vote")

    # Pacing must not widen to other keys — per-scenario originals matched
    # "kind" only, and hold-frame counts depend on it.
    refute FrameChrome.has_event?([%{"type" => "vote"}], "vote")
    refute FrameChrome.has_event?([%{type: :vote}], "vote")
    refute FrameChrome.has_event?(nil, "vote")
  end

  test "get reads string keys with atom fallback and vice versa" do
    assert FrameChrome.get(%{"day" => 3}, "day", 0) == 3
    assert FrameChrome.get(%{day: 3}, "day", 0) == 3
    assert FrameChrome.get(%{"day" => 3}, :day, 0) == 3
    assert FrameChrome.get(%{day: 3}, :day, 0) == 3
    assert FrameChrome.get(%{}, "missing_key_never_an_atom", :fallback) == :fallback
    assert FrameChrome.get(nil, "day", :fallback) == :fallback
  end

  test "esc stringifies non-binary input" do
    assert FrameChrome.esc(42) == "42"
    assert FrameChrome.esc(:"<a>") == "&lt;a&gt;"
  end
end

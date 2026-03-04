defmodule LemonSim.Projectors.ToolkitTest do
  use ExUnit.Case, async: true

  alias LemonSim.Projectors.Toolkit

  test "stable_json sorts object keys deterministically" do
    json =
      Toolkit.stable_json(%{
        "z" => 1,
        "a" => %{"d" => true, "b" => 3},
        "m" => [%{"k2" => 2, "k1" => 1}]
      })

    assert String.contains?(json, "\"a\"")
    assert String.contains?(json, "\"m\"")
    assert String.contains?(json, "\"z\"")
    assert String.contains?(json, "\"b\": 3")
    assert String.contains?(json, "\"d\": true")

    assert String.index(json, "\"a\"") < String.index(json, "\"m\"")
    assert String.index(json, "\"m\"") < String.index(json, "\"z\"")
  end

  test "render_sections includes stable prompt version and json fences" do
    prompt =
      Toolkit.render_sections([
        %{id: :world_state, title: "World State", format: :json, content: %{"hp" => 10}},
        %{id: :note, title: "Note", format: :markdown, content: "stay hidden"}
      ])

    assert String.starts_with?(prompt, "SIM_PROMPT_V1")
    assert String.contains?(prompt, "## World State")
    assert String.contains?(prompt, "```json")
    assert String.contains?(prompt, "\"hp\": 10")
    assert String.contains?(prompt, "## Note")
    assert String.contains?(prompt, "stay hidden")
  end
end

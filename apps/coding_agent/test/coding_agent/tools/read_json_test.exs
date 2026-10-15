defmodule CodingAgent.Tools.ReadJsonTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Read
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    data = %{
      "a" => %{"b" => [3, 1, 2]},
      "users" => [%{"name" => "Ada", "age" => 36}, %{"name" => "Bo", "age" => 17}],
      "empty" => []
    }

    File.write!(Path.join(dir, "data.json"), Jason.encode!(data))
    %{data: data}
  end

  defp query(dir, filter, opts \\ [], params \\ %{}) do
    path = "data.json?q=" <> URI.encode_www_form(filter)
    Read.execute("read", Map.put(params, "path", path), nil, nil, dir, opts)
  end

  defp values(%AgentToolResult{content: [%{text: text}]}) do
    text |> String.split("\n") |> Enum.map_join("\n", &Regex.replace(~r/^\d+: /, &1, ""))
  end

  test "identity, nested paths and array indexing", %{tmp_dir: dir, data: data} do
    assert %AgentToolResult{details: %{format: :json_query, immutable: true}} =
             result = query(dir, ".")

    assert Jason.decode!(values(result)) == data
    assert values(query(dir, ".a.b[0]")) == "3"
    assert values(query(dir, ".a.b[-1]")) == "2"
    assert values(query(dir, ".a.b[99]")) == "null"
    assert values(query(dir, ".missing.field")) == "null"
    File.write!(Path.join(dir, "data.json"), "[10,20]")
    assert values(query(dir, ".[1]")) == "20"
  end

  test "iteration, pipes, keys and length", %{tmp_dir: dir} do
    assert values(query(dir, ".a.b[]")) == "3\n1\n2"
    assert values(query(dir, ".users | .[] | .name")) == ~s("Ada"\n"Bo")
    assert Jason.decode!(values(query(dir, ".a | keys"))) == ["b"]
    assert values(query(dir, ".users | length")) == "2"
    assert values(query(dir, ".users[0].name | length")) == "3"
    assert Jason.decode!(values(query(dir, ".empty | keys"))) == []
    assert values(query(dir, ".empty[]")) == "(no results)"
  end

  test "select supports scalar equality, inequality and ordering", %{tmp_dir: dir} do
    for {operator, threshold, expected} <- [
          {">", 17, "Ada"},
          {"<", 18, "Bo"},
          {"==", 17, "Bo"},
          {"!=", 17, "Ada"}
        ] do
      assert values(query(dir, ".users[] | select(.age #{operator} #{threshold}) | .name")) ==
               Jason.encode!(expected)
    end

    File.write!(
      Path.join(dir, "data.json"),
      ~s|[{"x":true},{"x":false},{"x":null},{"x":"a\\u007cb"}]|
    )

    assert values(query(dir, ~s/.[] | select(.x == "a|b") | .x/)) == ~s("a|b")
    assert values(query(dir, ".[] | select(.x == null) | .x")) == "null"
    assert values(query(dir, ".[] | select(.x == true) | .x")) == "true"
  end

  test "literal question-mark paths win", %{tmp_dir: dir} do
    path = "data.json?q=.missing"
    File.write!(Path.join(dir, path), "literal file\n")

    assert %AgentToolResult{content: [%{text: text}]} =
             Read.execute("read", %{"path" => path}, nil, nil, dir, [])

    assert text =~ "literal file"
  end

  test "invalid syntax, invalid JSON and type errors are explicit", %{tmp_dir: dir} do
    for filter <- [
          "",
          ".a | sort",
          ".a[abc]",
          ".a || length",
          "select(.x >= 1)",
          "select(.x == [])",
          ".users | .field"
        ] do
      assert {:error, _} = query(dir, filter)
    end

    File.write!(Path.join(dir, "data.json"), "{not JSON secret}")
    assert {:error, message} = query(dir, ".")
    refute message =~ "secret"
  end

  test "results obey read budgets and remain pageable", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "data.json"), Jason.encode!(Enum.to_list(1..100)))

    assert %AgentToolResult{
             details: %{truncation: %{truncated: true}, next_offset: next},
             content: [%{text: text}]
           } = query(dir, ".[]", max_lines: 3, max_bytes: 700)

    assert byte_size(text) <= 700
    assert next == 4
    assert values(query(dir, ".[]", [], %{"offset" => next, "limit" => 1})) =~ "4"
  end
end

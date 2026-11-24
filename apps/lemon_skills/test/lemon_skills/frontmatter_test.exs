defmodule LemonSkills.FrontmatterTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Frontmatter
  alias LemonSkills.Manifest.Parser

  test "parses a mapping and keeps nested shapes" do
    assert {:ok, %{"name" => "x", "tags" => ["a", "b"], "meta" => %{"k" => 1}}} =
             Frontmatter.parse_yaml("name: x\ntags: [a, b]\nmeta:\n  k: 1\n")

    assert {:ok, %{}} = Frontmatter.parse_yaml("")
    assert {:ok, %{}} = Frontmatter.parse_yaml("# only a comment\n")
  end

  test "refuses duplicate keys, non-mappings, malformed YAML and oversized text" do
    assert {:error, :duplicate_key} = Frontmatter.parse_yaml("a: 1\na: 2\n")
    assert {:error, :not_a_mapping} = Frontmatter.parse_yaml("- a\n- b\n")
    assert {:error, :not_a_mapping} = Frontmatter.parse_yaml("plain")
    assert {:error, :malformed} = Frontmatter.parse_yaml("globs: *.ts\n")

    big = "a: " <> String.duplicate("x", Frontmatter.default_max_bytes())
    assert {:error, :too_large} = Frontmatter.parse_yaml(big)
    assert {:ok, _} = Frontmatter.parse_yaml(big, max_bytes: byte_size(big))
    assert {:error, :too_large} = Frontmatter.parse_yaml("a: 1", max_bytes: 3)
  end

  test "skill manifests refuse duplicate keys" do
    assert :error = Parser.parse("---\nname: one\nname: two\n---\nbody")
    assert {:ok, %{"name" => "one"}, "body"} = Parser.parse("---\nname: one\n---\nbody")
  end
end

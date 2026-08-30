defmodule LemonSkills.Sources.HermesTest do
  use ExUnit.Case, async: false

  alias LemonSkills.HttpClient.Mock, as: HttpMock
  alias LemonSkills.Sources.Hermes

  @tree_url "https://api.github.com/repos/NousResearch/hermes-agent/git/trees/main?recursive=1"

  setup do
    previous = Application.get_env(:lemon_skills, :hermes_repo)
    Application.delete_env(:lemon_skills, :hermes_repo)
    System.delete_env("LEMON_HERMES_REPO")
    HttpMock.reset()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_skills, :hermes_repo, previous),
        else: Application.delete_env(:lemon_skills, :hermes_repo)
    end)

    :ok
  end

  test "discovers bundled, optional, and uncategorized skills from the live tree" do
    HttpMock.stub(@tree_url, {:ok, tree_json()})

    assert {:ok, entries} = Hermes.catalog()

    assert Enum.map(entries, & &1.id) == [
             "hermes:bundled/apple/apple-notes",
             "hermes:optional/yuanbao",
             "hermes:optional/research/arxiv"
           ]

    assert Enum.find(entries, &(&1.key == "yuanbao")).category == "other"
  end

  test "loads descriptions only for the filtered detail set" do
    HttpMock.stub(@tree_url, {:ok, tree_json()})

    HttpMock.stub(
      "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/optional-skills/research/arxiv/SKILL.md",
      {:ok, "---\nname: arxiv\ndescription: Search research papers.\n---\nbody"}
    )

    assert {:ok, [entry]} =
             Hermes.catalog(collection: "optional", category: "research", details: true)

    assert entry.description == "Search research papers."
  end

  test "copies a selected skill from a configured local Hermes checkout" do
    repo = tmp_dir("hermes_repo")
    dest = tmp_dir("hermes_dest")
    source = Path.join(repo, "skills/apple/apple-notes")
    File.mkdir_p!(Path.join(source, "scripts"))
    File.write!(Path.join(source, "SKILL.md"), "---\nname: apple-notes\n---\nbody")
    File.write!(Path.join(source, "scripts/run.sh"), "echo notes")

    assert {:ok, ^dest} =
             Hermes.fetch("hermes:bundled/apple/apple-notes", dest, hermes_repo: repo)

    assert File.read!(Path.join(dest, "scripts/run.sh")) == "echo notes"
  end

  test "rejects invalid identifiers" do
    assert {:error, :invalid_hermes_id} = Hermes.parse_id("hermes:optional/../secret")
    assert {:error, :invalid_hermes_id} = Hermes.parse_id("hermes:community/foo/bar")
  end

  defp tree_json do
    Jason.encode!(%{
      "tree" => [
        %{"path" => "skills/apple/apple-notes/SKILL.md", "sha" => "sha-1", "type" => "blob"},
        %{
          "path" => "optional-skills/research/arxiv/SKILL.md",
          "sha" => "sha-2",
          "type" => "blob"
        },
        %{"path" => "optional-skills/yuanbao/SKILL.md", "sha" => "sha-3", "type" => "blob"},
        %{"path" => "README.md", "sha" => "ignored", "type" => "blob"}
      ]
    })
  end

  defp tmp_dir(label) do
    path = Path.join(System.tmp_dir!(), "#{label}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end

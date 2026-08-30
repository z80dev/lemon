defmodule LemonControlPlane.Methods.SkillsHermesCatalogTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.SkillsHermesCatalog

  setup do
    repo = Path.join(System.tmp_dir!(), "hermes_catalog_#{System.unique_integer([:positive])}")
    skill = Path.join(repo, "optional-skills/research/arxiv")
    File.mkdir_p!(skill)
    File.write!(Path.join(skill, "SKILL.md"), "---\nname: arxiv\ndescription: Papers.\n---\nbody")

    previous = Application.get_env(:lemon_skills, :hermes_repo)
    Application.put_env(:lemon_skills, :hermes_repo, repo)

    on_exit(fn ->
      File.rm_rf(repo)

      if previous,
        do: Application.put_env(:lemon_skills, :hermes_repo, previous),
        else: Application.delete_env(:lemon_skills, :hermes_repo)
    end)

    :ok
  end

  test "returns categories and install-ready Hermes ids" do
    assert SkillsHermesCatalog.name() == "skills.hermes.catalog"
    assert SkillsHermesCatalog.scopes() == [:read]

    assert {:ok, result} =
             SkillsHermesCatalog.handle(%{"details" => true}, %{auth: %{role: :operator}})

    assert [%{"id" => "hermes:optional/research/arxiv", "description" => "Papers."}] =
             result["skills"]

    assert [%{"category" => "research", "count" => 1}] = result["categories"]
    assert result["summary"]["dynamic"]
  end
end

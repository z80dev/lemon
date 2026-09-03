defmodule LemonSkills.Sources.GithubRegistryTest do
  use ExUnit.Case, async: false

  alias LemonSkills.HttpClient.Mock, as: HttpMock
  alias LemonSkills.Sources.{Github, Registry}

  @moduletag :tmp_dir

  setup do
    previous_client = Application.get_env(:lemon_skills, :http_client)
    Application.put_env(:lemon_skills, :http_client, HttpMock)
    HttpMock.reset()

    on_exit(fn ->
      if previous_client do
        Application.put_env(:lemon_skills, :http_client, previous_client)
      else
        Application.delete_env(:lemon_skills, :http_client)
      end
    end)

    :ok
  end

  describe "GitHub source" do
    test "search maps repository metadata into unvalidated community entries" do
      HttpMock.stub(
        "https://api.github.com/search/repositories",
        {:ok,
         Jason.encode!(%{
           "items" => [
             %{
               "full_name" => "acme/deploy-skill",
               "name" => "Deploy Skill",
               "description" => "Deploy services safely",
               "html_url" => "https://github.com/acme/deploy-skill",
               "stargazers_count" => 7
             }
           ]
         })}
      )

      assert [%{entry: entry, source: :github, validated: false, url: url}] =
               Github.search("deploy", github_token: "token", per_page: 1)

      assert entry.key == "acme-deploy-skill"
      assert entry.name == "Deploy Skill"
      assert entry.description == "Deploy services safely"
      assert entry.source_kind == :git
      assert entry.trust_level == :community
      assert entry.manifest["_discovery_metadata"]["discovery_score"] == 77
      assert url == "https://raw.githubusercontent.com/acme/deploy-skill/main/SKILL.md"
    end

    test "search degrades safely for malformed or failed API responses" do
      prefix = "https://api.github.com/search/repositories"

      HttpMock.stub(prefix, {:ok, "not-json"})
      assert Github.search("deploy", []) == []

      HttpMock.stub(prefix, {:ok, Jason.encode!(%{"unexpected" => []})})
      assert Github.search("deploy", []) == []

      HttpMock.stub(prefix, {:error, :timeout})
      assert Github.search("deploy", []) == []
    end

    test "inspect returns decoded repository metadata and preserves failures" do
      url = "https://api.github.com/repos/acme/deploy-skill"
      HttpMock.stub(url, {:ok, Jason.encode!(%{"full_name" => "acme/deploy-skill"})})

      assert {:ok, %{"full_name" => "acme/deploy-skill"}} =
               Github.inspect("acme/deploy-skill", github_token: "token")

      HttpMock.stub(url, {:ok, "invalid"})
      assert Github.inspect("acme/deploy-skill", []) == {:error, :invalid_json}

      HttpMock.stub(url, {:error, :forbidden})
      assert Github.inspect("acme/deploy-skill", []) == {:error, :forbidden}
    end

    test "fetch_manifest validates the remote SKILL document" do
      url = "https://raw.githubusercontent.com/acme/deploy-skill/main/SKILL.md"

      HttpMock.stub(
        url,
        {:ok,
         "---\nname: Deploy Skill\ndescription: Deploy services safely.\n---\n\n# Use\n\nDeploy.\n"}
      )

      assert {:ok, manifest, body} =
               Github.fetch_manifest("acme/deploy-skill", github_token: "token")

      assert manifest["name"] == "Deploy Skill"
      assert body =~ "Deploy."

      HttpMock.stub(url, {:ok, "---\nname: []\n---\nbody"})

      assert {:error, {:invalid_manifest, reason}} =
               Github.fetch_manifest("acme/deploy-skill")

      assert is_binary(reason)

      HttpMock.stub(url, {:error, :not_found})
      assert Github.fetch_manifest("acme/deploy-skill") == {:error, :not_found}
    end

    test "reports community trust and non-cloning inspection metadata" do
      assert Github.trust_level() == :community
    end
  end

  describe "registry source" do
    test "search maps official and community results with namespace-derived trust" do
      base = "https://registry.example.test"

      HttpMock.stub(
        "#{base}/search",
        {:ok,
         Jason.encode!(%{
           "skills" => [
             %{
               "ref" => "official/devops/deploy",
               "name" => "Deploy",
               "description" => "Deploy safely"
             },
             %{"id" => "community/tools/helper"}
           ]
         })}
      )

      assert [official, community] = Registry.search("deploy", registry_url: base)
      assert official.entry.key == "official-devops-deploy"
      assert official.entry.trust_level == :official
      assert official.url == "#{base}/skills/official/devops/deploy"
      assert community.entry.key == "community-tools-helper"
      assert community.entry.trust_level == :community
    end

    test "search and inspect preserve malformed and failed response semantics" do
      base = "https://registry.example.test"
      search_url = "#{base}/search"
      inspect_url = "#{base}/skills/official/devops/deploy"

      HttpMock.stub(search_url, {:ok, "invalid"})
      assert Registry.search("deploy", registry_url: base) == []

      HttpMock.stub(search_url, {:error, :timeout})
      assert Registry.search("deploy", registry_url: base) == []

      HttpMock.stub(inspect_url, {:ok, Jason.encode!(%{"name" => "Deploy"})})

      assert {:ok, %{"name" => "Deploy"}} =
               Registry.inspect("official/devops/deploy", registry_url: base)

      HttpMock.stub(inspect_url, {:ok, "invalid"})

      assert Registry.inspect("official/devops/deploy", registry_url: base) ==
               {:error, :invalid_json}

      HttpMock.stub(inspect_url, {:error, :forbidden})

      assert Registry.inspect("official/devops/deploy", registry_url: base) ==
               {:error, :forbidden}
    end

    test "fetch and upstream_hash resolve a local clone URL through the registry", %{
      tmp_dir: tmp_dir
    } do
      base = "https://registry.example.test"
      ref = "official/devops/deploy"
      repo = create_repo!(tmp_dir)
      dest = Path.join(tmp_dir, "installed")
      expected_head = git!(repo, ["rev-parse", "HEAD"])

      HttpMock.stub("#{base}/skills/#{ref}", {:ok, Jason.encode!(%{"clone_url" => repo})})

      assert {:ok, ^dest} = Registry.fetch(ref, dest, registry_url: base)
      assert File.exists?(Path.join(dest, "SKILL.md"))
      assert {:ok, ^expected_head} = Registry.upstream_hash(ref, registry_url: base)
    end

    test "accepts legacy URL metadata and rejects entries without clone metadata", %{
      tmp_dir: tmp_dir
    } do
      base = "https://registry.example.test"
      ref = "official/devops/deploy"
      url = "#{base}/skills/#{ref}"
      missing_repo = Path.join(tmp_dir, "missing-repository")

      HttpMock.stub(url, {:ok, Jason.encode!(%{"url" => missing_repo})})
      assert {:error, {:ls_remote_failed, _}} = Registry.upstream_hash(ref, registry_url: base)

      HttpMock.stub(url, {:ok, Jason.encode!(%{"name" => "Deploy"})})
      assert Registry.fetch(ref, "unused", registry_url: base) == {:error, {:no_clone_url, ref}}

      HttpMock.stub(url, {:error, :offline})
      assert Registry.fetch(ref, "unused", registry_url: base) == {:error, :offline}
    end
  end

  defp create_repo!(tmp_dir) do
    repo = Path.join(tmp_dir, "registry-repo")
    hooks_dir = Path.join(tmp_dir, "registry-hooks")
    File.mkdir_p!(repo)
    File.mkdir_p!(hooks_dir)

    File.write!(
      Path.join(repo, "SKILL.md"),
      "---\nname: Registry Skill\ndescription: Registry fixture.\n---\n\nUse it.\n"
    )

    git!(repo, ["init", "--initial-branch=main"])
    git!(repo, ["config", "user.email", "skills-test@example.invalid"])
    git!(repo, ["config", "user.name", "Lemon Skills Test"])
    git!(repo, ["config", "core.hooksPath", hooks_dir])
    git!(repo, ["add", "SKILL.md"])

    git!(repo, [
      "-c",
      "core.hooksPath=#{hooks_dir}",
      "commit",
      "--no-gpg-sign",
      "-m",
      "initial skill"
    ])

    repo
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git command failed with #{status}: #{output}")
    end
  end
end

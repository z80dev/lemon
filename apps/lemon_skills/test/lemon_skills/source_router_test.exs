defmodule LemonSkills.SourceRouterTest do
  use ExUnit.Case, async: true

  alias LemonSkills.SourceRouter
  alias LemonSkills.Sources.{Builtin, Git, Github, Local, Registry}

  describe "resolve/1 — builtin" do
    test "routes 'builtin' to Builtin with nil id" do
      assert {:ok, Builtin, nil} = SourceRouter.resolve("builtin")
    end

    test "strips leading/trailing whitespace" do
      assert {:ok, Builtin, nil} = SourceRouter.resolve("  builtin  ")
    end
  end

  describe "resolve/1 — git URLs" do
    test "routes https:// URLs to Git" do
      url = "https://github.com/acme/k8s-skill"
      assert {:ok, Git, ^url} = SourceRouter.resolve(url)
    end

    test "routes http:// URLs to Git" do
      url = "http://internal.example.com/skill"
      assert {:ok, Git, ^url} = SourceRouter.resolve(url)
    end

    test "routes SSH git@ URLs to Git" do
      url = "git@github.com:acme/k8s-skill.git"
      assert {:ok, Git, ^url} = SourceRouter.resolve(url)
    end

    test "strips git+ prefix" do
      assert {:ok, Git, "https://github.com/acme/skill"} =
               SourceRouter.resolve("git+https://github.com/acme/skill")
    end
  end

  describe "resolve/1 — GitHub shorthand" do
    test "routes gh: prefix to Github" do
      assert {:ok, Github, "acme/k8s-skill"} = SourceRouter.resolve("gh:acme/k8s-skill")
    end
  end

  describe "resolve/1 — local paths" do
    test "routes absolute paths to Local" do
      assert {:ok, Local, path} = SourceRouter.resolve("/home/user/my-skill")
      assert Path.type(path) == :absolute
    end

    test "routes ./relative paths to Local with expanded absolute path" do
      assert {:ok, Local, path} = SourceRouter.resolve("./my-skill")
      assert Path.type(path) == :absolute
    end

    test "routes ../relative paths to Local" do
      assert {:ok, Local, path} = SourceRouter.resolve("../sibling-skill")
      assert Path.type(path) == :absolute
    end
  end

  describe "resolve/1 — registry refs" do
    test "routes three-segment ref to Registry" do
      assert {:ok, Registry, "official/devops/k8s-rollout"} =
               SourceRouter.resolve("official/devops/k8s-rollout")
    end

    test "routes community namespace refs to Registry" do
      assert {:ok, Registry, "community/tools/gh-cli"} =
               SourceRouter.resolve("community/tools/gh-cli")
    end

    test "routes deep paths to Registry" do
      assert {:ok, Registry, "official/languages/elixir/liveview"} =
               SourceRouter.resolve("official/languages/elixir/liveview")
    end
  end

  describe "resolve/1 — unknown identifiers" do
    test "returns error for bare names" do
      assert {:error, msg} = SourceRouter.resolve("some-skill")
      assert msg =~ "Cannot resolve"
    end

    test "returns error for empty string" do
      assert {:error, _} = SourceRouter.resolve("")
    end

    test "returns error for two-segment registry-like strings" do
      assert {:error, _} = SourceRouter.resolve("official/devops")
    end
  end

  describe "source_kind/1" do
    test "Builtin → :builtin" do
      assert SourceRouter.source_kind(Builtin) == :builtin
    end

    test "Local → :local" do
      assert SourceRouter.source_kind(Local) == :local
    end

    test "Git → :git" do
      assert SourceRouter.source_kind(Git) == :git
    end

    test "Github → :git" do
      assert SourceRouter.source_kind(Github) == :git
    end

    test "Registry → :registry" do
      assert SourceRouter.source_kind(Registry) == :registry
    end
  end
end

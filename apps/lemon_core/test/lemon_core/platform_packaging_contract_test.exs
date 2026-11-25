defmodule LemonCore.PlatformPackagingContractTest do
  @moduledoc """
  Repository invariants behind the platform-split proof (#70, #91, #93):
  the published package set named by `scripts/verify_packages` is the set
  `.github/workflows/packaging.yml` rebuilds on every pull request, it is
  listed in dependency order, every sibling requirement accepts the sibling's
  in-repo version, and no runtime profile app is a published package.
  """

  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Profile

  @repo_root Path.expand("../../../..", __DIR__)

  defp read!(relative), do: File.read!(Path.join(@repo_root, relative))

  defp published_packages do
    [_, list] = Regex.run(~r/^PACKAGES=\(([^)]*)\)/m, read!("scripts/verify_packages"))
    list |> String.split() |> Enum.map(&String.to_atom/1)
  end

  defp mix_exs(package), do: read!("apps/#{package}/mix.exs")

  defp version(package) do
    [_, version] = Regex.run(~r/@version\s+"([^"]+)"/, mix_exs(package))
    Version.parse!(version)
  end

  # Each package derives its one sibling requirement from its own @version
  # (`@lemon_requirement`) and applies it to every sibling it declares
  # `in_umbrella`. This evaluates that derivation as the package would.
  defp lemon_requirements(package) do
    source = mix_exs(package)

    siblings =
      ~r/\{:(lemon_\w+),\s*in_umbrella:\s*true/
      |> Regex.scan(source)
      |> Enum.map(fn [_, app] -> String.to_atom(app) end)
      |> Enum.filter(&(&1 in published_packages()))

    case {siblings, Regex.run(~r/^\s*@lemon_requirement\s+(.+)$/m, source)} do
      {[], _} ->
        %{}

      {_, nil} ->
        flunk("#{package} has sibling packages but no @lemon_requirement")

      {_, [_, expression]} ->
        own = inspect(to_string(version(package)))
        {requirement, _} = Code.eval_string(String.replace(expression, "@version", own))
        Map.new(siblings, &{&1, requirement})
    end
  end

  test "the published set is the five packages D18 settled on" do
    assert published_packages() ==
             [:lemon_ai, :lemon_core, :lemon_agent, :lemon_memory, :lemon_platform_test]
  end

  test "packaging CI rebuilds the tarballs whenever a published package changes" do
    workflow = read!(".github/workflows/packaging.yml")

    for package <- published_packages() do
      assert workflow =~ ~s("apps/#{package}/**"),
             "packaging.yml does not trigger on changes to apps/#{package}"
    end

    for script <- ["scripts/verify_packages", "scripts/verify_generator"] do
      assert workflow =~ ~s("#{script}")
      assert workflow =~ "run: #{script}"
    end
  end

  test "each package requires only packages published before it, at a version it accepts" do
    packages = published_packages()

    for {package, index} <- Enum.with_index(packages) do
      earlier = Enum.take(packages, index)

      for {dep, requirement} <- lemon_requirements(package) do
        assert dep in earlier,
               "#{package} requires #{dep}, which is not published before it"

        assert Version.match?(version(dep), requirement),
               "#{package} requires #{dep} #{requirement}, in-repo is #{version(dep)}"
      end
    end
  end

  # Every 0.x minor may break, so a sibling requirement must admit the
  # sibling's patch releases and nothing on another minor (#730).
  test "sibling requirements cannot resolve across a 0.x minor" do
    checked =
      for package <- published_packages(), {dep, requirement} <- lemon_requirements(package) do
        %Version{major: major, minor: minor} = version(dep)

        assert Version.match?("#{major}.#{minor}.99", requirement),
               "#{package} requires #{dep} #{requirement}, which refuses a patch release"

        for other <-
              ["#{major}.#{minor + 1}.0", "#{major + 1}.0.0"] ++
                if(minor > 0, do: ["#{major}.#{minor - 1}.99"], else: []) do
          refute Version.match?(other, requirement),
                 "#{package} requires #{dep} #{requirement}, which admits #{other}"
        end

        {package, dep}
      end

    # The three packages with siblings are covered, not skipped.
    assert checked |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort() ==
             [:lemon_agent, :lemon_memory, :lemon_platform_test]
  end

  # The declared Elixir floor is a claim scripts/verify_packages proves by
  # running the packaged consumer and doctor on it, as a required CI leg (#730).
  test "packaging CI requires a leg on the Elixir floor every package declares" do
    floors =
      for package <- published_packages(), into: MapSet.new() do
        [_, requirement] = Regex.run(~r/^\s*elixir: "([^"]+)"/m, mix_exs(package))
        requirement
      end

    assert [floor] = MapSet.to_list(floors),
           "packages declare different floors: #{inspect(floors)}"

    assert [_, minimum] = Regex.run(~r/^~> (\d+\.\d+)$/, floor)

    workflow = read!(".github/workflows/packaging.yml")
    legs = Regex.scan(~r/^\s*elixir: "(\d+\.\d+)\.\d+"/m, workflow, capture: :all_but_first)

    assert [minimum] in legs, "packaging.yml has no Elixir #{minimum} leg for `#{floor}`"
    refute workflow =~ "continue-on-error", "the floor leg must be required"

    assert read!("scripts/verify_packages") =~ ~s(elixir: "#{floor}"),
           "the verify_packages consumer must declare the packages' floor"
  end

  test "published mix.exs files load outside the umbrella" do
    for package <- published_packages() do
      source = mix_exs(package)
      refute source =~ "hex_package.exs", "#{package}/mix.exs requires a file outside its tarball"
      refute source =~ ~r/Code\.(require|eval)_file/, "#{package}/mix.exs loads external code"
    end
  end

  test "runtime profiles start only umbrella apps and dependencies, never a published package" do
    published = MapSet.new(published_packages())
    deps = Mix.Project.deps_paths()

    for name <- Profile.names(), app <- Profile.app_list(name) do
      assert File.dir?(Path.join(@repo_root, "apps/#{app}")) or Map.has_key?(deps, app),
             "#{name} names unknown app #{app}"

      refute MapSet.member?(published, app), "#{name} starts published package #{app}"
    end
  end
end

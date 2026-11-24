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

  defp lemon_requirements(package) do
    case Regex.run(~r/@lemon_requirements\s+%\{([^}]*)\}/, mix_exs(package)) do
      nil ->
        %{}

      [_, body] ->
        ~r/(\w+):\s*"([^"]+)"/
        |> Regex.scan(body)
        |> Map.new(fn [_, app, req] -> {String.to_atom(app), req} end)
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

  test "published mix.exs files load outside the umbrella" do
    for package <- published_packages() do
      source = mix_exs(package)
      refute source =~ "hex_package.exs", "#{package}/mix.exs requires a file outside its tarball"
      refute source =~ ~r/Code\.(require|eval)_file/, "#{package}/mix.exs loads external code"
    end
  end

  test "runtime profiles start only umbrella apps, never a published package" do
    published = MapSet.new(published_packages())

    for name <- Profile.names(), app <- Profile.app_list(name) do
      assert File.dir?(Path.join(@repo_root, "apps/#{app}")), "#{name} names unknown app #{app}"
      refute MapSet.member?(published, app), "#{name} starts published package #{app}"
    end
  end
end

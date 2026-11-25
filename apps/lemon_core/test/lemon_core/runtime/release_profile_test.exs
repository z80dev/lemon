defmodule LemonCore.Runtime.ReleaseProfileTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The runtime profiles (`priv/runtime_profiles.exs`) are the single source of
  the application lists: the umbrella releases, the source launcher and the
  deployment docs must all name exactly the profile's applications (#726).
  """

  alias LemonCore.Runtime.Profile

  @repo_root Path.expand("../../../../..", __DIR__)

  # Lemon.MixProject is the umbrella project `mix test` runs under; a module
  # variable keeps the call out of the compiler's undefined-module checks.
  defp releases do
    project = Lemon.MixProject

    assert Code.ensure_loaded?(project),
           "run the suite from the umbrella root so the release config is loaded"

    Keyword.fetch!(project.project(), :releases)
  end

  describe "releases and profiles share one source" do
    test "every release is a profile and every profile is a release" do
      assert Enum.sort(Keyword.keys(releases())) ==
               Enum.sort(Enum.map(Profile.names(), &String.to_atom(Profile.release_name(&1))))
    end

    test "every release app is in Profile.app_list/1, with its start type, and vice versa" do
      for name <- Profile.names() do
        release = Keyword.fetch!(releases(), String.to_atom(Profile.release_name(name)))
        applications = Keyword.fetch!(release, :applications)

        assert applications == Profile.get(name).applications
        assert Keyword.keys(applications) == Profile.app_list(name)
      end
    end

    test "each profile starts every :permanent app of its release" do
      for name <- Profile.names() do
        release = Keyword.fetch!(releases(), String.to_atom(Profile.release_name(name)))
        permanent = for {app, :permanent} <- Keyword.fetch!(release, :applications), do: app

        assert permanent -- Profile.get(name).apps == []
        assert permanent == Profile.running_apps(name)
      end
    end

    test "runtime_full starts every :permanent app of both releases" do
      for {_release, config} <- releases(),
          {app, :permanent} <- Keyword.fetch!(config, :applications) do
        assert app in Profile.get(:runtime_full).apps
      end
    end
  end

  describe "profile membership" do
    test "the satellites start in every profile" do
      for name <- Profile.names(), app <- [:lemon_honcho, :lemon_computer_use] do
        assert {app, :permanent} in Profile.get(name).applications,
               "#{name} must start #{app}: nothing depends on a satellite"
      end
    end

    test "the MCP client library is loaded, never started" do
      for name <- Profile.names() do
        assert {:lemon_mcp, :load} in Profile.get(name).applications
        refute :lemon_mcp in Profile.running_apps(name)
      end
    end

    test "runtime_min is the headless runtime: runtime_full minus the web UI" do
      assert Profile.get(:runtime_full).applications --
               Profile.get(:runtime_min).applications == [lemon_web: :permanent]

      assert Profile.get(:runtime_min).applications --
               Profile.get(:runtime_full).applications == []
    end

    test "each profile names every umbrella app its apps start" do
      deps = umbrella_runtime_deps()

      for name <- Profile.names() do
        apps = Profile.app_list(name)
        closure = closure(Enum.filter(apps, &Map.has_key?(deps, &1)), deps)
        unnamed = (closure -- apps) -- published_packages()

        assert unnamed == [],
               "#{name} starts #{inspect(unnamed)} without naming them in priv/runtime_profiles.exs"
      end
    end
  end

  describe "deployment docs" do
    test "the profiles table names every umbrella app of each profile" do
      doc = File.read!(Path.join(@repo_root, "docs/release/deployment_flows.md"))
      deps = umbrella_runtime_deps()

      for name <- Profile.names() do
        release = Profile.release_name(name)
        [row] = Regex.run(~r/^\| `#{release}` \|.*$/m, doc)
        listed = ~r/`(\w+)`/ |> Regex.scan(row) |> Enum.map(fn [_, app] -> app end)

        for app <- Profile.app_list(name), Map.has_key?(deps, app) do
          assert Atom.to_string(app) in listed,
                 "docs/release/deployment_flows.md: #{release} row does not list #{app}"
        end

        for app <- listed,
            app != release,
            String.starts_with?(app, "lemon_") or app == "coding_agent" do
          assert String.to_atom(app) in Profile.app_list(name),
                 "docs/release/deployment_flows.md: #{release} row lists #{app}, which it does not start"
        end
      end
    end
  end

  defp published_packages do
    [_, list] =
      Regex.run(
        ~r/^PACKAGES=\(([^)]*)\)/m,
        File.read!(Path.join(@repo_root, "scripts/verify_packages"))
      )

    list |> String.split() |> Enum.map(&String.to_atom/1)
  end

  # Umbrella app => the umbrella apps it starts (in_umbrella deps that are
  # neither `runtime: false` nor restricted with `only:`).
  defp umbrella_runtime_deps do
    for mix_exs <- Path.wildcard(Path.join(@repo_root, "apps/*/mix.exs")), into: %{} do
      app = mix_exs |> Path.dirname() |> Path.basename() |> String.to_atom()

      deps =
        for [line, dep] <-
              Regex.scan(~r/\{:(\w+),[^}]*in_umbrella: true[^}]*\}/, File.read!(mix_exs)),
            not (line =~ "runtime: false" or line =~ "only:"),
            do: String.to_atom(dep)

      {app, deps}
    end
  end

  defp closure(apps, deps), do: closure(apps, deps, MapSet.new())

  defp closure([], _deps, seen), do: MapSet.to_list(seen)

  defp closure([app | rest], deps, seen) do
    if MapSet.member?(seen, app) do
      closure(rest, deps, seen)
    else
      closure(Map.get(deps, app, []) ++ rest, deps, MapSet.put(seen, app))
    end
  end
end

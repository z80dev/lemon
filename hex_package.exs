defmodule Lemon.HexPackage do
  @moduledoc false

  # Shared packaging facts for the umbrella apps that publish to hex.
  #
  # Each publishable app's mix.exs loads this file:
  #
  #     Code.require_file("../../hex_package.exs", __DIR__)
  #
  # and wraps its dependency list in `Lemon.HexPackage.deps/1`.
  #
  # Why: sibling packages depend on each other with `in_umbrella: true`, and
  # `mix hex.build` keeps only Hex-SCM dependencies. A path dep is not an
  # error to hex — it is *dropped*, so an unguarded `mix hex.publish` would
  # ship a tarball claiming lemon_router has no dependencies at all. Building
  # with LEMON_HEX_PUBLISH=1 rewrites those path deps into the published
  # requirements; without it nothing changes, so the umbrella dev workflow
  # (compile, test, `mix deps.get`) never sees the hex form.
  #
  # An umbrella dep that is not in @packages raises in publish mode rather
  # than being dropped — that is the whole point of the mechanism.

  # Every published package starts at 0.1.0 and moves together for now (D10).
  @requirement "~> 0.1"

  @env_var "LEMON_HEX_PUBLISH"

  # OTP application => hex package name. The application name is what every
  # module and config key already says and never changes; the hex name is what
  # a third party types into their own deps. They differ for the two apps that
  # predate the `lemon_` prefix.
  @packages %{
    ai: :lemon_ai,
    agent_core: :lemon_agent,
    lemon_core: :lemon_core,
    lemon_media: :lemon_media,
    lemon_memory: :lemon_memory,
    lemon_router: :lemon_router,
    lemon_gateway: :lemon_gateway,
    lemon_channels: :lemon_channels,
    lemon_platform_test: :lemon_platform_test
  }

  @doc "The hex package name for a publishable umbrella app."
  def name(app), do: Map.fetch!(@packages, app)

  @doc "True when the build is producing a hex tarball rather than an umbrella build."
  def publishing?, do: System.get_env(@env_var) in ["1", "true"]

  @doc """
  Rewrites `in_umbrella: true` deps into hex requirements when publishing.

  Leaves the list untouched otherwise, so this is a no-op for every umbrella
  command.
  """
  def deps(deps) when is_list(deps) do
    if publishing?(), do: Enum.map(deps, &to_hex_dep/1), else: deps
  end

  defp to_hex_dep({app, opts} = dep) when is_atom(app) and is_list(opts) do
    if Keyword.get(opts, :in_umbrella) do
      {app, @requirement,
       opts |> Keyword.delete(:in_umbrella) |> Keyword.put(:hex, hex_name!(app))}
    else
      dep
    end
  end

  defp to_hex_dep(dep), do: dep

  defp hex_name!(app) do
    Map.get(@packages, app) ||
      Mix.raise("""
      #{inspect(app)} is an umbrella dependency of this package but is not published to hex.

      A hex release cannot depend on an unpublished umbrella app: `mix hex.build`
      would silently drop the dependency and the release would fail to compile for
      anyone outside this repository.

      Resolve it one of these ways before publishing:

        * publish #{inspect(app)} too, and add it to @packages in hex_package.exs
        * make the dependency optional and degrade when the module is absent
        * invert the dependency so #{inspect(app)} registers with this package at boot
      """)
  end
end

Code.require_file("rel/distribution.exs", __DIR__)

defmodule Lemon.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "2026.11.11",
      start_permanent: Mix.env() == :prod,
      # Coverage thresholds are enforced per app; see each app's mix.exs.
      deps: deps(),
      releases: releases(),
      dialyzer: dialyzer()
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  defp deps do
    [
      {:benchee, "~> 1.3", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Dialyzer lane: the `dialyzer` job in .github/workflows/ci.yml runs the
  # whole umbrella and scripts/dialyzer_gate.sh gates the clean apps. PLTs are
  # written under _build/ so they're picked up by the existing gitignore rule
  # and can be cached in CI keyed on mix.lock.
  defp dialyzer do
    [
      plt_core_path: "_build/dialyzer",
      plt_local_path: "_build/dialyzer",
      # :nostrum is runtime: false in lemon_channels, so dialyxir's automatic
      # per-app PLT discovery never pulls it in on its own; add it explicitly
      # so Discord adapter calls into Nostrum.Api.* type-check.
      plt_add_apps: [:mix, :ex_unit, :public_key, :nostrum],
      # Umbrella apps are analysed from their own beams on every run. Keeping
      # them out of the dependency PLT means a code change no longer makes the
      # cached PLT stale (dialyxir otherwise adds every in_umbrella dependency).
      plt_ignore_apps: umbrella_apps(),
      flags: [:error_handling, :unmatched_returns],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  defp umbrella_apps do
    for mix_file <- Path.wildcard(Path.join(__DIR__, "apps/*/mix.exs")) do
      mix_file |> Path.dirname() |> Path.basename() |> String.to_atom()
    end
  end

  # Runtime release configuration
  #
  # Each release `lemon_<profile>` ships exactly the applications of one
  # runtime profile in apps/lemon_core/priv/runtime_profiles.exs, the single
  # source LemonCore.Runtime.Profile also compiles: the source launcher, the
  # releases, /healthz and `lemon doctor` all start or expect the same list.
  # That file documents why each application is named.
  defp releases do
    for {profile, spec} <- runtime_profiles() do
      {:"lemon_#{profile}",
       [
         applications: Keyword.fetch!(spec, :applications),
         include_executables_for: [:unix],
         steps: [
           :assemble,
           &Lemon.DistributionRelease.secure/1,
           &bundle_python/1,
           &bundle_browser_driver/1,
           &stamp_build/1,
           :tar
         ]
       ]}
    end
  end

  defp runtime_profiles do
    {profiles, _binding} =
      Code.eval_file("apps/lemon_core/priv/runtime_profiles.exs", __DIR__)

    profiles
  end

  defp stamp_build(release) do
    commit =
      System.get_env("LEMON_GIT_SHA") ||
        case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha)
          _ -> "unknown"
        end

    metadata = %{
      version: release.version,
      commit: commit,
      channel: System.get_env("LEMON_CHANNEL") || "stable"
    }

    File.write!(Path.join(release.version_path, "lemon-build.json"), Jason.encode!(metadata))
    release
  end

  # Runtime releases ship the local browser driver so a packaged install needs
  # only Node.js and Chrome, never a source checkout. The driver is rebuilt from
  # the lockfile on every release (a stale dist/ must not ship), and only its
  # production dependencies are staged under lemon_browser's priv/driver, where
  # LemonBrowser.LocalServer resolves it.
  defp bundle_browser_driver(release) do
    client = Path.expand("clients/lemon-browser-node", __DIR__)
    vsn = release.applications |> Map.fetch!(:lemon_browser) |> Keyword.fetch!(:vsn)
    target = Path.join([release.path, "lib", "lemon_browser-#{vsn}", "priv", "driver"])

    npm!(client, ["ci", "--no-audit", "--no-fund"])
    npm!(client, ["run", "build"])

    File.rm_rf!(target)
    File.mkdir_p!(target)
    File.cp_r!(Path.join(client, "dist"), target)

    for file <- ~w(package.json package-lock.json) do
      File.cp!(Path.join(client, file), Path.join(target, file))
    end

    npm!(target, ["ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"])
    release
  end

  defp npm!(dir, args) do
    npm =
      System.find_executable("npm") || Mix.raise("npm is required to bundle the browser driver")

    case System.cmd(npm, args, cd: dir, into: IO.stream(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> Mix.raise("npm #{Enum.join(args, " ")} failed in #{dir} (exit #{status})")
    end
  end

  defp bundle_python(release) do
    if :os.type() == {:unix, :darwin} do
      do_bundle_python(release)
    else
      release
    end
  end

  defp do_bundle_python(release) do
    lock = Jason.decode!(File.read!(Path.expand("rel/python.lock.json", __DIR__)))
    entry = Map.fetch!(lock, "darwin-arm64")
    url = Map.fetch!(entry, "url")
    expected_sha = entry |> Map.fetch!("sha256") |> String.downcase()
    series = python_series(Map.fetch!(entry, "version"))

    cache_dir = Path.join(System.tmp_dir!(), "lemon-python-build-cache")
    File.mkdir_p!(cache_dir)
    archive = Path.join(cache_dir, "cpython-darwin-arm64-#{expected_sha}.tar.gz")

    unless File.regular?(archive) and sha256_file(archive) == expected_sha do
      download = "#{archive}.download-#{System.unique_integer([:positive])}"
      File.rm_rf!(download)
      download_file!(url, download)
      actual_sha = sha256_file(download)

      if actual_sha != expected_sha do
        File.rm_rf!(download)

        Mix.raise(
          "pinned python artifact sha256 mismatch: expected #{expected_sha}, got #{actual_sha}"
        )
      end

      File.rename!(download, archive)
    end

    tar = System.find_executable("tar") || Mix.raise("tar is required to bundle python")
    staging = Path.join(cache_dir, "extract-#{System.unique_integer([:positive])}")
    File.rm_rf!(staging)
    File.mkdir_p!(staging)

    case System.cmd(tar, ["-xzf", archive, "-C", staging], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, status} ->
        File.rm_rf!(staging)
        Mix.raise("extracting the pinned python failed (exit #{status}): #{output}")
    end

    # python-build-standalone's install_only layout is a single `python/` root.
    source = Path.join(staging, "python")
    source = if File.dir?(source), do: source, else: staging

    target = Path.join(release.path, "python")
    File.rm_rf!(target)
    File.cp_r!(source, target)
    File.rm_rf!(staging)

    # Development headers, pkg-config, docs, Tk/Tcl and the stdlib test suite
    # are dead weight for the worker helpers.
    for pruned <- [
          Path.join(target, "include"),
          Path.join(target, "share"),
          Path.join([target, "lib", "pkgconfig"])
        ] do
      File.rm_rf!(pruned)
    end

    for pruned <- ~w(test idlelib tkinter turtledemo ensurepip) do
      File.rm_rf!(Path.join([target, "lib", series, pruned]))
    end

    for pattern <- ~w(lib/tcl* lib/tk* lib/itcl* bin/idle* bin/pydoc* bin/*-config) do
      target |> Path.join(pattern) |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)
    end

    # `bin/python3` ships as a symlink; releases must contain no links at all
    # (LemonCore.Update.Archive rejects them), so it becomes a real copy.
    versioned = Path.join([target, "bin", series])
    python3 = Path.join([target, "bin", "python3"])

    unless File.regular?(versioned) do
      Mix.raise("pinned python is missing a regular bin/#{series}")
    end

    File.rm_rf!(python3)
    File.cp!(versioned, python3)
    File.chmod!(python3, 0o755)

    retain_python_licenses(target, series)
    for link <- symlinks(target), do: File.rm!(link)

    case symlinks(target) do
      # Mix's :tar step only packages standard release paths and registered overlays.
      [] -> %{release | overlays: Enum.uniq(["python" | release.overlays])}
      links -> Mix.raise("bundled python still contains symlinks:\n#{Enum.join(links, "\n")}")
    end
  end

  # Redistributing CPython requires the PSF license text, and the pinned build
  # comes from astral-sh/python-build-standalone (MPL-2.0). Both notices are
  # collected under python/licenses/ so they survive any future pruning.
  defp retain_python_licenses(target, series) do
    cpython = Path.join([target, "lib", series, "LICENSE.txt"])

    unless File.regular?(cpython) do
      Mix.raise("pinned python is missing lib/#{series}/LICENSE.txt")
    end

    builder =
      Path.expand("rel/python_licenses/python-build-standalone-LICENSE.txt", __DIR__)

    notices = Path.join(target, "licenses")
    File.mkdir_p!(notices)
    File.cp!(cpython, Path.join(notices, "CPYTHON-LICENSE.txt"))
    File.cp!(builder, Path.join(notices, "PYTHON-BUILD-STANDALONE-LICENSE.txt"))
  end

  defp symlinks(dir) do
    find = System.find_executable("find") || Mix.raise("find is required to bundle python")

    case System.cmd(find, [dir, "-type", "l"], stderr_to_stdout: true) do
      {output, 0} -> String.split(output, "\n", trim: true)
      {output, status} -> Mix.raise("listing symlinks failed (exit #{status}): #{output}")
    end
  end

  defp python_series(version) do
    case Regex.run(~r/^(\d+)\.(\d+)\./, version) do
      [_, major, minor] -> "python#{major}.#{minor}"
      _ -> Mix.raise("rel/python.lock.json version is not major.minor.patch: #{version}")
    end
  end

  defp sha256_file(path) do
    File.stream!(path, 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp download_file!(url, target_path) do
    if curl = System.find_executable("curl") do
      case System.cmd(curl, ["-fsSL", url, "-o", target_path], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, status} ->
          Mix.raise("curl failed to download #{url} (exit #{status}): #{output}")
      end
    else
      {:ok, _} = Application.ensure_all_started(:inets)
      {:ok, _} = Application.ensure_all_started(:ssl)

      request = {String.to_charlist(url), []}

      case :httpc.request(:get, request, [autoredirect: true], body_format: :binary) do
        {:ok, {{_, 200, _}, _headers, body}} ->
          File.write!(target_path, body)

        other ->
          Mix.raise("downloading #{url} failed: #{inspect(other)}")
      end
    end
  end
end

defmodule LemonNew.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/z80dev/lemon"

  def project do
    [
      app: :lemon_new,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      homepage_url: @source_url,
      description: """
      Lemon project generator. Scaffolds a BEAM agent project wired to the
      lemon platform packages: an agent loop, one tool, one channel, and a
      test suite that runs without an API key.
      """
    ]
  end

  def application do
    [extra_applications: [:eex]]
  end

  # Deliberately none. The installer is distributed as a mix archive, which
  # cannot carry dependencies: anything listed here is simply unavailable at
  # `mix lemon.new` time. Templates are compiled into the beam files.
  defp deps, do: []

  defp docs do
    [
      source_ref: "v#{@version}",
      extras: ["README.md"]
    ]
  end

  defp package do
    [
      maintainers: ["z80"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib templates mix.exs README.md)
    ]
  end
end

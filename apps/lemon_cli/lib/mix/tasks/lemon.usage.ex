defmodule Mix.Tasks.Lemon.Usage do
  use Mix.Task

  @shortdoc "Show redacted usage diagnostics"
  @moduledoc "Source wrapper for `lemon usage`. Run `lemon usage --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonCli.Usage.CLI.run(args)
  rescue
    error in LemonCore.CLI.Error -> Mix.raise(error.message)
  end
end

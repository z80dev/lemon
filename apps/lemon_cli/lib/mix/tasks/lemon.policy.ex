defmodule Mix.Tasks.Lemon.Policy do
  use Mix.Task

  @shortdoc "Manage chat model and thinking defaults"
  @moduledoc "Source wrapper for `lemon policy`. Run `lemon policy --help` for options."
  @requirements ["loadpaths"]

  @impl true
  def run(args) do
    LemonCli.PolicyCommand.run(args)
  rescue
    error in LemonCore.CLI.Error -> Mix.raise(error.message)
  end
end

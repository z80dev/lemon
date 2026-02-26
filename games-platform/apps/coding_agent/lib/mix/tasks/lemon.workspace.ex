defmodule Mix.Tasks.Lemon.Workspace do
  use Mix.Task

  @shortdoc "Initialize ~/.lemon/agent/workspace bootstrap files"
  @moduledoc """
  Initialize the Lemon workspace with bootstrap files.

  Usage:
    mix lemon.workspace init [--workspace-dir PATH]

  This creates missing files under `~/.lemon/agent/workspace` using
  the bundled templates. Existing files are left untouched.
  """

  alias CodingAgent.Workspace

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, rest, _invalid} =
      OptionParser.parse(args,
        switches: [workspace_dir: :string],
        aliases: [w: :workspace_dir]
      )

    case rest do
      ["init"] ->
        workspace_dir = opts[:workspace_dir]

        if workspace_dir do
          Workspace.ensure_workspace(workspace_dir: workspace_dir)
          Mix.shell().info("Workspace initialized at #{workspace_dir}")
        else
          Workspace.ensure_workspace()
          Mix.shell().info("Workspace initialized at #{Workspace.workspace_dir()}")
        end

      _ ->
        Mix.shell().info("Usage: mix lemon.workspace init [--workspace-dir PATH]")
    end
  end
end

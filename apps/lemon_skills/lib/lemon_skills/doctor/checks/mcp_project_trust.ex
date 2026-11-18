defmodule LemonSkills.Doctor.Checks.McpProjectTrust do
  @moduledoc """
  Reports project MCP files (`.lemon/mcp.json` and other tools' files such as
  `.mcp.json` or `.vscode/mcp.json`) in the doctor's project directory that are
  waiting for operator trust, and project servers rejected for referencing host
  values or secrets. See `LemonSkills.McpDiscovery.project_status/2`.

  Registered with the `LemonCore.Doctor` framework via
  `config :lemon_core, :doctor_checks, [__MODULE__]`.
  """

  alias LemonCore.Doctor.Check
  alias LemonSkills.McpDiscovery

  @name "mcp.project_trust"

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    status = McpDiscovery.project_status(Keyword.get(opts, :project_dir, File.cwd!()))

    # With external discovery off, only Lemon's own project file is used.
    if McpDiscovery.enabled?() or ".lemon/mcp.json" in status.files do
      check(status)
    else
      [Check.skip(@name, "External MCP config discovery is disabled.")]
    end
  end

  defp check(%{trust: :none}),
    do: [Check.skip(@name, "No project MCP files in this project.")]

  defp check(%{trust: trust} = status) do
    rejected =
      for %{"reason" => "host_value_reference", "server" => server} <- status.findings,
          do: server

    # Only suggest `--cwd` when the path can be shown and quoted exactly.
    review =
      if status.cwd_arg,
        do: "Review with `lemon mcp trust --cwd #{status.cwd_arg}`.",
        else: "Review with `lemon mcp trust` run inside the project directory."

    trust_check =
      case trust do
        :trusted ->
          Check.pass(@name, "Project MCP files are trusted for their current content.")

        :changed ->
          Check.warn(
            @name,
            "Project MCP files changed since they were trusted (#{files(status)}); " <>
              "#{length(status.servers)} server(s) will not start until trusted again.",
            review
          )

        :untrusted ->
          Check.warn(
            @name,
            "Untrusted project MCP files found (#{files(status)}); " <>
              "#{length(status.servers)} server(s) will not start until trusted.",
            review
          )
      end

    if rejected == [] do
      [trust_check]
    else
      [
        trust_check,
        Check.warn(
          "mcp.project_host_values",
          "Project MCP servers rejected for referencing host environment, files or secrets: " <>
            Enum.join(rejected, ", ") <> ".",
          "Project MCP files cannot use ${VAR}, {env:}, {file:}, env_vars, env_http_headers, " <>
            "bearer_token_env_var or OAuth client_secret_secret/token_secret; configure " <>
            "credentials in the global Lemon MCP config instead."
        )
      ]
    end
  end

  defp files(status), do: Enum.join(status.files, ", ")
end

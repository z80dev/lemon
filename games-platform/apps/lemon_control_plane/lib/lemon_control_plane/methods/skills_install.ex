defmodule LemonControlPlane.Methods.SkillsInstall do
  @moduledoc """
  Handler for the skills.install control plane method.

  Installs a skill from a source (Git URL, local path, etc.).

  Per parity requirement, skill installation goes through the approval flow
  when approvals are enabled. The install will request approval via
  ApprovalsBridge and wait for resolution before proceeding.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "skills.install"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, ctx) do
    cwd = params["cwd"]
    skill_key = params["skillKey"] || params["skill_key"]
    _install_id = params["installId"] || params["install_id"]
    _timeout_ms = params["timeoutMs"] || params["timeout_ms"] || 60_000

    if is_nil(skill_key) or skill_key == "" do
      {:error, Errors.invalid_request("skillKey is required")}
    else
      if Code.ensure_loaded?(LemonSkills.Installer) do
        # Installer.install/2 takes (source, opts) where source is the skill_key/URL
        # and opts includes cwd, approval settings, etc.
        #
        # Note: We pass approve: false to respect the approval flow.
        # The Installer will request approval via ApprovalsBridge if enabled.
        # This ensures parity with the contract that requires approval gating.
        opts = [
          cwd: cwd,
          approve: false,
          session_key: ctx[:session_key],
          agent_id: ctx[:agent_id],
          run_id: ctx[:run_id]
        ]

        case LemonSkills.Installer.install(skill_key, opts) do
          {:ok, entry} ->
            {:ok, %{
              "installed" => true,
              "skillKey" => entry.key,
              "name" => entry.name,
              "path" => entry.path,
              "source" => to_string(entry.source)
            }}

          {:error, "Skill install denied by user"} ->
            {:error, Errors.permission_denied("Skill installation was denied")}

          {:error, "Skill install approval timed out"} ->
            {:error, Errors.timeout("Skill installation approval timed out")}

          {:error, reason} ->
            {:error, Errors.internal_error("Install failed", inspect(reason))}
        end
      else
        {:error, Errors.not_implemented("LemonSkills.Installer not available")}
      end
    end
  end
end

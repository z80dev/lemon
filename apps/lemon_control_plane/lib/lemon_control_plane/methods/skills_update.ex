defmodule LemonControlPlane.Methods.SkillsUpdate do
  @moduledoc """
  Handler for the skills.update control plane method.

  Updates skill configuration (enable/disable, env vars, etc.).

  Unlike skills.install, this method primarily handles configuration changes:
  - Enabling/disabling skills
  - Setting environment variables for skills
  - Optionally triggering a version update (if no config changes specified)
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "skills.update"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, ctx) do
    cwd = params["cwd"]
    skill_key = params["skillKey"] || params["skill_key"]
    enabled = params["enabled"]
    env = params["env"]

    if is_nil(skill_key) or skill_key == "" do
      {:error, Errors.invalid_request("skillKey is required")}
    else
      # Check if this is a config update (enabled/env) or a version update
      has_config_changes = not is_nil(enabled) or (is_map(env) and map_size(env) > 0)

      if has_config_changes do
        # Apply configuration changes via LemonSkills.Config
        apply_config_changes(skill_key, enabled, env, cwd)
      else
        # No config changes specified - perform version update via Installer
        perform_version_update(skill_key, cwd, ctx)
      end
    end
  end

  # Apply enable/disable and env changes via LemonSkills.Config
  defp apply_config_changes(skill_key, enabled, env, cwd) do
    results = []

    # Handle enabled/disabled state
    results =
      if not is_nil(enabled) do
        result =
          if Code.ensure_loaded?(LemonSkills.Config) do
            if enabled do
              LemonSkills.Config.enable(skill_key, cwd: cwd)
            else
              LemonSkills.Config.disable(skill_key, cwd: cwd)
            end
          else
            # Fallback: store in LemonCore.Store
            LemonCore.Store.put(:skills_config, {cwd, skill_key, :enabled}, enabled)
            :ok
          end

        [{:enabled, result} | results]
      else
        results
      end

    # Handle env changes
    results =
      if is_map(env) and map_size(env) > 0 do
        result =
          if Code.ensure_loaded?(LemonSkills.Config) do
            # Get existing config and merge env
            existing = LemonSkills.Config.get_skill_config(skill_key, cwd)
            existing_env = Map.get(existing, "env", %{})
            merged_env = Map.merge(existing_env, env)
            updated_config = Map.put(existing, "env", merged_env)
            LemonSkills.Config.set_skill_config(skill_key, updated_config, cwd: cwd)
          else
            # Fallback: store in LemonCore.Store
            LemonCore.Store.put(:skills_config, {cwd, skill_key, :env}, env)
            :ok
          end

        [{:env, result} | results]
      else
        results
      end

    # Check for errors
    errors = Enum.filter(results, fn {_key, result} -> result != :ok end)

    if length(errors) > 0 do
      error_details = Enum.map(errors, fn {key, {:error, reason}} ->
        "#{key}: #{inspect(reason)}"
      end)
      {:error, Errors.internal_error("Update failed", Enum.join(error_details, "; "))}
    else
      # Get current enabled state for response
      current_enabled =
        if Code.ensure_loaded?(LemonSkills.Config) do
          not LemonSkills.Config.skill_disabled?(skill_key, cwd)
        else
          enabled
        end

      {:ok, %{
        "skillKey" => skill_key,
        "enabled" => current_enabled,
        "env" => env
      }}
    end
  end

  # Perform version update via Installer (when no config changes specified)
  defp perform_version_update(skill_key, cwd, ctx) do
    if Code.ensure_loaded?(LemonSkills.Installer) do
      # Build opts with approval context
      # Note: For control plane requests, we pass approve: false to respect approval flow
      # The approval will be requested via ApprovalsBridge if enabled
      opts = [
        cwd: cwd,
        approve: false,
        session_key: ctx[:session_key],
        agent_id: ctx[:agent_id],
        run_id: ctx[:run_id]
      ]

      case LemonSkills.Installer.update(skill_key, opts) do
        {:ok, entry} ->
          {:ok, %{
            "skillKey" => entry.key,
            "enabled" => entry.enabled,
            "name" => entry.name,
            "source" => to_string(entry.source),
            "updated" => true
          }}

        {:error, reason} ->
          {:error, Errors.internal_error("Update failed", inspect(reason))}
      end
    else
      {:error, Errors.not_implemented("LemonSkills.Installer not available")}
    end
  end
end

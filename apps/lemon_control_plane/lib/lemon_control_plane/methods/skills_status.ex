defmodule LemonControlPlane.Methods.SkillsStatus do
  @moduledoc """
  Handler for the skills.status method.

  Returns the status of installed skills.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "skills.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    cwd = params["cwd"] || File.cwd!()
    skills = get_skills_status(cwd)

    {:ok,
     %{
       "skills" => skills,
       "summary" => summarize(skills)
     }}
  end

  defp get_skills_status(cwd) do
    if Code.ensure_loaded?(LemonSkills.Registry) do
      LemonSkills.Registry.list(cwd: cwd)
      |> Enum.map(&format_skill(&1, cwd))
    else
      get_skills_from_extensions(cwd)
    end
  rescue
    _ -> []
  end

  defp get_skills_from_extensions(cwd) do
    if Code.ensure_loaded?(CodingAgent.Extensions) do
      paths = [
        Path.join([cwd, ".lemon", "extensions"]),
        Path.join([System.user_home(), ".lemon", "extensions"])
      ]

      {:ok, extensions, _errors, _validation} =
        CodingAgent.Extensions.load_extensions_with_errors(paths)

      extensions
      |> Enum.map(fn ext_module ->
        %{
          "key" => to_string(ext_module),
          "name" => extract_extension_name(ext_module),
          "enabled" => true,
          "source" => "extension",
          "status" => %{"ready" => true}
        }
      end)
    else
      []
    end
  rescue
    _ -> []
  end

  defp format_skill(skill) when is_struct(skill) do
    status = skill_status(skill)

    %{
      "key" => skill.key,
      "name" => skill.name,
      "description" => skill.description,
      "enabled" => skill.enabled,
      "source" => to_string(skill.source),
      "status" => format_status(status)
    }
  end

  defp format_skill(skill) when is_map(skill) do
    %{
      "key" => map_value(skill, :key),
      "name" => map_value(skill, :name),
      "description" => map_value(skill, :description),
      "enabled" => map_value(skill, :enabled, true),
      "source" => to_string(map_value(skill, :source, :unknown)),
      "status" => format_status(map_value(skill, :status))
    }
  end

  defp format_skill(skill, cwd) when is_struct(skill) do
    status = skill_status(skill, cwd)

    %{
      "key" => skill.key,
      "name" => skill.name,
      "description" => skill.description,
      "enabled" => skill.enabled,
      "source" => to_string(skill.source),
      "status" => format_status(status)
    }
  end

  defp format_skill(skill, _cwd), do: format_skill(skill)

  defp format_status(nil), do: %{"ready" => true}

  defp format_status(status) when is_map(status) do
    %{
      "activationState" => status_value(status, :activation_state),
      "ready" => status_value(status, :ready, true),
      "platformCompatible" => status_value(status, :platform_compatible, true),
      "missingBins" => status_value(status, :missing_bins, []),
      "missingConfig" => status_value(status, :missing_config, []),
      "missingEnvVars" => status_value(status, :missing_env_vars, []),
      "missingTools" => status_value(status, :missing_tools, []),
      "disabled" => status_value(status, :disabled, false),
      "error" => status_value(status, :error)
    }
  end

  defp format_status(_), do: %{"ready" => true}

  defp skill_status(skill, cwd \\ nil) do
    if Code.ensure_loaded?(LemonSkills.Status) and
         function_exported?(LemonSkills.Status, :check_entry, 2) do
      LemonSkills.Status.check_entry(skill, cwd: cwd)
    else
      skill.status
    end
  rescue
    _ -> skill.status
  end

  defp summarize(skills) do
    activation_counts =
      skills
      |> Enum.map(&get_in(&1, ["status", "activationState"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.frequencies()

    source_counts =
      skills
      |> Enum.map(&Map.get(&1, "source", "unknown"))
      |> Enum.frequencies()

    %{
      "count" => length(skills),
      "readyCount" => Enum.count(skills, &get_in(&1, ["status", "ready"])),
      "notReadyCount" => Map.get(activation_counts, "not_ready", 0),
      "hiddenCount" => Map.get(activation_counts, "hidden", 0),
      "blockedCount" => Map.get(activation_counts, "blocked", 0),
      "platformIncompatibleCount" => Map.get(activation_counts, "platform_incompatible", 0),
      "activationStateCounts" => activation_counts,
      "sourceCounts" => source_counts,
      "missingRequirementCounts" => missing_requirement_counts(skills)
    }
  end

  defp missing_requirement_counts(skills) do
    Enum.reduce(skills, %{"bins" => 0, "config" => 0, "envVars" => 0, "tools" => 0}, fn skill,
                                                                                        acc ->
      status = Map.get(skill, "status", %{})

      acc
      |> Map.update!("bins", &(&1 + length(Map.get(status, "missingBins", []))))
      |> Map.update!("config", &(&1 + length(Map.get(status, "missingConfig", []))))
      |> Map.update!("envVars", &(&1 + length(Map.get(status, "missingEnvVars", []))))
      |> Map.update!("tools", &(&1 + length(Map.get(status, "missingTools", []))))
    end)
  end

  defp status_value(status, key, default \\ nil) do
    cond do
      Map.has_key?(status, key) ->
        format_status_value(Map.fetch!(status, key))

      Map.has_key?(status, Atom.to_string(key)) ->
        format_status_value(Map.fetch!(status, Atom.to_string(key)))

      true ->
        default
    end
  end

  defp map_value(map, key, default \\ nil) do
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.fetch!(map, Atom.to_string(key))
      true -> default
    end
  end

  defp format_status_value(value) when is_boolean(value), do: value
  defp format_status_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_status_value(value), do: value

  defp extract_extension_name(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp extract_extension_name(other), do: to_string(other)
end

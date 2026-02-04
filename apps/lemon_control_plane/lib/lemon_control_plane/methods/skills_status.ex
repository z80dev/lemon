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
    {:ok, %{"skills" => skills}}
  end

  defp get_skills_status(cwd) do
    # Try LemonSkills.Registry first
    if Code.ensure_loaded?(LemonSkills.Registry) do
      # Registry.list/1 expects keyword opts with :cwd, not a string
      LemonSkills.Registry.list(cwd: cwd)
      |> Enum.map(&format_skill/1)
    else
      # Fallback: try CodingAgent.Extensions
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
    %{
      "key" => skill.key,
      "name" => skill.name,
      "description" => skill.description,
      "enabled" => skill.enabled,
      "source" => to_string(skill.source),
      "status" => format_status(skill.status)
    }
  end

  defp format_skill(skill) when is_map(skill) do
    %{
      "key" => skill[:key] || skill["key"],
      "name" => skill[:name] || skill["name"],
      "description" => skill[:description] || skill["description"],
      "enabled" => skill[:enabled] || skill["enabled"] || true,
      "source" => to_string(skill[:source] || skill["source"] || :unknown),
      "status" => format_status(skill[:status] || skill["status"])
    }
  end

  defp format_status(nil), do: %{"ready" => true}
  defp format_status(status) when is_map(status) do
    %{
      "ready" => status[:ready] || status["ready"] || true,
      "error" => status[:error] || status["error"]
    }
  end
  defp format_status(_), do: %{"ready" => true}

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

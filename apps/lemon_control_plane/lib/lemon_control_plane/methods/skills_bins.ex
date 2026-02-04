defmodule LemonControlPlane.Methods.SkillsBins do
  @moduledoc """
  Handler for the skills.bins control plane method.

  Returns required binary dependencies for skills.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "skills.bins"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    cwd = params["cwd"]

    # Get required binaries for skills in the cwd
    bins =
      if Code.ensure_loaded?(LemonSkills.Registry) do
        opts = if cwd, do: [cwd: cwd], else: []
        skills = LemonSkills.Registry.list(opts)

        skills
        |> Enum.flat_map(fn skill ->
          case skill.manifest do
            %{bins: bins} when is_list(bins) -> bins
            _ -> []
          end
        end)
        |> Enum.uniq_by(& &1[:name] || &1["name"])
        |> Enum.map(&bin_to_map/1)
      else
        []
      end

    {:ok, %{"bins" => bins}}
  end

  defp bin_to_map(bin) when is_map(bin) do
    %{
      "name" => bin[:name] || bin["name"],
      "command" => bin[:command] || bin["command"],
      "version" => bin[:version] || bin["version"],
      "required" => bin[:required] || bin["required"] || false,
      "installHint" => bin[:install_hint] || bin["installHint"]
    }
  end

  defp bin_to_map(name) when is_binary(name) do
    %{"name" => name, "required" => true}
  end
end

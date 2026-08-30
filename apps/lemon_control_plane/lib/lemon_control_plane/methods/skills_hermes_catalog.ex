defmodule LemonControlPlane.Methods.SkillsHermesCatalog do
  @moduledoc """
  Handler for the read-only `skills.hermes.catalog` control-plane method.

  It exposes the live official Nous Research Hermes catalog to clients. Skill
  installation remains a separate, admin-scoped `skills.install` request so the
  normal Lemon audit and approval flow is preserved.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "skills.hermes.catalog"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    if Code.ensure_loaded?(LemonSkills.Sources.Hermes) do
      opts =
        []
        |> maybe_put(:query, params["query"])
        |> maybe_put(:category, params["category"])
        |> maybe_put(:collection, params["collection"])
        |> maybe_put(:details, params["details"])

      case LemonSkills.Sources.Hermes.catalog(opts) do
        {:ok, entries} ->
          installed = installed_keys(params["cwd"])
          skills = Enum.map(entries, &serialize(&1, installed))

          categories =
            skills
            |> Enum.group_by(&{&1["collection"], &1["category"]})
            |> Enum.map(fn {{collection, category}, values} ->
              %{
                "collection" => collection,
                "category" => category,
                "count" => length(values),
                "installedCount" => Enum.count(values, & &1["installed"])
              }
            end)
            |> Enum.sort_by(&{&1["collection"], &1["category"]})

          {:ok,
           %{
             "skills" => skills,
             "categories" => categories,
             "summary" => %{
               "source" => "NousResearch/hermes-agent",
               "dynamic" => true,
               "count" => length(skills),
               "categoryCount" => length(categories),
               "installedCount" => Enum.count(skills, & &1["installed"]),
               "detailsIncluded" => params["details"] == true
             }
           }}

        {:error, reason} ->
          {:error, Errors.internal_error("Unable to load Hermes skill catalog", inspect(reason))}
      end
    else
      {:error, Errors.not_implemented("LemonSkills Hermes catalog not available")}
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp installed_keys(cwd) do
    if Code.ensure_loaded?(LemonSkills.Registry) do
      LemonSkills.Registry.list(cwd: cwd) |> MapSet.new(& &1.key)
    else
      MapSet.new()
    end
  end

  defp serialize(entry, installed) do
    %{
      "id" => entry.id,
      "key" => entry.key,
      "name" => entry.name,
      "description" => entry.description,
      "category" => entry.category,
      "collection" => entry.collection,
      "installed" => MapSet.member?(installed, entry.key)
    }
  end
end

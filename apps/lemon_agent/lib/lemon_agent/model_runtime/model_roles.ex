defmodule LemonAgent.ModelRuntime.ModelRoles do
  @moduledoc """
  Expands explicit `@role` selectors using canonical `[model_roles]` metadata.

  Role names and mappings remain strings; no atoms or catalog IDs are created.
  Concrete strings and model maps/structs pass through unchanged. Configured
  aliases expand recursively and errors are actionable strings. Unconfigured
  `@default`, `@smol`, `@slow`, `@plan` and `@commit` use the caller's
  default/current-model fallback; unknown custom roles and cycles never silently choose a different model.
  Catalog lookup and credentials belong to the consuming model resolver.
  """

  @type selector :: String.t() | map()
  @type roles :: %{optional(String.t()) => String.t()}
  @type reason :: String.t()

  @builtins ~w(default smol slow plan commit)

  @doc "Expands a selector into a concrete spec/model, or returns an actionable error."
  @spec resolve(selector(), roles(), selector() | nil) ::
          {:ok, selector()} | {:error, reason()}
  def resolve(selector, roles, fallback) do
    with :ok <- validate(roles) do
      expand(selector, roles, fallback, [])
    end
  end

  @doc "Validates all configured aliases, including unused overrides, without catalog lookup."
  @spec validate(roles()) :: :ok | {:error, reason()}
  def validate(roles) when is_map(roles) do
    Enum.reduce_while(roles, :ok, fn {role, value}, :ok ->
      cond do
        not valid_role?(role) ->
          {:halt,
           {:error, "model_roles keys must be non-empty role names without @ or whitespace"}}

        not is_binary(value) or String.trim(value) == "" ->
          {:halt, {:error, "model_roles.#{role} must be a non-empty model selector string"}}

        true ->
          # Built-ins may legitimately depend on a caller's concrete model.
          case expand("@" <> role, roles, "validation-fallback", []) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  def validate(_), do: {:error, "model_roles must be a table of model selector strings"}

  defp expand(selector, roles, fallback, visited) when is_binary(selector) do
    case String.trim(selector) do
      "@" <> role -> expand_role(role, roles, fallback, visited)
      "" -> {:error, "model selector must not be empty"}
      _ -> {:ok, selector}
    end
  end

  defp expand(model, _roles, _fallback, _visited) when is_map(model), do: {:ok, model}

  defp expand(_, _roles, _fallback, _visited),
    do: {:error, "a concrete model fallback is required"}

  defp expand_role(role, roles, fallback, visited) do
    cond do
      not valid_role?(role) ->
        {:error, "invalid model role @#{role}; use @ followed by a role name"}

      role in visited ->
        chain = Enum.map_join(Enum.reverse([role | visited]), " -> ", &("@" <> &1))
        {:error, "model role cycle: #{chain}; configure a concrete model in [model_roles]"}

      Map.has_key?(roles, role) ->
        value = Map.fetch!(roles, role)

        if is_binary(value) and String.trim(value) != "" do
          expand(value, roles, fallback, [role | visited])
        else
          {:error, "model_roles.#{role} must be a non-empty model selector string"}
        end

      role in @builtins ->
        expand(fallback, roles, fallback, [role | visited])

      true ->
        {:error, "unknown model role @#{role}; configure model_roles.#{role}"}
    end
  end

  defp valid_role?(role) when is_binary(role) do
    role != "" and not String.contains?(role, "@") and not String.match?(role, ~r/\s/u)
  end

  defp valid_role?(_), do: false
end

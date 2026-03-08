defmodule LemonControlPlane.SkillsConfigStore do
  @moduledoc """
  Typed wrapper for fallback persisted skills configuration.
  """

  alias LemonCore.Store

  @table :skills_config

  @spec get_enabled(binary() | nil, binary()) :: boolean() | nil
  def get_enabled(cwd, skill_key) when is_binary(skill_key),
    do: Store.get(@table, {cwd, skill_key, :enabled})

  @spec put_enabled(binary() | nil, binary(), boolean()) :: :ok | {:error, term()}
  def put_enabled(cwd, skill_key, enabled) when is_binary(skill_key) and is_boolean(enabled),
    do: Store.put(@table, {cwd, skill_key, :enabled}, enabled)

  @spec get_env(binary() | nil, binary()) :: map() | nil
  def get_env(cwd, skill_key) when is_binary(skill_key),
    do: Store.get(@table, {cwd, skill_key, :env})

  @spec put_env(binary() | nil, binary(), map()) :: :ok | {:error, term()}
  def put_env(cwd, skill_key, env) when is_binary(skill_key) and is_map(env),
    do: Store.put(@table, {cwd, skill_key, :env}, env)

  @spec get_config(binary() | nil, binary()) :: map()
  def get_config(cwd, skill_key) when is_binary(skill_key) do
    %{}
    |> maybe_put("enabled", get_enabled(cwd, skill_key))
    |> maybe_put("env", get_env(cwd, skill_key))
  end

  defp maybe_put(config, _key, nil), do: config
  defp maybe_put(config, key, value), do: Map.put(config, key, value)
end

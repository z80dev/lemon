defmodule LemonControlPlane.Methods.NodeSession do
  @moduledoc false

  alias LemonControlPlane.Auth.TokenStore

  def session_generation(auth) do
    auth
    |> get_field(:identity)
    |> case do
      identity when is_map(identity) -> get_field(identity, :sessionGeneration) || 0
      _ -> 0
    end
  end

  def current_session?(node_id, generation) when is_integer(generation) do
    case TokenStore.current_node_generation(node_id) do
      nil -> generation == 0
      current -> current == generation
    end
  end

  def current_session?(_node_id, _generation), do: false

  def get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end

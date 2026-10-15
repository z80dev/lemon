defmodule LemonControlPlane.Methods.LearningTimeline do
  @moduledoc "Read-only, profile-scoped learning timeline for operator clients."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @kinds ~w(all memory user project skill)

  @impl true
  def name, do: "learning.timeline"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) when is_map(params) or is_nil(params) do
    params = params || %{}
    profile = Map.get(params, "profileId", "default")
    kind = Map.get(params, "kind", "all")
    limit = Map.get(params, "limit", 50)

    if valid_profile?(profile) and kind in @kinds and is_integer(limit) and limit in 1..100 do
      case timeline(profile, kind: kind, limit: limit) do
        {:ok, payload} -> {:ok, payload}
        _ -> unavailable()
      end
    else
      invalid_params()
    end
  rescue
    _ -> unavailable()
  catch
    _, _ -> unavailable()
  end

  def handle(_params, _ctx), do: invalid_params()

  defp valid_profile?(value) when is_binary(value),
    do: byte_size(value) <= 64 and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, value)

  defp valid_profile?(_), do: false

  defp timeline(profile, opts) do
    case Application.get_env(:lemon_control_plane, :learning_timeline_fun) do
      fun when is_function(fun, 2) -> fun.(profile, opts)
      _ -> LemonSkills.Timeline.for_profile(profile, opts)
    end
  end

  defp invalid_params,
    do:
      {:error,
       Errors.invalid_request("Choose a valid local profile, learning kind and limit (1–100)")}

  defp unavailable,
    do: {:error, Errors.unavailable("Learning timeline is unavailable")}
end

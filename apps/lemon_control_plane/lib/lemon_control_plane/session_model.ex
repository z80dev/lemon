defmodule LemonControlPlane.SessionModel do
  @moduledoc """
  What model a session will actually run on, for the read-side methods.

  Nothing in the umbrella persists a session's *resolved* model: `LemonRouter.SubmissionBuilder`
  computes it per run from the session policy, the agent profile and the config default, then
  stamps it into the run's meta and forgets it. So there are two honest answers here, and this
  module keeps them apart:

    * `override/1` — the value stored on the session by `sessions.patch`, and nothing else. One
      ETS read, safe to call per row in a listing.
    * `resolve/2` — the same precedence chain `SubmissionBuilder` runs, minus the request-level
      inputs it cannot know about (an explicit `model` on a `chat.send` still wins at run time).
      This calls the `AgentProfiles` GenServer, so it is a per-session read, not a per-row one.

  `describe/1` turns a model id into provider and context window via `LemonAi.Models`, stripping
  the `provider:` / `provider/` prefixes the session store accepts — the same candidate logic
  `LemonRouter.RunProcess.CompactionTrigger` uses to size the context window.
  """

  alias LemonRouter.ModelSelection

  @typedoc "Resolved routing facts for a session, string-keyed for the wire."
  @type t :: %{optional(String.t()) => term()}

  @doc """
  The per-session model override, or nil. Cheap: one session-policy read.
  """
  @spec override(String.t() | nil) :: String.t() | nil
  def override(session_key) when is_binary(session_key) and session_key != "" do
    session_key |> session_policy() |> get_field(:model) |> normalize_string()
  end

  def override(_), do: nil

  @doc """
  The whole session policy, normalized: model and thinking level.

  Values are returned exactly as stored (no resolution, no defaults), so a caller can tell
  "the user pinned this" apart from "this is what it would run".
  """
  @spec overrides(String.t() | nil) :: %{
          model: String.t() | nil,
          thinking_level: String.t() | nil
        }
  def overrides(session_key) do
    policy = session_policy(session_key)

    %{
      model: policy |> get_field(:model) |> normalize_string(),
      thinking_level: policy |> get_field(:thinking_level) |> normalize_string()
    }
  end

  @doc """
  Resolve the model a session's next run would use, string-keyed for a JSON payload.

  Returns `model`, `provider`, `contextWindow`, `maxOutput`, `thinkingLevel`, `engine`
  (always `"lemon"`) and `modelSource` (`"session"` | `"profile"` | `"default"` | nil) — the
  last one so a client can tell a pinned model from an inherited one. Every key may be nil;
  nothing here raises.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: t()
  def resolve(session_key, agent_id \\ nil) do
    overrides = overrides(session_key)
    profile_model = profile_field(agent_id, :model)
    default_model = default_model()

    selection =
      ModelSelection.resolve(%{
        session_model: overrides.model,
        profile_model: profile_model,
        default_model: default_model
      })

    described = describe(selection.model)

    Map.merge(described, %{
      "modelSource" => model_source(overrides.model, profile_model, default_model),
      "thinkingLevel" => overrides.thinking_level,
      "engine" => "lemon"
    })
  end

  @doc """
  Provider and window for a model id: `%{"model" => id, "provider" => ..., "contextWindow" => ...}`.

  A model id the catalog does not know still comes back with its `model` set — an unknown id is
  a real answer, and blanking it would make the status bar look broken rather than the model
  look unrecognized. A `provider:` prefix on the id is used as the provider when the catalog
  has nothing better.
  """
  @spec describe(String.t() | nil) :: t()
  def describe(model_id) do
    model_id = normalize_string(model_id)

    case lookup(model_id) do
      nil ->
        %{
          "model" => model_id,
          "provider" => provider_prefix(model_id),
          "contextWindow" => nil,
          "maxOutput" => nil
        }

      model ->
        %{
          "model" => model_id,
          "provider" => to_string_or_nil(model.provider) || provider_prefix(model_id),
          "contextWindow" => positive_integer(model.context_window),
          "maxOutput" => positive_integer(model.max_tokens)
        }
    end
  end

  @doc """
  Just the provider for a model id, for callers that only need that (the event bridge).
  """
  @spec provider_for(String.t() | nil) :: String.t() | nil
  def provider_for(model_id), do: describe(model_id)["provider"]

  # -- internals -------------------------------------------------------------

  defp lookup(nil), do: nil

  defp lookup(model_id) do
    model_id
    |> candidates()
    |> Enum.find_value(fn candidate ->
      case LemonAi.Models.find_by_id(candidate) do
        %{} = model -> model
        _ -> nil
      end
    end)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # `"anthropic:claude-x"` and `"anthropic/claude-x"` are both accepted by `sessions.patch`;
  # the catalog only knows the bare id.
  defp candidates(model_id) do
    [model_id]
    |> then(fn acc -> acc ++ suffix_after(model_id, ":") ++ suffix_after(model_id, "/") end)
    |> Enum.uniq()
  end

  defp suffix_after(model_id, separator) do
    case String.split(model_id, separator, parts: 2) do
      [_prefix, rest] when rest != "" -> [rest]
      _ -> []
    end
  end

  defp provider_prefix(nil), do: nil

  defp provider_prefix(model_id) do
    case String.split(model_id, [":", "/"], parts: 2) do
      [prefix, _rest] when prefix != "" -> prefix
      _ -> nil
    end
  end

  defp model_source(session_model, profile_model, default_model) do
    cond do
      is_binary(session_model) -> "session"
      is_binary(profile_model) -> "profile"
      is_binary(default_model) -> "default"
      true -> nil
    end
  end

  defp session_policy(session_key) when is_binary(session_key) and session_key != "" do
    case LemonCore.PolicyStore.get_session(session_key) do
      policy when is_map(policy) -> policy
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp session_policy(_), do: %{}

  defp profile_field(agent_id, key) when is_binary(agent_id) and agent_id != "" do
    case LemonRouter.AgentProfiles.get(agent_id) do
      profile when is_map(profile) -> profile |> get_field(key) |> normalize_string()
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp profile_field(_agent_id, _key), do: nil

  defp default_model do
    normalize_string(LemonCore.Config.cached().agent.default_model)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp get_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp get_field(_map, _key), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value)
       when is_atom(value) and not is_nil(value) and not is_boolean(value),
       do: Atom.to_string(value)

  defp normalize_string(_), do: nil

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_or_nil(value), do: to_string(value)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_), do: nil
end

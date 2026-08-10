defmodule LemonCore.Events.EngineAction do
  @moduledoc """
  An engine action started, progressed or finished. Published on `run:<run_id>` and
  forwarded to `session:<session_key>`; it is what drives tool-status surfaces in chat
  channels and the web UI.
  """

  use LemonCore.Events.Payload,
    type: :engine_action,
    enforce: [:action],
    fields: [action: nil, engine: nil, phase: :updated, ok: nil, message: nil, level: nil]

  alias LemonCore.Events.Action

  @phases [:started, :updated, :completed]

  @type phase :: :started | :updated | :completed
  @type t :: %__MODULE__{
          action: Action.t(),
          engine: String.t() | nil,
          phase: phase(),
          ok: boolean() | nil,
          message: String.t() | nil,
          level: atom() | nil
        }

  @doc "The accepted action phases."
  @spec phases() :: [phase()]
  def phases, do: @phases

  @doc """
  Build from a legacy map, coercing the nested action and normalising `phase`.
  """
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      action: Action.from_map(get_field(attrs, :action) || %{}),
      engine: get_field(attrs, :engine),
      phase: normalize_phase(get_field(attrs, :phase)),
      ok: get_field(attrs, :ok),
      message: get_field(attrs, :message),
      level: get_field(attrs, :level)
    }
  end

  defp normalize_phase(phase) when phase in @phases, do: phase

  defp normalize_phase(phase) when is_binary(phase) do
    Enum.find(@phases, :updated, fn known -> Atom.to_string(known) == phase end)
  end

  defp normalize_phase(_phase), do: :updated

  # Not `Map.get(attrs, key) || Map.get(attrs, "key")`: that idiom turns a legitimate `false`
  # into `nil`, which silently drops the failure flag on a failed action.
  defp get_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end

defmodule LemonCore.Events.Action do
  @moduledoc """
  A single unit of engine activity — a tool call, command, file change, search, subagent
  or reasoning step. Carried inside `LemonCore.Events.EngineAction`.
  """

  use LemonCore.Events.Payload,
    type: :action,
    enforce: [:id, :kind, :title],
    fields: [id: nil, kind: nil, title: nil, detail: %{}]

  @kinds [:tool, :command, :file_change, :web_search, :subagent, :reasoning, :note]

  @type kind :: :tool | :command | :file_change | :web_search | :subagent | :reasoning | :note
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          title: String.t(),
          detail: map()
        }

  @doc "The accepted action kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  Build from a legacy map, normalising `kind` to an atom.

  Kinds were accepted as either atoms or strings before typing, so both appear in
  persisted event logs and in payloads arriving from the control-plane injectors.
  """
  @spec from_map(map() | struct() | keyword()) :: t()
  def from_map(%__MODULE__{} = payload), do: payload

  def from_map(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    %__MODULE__{
      id: get_field(attrs, :id),
      kind: normalize_kind(get_field(attrs, :kind)),
      title: get_field(attrs, :title),
      detail: get_field(attrs, :detail) || %{}
    }
  end

  @doc "Whether a term is an accepted kind, in either atom or legacy string form."
  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: not is_nil(normalize_kind(kind))

  defp normalize_kind(kind) when kind in @kinds, do: kind

  defp normalize_kind(kind) when is_binary(kind) do
    Enum.find(@kinds, fn known -> Atom.to_string(known) == kind end)
  end

  defp normalize_kind(_kind), do: nil

  # Not `Map.get(attrs, key) || Map.get(attrs, "key")`: that idiom turns a legitimate `false`
  # into `nil`, which silently drops the failure flag on a failed action.
  defp get_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key))
    end
  end
end

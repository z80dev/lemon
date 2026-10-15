defmodule LemonMemory.NoteMatch do
  @moduledoc false

  # Exact matches retain whole-entry semantics, including duplicate handling.
  def resolve(_entries, nil, text), do: {:ok, [], nil, text}

  def resolve(entries, replaces, text) do
    exact = Enum.filter(entries, &(&1 == replaces))

    if exact != [] do
      {:ok, exact, replaces, text}
    else
      case Enum.filter(entries, &String.contains?(&1, replaces)) do
        [] ->
          {:error, :not_found}

        [entry] ->
          cond do
            text == nil -> {:ok, [entry], entry, nil}
            repeated_span?(entry, replaces) -> {:error, :ambiguous_match}
            true -> {:ok, [entry], entry, String.replace(entry, replaces, text, global: false)}
          end

        _ ->
          {:error, :ambiguous_match}
      end
    end
  end

  defp repeated_span?(entry, span) do
    {position, _} = :binary.match(entry, span)
    start = position + 1
    :binary.match(entry, span, scope: {start, byte_size(entry) - start}) != :nomatch
  end
end

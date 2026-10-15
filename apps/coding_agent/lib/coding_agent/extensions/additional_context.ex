defmodule CodingAgent.Extensions.AdditionalContext do
  @moduledoc false

  @max_length 4_000

  def collect(context, text) when is_binary(text) do
    if String.valid?(text) and String.length(context) < @max_length do
      text = text |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, "") |> String.trim()
      combined = Enum.join(Enum.reject([context, text], &(&1 == "")), "\n")

      if String.length(combined) > @max_length,
        do: String.slice(combined, 0, @max_length - 1) <> "…",
        else: combined
    else
      context
    end
  end

  def collect(context, _text), do: context

  def block(context), do: "[hook context]\n" <> context

  def append(result, ""), do: result

  def append(result, context) do
    %{result | content: result.content ++ [%LemonAi.Types.TextContent{text: block(context)}]}
  end
end

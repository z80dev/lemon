defmodule LemonMemory.Usage do
  @moduledoc "Deterministic capacity labels for untrusted memory prompt blocks."

  @doc "Format the stored character count, excluding generated labels and bullets."
  def preferences(kind, used) when kind in ["user", "memory"] do
    {label, cap} = if kind == "user", do: {"USER PROFILE", 1_375}, else: {"MEMORY", 2_200}
    percent = div(used * 100, cap)

    "#{label} [#{percent}% — #{number(used)}/#{number(cap)} chars]" <>
      warning(used * 100 > cap * 80)
  end

  @doc "Format full project-store usage, including newline separators in its byte count."
  def project(facts) do
    count = length(facts)
    bytes = byte_size(Enum.join(facts, "\n"))

    "PROJECT MEMORY [#{count}/24 facts, #{number(bytes)}/2,000 bytes]" <>
      warning(count * 100 > 24 * 80 or bytes * 100 > 2_000 * 80)
  end

  defp warning(true), do: "\nAbove 80% capacity: consolidate before adding."
  defp warning(false), do: ""

  defp number(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end

defmodule LemonAi.SystemPrompt do
  @moduledoc """
  Ordered, provider-independent system prompt blocks.

  Place directory-independent blocks first and mark directory-derived blocks with
  `directory_derived: true`. Anthropic caches the prefix before the first such
  block; other providers receive the concatenated text. Include any separators
  in the block text: `text/1` never inserts or removes bytes.
  """

  @type block :: %{text: binary(), directory_derived: boolean()}
  @type t :: binary() | [block()] | nil

  @doc "Returns the exact concatenated text; a missing prompt becomes an empty binary."
  @spec text(t()) :: binary()
  def text(nil), do: ""
  def text(prompt) when is_binary(prompt), do: prompt

  def text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(fn %{text: text} -> text end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a lowercase SHA-256 digest of the canonical ordered blocks.

  The canonical encoding is the Erlang external term
  `{:system_prompt, 1, [{text, directory_derived}, ...]}`. It preserves arbitrary
  binary bytes, block boundaries, order and directory provenance without relying
  on map key order. A binary is one directory-independent block; `nil` is `[]`.
  This is a prompt identity, not a hash of provider-specific wire transformations.
  """
  @spec digest(t()) :: String.t()
  def digest(prompt) do
    {:system_prompt, 1, canonical_blocks(prompt)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_blocks(nil), do: []
  defp canonical_blocks(prompt) when is_binary(prompt), do: [{prompt, false}]

  defp canonical_blocks(blocks) when is_list(blocks) do
    Enum.map(blocks, fn %{text: text, directory_derived: directory_derived}
                        when is_binary(text) and is_boolean(directory_derived) ->
      {text, directory_derived}
    end)
  end
end

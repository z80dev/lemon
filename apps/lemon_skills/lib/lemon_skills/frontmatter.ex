defmodule LemonSkills.Frontmatter do
  @moduledoc """
  The shared YAML frontmatter parser for skill manifests, subagent definitions
  and rule files.

  It parses with `:yamerl_constr` directly. `YamlElixir.read_from_string/2`
  calls `Application.start(:yamerl)` on every read, a call into the application
  controller; sessions parse frontmatter in `init`, so a session starting while
  an application stopped deadlocked (the controller waited on the session
  supervisor, which waited on that `init`). yamerl is loaded as a `yaml_elixir`
  dependency, and parsing needs only its code, not its running application.

  The frontmatter must be a mapping with string keys. A repeated top-level key
  is refused rather than resolved last-wins, so a later duplicate cannot
  silently change a field, and text over `max_bytes` (default 16 KiB) is
  refused before parsing. Empty frontmatter parses to `%{}`. Nested mappings
  keep their YAML shape as maps.
  """

  alias YamlElixir.Mapper

  @default_max_bytes 16 * 1024

  @yamerl_options [
    detailed_constr: true,
    str_node_as_binary: true,
    keep_duplicate_keys: true
  ]

  @type error :: :too_large | :malformed | :not_a_mapping | :duplicate_key

  @doc "The default `max_bytes` cap."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc """
  Parse YAML frontmatter text (without the `---` delimiters) into a map.

  Options: `:max_bytes`, the largest accepted text in bytes. Never raises.
  """
  @spec parse_yaml(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def parse_yaml(yaml, opts \\ []) when is_binary(yaml) do
    if byte_size(yaml) > Keyword.get(opts, :max_bytes, @default_max_bytes) do
      {:error, :too_large}
    else
      with {:ok, document} <- read(yaml), do: map_document(document)
    end
  end

  @doc "A short, path-free description of a `parse_yaml/2` error."
  @spec describe_error(error()) :: String.t()
  def describe_error(:too_large), do: "frontmatter exceeds its size limit"
  def describe_error(:malformed), do: "malformed YAML frontmatter"
  def describe_error(:not_a_mapping), do: "frontmatter must be a mapping"
  def describe_error(:duplicate_key), do: "duplicate frontmatter fields"

  defp read(yaml) do
    {:ok, yaml |> :yamerl_constr.string(@yamerl_options) |> List.last()}
  catch
    _, _ -> {:error, :malformed}
  end

  defp map_document(nil), do: {:ok, %{}}

  # Map the document twice: as pairs to see duplicate keys, then as maps so
  # nested values keep their shape.
  defp map_document(document) do
    case Mapper.process(document, maps_as_keywords: true) do
      pairs when is_list(pairs) ->
        cond do
          not Enum.all?(pairs, &match?({key, _} when is_binary(key), &1)) ->
            {:error, :not_a_mapping}

          length(Enum.uniq_by(pairs, &elem(&1, 0))) != length(pairs) ->
            {:error, :duplicate_key}

          true ->
            case Mapper.process(document, []) do
              fields when is_map(fields) -> {:ok, fields}
              _ -> {:error, :not_a_mapping}
            end
        end

      _ ->
        {:error, :not_a_mapping}
    end
  rescue
    _ -> {:error, :malformed}
  end
end

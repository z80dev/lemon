defmodule LemonSim.Projectors.Toolkit do
  @moduledoc """
  Shared utilities for projector implementations.

  The toolkit provides:

  - a stable sectioned prompt shape (`SIM_PROMPT_V1`)
  - deterministic rendering for maps/lists via stable JSON formatting
  - helper functions for summarizing available action tools
  """

  alias AgentCore.Types.AgentTool

  @prompt_version "SIM_PROMPT_V1"

  @type section :: %{
          required(:id) => atom() | String.t(),
          required(:title) => String.t(),
          required(:content) => term(),
          optional(:format) => :auto | :json | :text | :markdown
        }

  @spec prompt_version() :: String.t()
  def prompt_version, do: @prompt_version

  @doc """
  Renders sections in a stable, markdown-friendly prompt format.
  """
  @spec render_sections([section()], keyword()) :: String.t()
  def render_sections(sections, opts \\ []) when is_list(sections) do
    version = Keyword.get(opts, :prompt_version, @prompt_version)

    body =
      sections
      |> Enum.reject(&section_empty?/1)
      |> Enum.map(&render_section(&1, opts))
      |> Enum.join("\n\n")

    """
    #{version}

    #{body}
    """
    |> String.trim()
  end

  @doc """
  Returns a stable JSON string with deterministic key ordering.
  """
  @spec stable_json(term()) :: String.t()
  def stable_json(value) do
    encode_json(normalize(value), 0)
  end

  @doc """
  Summarizes action tools into a compact model-readable structure.
  """
  @spec summarize_tools([AgentTool.t()]) :: [map()]
  def summarize_tools(tools) when is_list(tools) do
    tools
    |> Enum.map(fn %AgentTool{} = tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => tool.parameters
      }
    end)
    |> Enum.sort_by(&Map.get(&1, "name"))
  end

  @doc """
  Converts event-like structs/maps into maps with string keys.
  """
  @spec normalize_events([term()]) :: [map()]
  def normalize_events(events) when is_list(events) do
    Enum.map(events, &normalize/1)
  end

  @doc """
  Converts plan-step-like structs/maps into maps with string keys.
  """
  @spec normalize_plan_steps([term()]) :: [map()]
  def normalize_plan_steps(steps) when is_list(steps) do
    Enum.map(steps, &normalize/1)
  end

  defp render_section(%{title: title, content: content} = section, opts) do
    format = Map.get(section, :format, :auto)
    heading_level = Keyword.get(opts, :heading_level, 2)
    hashes = String.duplicate("#", heading_level)
    body = render_content(content, format)

    """
    #{hashes} #{title}
    #{body}
    """
    |> String.trim()
  end

  defp render_content(content, :markdown) when is_binary(content), do: String.trim(content)
  defp render_content(content, :text), do: to_text(content)

  defp render_content(content, :json) do
    """
    ```json
    #{stable_json(content)}
    ```
    """
    |> String.trim()
  end

  defp render_content(content, :auto) do
    cond do
      is_binary(content) ->
        String.trim(content)

      is_list(content) or is_map(content) ->
        render_content(content, :json)

      true ->
        to_text(content)
    end
  end

  defp to_text(content) when is_binary(content), do: String.trim(content)
  defp to_text(content), do: content |> normalize() |> inspect(limit: :infinity, pretty: true)

  defp section_empty?(%{content: nil}), do: true
  defp section_empty?(%{content: ""}), do: true
  defp section_empty?(%{content: []}), do: true
  defp section_empty?(_), do: false

  defp normalize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__struct__)
    |> normalize()
  end

  defp normalize(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, key_to_string(key), normalize(value))
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_integer(key), do: Integer.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp encode_json(value, indent) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map(fn {k, v} ->
        "#{indent_str(indent + 1)}#{encode_string(k)}: #{encode_json(v, indent + 1)}"
      end)

    case pairs do
      [] ->
        "{}"

      _ ->
        "{\n" <> Enum.join(pairs, ",\n") <> "\n" <> indent_str(indent) <> "}"
    end
  end

  defp encode_json(value, indent) when is_list(value) do
    items =
      Enum.map(value, fn item ->
        "#{indent_str(indent + 1)}#{encode_json(item, indent + 1)}"
      end)

    case items do
      [] ->
        "[]"

      _ ->
        "[\n" <> Enum.join(items, ",\n") <> "\n" <> indent_str(indent) <> "]"
    end
  end

  defp encode_json(value, _indent) when is_binary(value), do: encode_string(value)
  defp encode_json(value, _indent) when is_integer(value), do: Integer.to_string(value)
  defp encode_json(value, _indent) when is_float(value), do: :erlang.float_to_binary(value, [:compact, decimals: 16])
  defp encode_json(true, _indent), do: "true"
  defp encode_json(false, _indent), do: "false"
  defp encode_json(nil, _indent), do: "null"
  defp encode_json(value, _indent), do: value |> to_string() |> encode_string()

  defp encode_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp indent_str(level), do: String.duplicate("  ", level)
end

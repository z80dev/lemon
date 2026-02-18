defmodule CodingAgent.Wasm.Config do
  @moduledoc """
  WASM runtime configuration for per-session sidecar execution.
  """

  alias CodingAgent.Config, as: AgentConfig

  @default_memory_limit 10 * 1024 * 1024
  @default_timeout_ms 60_000
  @default_fuel_limit 10_000_000
  @default_max_depth 4

  @type t :: %__MODULE__{
          enabled: boolean(),
          auto_build: boolean(),
          runtime_path: String.t() | nil,
          tool_paths: [String.t()],
          discover_paths: [String.t()],
          default_memory_limit: non_neg_integer(),
          default_timeout_ms: non_neg_integer(),
          default_fuel_limit: non_neg_integer(),
          cache_compiled: boolean(),
          cache_dir: String.t() | nil,
          max_tool_invoke_depth: pos_integer()
        }

  defstruct enabled: false,
            auto_build: true,
            runtime_path: nil,
            tool_paths: [],
            discover_paths: [],
            default_memory_limit: @default_memory_limit,
            default_timeout_ms: @default_timeout_ms,
            default_fuel_limit: @default_fuel_limit,
            cache_compiled: true,
            cache_dir: nil,
            max_tool_invoke_depth: @default_max_depth

  @spec load(String.t(), map() | nil) :: t()
  def load(cwd, settings_manager \\ nil) do
    cwd = Path.expand(cwd)

    wasm =
      settings_manager
      |> extract_wasm_map()
      |> stringify_keys()

    extra_tool_paths = parse_paths(wasm["tool_paths"], cwd)

    runtime_path =
      wasm
      |> Map.get("runtime_path")
      |> parse_optional_path(cwd)

    cache_dir =
      wasm
      |> Map.get("cache_dir")
      |> parse_optional_path(cwd)

    discover_paths =
      [
        Path.join(cwd, ".lemon/wasm-tools"),
        Path.join(AgentConfig.agent_dir(), "wasm-tools")
      ] ++ extra_tool_paths

    %__MODULE__{
      enabled: parse_boolean(wasm["enabled"], false),
      auto_build: parse_boolean(wasm["auto_build"], true),
      runtime_path: runtime_path,
      tool_paths: extra_tool_paths,
      discover_paths: normalize_paths(discover_paths),
      default_memory_limit:
        parse_positive_integer(wasm["default_memory_limit"], @default_memory_limit),
      default_timeout_ms: parse_positive_integer(wasm["default_timeout_ms"], @default_timeout_ms),
      default_fuel_limit: parse_positive_integer(wasm["default_fuel_limit"], @default_fuel_limit),
      cache_compiled: parse_boolean(wasm["cache_compiled"], true),
      cache_dir: cache_dir,
      max_tool_invoke_depth:
        parse_positive_integer(wasm["max_tool_invoke_depth"], @default_max_depth)
    }
  end

  defp extract_wasm_map(%{tools: tools}) when is_map(tools) do
    Map.get(tools, :wasm) || Map.get(tools, "wasm") || %{}
  end

  defp extract_wasm_map(%{"tools" => tools}) when is_map(tools) do
    Map.get(tools, :wasm) || Map.get(tools, "wasm") || %{}
  end

  defp extract_wasm_map(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp parse_boolean(nil, default), do: default
  defp parse_boolean(value, _default) when value in [true, "true", "1", 1], do: true
  defp parse_boolean(value, _default) when value in [false, "false", "0", 0], do: false
  defp parse_boolean(_, default), do: default

  defp parse_positive_integer(value, _default) when is_integer(value), do: max(value, 1)

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> max(parsed, 1)
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp parse_optional_path(nil, _cwd), do: nil

  defp parse_optional_path(path, cwd) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> nil
      Path.type(trimmed) == :absolute -> Path.expand(trimmed)
      true -> Path.expand(trimmed, cwd)
    end
  end

  defp parse_optional_path(_, _cwd), do: nil

  defp parse_paths(nil, _cwd), do: []

  defp parse_paths(paths, cwd) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&parse_optional_path(&1, cwd))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_paths(paths, cwd) when is_binary(paths) do
    paths
    |> String.split(~r/[,:]/, trim: true)
    |> parse_paths(cwd)
  end

  defp parse_paths(_, _cwd), do: []

  defp normalize_paths(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end
end

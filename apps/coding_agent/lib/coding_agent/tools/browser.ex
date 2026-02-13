defmodule CodingAgent.Tools.Browser do
  @moduledoc """
  Browser tool for the coding agent (local browser mode).

  Uses LemonCore.Browser.LocalServer which spawns a local Node + Playwright driver.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @default_timeout_ms 30_000

  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(_cwd, _opts \\ []) do
    %AgentTool{
      name: "browser",
      description:
        "Control a local Chrome/Chromium browser (persistent profile) for navigation, screenshots, and DOM actions.",
      label: "Browser",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "method" => %{
            "type" => "string",
            "description" =>
              "Browser method: navigate, screenshot, click, type, evaluate, waitForSelector, getContent, getCookies, setCookies."
          },
          "args" => %{
            "type" => "object",
            "description" => "Method arguments (shape depends on method)."
          },
          "timeoutMs" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default: 30000)."
          }
        },
        "required" => ["method"]
      },
      execute: &execute/4
    }
  end

  @spec execute(String.t(), map(), reference() | nil, (AgentToolResult.t() -> :ok) | nil) ::
          AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, _signal, _on_update) do
    with {:ok, method} <- read_required_string(params, "method"),
         {:ok, args} <- read_optional_map(params, "args"),
         timeout_ms <- read_timeout_ms(params) do
      full = if String.starts_with?(method, "browser."), do: method, else: "browser.#{method}"

      case LemonCore.Browser.LocalServer.request(full, args, timeout_ms) do
        {:ok, result} ->
          json_result(%{"ok" => true, "result" => result})

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp read_timeout_ms(params) do
    case Map.get(params, "timeoutMs") do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout_ms
    end
  end

  defp read_required_string(params, key) do
    value = Map.get(params, key)

    if is_binary(value) do
      trimmed = String.trim(value)

      if byte_size(trimmed) > 0 do
        {:ok, trimmed}
      else
        {:error, "#{key} is required"}
      end
    else
      {:error, "#{key} is required"}
    end
  end

  defp read_optional_map(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, %{}}
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "#{key} must be an object"}
    end
  end

  defp json_result(payload) do
    text = Jason.encode!(payload, pretty: true)

    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: payload
    }
  end
end

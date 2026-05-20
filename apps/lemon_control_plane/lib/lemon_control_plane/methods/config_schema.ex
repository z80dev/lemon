defmodule LemonControlPlane.Methods.ConfigSchema do
  @moduledoc """
  Handler for the config.schema control plane method.

  Returns the configuration schema for validation and UI generation.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "config.schema"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    schema = %{
      "type" => "object",
      "properties" => %{
        "logLevel" => %{
          "type" => "string",
          "enum" => ["debug", "info", "warning", "error"],
          "default" => "info",
          "description" => "Logging level"
        },
        "maxConcurrentRuns" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 100,
          "default" => 10,
          "description" => "Maximum concurrent agent runs"
        },
        "defaultModel" => %{
          "type" => "string",
          "description" => "Default model for agent runs"
        },
        "defaultTimeout" => %{
          "type" => "integer",
          "minimum" => 1000,
          "maximum" => 3_600_000,
          "default" => 300_000,
          "description" => "Default timeout for agent runs (ms)"
        }
      }
    }

    {:ok, %{"schema" => schema, "summary" => summary(schema)}}
  end

  defp summary(schema) do
    properties = Map.get(schema, "properties", %{})

    %{
      "type" => schema["type"],
      "propertyCount" => map_size(properties),
      "propertyKeys" => Map.keys(properties),
      "cleanup" => %{
        "includesValues" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end
end

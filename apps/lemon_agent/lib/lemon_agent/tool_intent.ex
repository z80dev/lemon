defmodule LemonAgent.ToolIntent do
  @moduledoc """
  Provider-only tool intent schemas and task-local invocation intent.

  Intent is presentation data, never authorization or telemetry. Tools that own
  an `i` parameter retain its native meaning and do not participate in tracing.
  """

  @key {__MODULE__, :intent}
  @description "Concise intent: 2–6 word present-participle phrase, e.g. Reading model role settings"

  @doc "Adds optional intent to a provider schema without changing the execution schema."
  def schema(parameters, enabled \\ true)
  def schema(parameters, false), do: parameters

  def schema(parameters, _enabled) when is_map(parameters) do
    cond do
      owns_intent?(parameters) ->
        parameters

      not is_map(parameters["properties"]) and is_list(parameters["anyOf"]) ->
        Map.update!(parameters, "anyOf", &Enum.map(&1, fn variant -> schema(variant) end))

      not is_map(parameters["properties"]) and is_list(parameters["oneOf"]) ->
        Map.update!(parameters, "oneOf", &Enum.map(&1, fn variant -> schema(variant) end))

      true ->
        Map.update(
          parameters,
          "properties",
          %{"i" => intent_schema()},
          &Map.put(&1, "i", intent_schema())
        )
    end
  end

  def schema(parameters, _enabled), do: parameters

  @doc false
  def extract(parameters, arguments) when is_map(arguments) do
    if owns_intent?(parameters) do
      {nil, arguments}
    else
      {intent, arguments} = Map.pop(arguments, "i")
      {if(is_binary(intent), do: intent), arguments}
    end
  end

  def extract(parameters, arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> extract(parameters, decoded)
      _ -> {nil, arguments}
    end
  end

  def extract(_parameters, arguments), do: {nil, arguments}

  @doc "Returns the model's intent inside the current supervised tool invocation."
  @spec current() :: String.t() | nil
  def current, do: Process.get(@key)

  @doc false
  def put(intent), do: Process.put(@key, intent)

  defp intent_schema, do: %{"type" => "string", "description" => @description}

  defp owns_intent?(parameters) when is_map(parameters) do
    Map.has_key?(Map.get(parameters, "properties", %{}), "i") or
      Enum.any?(
        Map.get(parameters, "anyOf", []) ++ Map.get(parameters, "oneOf", []),
        &owns_intent?/1
      )
  end

  defp owns_intent?(_parameters), do: false
end

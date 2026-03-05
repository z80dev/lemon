defmodule LemonSim.ActionSpace do
  @moduledoc """
  Behaviour for generating dynamic legal tools from current state.

  This module also provides a helper DSL for discrete legal actions. Many
  turn-based sims can express their current action space as maps containing
  concrete arguments and resulting event(s), then compile those maps into
  executable `AgentTool`s with `to_tools/2`.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias LemonSim.Event

  @type trust :: :trusted | :untrusted

  @typedoc """
  Concrete legal action for the current state.

  Action maps are grouped by `name` into one tool. The generated tool accepts
  argument maps matching one of the provided legal actions exactly and returns
  the action's event payload via `result_details`.
  """
  @type legal_action :: %{
          required(:name) => String.t(),
          optional(:arguments) => map(),
          optional(:description) => String.t(),
          optional(:label) => String.t(),
          optional(:event) => Event.t() | map(),
          optional(:events) => [Event.t() | map()],
          optional(:result_text) => String.t(),
          optional(:trust) => trust()
        }

  @callback tools(state :: LemonSim.State.t(), opts :: keyword()) ::
              {:ok, [AgentCore.Types.AgentTool.t()]} | {:error, term()}

  @doc """
  Builds a normalized legal action map.
  """
  @spec legal_action(String.t() | atom(), map() | keyword(), keyword()) :: legal_action()
  def legal_action(name, arguments \\ %{}, opts \\ [])
      when (is_binary(name) or is_atom(name)) and (is_map(arguments) or is_list(arguments)) and
             is_list(opts) do
    %{
      name: to_string(name),
      arguments: normalize_map(arguments),
      description: Keyword.get(opts, :description),
      label: Keyword.get(opts, :label),
      event: Keyword.get(opts, :event),
      events: Keyword.get(opts, :events),
      result_text: Keyword.get(opts, :result_text),
      trust: Keyword.get(opts, :trust, :trusted)
    }
  end

  @doc """
  Compiles legal action maps into executable `AgentTool`s.
  """
  @spec to_tools([legal_action() | map() | keyword()], keyword()) :: [AgentTool.t()]
  def to_tools(actions, opts \\ []) when is_list(actions) and is_list(opts) do
    actions
    |> Enum.map(&normalize_legal_action/1)
    |> Enum.group_by(& &1.name)
    |> Enum.sort_by(fn {name, _actions} -> name end)
    |> Enum.map(fn {name, grouped_actions} -> build_tool(name, grouped_actions, opts) end)
  end

  defp build_tool(name, actions, opts) do
    properties = infer_properties(actions)
    required = infer_required_keys(actions)
    label = actions |> Enum.find_value(& &1.label) || titleize(name)

    %AgentTool{
      name: name,
      description: build_description(name, actions, opts),
      parameters: %{
        "type" => "object",
        "properties" => properties,
        "required" => required,
        "additionalProperties" => false
      },
      label: label,
      execute: fn _tool_call_id, params, _signal, _on_update ->
        execute_legal_action(name, actions, params)
      end
    }
  end

  defp execute_legal_action(name, actions, params) do
    normalized_params = normalize_map(params || %{})

    case Enum.find(actions, &(&1.arguments == normalized_params)) do
      nil ->
        {:error, invalid_action_message(name, actions, normalized_params)}

      action ->
        {:ok,
         %AgentToolResult{
           content: [AgentCore.text_content(action.result_text)],
           details: event_details(action.events),
           trust: action.trust
         }}
    end
  end

  defp normalize_legal_action(%{} = action) do
    name =
      action
      |> fetch_required(:name, "name")
      |> to_string()

    arguments = action |> fetch(:arguments, "arguments", %{}) |> normalize_map()
    description = fetch(action, :description, "description", nil)
    label = fetch(action, :label, "label", nil)
    result_text = fetch(action, :result_text, "result_text", default_result_text(name, arguments))
    trust = fetch(action, :trust, "trust", :trusted)

    events =
      case {fetch(action, :event, "event", nil), fetch(action, :events, "events", nil)} do
        {nil, nil} ->
          raise ArgumentError,
                "legal action #{inspect(name)} must include :event or :events"

        {event, nil} ->
          [Event.new(event)]

        {nil, events} when is_list(events) ->
          Enum.map(events, &Event.new/1)

        {nil, events} ->
          raise ArgumentError,
                "legal action #{inspect(name)} expected :events to be a list, got #{inspect(events)}"

        {_event, _events} ->
          raise ArgumentError,
                "legal action #{inspect(name)} cannot include both :event and :events"
      end

    %{
      name: name,
      arguments: arguments,
      description: description,
      label: label,
      result_text: result_text,
      events: events,
      trust: trust
    }
  end

  defp normalize_legal_action(action) when is_list(action) do
    action
    |> Enum.into(%{})
    |> normalize_legal_action()
  end

  defp infer_properties(actions) do
    actions
    |> Enum.flat_map(&Map.keys(&1.arguments))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.into(%{}, fn key ->
      values =
        actions
        |> Enum.map(&Map.get(&1.arguments, key))
        |> Enum.reject(&is_nil/1)

      {key, property_schema(key, values)}
    end)
  end

  defp infer_required_keys(actions) do
    case actions do
      [] ->
        []

      [first | rest] ->
        first.arguments
        |> Map.keys()
        |> Enum.filter(fn key ->
          Enum.all?(rest, &Map.has_key?(&1.arguments, key))
        end)
        |> Enum.sort()
    end
  end

  defp property_schema(key, values) do
    schema =
      %{"type" => infer_type(values)}
      |> maybe_put_enum(values)

    if values == [] do
      Map.put(schema, "description", "Legal argument #{key}")
    else
      schema
    end
  end

  defp infer_type([]), do: "string"

  defp infer_type(values) do
    cond do
      Enum.all?(values, &is_integer/1) -> "integer"
      Enum.all?(values, &is_number/1) -> "number"
      Enum.all?(values, &is_boolean/1) -> "boolean"
      true -> "string"
    end
  end

  defp maybe_put_enum(schema, values) do
    unique_values = Enum.uniq(values)

    cond do
      unique_values == [] ->
        schema

      length(unique_values) > 12 ->
        schema

      Enum.all?(
        unique_values,
        &(is_integer(&1) or is_float(&1) or is_boolean(&1) or is_binary(&1))
      ) ->
        Map.put(schema, "enum", unique_values)

      true ->
        schema
    end
  end

  defp build_description(name, actions, opts) do
    base_description =
      actions
      |> Enum.find_value(& &1.description)
      |> case do
        nil -> "Take the legal `#{name}` action."
        description -> description
      end

    limit = Keyword.get(opts, :legal_option_preview_limit, 12)

    if length(actions) <= limit do
      formatted =
        actions
        |> Enum.map(&format_arguments(&1.arguments))
        |> Enum.join("; ")

      "#{base_description} Legal arguments: #{formatted}."
    else
      base_description
    end
  end

  defp invalid_action_message(name, actions, params) do
    legal_options =
      actions
      |> Enum.map(&format_arguments(&1.arguments))
      |> Enum.join("; ")

    "illegal #{name} arguments #{format_arguments(params)}. Expected one of: #{legal_options}"
  end

  defp default_result_text(name, arguments) do
    "#{name} #{format_arguments(arguments)}"
  end

  defp format_arguments(arguments) when map_size(arguments) == 0, do: "{}"

  defp format_arguments(arguments) do
    arguments
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end

  defp event_details([event]), do: %{"event" => event}
  defp event_details(events), do: %{"events" => events}

  defp titleize(name) do
    name
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp fetch(map, atom_key, string_key, default) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  defp fetch_required(map, atom_key, string_key) do
    case fetch(map, atom_key, string_key, nil) do
      nil -> raise ArgumentError, "missing required key #{inspect(atom_key)}"
      value -> value
    end
  end

  defp normalize_map(value) when is_list(value), do: value |> Enum.into(%{}) |> normalize_map()

  defp normalize_map(value) when is_map(value) do
    value
    |> Enum.map(fn {key, entry} -> {normalize_key(key), entry} end)
    |> Enum.into(%{})
  end

  defp normalize_map(_value), do: %{}

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)
end

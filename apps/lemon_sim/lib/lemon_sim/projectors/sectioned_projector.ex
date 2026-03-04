defmodule LemonSim.Projectors.SectionedProjector do
  @moduledoc """
  Default section-based projector implementation.

  This projector provides a stable prompt scaffold while allowing sim-specific
  customization through section builders and section overrides.
  """

  @behaviour LemonSim.Projector

  alias Ai.Types.Context
  alias LemonSim.DecisionFrame
  alias LemonSim.Projectors.Toolkit

  @default_system_prompt """
  You are a simulation decision engine.
  Use tools for actions.
  Use memory tools to read/write notes only when needed.
  Keep decisions valid, minimal, and aligned with current world state.
  """

  @default_section_order [
    :world_state,
    :recent_events,
    :current_intent,
    :plan_history,
    :memory,
    :available_actions,
    :decision_contract
  ]

  @impl true
  def project(%DecisionFrame{} = frame, tools, opts) when is_list(tools) and is_list(opts) do
    sections =
      frame
      |> default_sections(tools, opts)
      |> apply_section_overrides(opts)
      |> apply_section_builders(frame, tools, opts)
      |> ordered_sections(opts)

    prompt = Toolkit.render_sections(sections, opts)
    system_prompt = Keyword.get(opts, :system_prompt, @default_system_prompt)

    context =
      Context.new(system_prompt: String.trim(system_prompt))
      |> Context.add_user_message(prompt)

    {:ok, context}
  end

  defp default_sections(frame, tools, _opts) do
    %{
      world_state: %{
        id: :world_state,
        title: "World State",
        format: :json,
        content: frame.world
      },
      recent_events: %{
        id: :recent_events,
        title: "Recent Events",
        format: :json,
        content: Toolkit.normalize_events(frame.recent_events)
      },
      current_intent: %{
        id: :current_intent,
        title: "Current Intent",
        format: :json,
        content: frame.intent
      },
      plan_history: %{
        id: :plan_history,
        title: "Plan History",
        format: :json,
        content: Toolkit.normalize_plan_steps(frame.plan_history)
      },
      memory: %{
        id: :memory,
        title: "Memory",
        format: :json,
        content: %{
          "index_file" => frame.memory_index_path,
          "instruction" => "Read index.md first, then open linked files only if needed."
        }
      },
      available_actions: %{
        id: :available_actions,
        title: "Available Actions",
        format: :json,
        content: Toolkit.summarize_tools(tools)
      },
      decision_contract: %{
        id: :decision_contract,
        title: "Decision Contract",
        format: :markdown,
        content: default_decision_contract()
      }
    }
  end

  defp apply_section_overrides(sections, opts) do
    overrides = Keyword.get(opts, :section_overrides, %{})

    Enum.reduce(overrides, sections, fn {id, override}, acc ->
      update_section(acc, id, override)
    end)
  end

  defp apply_section_builders(sections, frame, tools, opts) do
    builders = Keyword.get(opts, :section_builders, %{})

    Enum.reduce(builders, sections, fn {id, builder}, acc ->
      if is_function(builder, 3) do
        update_section(acc, id, builder.(frame, tools, opts))
      else
        acc
      end
    end)
  end

  defp update_section(sections, id, nil), do: Map.delete(sections, id)

  defp update_section(sections, id, value) when is_binary(value) do
    Map.update(
      sections,
      id,
      %{id: id, title: title_from_id(id), format: :markdown, content: value},
      fn existing -> Map.merge(existing, %{content: value}) end
    )
  end

  defp update_section(sections, id, value) when is_map(value) do
    value = Map.put_new(value, :id, id)
    value = Map.put_new(value, :title, title_from_id(id))
    Map.put(sections, id, value)
  end

  defp update_section(sections, id, value) do
    Map.update(
      sections,
      id,
      %{id: id, title: title_from_id(id), format: :json, content: value},
      fn existing -> Map.merge(existing, %{content: value}) end
    )
  end

  defp ordered_sections(sections, opts) do
    section_order = Keyword.get(opts, :section_order, @default_section_order)

    ordered =
      section_order
      |> Enum.map(&Map.get(sections, &1))
      |> Enum.reject(&is_nil/1)

    extra =
      sections
      |> Map.drop(section_order)
      |> Map.values()
      |> Enum.sort_by(&Map.get(&1, :title, ""))

    ordered ++ extra
  end

  defp title_from_id(id) do
    id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp default_decision_contract do
    """
    - Use memory tools only for memory maintenance.
    - Use non-memory tools to make environment decisions.
    - Pick one valid action based on world state and current intent.
    """
    |> String.trim()
  end
end

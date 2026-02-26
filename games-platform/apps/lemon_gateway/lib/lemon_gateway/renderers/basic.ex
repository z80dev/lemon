defmodule LemonGateway.Renderers.Basic do
  @moduledoc """
  Basic plain-text renderer implementing the `LemonGateway.Renderer` behaviour.

  Renders run lifecycle events (started, action, completed) into simple textual
  status messages with action lists and resume information.
  """
  @behaviour LemonGateway.Renderer

  @impl true
  def init(meta) do
    %{
      engine: meta[:engine],
      resume_line: nil,
      actions: %{},
      action_order: [],
      last_text: nil,
      last_status: nil,
      last_answer: nil
    }
  end

  @impl true
  def apply_event(state, %{__event__: :started, resume: resume}) do
    resume_line = format_resume(state.engine, resume)
    state = %{state | resume_line: resume_line}
    render(state, :running, nil)
  end

  def apply_event(state, %{__event__: :action_event, action: action, phase: phase} = ev) do
    state = track_action(state, action, phase, ev)
    render(state, :running, nil)
  end

  def apply_event(state, %{__event__: :completed, ok: true, answer: answer} = completed) do
    state = maybe_apply_resume_from_completed(state, completed)
    render(state, :done, answer || "")
  end

  def apply_event(state, %{__event__: :completed, ok: false, error: error} = completed)
      when error in [:user_requested, :interrupted] do
    state = maybe_apply_resume_from_completed(state, completed)
    render(state, :cancelled, nil)
  end

  def apply_event(state, %{__event__: :completed, ok: false, error: error} = completed) do
    state = maybe_apply_resume_from_completed(state, completed)
    render(state, :error, to_string(error || ""))
  end

  def apply_event(state, _event), do: {state, :unchanged}

  defp render(state, status, answer) do
    text = build_text(state, status, answer)

    if text == state.last_text and status == state.last_status do
      {state, :unchanged}
    else
      {%{state | last_text: text, last_status: status, last_answer: answer},
       {:render, %{text: text, status: status}}}
    end
  end

  defp build_text(state, :running, _answer) do
    parts =
      [
        "Running…",
        actions_text(state),
        state.resume_line
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(parts, "\n\n")
  end

  defp build_text(state, :done, answer) do
    parts =
      [
        "Done.",
        answer,
        state.resume_line
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(parts, "\n\n")
  end

  defp build_text(state, :cancelled, _answer) do
    parts =
      [
        "Cancelled.",
        state.resume_line
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(parts, "\n\n")
  end

  defp build_text(state, :error, error_text) do
    parts =
      [
        "Error.",
        error_text,
        state.resume_line
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(parts, "\n\n")
  end

  defp actions_text(state) do
    lines =
      Enum.map(state.action_order, fn id ->
        action = Map.get(state.actions, id)
        format_action(action)
      end)

    case Enum.reject(lines, &is_nil/1) do
      [] -> nil
      list -> Enum.join(list, "\n")
    end
  end

  defp format_action(nil), do: nil

  defp format_action(%{title: title, phase: phase}) do
    "- #{title}: #{phase}"
  end

  defp track_action(state, action, phase, _ev) do
    id = Map.get(action, :id)
    title = Map.get(action, :title)

    {actions, order} =
      case Map.has_key?(state.actions, id) do
        true ->
          {state.actions, state.action_order}

        false ->
          {state.actions, state.action_order ++ [id]}
      end

    action = %{title: title, phase: phase}
    %{state | actions: Map.put(actions, id, action), action_order: order}
  end

  defp format_resume(nil, _resume), do: nil
  defp format_resume(engine, resume), do: engine.format_resume(resume)

  defp maybe_apply_resume_from_completed(state, completed) do
    resume = Map.get(completed, :resume)

    cond do
      state.resume_line != nil ->
        state

      is_nil(resume) ->
        state

      true ->
        resume_line = format_resume(state.engine, resume)
        %{state | resume_line: resume_line}
    end
  end
end

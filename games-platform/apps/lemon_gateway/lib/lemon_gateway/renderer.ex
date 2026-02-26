defmodule LemonGateway.Renderer do
  @moduledoc """
  Behaviour for rendering engine events into user-facing text.

  Renderers transform engine lifecycle events (started, action, completed)
  into formatted text suitable for display in transport channels.
  """

  @type state :: term()
  @type render_out :: %{text: String.t(), status: :running | :done | :error | :cancelled}

  @callback init(job_meta :: map()) :: state()
  @callback apply_event(state(), term()) :: {state(), :unchanged | {:render, render_out()}}
end

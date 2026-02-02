defmodule LemonGateway.Renderer do
  @moduledoc false

  @type state :: term()
  @type render_out :: %{text: String.t(), status: :running | :done | :error | :cancelled}

  @callback init(job_meta :: map()) :: state()
  @callback apply_event(state(), term()) :: {state(), :unchanged | {:render, render_out()}}
end

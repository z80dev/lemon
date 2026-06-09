defmodule LemonSim.LLM do
  @moduledoc """
  Internal namespace for Lemon-native model and tool-loop execution.

  LLM modules own `Ai` and `AgentCore` integration above the simulation runner:
  tool-loop deciders, tool-loop policies, provider credential resolution, request
  pacing, transcript capture, and shared live-run helpers. Domain examples should
  depend on this layer for model execution instead of embedding provider setup.
  """
end

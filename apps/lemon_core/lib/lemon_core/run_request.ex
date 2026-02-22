defmodule LemonCore.RunRequest do
  @moduledoc """
  Canonical run submission contract shared by router-facing callers.

  This module centralizes normalization for run submission fields so different
  entry points (channels, control plane, automation) can submit consistently to
  the router orchestrator.
  """

  alias LemonCore.MapHelpers
  alias LemonCore.SessionKey

  @type origin :: :channel | :control_plane | :cron | :node | :unknown | atom()
  @type queue_mode :: :collect | :followup | :steer | :steer_backlog | :interrupt | term()

  @type t :: %__MODULE__{
          origin: origin(),
          session_key: binary() | nil,
          agent_id: term(),
          prompt: term(),
          queue_mode: queue_mode(),
          engine_id: term(),
          model: term(),
          meta: map(),
          cwd: term(),
          tool_policy: map() | nil,
          run_id: binary() | nil
        }

  defstruct origin: :unknown,
            session_key: nil,
            agent_id: "default",
            prompt: nil,
            queue_mode: :collect,
            engine_id: nil,
            model: nil,
            meta: %{},
            cwd: nil,
            tool_policy: nil,
            run_id: nil

  @doc """
  Build a normalized run request from a keyword list or map.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> normalize()
  def new(attrs) when is_map(attrs), do: normalize(attrs)

  @doc """
  Normalize request input into the canonical run request struct.

  Accepts `%RunRequest{}` or maps with atom/string keys.
  """
  @spec normalize(t() | map()) :: t()
  def normalize(%__MODULE__{} = request) do
    request
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(params) when is_map(params) do
    session_key = normalize_session_key(field(params, :session_key))

    %__MODULE__{
      origin: normalize_origin(field(params, :origin)),
      session_key: session_key,
      agent_id: normalize_agent_id(field(params, :agent_id), session_key),
      prompt: normalize_prompt(field(params, :prompt)),
      queue_mode: normalize_queue_mode(field(params, :queue_mode)),
      engine_id: normalize_engine_id(field(params, :engine_id)),
      model: normalize_model(field(params, :model)),
      meta: normalize_meta(field(params, :meta)),
      cwd: normalize_cwd(field(params, :cwd)),
      tool_policy: normalize_tool_policy(field(params, :tool_policy)),
      run_id: normalize_run_id(field(params, :run_id))
    }
  end

  @spec normalize_origin(term()) :: origin()
  def normalize_origin(origin) when origin in [nil, false], do: :unknown
  def normalize_origin(origin), do: origin

  @spec normalize_session_key(term()) :: term()
  def normalize_session_key(session_key) when session_key in [nil, false], do: nil
  def normalize_session_key(session_key), do: session_key

  @spec normalize_agent_id(term(), term()) :: term()
  def normalize_agent_id(agent_id, _session_key) when agent_id not in [nil, false], do: agent_id

  def normalize_agent_id(_agent_id, session_key) do
    session_key
    |> session_agent_id()
    |> Kernel.||("default")
  end

  @spec normalize_prompt(term()) :: term()
  def normalize_prompt(prompt), do: prompt

  @spec normalize_queue_mode(term()) :: queue_mode()
  def normalize_queue_mode(queue_mode) when queue_mode in [nil, false], do: :collect
  def normalize_queue_mode(queue_mode), do: queue_mode

  @spec normalize_engine_id(term()) :: term()
  def normalize_engine_id(engine_id) when engine_id in [nil, false], do: nil
  def normalize_engine_id(engine_id), do: engine_id

  @spec normalize_model(term()) :: term()
  def normalize_model(model) when model in [nil, false], do: nil
  def normalize_model(model), do: model

  @spec normalize_meta(term()) :: map()
  def normalize_meta(meta) when is_map(meta), do: meta
  def normalize_meta(_), do: %{}

  @spec normalize_cwd(term()) :: term()
  def normalize_cwd(cwd), do: cwd

  @spec normalize_tool_policy(term()) :: map() | nil
  def normalize_tool_policy(tool_policy) when is_map(tool_policy), do: tool_policy
  def normalize_tool_policy(_), do: nil

  @spec normalize_run_id(term()) :: binary() | nil
  def normalize_run_id(run_id) when is_binary(run_id) and run_id != "", do: run_id
  def normalize_run_id(_), do: nil

  defp field(params, key) when is_map(params) and is_atom(key) do
    MapHelpers.get_key(params, key)
  end

  defp session_agent_id(session_key) when is_binary(session_key),
    do: SessionKey.agent_id(session_key)

  defp session_agent_id(_), do: nil
end

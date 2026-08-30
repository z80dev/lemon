defmodule LemonControlPlane.Methods.SessionHeartbeat do
  @moduledoc """
  Read and manage one live session's recurring same-context heartbeat.

  Unlike cron, a heartbeat re-enters the named session as an ordinary user
  turn and therefore requires that session process to be running.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.AgentRuntime

  @actions %{
    "status" => :status,
    "set" => :set,
    "pause" => :pause,
    "resume" => :resume,
    "clear" => :clear
  }

  @impl true
  def name, do: "sessions.heartbeat"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) when is_map(params) do
    with {:ok, session_key} <- required_string(params, "sessionKey"),
         {:ok, action} <- parse_action(params["action"]),
         {:ok, call_params} <- validate_action_params(action, params),
         {:ok, heartbeat} <- call_runtime(session_key, action, call_params),
         {:ok, heartbeat} <- validate_runtime_status(heartbeat) do
      {:ok,
       %{
         "sessionKey" => session_key,
         "action" => Atom.to_string(action),
         "heartbeat" => encode_status(heartbeat),
         "summary" => summary(action, heartbeat)
       }}
    else
      {:error, :session_not_found} ->
        {:error, {:not_found, "Live session not found", nil}}

      {:error, :session_ambiguous} ->
        {:error, {:conflict, "More than one live session has this session key", nil}}

      {:error, :not_configured} ->
        {:error, {:not_found, "No heartbeat is configured for this session", nil}}

      {:error, :runtime_unavailable} ->
        {:error, {:unavailable, "Session heartbeat runtime is unavailable", nil}}

      {:error, :ephemeral_session} ->
        {:error, {:invalid_request, "Heartbeats require a durable session", nil}}

      {:error, reason} when reason in [:empty_prompt, :invalid_prompt] ->
        {:error, {:invalid_request, "prompt must be a non-empty string", nil}}

      {:error, :prompt_too_large} ->
        {:error, {:invalid_request, "prompt exceeds 16384 bytes", nil}}

      {:error, :interval_too_small} ->
        {:error, {:invalid_request, "intervalSeconds must be at least 60", nil}}

      {:error, :invalid_interval} ->
        {:error, {:invalid_request, "intervalSeconds must be an integer", nil}}

      {:error, :invalid_runtime_response} ->
        {:error, {:internal_error, "Session heartbeat runtime returned invalid state", nil}}

      {:error, {:invalid_request, _message, _details} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, {:internal_error, "Session heartbeat operation failed", reason}}
    end
  end

  def handle(_params, _ctx),
    do: {:error, {:invalid_request, "params must be an object", nil}}

  defp required_string(params, key) do
    case params[key] do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: invalid("#{key} is required"), else: {:ok, value}

      _ ->
        invalid("#{key} is required")
    end
  end

  defp parse_action(nil), do: {:ok, :status}

  defp parse_action(action) when is_binary(action) do
    case Map.fetch(@actions, String.downcase(String.trim(action))) do
      {:ok, value} -> {:ok, value}
      :error -> invalid("action must be one of: status, set, pause, resume, clear")
    end
  end

  defp parse_action(_), do: invalid("action must be a string")

  defp validate_action_params(:set, params) do
    with {:ok, prompt} <- required_string(params, "prompt"),
         interval when is_integer(interval) <- params["intervalSeconds"] do
      {:ok, %{prompt: prompt, interval_seconds: interval}}
    else
      nil -> invalid("intervalSeconds is required for action=set")
      _ -> invalid("intervalSeconds must be an integer")
    end
  end

  defp validate_action_params(_action, _params), do: {:ok, %{}}

  defp call_runtime(session_key, action, params) do
    AgentRuntime.call(
      :session_heartbeat,
      [session_key, action, params],
      {:error, :runtime_unavailable}
    )
  end

  defp validate_runtime_status(
         %{
           configured: configured,
           status: status,
           prompt: prompt,
           interval_seconds: interval_seconds,
           fire_count: fire_count,
           created_at_ms: created_at_ms,
           last_fired_at_ms: last_fired_at_ms,
           next_fire_at_ms: next_fire_at_ms,
           next_in_seconds: next_in_seconds
         } = heartbeat
       ) do
    valid? =
      is_boolean(configured) and status in [:active, :paused, :cleared] and
        (is_nil(prompt) or (is_binary(prompt) and byte_size(prompt) <= 16_384)) and
        optional_non_negative_integer?(interval_seconds) and
        is_integer(fire_count) and fire_count >= 0 and
        optional_non_negative_integer?(created_at_ms) and
        optional_non_negative_integer?(last_fired_at_ms) and
        optional_non_negative_integer?(next_fire_at_ms) and
        optional_non_negative_integer?(next_in_seconds)

    if valid?, do: {:ok, heartbeat}, else: {:error, :invalid_runtime_response}
  end

  defp validate_runtime_status(_heartbeat), do: {:error, :invalid_runtime_response}

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp encode_status(status) do
    %{
      "configured" => status.configured,
      "status" => Atom.to_string(status.status),
      "prompt" => status.prompt,
      "intervalSeconds" => status.interval_seconds,
      "fireCount" => status.fire_count,
      "createdAtMs" => status.created_at_ms,
      "lastFiredAtMs" => status.last_fired_at_ms,
      "nextFireAtMs" => status.next_fire_at_ms,
      "nextInSeconds" => status.next_in_seconds
    }
  end

  defp summary(action, heartbeat) do
    %{
      "action" => Atom.to_string(action),
      "configured" => heartbeat.configured,
      "status" => Atom.to_string(heartbeat.status),
      "promptReturned" => is_binary(heartbeat.prompt),
      "promptBytes" => if(is_binary(heartbeat.prompt), do: byte_size(heartbeat.prompt), else: 0),
      "cleanup" => %{
        "includesMessageHistory" => false,
        "includesProviderResponses" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp invalid(message), do: {:error, {:invalid_request, message, nil}}
end

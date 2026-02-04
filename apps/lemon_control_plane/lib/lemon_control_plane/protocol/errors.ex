defmodule LemonControlPlane.Protocol.Errors do
  @moduledoc """
  Error codes and structures for the control plane protocol.

  Errors are returned in response frames with the following structure:

      %{
        "code" => "ERROR_CODE",
        "message" => "Human-readable message",
        "details" => %{...}  # optional, additional context
      }

  ## Standard Error Codes

  - `INVALID_REQUEST` - Malformed request or missing required fields
  - `INVALID_PARAMS` - Invalid method parameters
  - `METHOD_NOT_FOUND` - Unknown method name
  - `UNAUTHORIZED` - Authentication required
  - `FORBIDDEN` - Insufficient permissions
  - `NOT_FOUND` - Requested resource not found
  - `CONFLICT` - Resource state conflict
  - `RATE_LIMITED` - Too many requests
  - `INTERNAL_ERROR` - Server error
  - `NOT_IMPLEMENTED` - Method not yet implemented
  - `HANDSHAKE_REQUIRED` - Must complete handshake first
  - `ALREADY_CONNECTED` - Connection already established
  """

  @type error_code ::
          :invalid_request
          | :invalid_params
          | :method_not_found
          | :unauthorized
          | :forbidden
          | :permission_denied
          | :not_found
          | :conflict
          | :rate_limited
          | :timeout
          | :internal_error
          | :not_implemented
          | :handshake_required
          | :already_connected
          | :unavailable

  @type error :: {error_code(), String.t()} | {error_code(), String.t(), term()}

  @type error_payload :: %{
          code: String.t(),
          message: String.t(),
          details: term() | nil
        }

  @error_codes %{
    invalid_request: "INVALID_REQUEST",
    invalid_params: "INVALID_PARAMS",
    method_not_found: "METHOD_NOT_FOUND",
    unauthorized: "UNAUTHORIZED",
    forbidden: "FORBIDDEN",
    permission_denied: "PERMISSION_DENIED",
    not_found: "NOT_FOUND",
    conflict: "CONFLICT",
    rate_limited: "RATE_LIMITED",
    timeout: "TIMEOUT",
    internal_error: "INTERNAL_ERROR",
    not_implemented: "NOT_IMPLEMENTED",
    handshake_required: "HANDSHAKE_REQUIRED",
    already_connected: "ALREADY_CONNECTED",
    unavailable: "UNAVAILABLE"
  }

  @doc """
  Creates an error tuple.

  ## Examples

      iex> Errors.error(:not_found, "Session not found")
      {:not_found, "Session not found"}

      iex> Errors.error(:invalid_params, "Invalid agent_id", %{field: "agent_id"})
      {:invalid_params, "Invalid agent_id", %{field: "agent_id"}}
  """
  @spec error(error_code(), String.t(), term() | nil) :: error()
  def error(code, message, details \\ nil) do
    if details do
      {code, message, details}
    else
      {code, message}
    end
  end

  @doc """
  Converts an error tuple to a payload map for JSON encoding.
  """
  @spec to_payload(error() | term()) :: error_payload()
  def to_payload({code, message, details}) when is_atom(code) do
    %{
      "code" => Map.get(@error_codes, code, "INTERNAL_ERROR"),
      "message" => message,
      "details" => details
    }
  end

  def to_payload({code, message}) when is_atom(code) do
    %{
      "code" => Map.get(@error_codes, code, "INTERNAL_ERROR"),
      "message" => message
    }
  end

  def to_payload(%{code: code, message: message} = error) do
    payload = %{
      "code" => to_string(code),
      "message" => message
    }

    if Map.has_key?(error, :details) and error.details != nil do
      Map.put(payload, "details", error.details)
    else
      payload
    end
  end

  def to_payload(other) do
    %{
      "code" => "INTERNAL_ERROR",
      "message" => "An unexpected error occurred",
      "details" => inspect(other)
    }
  end

  @doc """
  Creates a standard invalid_request error.
  """
  @spec invalid_request(String.t()) :: error()
  def invalid_request(message), do: error(:invalid_request, message)

  @doc """
  Creates a standard invalid_params error.
  """
  @spec invalid_params(String.t(), term() | nil) :: error()
  def invalid_params(message, details \\ nil), do: error(:invalid_params, message, details)

  @doc """
  Creates a standard method_not_found error.
  """
  @spec method_not_found(String.t()) :: error()
  def method_not_found(method), do: error(:method_not_found, "Unknown method: #{method}")

  @doc """
  Creates a standard unauthorized error.
  """
  @spec unauthorized(String.t()) :: error()
  def unauthorized(message \\ "Authentication required"), do: error(:unauthorized, message)

  @doc """
  Creates a standard forbidden error.
  """
  @spec forbidden(String.t()) :: error()
  def forbidden(message \\ "Insufficient permissions"), do: error(:forbidden, message)

  @doc """
  Creates a standard not_found error.
  """
  @spec not_found(String.t()) :: error()
  def not_found(message), do: error(:not_found, message)

  @doc """
  Creates a standard internal_error error.
  """
  @spec internal_error(String.t(), term() | nil) :: error()
  def internal_error(message \\ "Internal server error", details \\ nil) do
    error(:internal_error, message, details)
  end

  @doc """
  Creates a standard not_implemented error.
  """
  @spec not_implemented(String.t()) :: error()
  def not_implemented(method), do: error(:not_implemented, "Method not implemented: #{method}")

  @doc """
  Creates a handshake_required error.
  """
  @spec handshake_required() :: error()
  def handshake_required, do: error(:handshake_required, "Must send connect request first")

  @doc """
  Creates an already_connected error.
  """
  @spec already_connected() :: error()
  def already_connected, do: error(:already_connected, "Connection already established")

  @doc """
  Creates a permission_denied error.
  """
  @spec permission_denied(String.t()) :: error()
  def permission_denied(message \\ "Permission denied"), do: error(:permission_denied, message)

  @doc """
  Creates a timeout error.
  """
  @spec timeout(String.t()) :: error()
  def timeout(message \\ "Operation timed out"), do: error(:timeout, message)

  @doc """
  Creates a conflict error.
  """
  @spec conflict(String.t()) :: error()
  def conflict(message \\ "Resource state conflict"), do: error(:conflict, message)

  @doc """
  Creates an unavailable error (resource is temporarily unavailable).
  """
  @spec unavailable(String.t()) :: error()
  def unavailable(message \\ "Resource unavailable"), do: error(:unavailable, message)
end

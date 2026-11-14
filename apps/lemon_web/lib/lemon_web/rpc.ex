defmodule LemonWeb.Rpc do
  @moduledoc """
  In-process client of the control-plane method registry.

  The web UI is an operator client like the TUI: it calls the same retained
  RPC surface (`LemonControlPlane.Methods.Registry`) with the same schema
  validation, scopes and bounded/redacted projections, without a WebSocket hop.
  Access to a LiveView already passed `LemonWeb.LiveAuth`, so calls run with
  the operator context and client id `"lemon-web"`.

  Results:

    * `{:ok, payload}` — the method's wire payload (string keys, camelCase).
    * `{:error, %{code: atom, message: String.t(), details: map | nil}}` — the
      method's wire error. Internal-error details are dropped (they may carry
      exception text); other details are kept only when they are maps.

  Methods whose handler declares `dispatch_mode/0 == :async` can block on slow
  work; call them from `Phoenix.LiveView.start_async/3`. A
  result with `"retrySafe" => false` (or `:outcome_unknown`) may already have
  taken effect: never retry it automatically.
  """

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.Registry

  @type error :: %{code: atom(), message: String.t(), details: map() | nil}

  @doc "Calls `method` with `params` as the web operator."
  @spec call(String.t(), map() | nil) :: {:ok, term()} | {:error, error()}
  def call(method, params \\ %{}) when is_binary(method) do
    ctx = %{
      auth: Map.put(Authorize.default_operator(), :client_id, "lemon-web"),
      conn_id: "lemon-web:" <> inspect(self()),
      conn_pid: self()
    }

    case Registry.dispatch(method, params || %{}, ctx) do
      {:ok, payload} -> {:ok, payload}
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  catch
    :exit, _reason ->
      {:error, %{code: :unavailable, message: "Lemon runtime is unavailable", details: nil}}
  end

  @doc false
  def put_present(map, _key, value) when value in [nil, ""], do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc "Human-readable message for an error returned by `call/2`."
  @spec message(error() | term()) :: String.t()
  def message(%{message: message}) when is_binary(message) and message != "", do: message
  def message(_), do: "The request could not be completed."

  @doc false
  @spec normalize_error(term()) :: error()
  def normalize_error({:internal_error, message, _details}) when is_binary(message),
    do: %{code: :internal_error, message: message, details: nil}

  def normalize_error({code, message, details}) when is_atom(code) and is_binary(message),
    do: %{code: code, message: message, details: if(is_map(details), do: details)}

  def normalize_error({code, message}) when is_atom(code) and is_binary(message),
    do: %{code: code, message: message, details: nil}

  def normalize_error(%{code: code, message: message} = error)
      when is_atom(code) and is_binary(message),
      do: %{code: code, message: message, details: if(is_map(error[:details]), do: error.details)}

  def normalize_error(_other),
    do: %{code: :internal_error, message: "The request could not be completed.", details: nil}
end

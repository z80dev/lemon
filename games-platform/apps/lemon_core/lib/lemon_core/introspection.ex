defmodule LemonCore.Introspection do
  @moduledoc """
  Canonical introspection event API.

  Events are persisted through `LemonCore.Store` in `:introspection_log` with
  the following contract:

  - `:event_id` - stable unique identifier
  - `:event_type` - event taxonomy name
  - `:ts_ms` - wall clock timestamp in milliseconds
  - `:run_id` - run identifier when available
  - `:session_key` - session identifier when available
  - `:agent_id` - agent identifier when available
  - `:parent_run_id` - lineage link when available
  - `:engine` - engine name when available
  - `:provenance` - `:direct | :inferred | :unavailable`
  - `:payload` - redacted event-specific metadata

  ## Redaction Defaults

  - Prompt/response and obvious secret fields are removed.
  - Tool argument payloads are redacted by default (`capture_tool_args: false`).
  - Result previews are kept by default and truncated.
  """

  alias LemonCore.{Id, Store}

  @forbidden_payload_keys MapSet.new([
                            "api_key",
                            "apikey",
                            "authorization",
                            "password",
                            "private_key",
                            "prompt",
                            "response",
                            "secret",
                            "secrets",
                            "stderr",
                            "stdout",
                            "token"
                          ])
  @tool_args_payload_keys MapSet.new(["arguments", "input", "tool_arguments"])
  @result_preview_payload_keys MapSet.new(["preview", "result_preview"])
  @max_payload_bytes 4_096
  @max_result_preview_bytes 256

  @type provenance :: :direct | :inferred | :unavailable

  @type event :: %{
          required(:event_id) => binary(),
          required(:event_type) => atom() | binary(),
          required(:ts_ms) => non_neg_integer(),
          required(:provenance) => provenance(),
          required(:payload) => map(),
          optional(:run_id) => binary() | nil,
          optional(:session_key) => binary() | nil,
          optional(:agent_id) => binary() | nil,
          optional(:parent_run_id) => binary() | nil,
          optional(:engine) => binary() | nil
        }

  @doc """
  Build and persist an introspection event.
  """
  @spec record(atom() | binary(), map(), keyword()) :: :ok | {:error, term()}
  def record(event_type, payload \\ %{}, opts \\ []) do
    if enabled?() do
      with {:ok, event} <- build_event(event_type, payload, opts) do
        Store.append_introspection_event(event)
      end
    else
      :ok
    end
  end

  @doc """
  Build a canonical introspection event without persisting it.
  """
  @spec build_event(atom() | binary(), map(), keyword()) :: {:ok, event()} | {:error, term()}
  def build_event(event_type, payload, opts \\ [])

  def build_event(event_type, payload, opts) when is_map(payload) and is_list(opts) do
    provenance = Keyword.get(opts, :provenance, :direct)
    ts_ms = Keyword.get(opts, :ts_ms, System.system_time(:millisecond))

    with :ok <- validate_event_type(event_type),
         :ok <- validate_provenance(provenance),
         true <- is_integer(ts_ms) and ts_ms > 0 do
      redaction_opts = %{
        capture_tool_args?: Keyword.get(opts, :capture_tool_args, false),
        capture_result_preview?: Keyword.get(opts, :capture_result_preview, true)
      }

      {:ok,
       %{
         event_id: Keyword.get(opts, :event_id, "evt_#{Id.uuid()}"),
         event_type: event_type,
         ts_ms: ts_ms,
         run_id: normalize_identifier(Keyword.get(opts, :run_id)),
         session_key: normalize_identifier(Keyword.get(opts, :session_key)),
         agent_id: normalize_identifier(Keyword.get(opts, :agent_id)),
         parent_run_id: normalize_identifier(Keyword.get(opts, :parent_run_id)),
         engine: normalize_identifier(Keyword.get(opts, :engine)),
         provenance: provenance,
         payload: sanitize_payload(payload, redaction_opts)
       }}
    else
      _ -> {:error, :invalid_introspection_event}
    end
  end

  def build_event(_event_type, _payload, _opts), do: {:error, :invalid_payload}

  @doc """
  List introspection events through the store query API.
  """
  @spec list(keyword()) :: [event()]
  def list(opts \\ []) do
    Store.list_introspection_events(opts)
  end

  @doc """
  Returns whether persistence is currently enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:lemon_core, :introspection, [])
    |> Keyword.get(:enabled, true)
  end

  defp validate_event_type(event_type) when is_atom(event_type) and not is_nil(event_type),
    do: :ok

  defp validate_event_type(event_type) when is_binary(event_type) and event_type != "", do: :ok
  defp validate_event_type(_), do: {:error, :invalid_event_type}

  defp validate_provenance(provenance) when provenance in [:direct, :inferred, :unavailable],
    do: :ok

  defp validate_provenance(_), do: {:error, :invalid_provenance}

  defp normalize_identifier(nil), do: nil
  defp normalize_identifier(value) when is_binary(value) and value != "", do: value
  defp normalize_identifier(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_identifier(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_identifier(_), do: nil

  defp sanitize_payload(payload, opts) when is_map(payload), do: sanitize_value(payload, opts)
  defp sanitize_payload(_payload, _opts), do: %{}

  defp sanitize_value(%{__struct__: _} = struct, opts) do
    struct
    |> Map.from_struct()
    |> sanitize_value(opts)
  end

  defp sanitize_value(value, opts) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw}, acc ->
      key_name = normalize_key_name(key)

      cond do
        forbidden_payload_key?(key_name) ->
          acc

        tool_args_payload_key?(key_name) and not opts.capture_tool_args? ->
          Map.put(acc, key, "[redacted]")

        result_preview_payload_key?(key_name) and not opts.capture_result_preview? ->
          Map.put(acc, key, "[redacted]")

        result_preview_payload_key?(key_name) ->
          Map.put(acc, key, truncate_binary(raw, @max_result_preview_bytes))

        true ->
          Map.put(acc, key, sanitize_value(raw, opts))
      end
    end)
  end

  defp sanitize_value(value, opts) when is_list(value) do
    Enum.map(value, &sanitize_value(&1, opts))
  end

  defp sanitize_value(value, _opts) when is_binary(value) do
    truncate_binary(value, @max_payload_bytes)
  end

  defp sanitize_value(value, _opts), do: value

  defp normalize_key_name(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key_name(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key_name(_), do: ""

  defp forbidden_payload_key?(key_name), do: MapSet.member?(@forbidden_payload_keys, key_name)
  defp tool_args_payload_key?(key_name), do: MapSet.member?(@tool_args_payload_keys, key_name)

  defp result_preview_payload_key?(key_name),
    do: MapSet.member?(@result_preview_payload_keys, key_name)

  defp truncate_binary(value, max_bytes) when is_binary(value) and byte_size(value) > max_bytes do
    prefix = value |> binary_part(0, max_bytes) |> trim_to_valid_utf8()
    "#{prefix}...[truncated #{byte_size(value) - byte_size(prefix)} bytes]"
  end

  defp truncate_binary(value, _max_bytes), do: value

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end
end

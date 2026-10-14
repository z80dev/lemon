defmodule LemonControlPlane.Methods.NodeProcessSupport do
  @moduledoc false

  alias LemonControlPlane.NodeIO
  alias LemonControlPlane.Protocol.Errors

  @identity_fields ~w(nodeId processId)
  @run_fields ~w(nodeId processId cwd argv stdinBase64 timeoutMs maxOutputBytes)
  @receipt_fields ~w(processId nodeId state exitCode stdoutBase64 stderrBase64 outputTruncated)
  @max_bytes 1_048_576
  @max_base64_bytes 1_398_104

  def handle(method, params, ctx) when is_map(params) do
    with :ok <- validate(method, params),
         {:ok, opts} <- dispatch_opts(method, params),
         {:ok, result} <- NodeIO.invoke(params["nodeId"], method, Map.delete(params, "nodeId"), ctx, opts) do
      receipt(method, params, result)
    end
  end

  def handle(_, _, _), do: invalid("params must be an object")

  # Only a real durable-ID resolution can supply these internal admission options.
  # The broker checks the actual live capability and session atomically at dispatch.
  def dispatch_opts(method, params) do
    node_id = params["nodeId"]

    case LemonCore.NodeRegistry.resolve_id(node_id) do
      {:ok, %{id: ^node_id, pid: pid, generation: generation}}
          when is_pid(pid) and is_integer(generation) and generation >= 0 ->
        opts = [expected_pid: pid, expected_generation: generation, required_process_execution: 1]
        timeout_ms = if method == "node.process.run", do: params["timeoutMs"] + 5_000, else: 30_000
        {:ok, Keyword.put(opts, :timeout_ms, timeout_ms)}

      _ ->
        {:error, Errors.error(:unavailable, "Node is not available",
          %{"reason" => "node_offline", "preDispatch" => true, "retrySafe" => false})}
    end
  end

  defp validate(method, params) do
    fields = if method == "node.process.run", do: @run_fields, else: @identity_fields

    with :ok <- exact_fields(params, fields),
         :ok <- string(params["nodeId"], "nodeId", 256),
         :ok <- process_id(params["processId"]) do
      if method == "node.process.run", do: validate_run(params), else: :ok
    end
  end

  defp exact_fields(params, fields) do
    if map_size(params) == length(fields) and Enum.all?(fields, &Map.has_key?(params, &1)),
      do: :ok,
      else: invalid("params must contain exactly the required process fields")
  end

  defp process_id(value) do
    if is_binary(value) and byte_size(value) in 1..128 and
         Regex.match?(~r/\A[A-Za-z0-9_:-]+\z/, value),
      do: :ok,
      else: invalid("processId must be 1..128 ASCII letters, digits, _, :, or -")
  end

  defp validate_run(params) do
    with :ok <- string(params["cwd"], "cwd", 4096),
         :ok <- cwd(params["cwd"]),
         :ok <- argv(params["argv"]),
         :ok <- stdin(params["stdinBase64"]),
         :ok <- integer(params["timeoutMs"], "timeoutMs", 1_000, 1_800_000),
         do: integer(params["maxOutputBytes"], "maxOutputBytes", 1, @max_bytes)
  end

  defp string(value, field, max) do
    if is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
         String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: :ok,
      else: invalid(field <> " must be a nonempty bounded UTF-8 string without NUL")
  end

  defp cwd(value) do
    if ".." in String.split(value, "/"),
      do: invalid("cwd must not contain traversal components"),
      else: :ok
  end

  defp argv(values) when is_list(values) do
    valid = length(values) in 1..128 and
      Enum.all?(values, fn value ->
        is_binary(value) and byte_size(value) <= 131_072 and String.valid?(value) and
          not String.contains?(value, <<0>>)
      end)

    if valid and hd(values) != "" and Enum.reduce(values, 0, &(byte_size(&1) + &2)) <= 131_072,
      do: :ok,
      else: invalid("argv must contain 1..128 literal UTF-8 strings without NUL, a nonempty executable, and at most 131072 total bytes")
  end

  defp argv(_), do: invalid("argv must be a list of literal UTF-8 strings")

  defp stdin(value) do
    case decoded_size(value) do
      {:ok, size} when size <= @max_bytes -> :ok
      _ -> invalid("stdinBase64 must be standard base64 decoding to at most 1048576 bytes")
    end
  end

  defp integer(value, field, min, max) do
    if is_integer(value) and value >= min and value <= max,
      do: :ok,
      else: invalid(field <> " must be an integer in #{min}..#{max}")
  end

  # Project only the frozen receipt. Missing output is not measured empty output,
  # and transport errors never become execution receipts or receipt absence.
  defp receipt(method, params, result) when is_map(result) do
    projected = Map.take(result, @receipt_fields)
    states = if method == "node.process.get",
      do: ~w(running completed cancelled outcome_unknown not_found),
      else: ~w(running completed cancelled outcome_unknown)
    limit = if method == "node.process.run", do: params["maxOutputBytes"], else: @max_bytes

    valid = map_size(projected) == length(@receipt_fields) and
      projected["nodeId"] == params["nodeId"] and projected["processId"] == params["processId"] and
      projected["state"] in states and
      (is_nil(projected["exitCode"]) or is_integer(projected["exitCode"])) and
      is_boolean(projected["outputTruncated"]) and valid_outputs?(projected, limit) and
      valid_state?(projected)

    if valid, do: {:ok, projected}, else: invalid_receipt()
  end

  defp receipt(_, _, _), do: invalid_receipt()

  defp valid_outputs?(receipt, limit) do
    case {output_size(receipt["stdoutBase64"]), output_size(receipt["stderrBase64"])} do
      {{:ok, stdout}, {:ok, stderr}} -> stdout + stderr <= limit
      {:unavailable, :unavailable} -> receipt["outputTruncated"] == true
      _ -> false
    end
  end

  defp valid_state?(%{"state" => state} = receipt)
       when state in ["running", "outcome_unknown", "not_found"] do
    is_nil(receipt["exitCode"]) and is_nil(receipt["stdoutBase64"]) and
      is_nil(receipt["stderrBase64"]) and receipt["outputTruncated"] == true
  end

  defp valid_state?(%{"state" => "completed", "exitCode" => code}), do: is_integer(code)

  defp valid_state?(_), do: true

  defp output_size(nil), do: :unavailable
  defp output_size(value), do: decoded_size(value)

  defp decoded_size(value) when is_binary(value) and byte_size(value) <= @max_base64_bytes do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, byte_size(bytes)}
      :error -> :error
    end
  end

  defp decoded_size(_), do: :error
  defp invalid(message), do: {:error, Errors.invalid_request(message)}

  defp invalid_receipt do
    {:error, Errors.error(:unavailable, "Destination process receipt is invalid; reconcile the fixed process ID",
      %{"reason" => "invalid_process_receipt", "preDispatch" => false, "retrySafe" => false})}
  end
end

defmodule LemonControlPlane.Methods.NodeProcessRun do
  @moduledoc "Awaits a bounded destination-native process receipt for a fixed process ID; never uses a PTY or shell string."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.process.run"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeProcessSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeProcessGet do
  @moduledoc "Read-only strict fixed-ID receipt lookup; never launches or replays a process."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.process.get"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeProcessSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeProcessCancel do
  @moduledoc "Cancels an owned destination process or durably tombstones an absent fixed ID before acknowledging cancellation."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.process.cancel"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeProcessSupport.handle(name(), params, ctx)
end

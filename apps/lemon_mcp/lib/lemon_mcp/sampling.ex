defmodule LemonMCP.Sampling do
  @moduledoc """
  Policy wrapper for MCP `sampling/createMessage` callbacks.

  The low-level MCP client accepts a raw callback. This module builds callbacks
  that keep review and limit checks explicit before a server request is allowed
  to reach a model-backed delegate.
  """

  @default_max_tokens 1_024

  @type summary :: %{
          request_hash: String.t(),
          message_count: non_neg_integer(),
          roles: [String.t()],
          content_kinds: %{String.t() => non_neg_integer()},
          text_char_count: non_neg_integer(),
          max_tokens: non_neg_integer() | nil,
          requested_model: String.t() | nil
        }

  @doc """
  Builds a `sampling_handler` callback for `LemonMCP.Client`.

  Supported modes:

  - `:model` calls the delegate after local limits pass.
  - `:reviewed_model` requires a reviewer approval before calling the delegate.
  - `:deny` returns a structured policy denial.
  """
  @spec handler(keyword()) :: (map() -> {:ok, map()} | {:error, map()})
  def handler(opts) when is_list(opts) do
    fn params -> handle(params, opts) end
  end

  @doc """
  Handles a single MCP sampling request with the configured policy.
  """
  @spec handle(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def handle(params, opts) when is_map(params) and is_list(opts) do
    summary = summarize(params)
    mode = Keyword.get(opts, :mode, :deny)

    with :ok <- enforce_max_tokens(summary, opts),
         :ok <- enforce_allowed_models(summary, opts),
         :ok <- review(mode, summary, opts) do
      dispatch(mode, params, summary, opts)
    end
  end

  @doc """
  Returns a redacted summary of a sampling request.
  """
  @spec summarize(map()) :: summary()
  def summarize(params) when is_map(params) do
    messages = params |> Map.get("messages", []) |> List.wrap()
    content_kinds = Enum.reduce(messages, %{}, &count_content_kind/2)

    %{
      request_hash: hash(params),
      message_count: length(messages),
      roles:
        messages |> Enum.map(&string_value(&1, "role")) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      content_kinds: content_kinds,
      text_char_count: Enum.reduce(messages, 0, &(&2 + text_char_count(&1))),
      max_tokens: integer_value(params, "maxTokens") || integer_value(params, "max_tokens"),
      requested_model: requested_model(params)
    }
  end

  defp enforce_max_tokens(%{max_tokens: nil}, _opts), do: :ok

  defp enforce_max_tokens(%{max_tokens: max_tokens} = summary, opts) do
    limit = Keyword.get(opts, :max_tokens, @default_max_tokens)

    if is_integer(max_tokens) and max_tokens <= limit do
      :ok
    else
      {:error, policy_error(:max_tokens_exceeded, summary)}
    end
  end

  defp enforce_allowed_models(%{requested_model: nil}, _opts), do: :ok

  defp enforce_allowed_models(%{requested_model: model} = summary, opts) do
    allowed = opts |> Keyword.get(:allowed_models, []) |> List.wrap()

    if allowed == [] or model in allowed do
      :ok
    else
      {:error, policy_error(:model_not_allowed, summary)}
    end
  end

  defp review(:reviewed_model, summary, opts) do
    case Keyword.get(opts, :reviewer) do
      reviewer when is_function(reviewer, 1) ->
        case reviewer.(summary) do
          :approve -> :ok
          :approved -> :ok
          {:approve, _metadata} -> :ok
          {:approved, _metadata} -> :ok
          :reject -> {:error, policy_error(:review_rejected, summary)}
          {:reject, reason} -> {:error, policy_error({:review_rejected, reason}, summary)}
          {:error, reason} -> {:error, policy_error({:review_failed, reason}, summary)}
          other -> {:error, policy_error({:invalid_review_result, other}, summary)}
        end

      _ ->
        {:error, policy_error(:reviewer_required, summary)}
    end
  end

  defp review(_mode, _summary, _opts), do: :ok

  defp dispatch(:deny, _params, summary, _opts) do
    {:error, policy_error(:sampling_disabled, summary)}
  end

  defp dispatch(mode, params, summary, opts) when mode in [:model, :reviewed_model] do
    case Keyword.get(opts, :delegate) do
      delegate when is_function(delegate, 2) ->
        normalize_delegate_result(delegate.(params, summary), summary)

      delegate when is_function(delegate, 1) ->
        normalize_delegate_result(delegate.(params), summary)

      _ ->
        {:error, policy_error(:delegate_required, summary)}
    end
  end

  defp dispatch(mode, _params, summary, _opts) do
    {:error, policy_error({:unknown_mode, mode}, summary)}
  end

  defp normalize_delegate_result({:ok, result}, _summary) when is_map(result), do: {:ok, result}

  defp normalize_delegate_result({:error, reason}, summary),
    do: {:error, policy_error({:delegate_failed, reason}, summary)}

  defp normalize_delegate_result(other, summary),
    do: {:error, policy_error({:invalid_delegate_result, other}, summary)}

  defp policy_error(reason, summary) do
    %{
      reason: safe_reason(reason),
      request: summary
    }
  end

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_reason({kind, detail}) when is_atom(kind) do
    %{
      kind: Atom.to_string(kind),
      detail_hash: hash(detail)
    }
  end

  defp safe_reason(reason), do: %{kind: "policy_error", detail_hash: hash(reason)}

  defp requested_model(params) do
    string_value(params, "model") ||
      get_in(params, ["modelPreferences", "hints", Access.at(0), "name"]) ||
      get_in(params, ["model_preferences", "hints", Access.at(0), "name"])
  end

  defp count_content_kind(message, acc) do
    message
    |> Map.get("content")
    |> content_kind()
    |> then(&Map.update(acc, &1, 1, fn count -> count + 1 end))
  end

  defp content_kind(%{"type" => type}) when is_binary(type), do: type
  defp content_kind(value) when is_binary(value), do: "text"
  defp content_kind(values) when is_list(values), do: "list"
  defp content_kind(_value), do: "unknown"

  defp text_char_count(%{"content" => content}), do: text_content_chars(content)
  defp text_char_count(_message), do: 0

  defp text_content_chars(%{"type" => "text", "text" => text}) when is_binary(text),
    do: String.length(text)

  defp text_content_chars(text) when is_binary(text), do: String.length(text)

  defp text_content_chars(values) when is_list(values),
    do: Enum.reduce(values, 0, &(&2 + text_content_chars(&1)))

  defp text_content_chars(_value), do: 0

  defp string_value(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp integer_value(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp hash(value) do
    binary = :erlang.term_to_binary(value)

    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end

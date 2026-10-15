defmodule CodingAgent.Tools.Ask do
  @moduledoc """
  Ask an interactive user through a session prompt surface or ACP elicitation.

  Available only while a session user-prompt surface is bound, or a run's client
  advertised `elicitation.form` and its bridge is registered. Answers come from
  the real client; decline, cancellation, disconnection and timeout never choose
  a recommendation for the user.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.ACPClientBridge
  alias CodingAgent.Session.UserPrompt

  @max_questions 8
  @max_options 20
  @answer_bytes 4_000

  def available?(opts) do
    acp_available?(opts) or UserPrompt.bound?(Keyword.get(opts, :session_key))
  end

  defp acp_available?(opts) do
    run_id = Keyword.get(opts, :run_id)

    Keyword.get(opts, :acp_client_elicitation_form, false) == true and
      is_binary(run_id) and not is_nil(ACPClientBridge.whereis(run_id))
  rescue
    ArgumentError -> false
  end

  def tool(_cwd, opts \\ []) do
    %AgentTool{
      name: "ask",
      timeout_ms: :infinity,
      label: "Ask User",
      description:
        "Ask the user for clarification or a decision. Supply questions with choices, or an empty options list for free text. The user can provide a custom answer, decline, or cancel. Do not ask for credentials or secrets.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Optional deadline in milliseconds. Timeout never selects an answer."
          },
          "questions" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => @max_questions,
            "items" => %{
              "type" => "object",
              "properties" => %{
                "id" => %{"type" => "string", "maxLength" => 128},
                "question" => %{"type" => "string", "maxLength" => 3_000},
                "header" => %{"type" => "string", "maxLength" => 1_000},
                "options" => %{
                  "type" => "array",
                  "maxItems" => @max_options,
                  "items" => %{
                    "type" => "object",
                    "properties" => %{
                      "label" => %{"type" => "string", "maxLength" => 256},
                      "description" => %{"type" => "string", "maxLength" => 1_000}
                    },
                    "required" => ["label"]
                  }
                },
                "multi" => %{"type" => "boolean"},
                "recommended" => %{"type" => "integer", "minimum" => 0}
              },
              "required" => ["id", "question", "options"]
            }
          }
        },
        "required" => ["questions"]
      },
      execute: fn id, params, signal, on_update ->
        execute(id, params, signal, on_update, opts)
      end
    }
  end

  def execute(_id, params, signal, on_update, opts) do
    with :ok <- connected(opts),
         :ok <- not_aborted(signal),
         {:ok, questions} <- questions(params),
         {:ok, timeout} <- timeout(params, opts),
         :ok <- announce_waiting(on_update),
         {:ok, response} <- request_answer(questions, signal, opts, timeout),
         :ok <- not_aborted(signal) do
      response_result(questions, response)
    else
      {:error, reason} -> failure(reason)
    end
  end

  defp timeout(params, opts) do
    value = Map.get(params, "timeout_ms", Keyword.get(opts, :user_prompt_timeout_ms, :infinity))

    if value == :infinity or (is_integer(value) and value > 0),
      do: {:ok, value},
      else: {:error, :invalid_timeout}
  end

  defp request_answer(questions, signal, opts, timeout) do
    if acp_available?(opts) do
      timeout =
        if timeout == :infinity,
          do: Keyword.get(opts, :elicitation_timeout_ms, 300_000),
          else: timeout

      ACPClientBridge.request(
        Keyword.fetch!(opts, :run_id),
        "elicitation/create",
        request(questions),
        timeout
      )
    else
      UserPrompt.request(Keyword.get(opts, :session_key), Keyword.get(opts, :run_id), questions,
        timeout_ms: timeout,
        signal: signal
      )
    end
  end

  defp connected(opts) do
    if available?(opts), do: :ok, else: {:error, :no_client}
  end

  defp not_aborted(signal) do
    if LemonAgent.AbortSignal.aborted?(signal), do: {:error, :cancelled}, else: :ok
  end

  defp announce_waiting(callback) when is_function(callback, 1) do
    callback.(%AgentToolResult{content: [], details: %{status: "waiting_for_user"}})
    :ok
  end

  defp announce_waiting(_callback), do: :ok

  defp questions(%{"questions" => questions}) when is_list(questions) do
    if length(questions) in 1..@max_questions do
      Enum.reduce_while(questions, {:ok, [], MapSet.new()}, fn question, {:ok, valid, ids} ->
        case validate_question(question) do
          {:ok, question} ->
            if MapSet.member?(ids, question["id"]),
              do: {:halt, {:error, "question ids must be unique"}},
              else: {:cont, {:ok, [question | valid], MapSet.put(ids, question["id"])}}

          error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, valid, _ids} -> {:ok, Enum.reverse(valid)}
        error -> error
      end
    else
      {:error, "questions must contain between 1 and #{@max_questions} entries"}
    end
  end

  defp questions(_params), do: {:error, "questions is required"}

  defp validate_question(question) when is_map(question) do
    options = question["options"]
    multi = Map.get(question, "multi", false)
    recommended = question["recommended"]

    with :ok <- text(question["id"], "id", 128),
         :ok <- text(question["question"], "question", 3_000),
         :ok <- optional_text(question["header"], "header", 1_000),
         true <- is_boolean(multi),
         true <- is_list(options) and length(options) <= @max_options,
         :ok <- validate_options(options),
         true <-
           is_nil(recommended) or
             (is_integer(recommended) and recommended >= 0 and recommended < length(options)) do
      {:ok,
       Map.take(question, ["id", "question", "header", "options", "multi", "recommended"])
       |> Map.put("multi", multi)}
    else
      false -> {:error, "multi, options or recommended has an invalid value"}
      error -> error
    end
  end

  defp validate_question(_question), do: {:error, "each question must be an object"}

  defp validate_options(options) do
    Enum.reduce_while(options, {:ok, MapSet.new()}, fn option, {:ok, labels} ->
      with true <- is_map(option),
           :ok <- text(option["label"], "option label", 256),
           :ok <- optional_text(option["description"], "option description", 1_000),
           false <- MapSet.member?(labels, option["label"]) do
        {:cont, {:ok, MapSet.put(labels, option["label"])}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, "options must be objects with unique labels"}}
      end
    end)
    |> case do
      {:ok, _labels} -> :ok
      error -> error
    end
  end

  defp text(value, _name, max_bytes)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes do
    if String.valid?(value), do: :ok, else: {:error, "question text must be UTF-8"}
  end

  defp text(_value, name, max_bytes),
    do: {:error, "#{name} must be nonempty text of at most #{max_bytes} UTF-8 bytes"}

  defp optional_text(nil, _name, _max), do: :ok
  defp optional_text("", _name, _max), do: :ok
  defp optional_text(value, name, max), do: text(value, name, max)

  defp request(questions) do
    properties =
      questions
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {question, index}, properties ->
        key = "q#{index}"

        labels =
          Enum.map(question["options"], fn option ->
            %{"const" => option["label"], "title" => option["label"]}
            |> put_optional("description", option["description"])
          end)

        properties =
          if labels == [] do
            properties
          else
            property =
              if question["multi"] do
                %{"type" => "array", "items" => %{"anyOf" => labels}}
              else
                %{"type" => "string", "oneOf" => labels}
                |> put_optional(
                  "default",
                  if(is_integer(question["recommended"]),
                    do: Enum.at(question["options"], question["recommended"])["label"]
                  )
                )
              end

            property =
              property
              |> Map.put("title", question["question"])
              |> put_optional("description", question["header"])

            Map.put(properties, key, property)
          end

        Map.put(properties, key <> "__other", %{
          "type" => "string",
          "title" => "Other (type your own)"
        })
      end)

    message =
      if length(questions) == 1,
        do: hd(questions)["question"],
        else: "Answer #{length(questions)} questions"

    %{
      "mode" => "form",
      "message" => message,
      "requestedSchema" => %{"type" => "object", "properties" => properties}
    }
  end

  defp response_result(questions, response) do
    result =
      case response do
        %{"result" => result} when is_map(result) -> result
        result when is_map(result) -> result
        _ -> %{}
      end

    case result["action"] do
      "accept" -> accepted(questions, result["content"])
      "decline" -> failure(:declined)
      "cancel" -> failure(:cancelled)
      _ -> failure(:invalid_response)
    end
  end

  defp accepted(questions, content) when is_map(content) do
    questions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {question, index}, {:ok, answers} ->
      key = "q#{index}"
      labels = Enum.map(question["options"], & &1["label"])
      selected = content[key]
      custom = content[key <> "__other"]

      custom =
        cond do
          is_nil(custom) -> nil
          is_binary(custom) -> if(String.trim(custom) == "", do: nil, else: String.trim(custom))
          true -> :invalid
        end

      custom =
        if labels == [] and is_nil(custom) and is_binary(selected),
          do: String.trim(selected),
          else: custom

      selected =
        cond do
          labels == [] and is_binary(selected) -> []
          question["multi"] and is_list(selected) -> selected
          not question["multi"] and is_binary(selected) and is_nil(custom) -> [selected]
          is_nil(selected) or is_binary(custom) -> []
          true -> :invalid
        end

      if is_list(selected) and length(selected) <= @max_options and
           Enum.all?(selected, &(&1 in labels)) and
           (is_nil(custom) or
              (is_binary(custom) and byte_size(custom) <= @answer_bytes and String.valid?(custom))) and
           (selected != [] or (is_binary(custom) and custom != "")) do
        answer =
          %{
            "id" => question["id"],
            "question" => question["question"],
            "options" => labels,
            "multi" => question["multi"],
            "selectedOptions" => Enum.uniq(selected)
          }
          |> put_optional("customInput", custom)

        {:cont, {:ok, [answer | answers]}}
      else
        {:halt, {:error, :invalid_response}}
      end
    end)
    |> case do
      {:ok, answers} ->
        answers = Enum.reverse(answers)

        %AgentToolResult{
          content: [%TextContent{text: Jason.encode!(%{results: answers})}],
          details: %{status: "answered", results: answers}
        }

      {:error, reason} ->
        failure(reason)
    end
  end

  defp accepted(_questions, _content), do: failure(:invalid_response)

  defp failure(reason) do
    {message, details} =
      case reason do
        :declined ->
          {"The user declined to answer the questions.",
           %{status: "declined", error_type: "user_declined"}}

        :cancelled ->
          {"The user cancelled the questions; no answer was selected.",
           %{status: "cancelled", cancelled: true, error_type: "aborted"}}

        :timeout ->
          {"The user question timed out; no recommendation was selected.",
           %{status: "timed_out", error_type: "timeout"}}

        :no_client ->
          {"No interactive user-prompt surface is connected to this session.",
           %{error_type: "client_unavailable"}}

        :client_down ->
          {"The interactive client disconnected before answering.",
           %{error_type: "client_unavailable"}}

        :invalid_response ->
          {"The client did not supply a valid answer for every question.",
           %{error_type: "invalid_client_response"}}

        :prompt_pending ->
          {"Another user question is already pending for this session.",
           %{error_type: "prompt_pending"}}

        :invalid_timeout ->
          {"timeout_ms must be a positive integer.", %{error_type: "invalid_arguments"}}

        message when is_binary(message) ->
          {message, %{error_type: "invalid_arguments"}}
      end

    %AgentToolResult{content: [%TextContent{text: message}], details: details, is_error: true}
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end

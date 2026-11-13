defmodule CodingAgent.Tools.Ask do
  @moduledoc """
  Ask an interactive user through a session prompt surface or ACP elicitation.

  Takes either structured `questions` or one agent-written HTML `<form>` (`html`).
  Forms are rendered only by session prompt surfaces that declared `html_forms`
  support when binding (the TUI); ACP elicitation and chat channels fail with a
  clear error rather than waiting forever.

  Available only while a session user-prompt surface is bound, or a run's client
  advertised `elicitation.form` and its bridge is registered. Answers come from
  the real client; decline, cancellation, disconnection and timeout never choose
  a recommendation for the user.
  """

  alias CodingAgent.Session.UserPrompt
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.ACPClientBridge

  @max_questions 8
  @max_options 20
  @answer_bytes 4_000
  @max_html_bytes 65_536
  @max_form_fields 64
  @form_text_bytes 4_100

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
        "Ask the user for clarification or a decision. Provide exactly one of `questions` or `html`. " <>
          "Use `questions` for quick choices or free text (empty options list); the user can also give a custom answer. " <>
          "Use `html` (one <form>) when you need several related answers, typed fields (number, date, textarea) or richer context: " <>
          "radios, checkboxes, <select>, <input>, <textarea> with `name` attributes, <fieldset>/<legend> and <p> for context. " <>
          "No scripts, buttons or password fields; the UI adds Submit and Cancel. " <>
          "The user can decline or cancel. Do not ask for credentials or secrets.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "timeout_ms" => %{
            "type" => "integer",
            "minimum" => 1,
            "description" => "Optional deadline in milliseconds. Timeout never selects an answer."
          },
          "html" => %{
            "type" => "string",
            "maxLength" => @max_html_bytes,
            "description" =>
              "A single HTML <form> rendered as an interactive dialog. Exclusive with `questions`."
          },
          "questions" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => @max_questions,
            "description" => "Structured questions. Exclusive with `html`.",
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
        }
      },
      execute: fn id, params, signal, on_update ->
        execute(id, params, signal, on_update, opts)
      end
    }
  end

  def execute(_id, params, signal, on_update, opts) do
    with :ok <- connected(opts),
         :ok <- not_aborted(signal),
         {:ok, ask} <- ask_request(params),
         {:ok, timeout} <- timeout(params, opts),
         :ok <- announce_waiting(on_update),
         {:ok, response} <- request_answer(ask, signal, opts, timeout),
         :ok <- not_aborted(signal) do
      response_result(ask, response)
    else
      {:error, reason} -> failure(reason)
    end
  end

  # Exactly one of `html` or `questions`; neither or both is an argument error.
  defp ask_request(params) do
    html = params["html"]
    questions = params["questions"]

    cond do
      not is_nil(html) and not is_nil(questions) ->
        {:error, "provide either html or questions, not both"}

      not is_nil(html) ->
        with {:ok, html} <- validate_html(html), do: {:ok, {:html, html}}

      is_nil(questions) ->
        {:error, "provide either questions or html"}

      true ->
        with {:ok, questions} <- questions(params), do: {:ok, {:questions, questions}}
    end
  end

  defp validate_html(html) when is_binary(html) do
    cond do
      not String.valid?(html) -> {:error, "html must be UTF-8"}
      byte_size(html) > @max_html_bytes -> {:error, "html must be at most #{@max_html_bytes} bytes"}
      String.trim(html) == "" -> {:error, "html must contain a <form>"}
      true -> validate_form(html)
    end
  end

  defp validate_html(_html), do: {:error, "html must be a string containing a <form>"}

  defp validate_form(html) do
    with {:ok, document} <- Floki.parse_document(html),
         [form | _] <- Floki.find(document, "form") do
      controls =
        [form] |> Floki.find("input, select, textarea") |> Enum.reject(&inert_control?/1)

      cond do
        controls == [] ->
          {:error, "the form must contain at least one input, select or textarea"}

        Enum.any?(controls, &(control_type(&1) == "password")) ->
          {:error, "forms must not ask for passwords or secrets"}

        true ->
          {:ok, html}
      end
    else
      _ -> {:error, "html must contain a <form> with fields"}
    end
  end

  defp control_type(node),
    do: node |> Floki.attribute("type") |> List.first() |> to_string() |> String.downcase()

  defp inert_control?({"input", _attrs, _children} = node),
    do: control_type(node) in ~w(hidden submit button reset image)

  defp inert_control?(_node), do: false

  defp timeout(params, opts) do
    value = Map.get(params, "timeout_ms", Keyword.get(opts, :user_prompt_timeout_ms, :infinity))

    if value == :infinity or (is_integer(value) and value > 0),
      do: {:ok, value},
      else: {:error, :invalid_timeout}
  end

  # Forms need a surface that declared it can render them; ACP elicitation has no
  # HTML form mode, so it fails fast instead of hanging or degrading silently.
  defp request_answer({:html, html}, signal, opts, timeout) do
    key = Keyword.get(opts, :session_key)

    if UserPrompt.bound?(key),
      do:
        UserPrompt.request(key, Keyword.get(opts, :run_id), [],
          html: html,
          timeout_ms: timeout,
          signal: signal
        ),
      else: {:error, :html_unsupported}
  end

  defp request_answer({:questions, questions}, signal, opts, timeout) do
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

  defp response_result(ask, response) do
    result =
      case response do
        %{"result" => result} when is_map(result) -> result
        result when is_map(result) -> result
        _ -> %{}
      end

    case {result["action"], ask} do
      {"accept", {:questions, questions}} -> accepted(questions, result["content"])
      {"accept", {:html, _html}} -> accepted_form(result)
      {"decline", _} -> failure(:declined)
      {"cancel", _} -> failure(:cancelled)
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

  # Form submissions: `content` is the form data (text, numbers, checkbox arrays);
  # `answers`/`notes` are the client's `formAnswers`/option-note listings and are
  # optional, falling back to name/value lines when absent.
  defp accepted_form(result) do
    content = result["content"]

    with true <- valid_form_content?(content),
         {:ok, answers} <- form_answers(result["answers"], content),
         {:ok, notes} <- form_notes(result["notes"]) do
      %AgentToolResult{
        content: [%TextContent{text: form_text(answers, notes, content)}],
        details: %{status: "answered", answers: answers, notes: notes, data: content}
      }
    else
      _ -> failure(:invalid_response)
    end
  end

  defp valid_form_content?(content) when is_map(content) and map_size(content) <= @max_form_fields do
    Enum.all?(content, fn {key, value} ->
      is_binary(key) and byte_size(key) <= 256 and
        (is_number(value) or form_text?(value, @answer_bytes) or
           (is_list(value) and length(value) <= @max_form_fields and
              Enum.all?(value, &form_text?(&1, @answer_bytes))))
    end)
  end

  defp valid_form_content?(_content), do: false

  defp form_text?(value, max), do: is_binary(value) and byte_size(value) <= max and String.valid?(value)

  defp form_answers(nil, content) do
    {:ok,
     content
     |> Enum.sort_by(&elem(&1, 0))
     |> Enum.map(fn {name, value} ->
       %{"name" => name, "question" => name, "answer" => answer_text(value)}
     end)}
  end

  defp form_answers(answers, _content) when is_list(answers) and length(answers) <= @max_form_fields do
    answers
    |> Enum.reduce_while({:ok, []}, fn answer, {:ok, acc} ->
      with true <- is_map(answer),
           true <- form_text?(answer["name"], 256),
           true <- form_text?(answer["question"], @form_text_bytes),
           true <- form_text?(answer["answer"], @form_text_bytes * 4) do
        {:cont, {:ok, [Map.take(answer, ["name", "question", "answer"]) | acc]}}
      else
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp form_answers(_answers, _content), do: :error

  defp form_notes(nil), do: {:ok, []}

  defp form_notes(notes) when is_list(notes) and length(notes) <= @max_form_fields do
    notes
    |> Enum.reduce_while({:ok, []}, fn note, {:ok, acc} ->
      keys = ["name", "question", "option", "value", "text"]

      if is_map(note) and Enum.all?(keys, &form_text?(note[&1], @form_text_bytes)),
        do: {:cont, {:ok, [Map.take(note, keys) | acc]}},
        else: {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp form_notes(_notes), do: :error

  defp answer_text(value) when is_list(value), do: Enum.map_join(value, ", ", &to_string/1)
  defp answer_text(value), do: to_string(value)

  defp form_text(answers, notes, content) do
    lines =
      Enum.map(answers, fn answer ->
        text = if answer["answer"] == "", do: "(no answer)", else: indent(answer["answer"])
        "#{String.replace(answer["question"], ~r/\s+/u, " ")}: #{text}"
      end)

    note_lines =
      if notes == [],
        do: [],
        else:
          ["Notes on selected options:"] ++
            Enum.map(notes, fn note ->
              "- #{note["question"]} / #{note["option"]}: #{indent(note["text"])}"
            end)

    Enum.join(
      ["The user submitted the form.", "Answers:"] ++
        lines ++ note_lines ++ ["Raw form data: " <> Jason.encode!(content)],
      "\n"
    )
  end

  defp indent(text), do: String.replace(text, "\n", "\n  ")

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

        :html_unsupported ->
          {"No connected surface can render an HTML form (ACP elicitation and chat channels cannot). Ask again with `questions` instead.",
           %{error_type: "unsupported_surface"}}

        message when is_binary(message) ->
          {message, %{error_type: "invalid_arguments"}}
      end

    %AgentToolResult{content: [%TextContent{text: message}], details: details, is_error: true}
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end

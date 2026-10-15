defmodule CodingAgent.Tools.ReadImageQuestionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.Read
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{AssistantMessage, Context, ImageContent, TextContent, UserMessage}

  @moduletag :tmp_dir
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jDnoAAAAASUVORK5CYII="
       )

  test "routes image bytes and decoded question to the active vision model", %{tmp_dir: dir} do
    path = image(dir)
    owner = self()
    model = vision_model()

    completion = fn selected, context, options ->
      send(owner, {:completion, selected, context, options})
      response("A white pixel")
    end

    assert %AgentToolResult{
             trust: :untrusted,
             content: [%TextContent{text: "A white pixel"}],
             details: details
           } =
             read(path <> "?q=What+color%3F+Red%26blue%3F", dir,
               model: model,
               image_question_complete: completion
             )

    assert details.format == :image_question
    assert details.path == path

    assert_receive {:completion, ^model,
                    %Context{
                      messages: [
                        %UserMessage{
                          content: [
                            %TextContent{text: "What color? Red&blue?"},
                            %ImageContent{data: data, mime_type: "image/png"}
                          ]
                        }
                      ],
                      tools: []
                    }, options}

    assert Base.decode64!(data) == @png
    assert options.max_tokens == 1024
    assert options.stream_timeout == 30_000
  end

  test "configured vision role (including aliases) takes precedence over a text-only active model",
       %{tmp_dir: dir} do
    path = image(dir)
    owner = self()
    settings = %SettingsManager{model_roles: %{"vision" => "@eyes", "eyes" => "openai:gpt-4o"}}

    completion = fn model, _, _ ->
      send(owner, {:selected, model})
      response("answer")
    end

    assert %AgentToolResult{} =
             read(path <> "?q=describe", dir,
               model: Mocks.mock_model(),
               settings_manager: settings,
               image_question_complete: completion
             )

    assert_receive {:selected, %{id: "gpt-4o", input: input}}
    assert :image in input
  end

  test "no vision model configured gives actionable guidance without completing", %{tmp_dir: dir} do
    path = image(dir)

    for opts <- [
          [],
          [model: Mocks.mock_model()],
          [settings_manager: %SettingsManager{model_roles: %{"vision" => "unknown:model"}}]
        ] do
      assert {:error, message} = read(path <> "?q=describe", dir, opts)
      assert message =~ "[model_roles]"
      assert message =~ ":image"
    end
  end

  test "non-image questions fail instead of sending text to a model", %{tmp_dir: dir} do
    path = Path.join(dir, "notes.txt")
    File.write!(path, "hello")
    assert {:error, message} = read(path <> "?q=describe", dir)
    assert message =~ "requires an image path"
    svg = Path.join(dir, "drawing.svg")
    File.write!(svg, "<svg/>")
    assert {:error, message} = read(svg <> "?q=describe", dir)
    assert message =~ ":img?q="
  end

  test "SVG and SVGZ img selectors compose with image questions", %{tmp_dir: dir} do
    rasterizer = Path.join(dir, "rasterizer")

    File.write!(
      rasterizer,
      "#!/bin/sh\nprintf '%s' '#{Base.encode64(@png)}' | /usr/bin/base64 -D\n"
    )

    File.chmod!(rasterizer, 0o700)

    for extension <- ["svg", "svgz"] do
      path = Path.join(dir, "drawing." <> extension)
      markup = ~s(<svg xmlns="http://www.w3.org/2000/svg"/>)
      File.write!(path, if(extension == "svgz", do: :zlib.gzip(markup), else: markup))

      completion = fn _,
                      %Context{
                        messages: [
                          %UserMessage{
                            content: [%TextContent{text: "layout?"}, %ImageContent{data: data}]
                          }
                        ]
                      },
                      _ ->
        assert Base.decode64!(data) == @png
        response("layout answer")
      end

      assert %AgentToolResult{content: [%TextContent{text: "layout answer"}]} =
               read(path <> ":img?q=layout%3F", dir,
                 model: vision_model(),
                 svg_rasterizer: rasterizer,
                 image_question_complete: completion
               )
    end
  end

  test "literal filenames containing question marks or q markers win", %{tmp_dir: dir} do
    path = Path.join(dir, "literal?q=part?.png")
    File.write!(path, @png)
    assert %AgentToolResult{content: content} = read(path, dir)
    assert Enum.any?(content, &match?(%ImageContent{}, &1))
    completion = fn _, _, _ -> response("answer") end

    assert %AgentToolResult{content: [%TextContent{text: "answer"}]} =
             read(path <> "?q=what?", dir,
               model: vision_model(),
               image_question_complete: completion
             )

    literal = Path.join(dir, "literal.png?q=not-a-query")
    File.write!(literal, "literal text")
    assert %AgentToolResult{content: [%TextContent{text: text}]} = read(literal, dir)
    assert text =~ "literal text"
  end

  test "JSON queries retain their existing meaning", %{tmp_dir: dir} do
    path = Path.join(dir, "data.json")
    File.write!(path, ~s({"color":"red"}))
    assert %AgentToolResult{content: [%TextContent{text: text}]} = read(path <> "?q=.color", dir)
    assert text =~ "red"
  end

  test "bounds long completion answers and rejects empty questions", %{tmp_dir: dir} do
    path = image(dir)
    completion = fn _, _, _ -> response(String.duplicate("🌍", 9000)) end

    assert %AgentToolResult{
             content: [%TextContent{text: text}],
             details: %{answer_truncated: true}
           } =
             read(path <> "?q=describe", dir,
               model: vision_model(),
               image_question_complete: completion
             )

    assert String.length(text) == 8192
    assert String.valid?(text)

    assert {:error, message} =
             read(path <> "?q=", dir, model: vision_model(), image_question_complete: completion)

    assert message =~ "non-empty"
  end

  test "uses the session's current model after a model switch", %{tmp_dir: dir} do
    session = start_supervised!({Session, cwd: dir, model: Mocks.mock_model(), tools: []})
    assert %{model: %{input: [:text]}} = Session.model_context(session)
    model = vision_model()
    :ok = Session.switch_model(session, model)
    path = image(dir)

    completion = fn selected, _, _ ->
      assert selected == model
      response("current model")
    end

    assert %AgentToolResult{content: [%TextContent{text: "current model"}]} =
             read(path <> "?q=describe", dir,
               model: Mocks.mock_model(),
               session_pid: session,
               image_question_complete: completion
             )
  end

  test "provider failures return bounded safe errors", %{tmp_dir: dir} do
    path = image(dir)
    completion = fn _, _, _ -> {:error, "secret provider diagnostics"} end

    assert {:error, message} =
             read(path <> "?q=describe", dir,
               model: vision_model(),
               image_question_complete: completion
             )

    refute message =~ "secret"
  end

  defp vision_model, do: %{Mocks.mock_model() | input: [:text, :image]}
  defp response(text), do: {:ok, %AssistantMessage{content: [%TextContent{text: text}]}}

  defp read(path, cwd, opts \\ []),
    do: Read.execute("question", %{"path" => path}, nil, nil, cwd, opts)

  defp image(dir) do
    path = Path.join(dir, "pixel.png")
    File.write!(path, @png)
    path
  end
end

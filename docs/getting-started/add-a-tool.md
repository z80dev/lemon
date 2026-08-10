# Add a tool

A tool is the only way an agent affects anything. This guide adds a second one
to the project from [Build your first agent](build-your-first-agent.md) — a
`read_file` tool with a root guard — and covers the parts of the contract that
are not visible in the type signatures.

## What a tool is

`AgentCore.Types.AgentTool` is a struct with four fields the model sees and one
it does not:

| Field | Who reads it | Notes |
|---|---|---|
| `name` | the model | Snake case. Stable: it appears in transcripts. |
| `description` | the model | This is a prompt. See below. |
| `parameters` | the model | JSON Schema, as a plain map with string keys. |
| `label` | humans | Shown in UIs and logs. |
| `execute` | the loop | `(tool_call_id, params, signal, on_update)`. |

Two rules matter more than the rest:

**The description is a prompt, not documentation.** It is the only thing telling
the model when to reach for this tool. Say what it does *and* when to use it.
"Read a file" is worse than "Read a file from the project; use this before
answering questions about file contents rather than recalling them."

**`execute` should not raise.** Return a result whose content explains the
failure. A model can usually recover from "that file does not exist" by trying
a different path; it cannot recover from a dead run. Every failure path in the
tool below returns a result.

## 1. Write the tool

`lib/my_agent/tools/read_file.ex`:

```elixir
defmodule MyAgent.Tools.ReadFile do
  @moduledoc """
  Reads a UTF-8 text file from inside a root directory.

  The root guard is the point of the example: `path` comes from the model,
  which got it from whatever the model was reading, which may include text a
  stranger wrote. `Path.safe_relative/1` rejects anything that climbs out.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @max_chars 20_000

  @spec tool(keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &File.cwd!/0)

    %AgentTool{
      name: "read_file",
      label: "Read file",
      description: """
      Read a UTF-8 text file from the project. Paths are relative to the \
      project root; anything outside it is refused. Use this before answering \
      questions about file contents rather than recalling them.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the file, relative to the project root."
          }
        },
        "required" => ["path"]
      },
      execute: fn id, params, signal, on_update ->
        execute(root, id, params, signal, on_update)
      end
    }
  end

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts), do: tool(Keyword.put(opts, :root, cwd))

  def execute(root, _tool_call_id, %{"path" => path}, _signal, _on_update)
      when is_binary(path) do
    with {:ok, relative} <- Path.safe_relative(path),
         {:ok, contents} <- File.read(Path.join(root, relative)) do
      ok(String.slice(contents, 0, @max_chars))
    else
      :error ->
        failed("refused: #{path} points outside the project root")

      {:error, reason} ->
        failed("could not read #{path}: #{reason |> :file.format_error() |> List.to_string()}")
    end
  end

  def execute(_root, _tool_call_id, _params, _signal, _on_update) do
    failed(~s(read_file needs a "path" string parameter))
  end

  defp ok(text) do
    %AgentToolResult{
      content: [%TextContent{text: text}],
      details: %{chars: String.length(text)},
      # File contents are data, not instructions. Marking them untrusted is how
      # a downstream renderer or policy knows not to treat them as either.
      trust: :untrusted
    }
  end

  defp failed(message) do
    %AgentToolResult{content: [%TextContent{text: message}], details: %{error: true}}
  end
end
```

## 2. Give it to the agent

In `lib/my_agent/agent.ex`, add it to `tools/0`:

```elixir
def tools do
  builtin = [
    MyAgent.Tools.WordCount.tool(),
    MyAgent.Tools.ReadFile.tool()
  ]

  taken = Enum.map(builtin, &String.to_atom(&1.name))

  contributed =
    for {_name, module} <- AgentCore.ToolRegistry.available(taken), do: module.tool()

  builtin ++ contributed
end
```

## 3. Test it

`test/my_agent/tools/read_file_test.exs`:

```elixir
defmodule MyAgent.Tools.ReadFileTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias MyAgent.Tools.ReadFile

  setup do
    root = Path.join(System.tmp_dir!(), "read_file_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "reads a file inside the root", %{root: root} do
    File.write!(Path.join(root, "notes.txt"), "hello")

    assert %AgentToolResult{content: [%{text: "hello"}], trust: :untrusted} =
             run(root, "notes.txt")
  end

  test "refuses a path that climbs out of the root", %{root: root} do
    assert %AgentToolResult{details: %{error: true}} = run(root, "../../etc/passwd")
  end

  test "reports a missing file instead of raising", %{root: root} do
    assert %AgentToolResult{details: %{error: true}} = run(root, "nope.txt")
  end

  defp run(root, path) do
    ReadFile.tool(root: root).execute.("call_1", %{"path" => path}, nil, nil)
  end
end
```

Then prove the model can actually reach it, using the scripted LLM rather than
the network. Add to `test/my_agent/agent_test.exs`:

```elixir
test "reads a file when asked to" do
  File.write!("tmp_readme.txt", "two words")
  on_exit(fn -> File.rm("tmp_readme.txt") end)

  agent =
    start_supervised!(
      {Agent,
       name: nil,
       stream_fn:
         FakeLLM.scripted([
           FakeLLM.tool_call("read_file", %{"path" => "tmp_readme.txt"}),
           FakeLLM.say("It says: two words.")
         ])}
    )

  assert {:ok, "It says: two words."} = Agent.ask(agent, "what is in tmp_readme.txt?")
end
```

```bash
mix test
```

## The `execute` arguments

```elixir
execute: fn tool_call_id, params, signal, on_update -> ... end
```

- **`tool_call_id`** identifies this invocation. Useful for correlating logs
  with the transcript.
- **`params`** are the parsed arguments, with string keys, exactly as the model
  produced them. The model is not bound by your JSON Schema — it is a strong
  hint, not a validator — so match defensively and keep the catch-all clause.
- **`signal`** is an abort reference, or `nil`. Long-running tools should check
  it (`AgentCore.AbortSignal.aborted?/1`) between chunks of work so that
  cancelling a run actually stops them.
- **`on_update`** streams a partial result to the UI before the tool finishes.
  It is `nil` when nobody is listening, so always guard it:

  ```elixir
  if on_update do
    on_update.(%AgentToolResult{content: [%TextContent{text: "reading…"}]})
  end
  ```

## The result

`AgentCore.Types.AgentToolResult` has three fields:

- **`content`** — a list of `Ai.Types.TextContent` or `Ai.Types.ImageContent`.
  This is what the model sees.
- **`details`** — anything at all, for your UI and logs. The model never sees it,
  which makes it the right place for structured data you do not want retokenized.
- **`trust`** — `:trusted` (default) or `:untrusted`. Mark anything that came
  from outside your system. For content from a genuinely hostile source — an
  email, a web page — `AgentCore.Security.ExternalContent.wrap_external_content/2`
  additionally fences the text with a warning the model is trained to respect.

## Tools from a dependency

A library can add a tool to your agent without you naming it, by registering at
boot:

```elixir
# in the dependency's Application.start/2
AgentCore.ToolRegistry.register(:weather, MyLib.Tools.Weather)
```

`MyLib.Tools.Weather` needs the same `tool/0`, `tool/1` and `tool/2` functions
as the tools above. Your `tools/0` already picks it up: `available/1` returns
every registration whose name does not collide with one of yours, so a
dependency can never quietly replace a tool you wrote.

This is how integrations that live in their own repositories plug in — the
platform has no compile-time knowledge of them at all.

## Next

- [Add a channel](add-a-channel.md) — get the agent talking to something other
  than your terminal.
- [Persist memory](persist-memory.md) — keep what it learned.

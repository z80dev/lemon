defmodule CodingAgent.ToolDialects do
  @moduledoc """
  Opt-in vendor input dialects over already-authorized native tool closures.

  Apply only after registry policy, approvals, hooks and the plan gate. Parameter
  translation happens before entering those closures; no implementation, policy
  name, approval tier, checkpoint or mutation lock is replaced. Stream callbacks
  are disabled because they prepare native arguments, not vendor arguments.

  `:vendor_tool_dialects` overrides `runtime.tools.vendor_dialects` for controlled
  arena sessions. Both default to false. Claude model IDs use Read/Edit/Bash;
  Codex IDs or the Codex Responses API use the upstream freeform apply_patch.
  Other tools/models retain their native definitions.

  Input fields are pinned from @anthropic-ai/claude-code 2.1.325's
  `sdk-tools.d.ts` (FileReadInput, FileEditInput, BashInput). The patch grammar is
  from openai/codex b016cd18472588606c04af565528c4cd6746a41f,
  `codex-rs/core/assets/tools/apply_patch.lark`. The upstream identity manifest
  records source hashes. Lemon's native output, timeout and read limits remain
  authoritative; `dangerouslyDisableSandbox: true` is never supported.
  """

  alias LemonAgent.Types.AgentTool

  @grammar_path Path.expand("../../priv/tool_dialects/apply_patch.lark", __DIR__)
  import Kernel, except: [apply: 2]

  @external_resource @grammar_path
  @grammar File.read!(@grammar_path)

  @doc "Project an already wrapped native inventory without granting tools."
  def apply(tools, opts) do
    settings = Keyword.get(opts, :settings_manager) || %{}
    config = Map.get(settings, :tools, %{}) || %{}

    enabled =
      Keyword.get(
        opts,
        :vendor_tool_dialects,
        Map.get(config, :vendor_dialects, Map.get(config, "vendor_dialects", false))
      )

    if enabled == true do
      family = family(Keyword.get(opts, :model))

      tools
      |> Enum.map(&project(&1, family))
      |> Enum.uniq_by(& &1.name)
    else
      tools
    end
  end

  defp family(%{id: "claude-" <> _}), do: :claude
  defp family(%{api: :openai_codex_responses}), do: :codex

  defp family(%{id: id}) when is_binary(id) do
    if String.contains?(id, "codex"), do: :codex, else: :native
  end

  defp family(_), do: :native

  defp project(%AgentTool{name: "read"} = tool, :claude) do
    wrap(
      tool,
      "Read",
      schema(
        %{
          "file_path" => string("The absolute path to the file to read"),
          "offset" => %{"type" => "integer", "minimum" => 1},
          "limit" => %{"type" => "integer", "minimum" => 1},
          "pages" => string("PDF page range, e.g. 1-5; at most 20 pages"),
          "allow_large" => %{
            "type" => "boolean",
            "description" => "Lemon's native read caps still apply"
          }
        },
        ["file_path"]
      ),
      &read_args/1,
      "Read a file using Lemon's native reader, snapshots and output limits. PDF pages accepts a page or range."
    )
  end

  defp project(%AgentTool{name: "edit"} = tool, :claude) do
    wrap(
      tool,
      "Edit",
      schema(
        %{
          "file_path" => string("The absolute path to the file to modify"),
          "old_string" => string("The text to replace"),
          "new_string" => string("The replacement text"),
          "replace_all" => %{"type" => "boolean", "default" => false}
        },
        ["file_path", "old_string", "new_string"]
      ),
      fn args ->
        {:ok,
         args
         |> rename("file_path", "path")
         |> rename("old_string", "old_text")
         |> rename("new_string", "new_text")
         |> Map.put("mode", "text")}
      end,
      "Replace text using Lemon's native edit checks. The match must be unique unless replace_all is true."
    )
  end

  defp project(%AgentTool{name: "bash"} = tool, :claude) do
    wrap(
      tool,
      "Bash",
      schema(
        %{
          "command" => string("The command to execute"),
          "timeout" => %{"type" => "number", "maximum" => 600_000},
          "description" => string("Concise description of what the command does"),
          "run_in_background" => %{"type" => "boolean"},
          "dangerouslyDisableSandbox" => %{"type" => "boolean"}
        },
        ["command"]
      ),
      fn args ->
        if Map.get(args, "dangerouslyDisableSandbox", false) == false,
          do: {:ok, Map.drop(args, ["description", "dangerouslyDisableSandbox"])},
          else: {:error, "Lemon does not support disabling sandbox or policy checks"}
      end,
      "Execute through Lemon's native bash runtime, approvals and process ownership. Native timeout/background semantics apply; sandbox override is unsupported."
    )
  end

  defp project(%AgentTool{name: "patch"} = tool, :codex) do
    parameters =
      schema(%{"input" => string("The complete apply_patch patch")}, ["input"])
      |> Map.put("x-lemon-tool-format", %{
        "type" => "grammar",
        "syntax" => "lark",
        "definition" => @grammar
      })

    wrap(
      tool,
      "apply_patch",
      parameters,
      fn args ->
        {:ok, rename(args, "input", "patch_text")}
      end,
      "The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON."
    )
  end

  defp project(tool, _family), do: tool

  defp wrap(tool, name, parameters, translate, description) do
    execute = fn id, args, signal, on_update ->
      with {:ok, native_args} <- translate.(args) do
        tool.execute.(id, native_args, signal, on_update)
      end
    end

    %{
      tool
      | name: name,
        description: description,
        parameters: parameters,
        execute: execute,
        on_stream: nil
    }
  end

  defp read_args(args) do
    native = args |> rename("file_path", "path") |> Map.drop(["pages", "allow_large"])

    case Map.get(args, "pages") do
      nil ->
        {:ok, native}

      pages when is_binary(pages) ->
        case Regex.run(~r/\A([1-9]\d*)(?:-([1-9]\d*))?\z/, pages) do
          [_, first] ->
            {:ok, Map.merge(native, %{"page" => String.to_integer(first), "page_limit" => 1})}

          [_, first, last] ->
            start = String.to_integer(first)
            count = String.to_integer(last) - start + 1

            if count in 1..20,
              do: {:ok, Map.merge(native, %{"page" => start, "page_limit" => count})},
              else: {:error, "pages must select between 1 and 20 consecutive PDF pages"}

          _ ->
            {:error, "pages must be a PDF page number or range (e.g. 1-5)"}
        end

      _ ->
        {:error, "pages must be a string"}
    end
  end

  defp rename(args, from, to) do
    case Map.pop(args, from) do
      {nil, rest} -> rest
      {value, rest} -> Map.put(rest, to, value)
    end
  end

  defp string(description), do: %{"type" => "string", "description" => description}

  defp schema(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
end

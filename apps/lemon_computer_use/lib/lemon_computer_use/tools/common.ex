defmodule LemonComputerUse.Tools.Common do
  @moduledoc """
  Builds the `cua_js` and `cua_js_reset` agent tools from the original
  computer-use server's `js` and `js_reset` descriptors.

  The description and input schema are the runtime's own, unchanged, followed
  by one line mapping its `cua_repl` names onto Lemon's tool names. Results are
  forwarded as the runtime returned them — text and images, with its error flag
  — and marked untrusted: they carry window titles, UI text and screenshots of
  arbitrary apps, so instructions inside them are data.
  """

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{ImageContent, TextContent}
  alias LemonComputerUse.Server

  @names %{"js" => "cua_js", "js_reset" => "cua_js_reset"}
  @labels %{"js" => "Computer use", "js_reset" => "Computer use reset"}
  @max_error_bytes 2_000

  @name_note "In Lemon, `cua_repl.js` is the `cua_js` tool and `cua_repl.js_reset` is the " <>
               "`cua_js_reset` tool."

  @fallback_parameters %{
    "js" => %{
      "type" => "object",
      "properties" => %{
        "code" => %{
          "type" => "string",
          "description" => "JavaScript to execute using the initialized cua_repl runtime."
        },
        "timeout_ms" => %{"type" => "integer", "minimum" => 1},
        "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 80}
      },
      "required" => ["code"],
      "additionalProperties" => false
    },
    "js_reset" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
  }

  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(original, opts) when original in ["js", "js_reset"] do
    {description, parameters} =
      case Server.cached_catalog() || catalog() do
        %{tools: tools} -> describe(original, tools)
        {:error, reason} -> unavailable(original, reason)
      end

    %AgentTool{
      name: Map.fetch!(@names, original),
      label: Map.fetch!(@labels, original),
      description: description,
      parameters: parameters,
      execute: &execute(original, &1, &2, &3, &4, opts)
    }
  end

  defp catalog do
    case Server.catalog() do
      {:ok, catalog} -> catalog
      {:error, _} = error -> error
    end
  end

  defp describe(original, tools) do
    case Enum.find(tools, &(is_map(&1) and &1["name"] == original)) do
      %{"description" => description, "inputSchema" => %{} = schema}
      when is_binary(description) ->
        {description <> "\n\n" <> @name_note, schema}

      _ ->
        unavailable(original, :descriptor_missing)
    end
  end

  defp unavailable(original, reason) do
    description =
      "Control native apps on this computer through the local LCU computer-use runtime. " <>
        "Currently unavailable: " <> error_text(reason)

    {description, Map.fetch!(@fallback_parameters, original)}
  end

  @doc false
  def execute(original, tool_call_id, params, signal, _on_update, opts) do
    with {:ok, context} <- call_context(opts, tool_call_id) do
      case Server.call(original, normalize_params(params), context, signal) do
        {:ok, %{"content" => content} = result} when is_list(content) ->
          to_result(original, content, result["isError"] == true)

        {:ok, _invalid} ->
          error_result(:invalid_result)

        {:error, reason} ->
          error_result(reason)
      end
    end
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_params), do: %{}

  @doc false
  @spec call_context(keyword(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def call_context(opts, tool_call_id) do
    approval = Keyword.get(opts, :approval_context) || %{}
    session_id = Keyword.get(opts, :session_id) || approval[:session_id]
    run_id = Keyword.get(opts, :run_id) || approval[:run_id]

    if is_binary(session_id) and session_id != "" do
      {:ok,
       %{
         session_id: session_id,
         # A run is Lemon's turn. Sessions outside a run use one session-long turn.
         turn_id: run_id || session_turn(session_id, Keyword.get(opts, :session_pid)),
         run_id: run_id,
         session_pid: Keyword.get(opts, :session_pid),
         tool_call_id: tool_call_id,
         session_key: approval[:session_key] || Keyword.get(opts, :session_key),
         agent_id: approval[:agent_id] || Keyword.get(opts, :agent_id),
         invocation_context_key:
           approval[:invocation_context_key] || Keyword.get(opts, :invocation_context_key),
         approval_request_fun: approval[:approval_request_fun]
       }}
    else
      {:error, "Computer use needs a Lemon session; this tool call has no session id."}
    end
  end

  # The runtime remembers ended turns, so a turn id must never be reused. A
  # session outside a Lemon run gets one turn per session process (shared by
  # both tools), ended when that process exits; the per-boot nonce keeps a
  # resumed session in a later VM from landing on an ended turn.
  defp session_turn(session_id, session_pid) do
    "session-" <>
      session_id <> "-" <> Integer.to_string(:erlang.phash2({session_pid, boot_nonce()}))
  end

  defp boot_nonce do
    case :persistent_term.get({__MODULE__, :boot_nonce}, nil) do
      nil ->
        nonce = :crypto.strong_rand_bytes(16)
        :persistent_term.put({__MODULE__, :boot_nonce}, nonce)
        nonce

      nonce ->
        nonce
    end
  end

  @doc false
  @spec to_result(String.t(), [map()], boolean()) :: AgentToolResult.t()
  def to_result(original, content, is_error?) do
    blocks = Enum.map(content, &block/1)

    %AgentToolResult{
      content: blocks,
      details: %{
        "tool" => original,
        "is_error" => is_error?,
        "content_types" => Enum.map(content, &content_type/1)
      },
      trust: :untrusted,
      is_error: is_error?
    }
  end

  defp block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: %TextContent{text: text}

  defp block(%{"type" => "image", "data" => data, "mimeType" => mime})
       when is_binary(data) and is_binary(mime),
       do: %ImageContent{data: data, mime_type: mime}

  defp block(item) do
    %TextContent{
      text:
        "[#{content_type(item)} content omitted: Lemon does not forward this MCP content type]"
    }
  end

  defp content_type(%{"type" => type}) when is_binary(type), do: String.slice(type, 0, 40)
  defp content_type(_item), do: "unknown"

  defp error_result(reason) do
    %AgentToolResult{
      content: [%TextContent{text: error_text(reason)}],
      details: %{"error" => error_tag(reason)},
      # Bridge errors can quote the runtime; keep them on the untrusted side.
      trust: if(match?({:bridge_error, _, _}, reason), do: :untrusted, else: :trusted),
      is_error: true
    }
  end

  @doc false
  @spec error_text(term()) :: String.t()
  def error_text(:aborted), do: "Computer use call aborted."

  def error_text(:connect_timeout),
    do: "Timed out connecting to the LCU computer-use runtime. Run `lcu doctor` to check it."

  def error_text(:unavailable), do: "Computer use is not running in this Lemon runtime."

  def error_text(:lcu_not_installed),
    do:
      "LCU is not installed (no bin/lcu under the configured LCU root). Install LCU and the " <>
        "ChatGPT desktop app, or set LEMON_COMPUTER_USE_LCU_ROOT."

  def error_text(:node_missing),
    do: "LCU's Node runtime was not found. Re-run LCU setup or set LEMON_COMPUTER_USE_NODE."

  def error_text(:bridge_missing), do: "The Lemon LCU bridge script is missing from this build."
  def error_text(:descriptor_missing), do: "The LCU runtime did not offer this tool."
  def error_text(:invalid_catalog), do: "The LCU runtime returned an invalid tool catalog."
  def error_text(:invalid_result), do: "The LCU runtime returned an invalid tool result."

  def error_text({:bridge_exited, _status}),
    do:
      "The LCU bridge exited during the call; the action may already have taken effect. " <>
        "Check the app's state before retrying."

  def error_text({:spawn_failed, _}), do: "Could not start the LCU bridge."

  def error_text({:bridge_error, message, _code}) when is_binary(message),
    do: "Computer use failed: " <> bound(message)

  def error_text(_reason), do: "Computer use failed."

  defp bound(message) do
    if byte_size(message) <= @max_error_bytes,
      do: message,
      else: String.slice(message, 0, @max_error_bytes) <> "…"
  end

  defp error_tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_tag(reason) when is_tuple(reason), do: reason |> elem(0) |> to_string()
  defp error_tag(_reason), do: "unknown"
end

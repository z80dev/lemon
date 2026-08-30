defmodule CodingAgent.Tools.BrowserExec do
  @moduledoc """
  Provider-neutral Browser Use Agent style structured browser programs.

  This deliberately uses a bounded action DSL instead of arbitrary Python so
  the same program runs across local Chrome, extension CDP, hosted CDP, and
  REST backends while retaining Lemon's per-action policy boundaries.
  """

  alias CodingAgent.Security.ExternalContent
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonBrowser.RoutePolicy

  import CodingAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @max_steps 25
  @actions %{
    "navigate" => "browser.navigate",
    "tabs" => "browser.tabs",
    "tab_open" => "browser.tabOpen",
    "tab_activate" => "browser.tabActivate",
    "tab_close" => "browser.tabClose",
    "snapshot" => "browser.snapshot",
    "get_content" => "browser.getContent",
    "click" => "browser.click",
    "type" => "browser.type",
    "hover" => "browser.hover",
    "select_option" => "browser.selectOption",
    "press" => "browser.press",
    "scroll" => "browser.scroll",
    "back" => "browser.back",
    "wait_for_selector" => "browser.waitForSelector",
    "evaluate" => "browser.evaluate",
    "events" => "browser.events",
    "screenshot" => "browser.screenshot",
    "cdp" => "browser.cdp"
  }

  def tool(cwd, opts) do
    %AgentTool{
      name: "browser_exec",
      label: "Browser Program",
      description:
        "Run up to 25 typed browser steps as one provider-neutral program. This is Lemon's " <>
          "bounded BUA-style code mode: it supports navigation, tab control, DOM actions, " <>
          "evaluation, screenshots, and developer-gated raw CDP without arbitrary host code.",
      parameters: parameters(),
      execute: fn _tool_call_id, params, signal, on_update ->
        execute(params, signal, on_update, cwd, opts)
      end
    }
  end

  def execute(params, signal, on_update, _cwd, opts) do
    with :ok <- check_abort(signal),
         {:ok, steps} <- normalize_steps(params),
         :ok <- validate_developer_steps(steps, opts) do
      emit(on_update, "started", %{"stepCount" => length(steps)})
      request = browser_request(opts)

      result = run_steps(steps, request, signal, opts)
      emit(on_update, "completed", Map.take(result, ["ok", "completedSteps", "failedStep"]))

      result
      |> Map.put("tool", "browser_exec")
      |> Map.put(
        "trustMetadata",
        ExternalContent.trust_metadata(:web_fetch,
          key_style: :camel_case,
          warning_included: false,
          wrapped_fields: []
        )
      )
      |> ExternalContent.untrusted_json_result()
    end
  end

  defp run_steps(steps, request, signal, opts) do
    Enum.reduce_while(Enum.with_index(steps), initial_result(), fn {step, index}, acc ->
      with :ok <- check_abort(signal),
           {:ok, method} <- method_for(step["action"]),
           {:ok, args} <- prepare_args(step, acc),
           {:ok, output} <- request.(method, args, step_timeout(step, opts)) do
        item = %{
          "index" => index,
          "action" => step["action"],
          "output" => redact_output(output, step["action"])
        }

        next =
          acc
          |> Map.update!("results", &(&1 ++ [item]))
          |> Map.put("completedSteps", index + 1)
          |> update_active_target(output)

        {:cont, next}
      else
        {:error, reason} ->
          failed = %{
            "ok" => false,
            "failedStep" => index,
            "failedAction" => step["action"],
            "error" => safe_reason(reason)
          }

          {:halt, Map.merge(acc, failed)}
      end
    end)
    |> Map.drop(["activeTargetId"])
  end

  defp initial_result,
    do: %{"ok" => true, "completedSteps" => 0, "results" => [], "activeTargetId" => nil}

  defp prepare_args(step, acc) do
    action = step["action"]
    args = if is_map(step["args"]), do: step["args"], else: %{}

    args =
      case args["targetId"] do
        "$active" -> Map.put(args, "targetId", acc["activeTargetId"])
        _ -> args
      end

    cond do
      args["targetId"] == nil and step["args"]["targetId"] == "$active" ->
        {:error, "browser_exec has no active target for $active"}

      action in ["navigate", "tab_open"] ->
        url = args["url"] || if(action == "tab_open", do: "about:blank")

        with true <- is_binary(url) || {:error, "#{action} requires args.url"},
             {:ok, _policy} <- RoutePolicy.validate_navigation(url, step["route"] || "auto") do
          {:ok, Map.put(args, "url", url)}
        end

      true ->
        {:ok, args}
    end
  end

  defp update_active_target(acc, output) when is_map(output) do
    target = output["activeTargetId"] || output["targetId"]
    if is_binary(target), do: Map.put(acc, "activeTargetId", target), else: acc
  end

  defp update_active_target(acc, _output), do: acc

  defp browser_request(opts) do
    Keyword.get_lazy(opts, :browser_request, fn ->
      browser_opts =
        opts
        |> Keyword.take([
          :browser_backend,
          :browser_controller_id,
          :browser_profile_id,
          :browser_provider_config,
          :browser_hybrid_local_backend,
          :browser_hybrid_public_backend,
          :browser_developer_mode,
          :session_id,
          :run_id
        ])
        |> Enum.map(fn
          {:browser_backend, value} -> {:backend, value}
          {:browser_controller_id, value} -> {:controller_id, value}
          {:browser_provider_config, value} -> {:provider_config, value}
          {:browser_hybrid_local_backend, value} -> {:hybrid_local_backend, value}
          {:browser_hybrid_public_backend, value} -> {:hybrid_public_backend, value}
          {:browser_developer_mode, value} -> {:developer_mode, value}
          pair -> pair
        end)

      fn method, args, timeout -> LemonBrowser.request(method, args, timeout, browser_opts) end
    end)
  end

  defp normalize_steps(%{"steps" => steps}) when is_list(steps) do
    cond do
      steps == [] ->
        {:error, "browser_exec steps cannot be empty"}

      length(steps) > @max_steps ->
        {:error, "browser_exec supports at most #{@max_steps} steps"}

      Enum.any?(steps, &(not is_map(&1))) ->
        {:error, "every browser_exec step must be an object"}

      Enum.any?(steps, fn step -> not is_map(step["args"] || step[:args]) end) ->
        {:error, "every browser_exec step requires an args object"}

      true ->
        {:ok, Enum.map(steps, &stringify_keys/1)}
    end
  end

  defp normalize_steps(_), do: {:error, "browser_exec requires a steps array"}

  defp validate_developer_steps(steps, opts) do
    if Enum.any?(steps, &(&1["action"] == "cdp")) and
         Keyword.get(opts, :browser_developer_mode, false) != true do
      {:error, "browser_exec cdp steps require browser_developer_mode=true"}
    else
      :ok
    end
  end

  defp method_for(action) do
    case Map.fetch(@actions, action) do
      {:ok, method} -> {:ok, method}
      :error -> {:error, "unsupported browser_exec action: #{inspect(action)}"}
    end
  end

  defp redact_output(output, "type") when is_map(output), do: Map.drop(output, ["text", "value"])
  defp redact_output(output, _action), do: output

  defp step_timeout(step, opts) do
    value = step["timeoutMs"] || Keyword.get(opts, :browser_exec_timeout_ms, 30_000)
    if is_integer(value) and value > 0, do: min(value, 120_000), else: 30_000
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp emit(on_update, phase, details) when is_function(on_update, 1) do
    on_update.(%AgentToolResult{
      content: [%TextContent{text: "browser_exec #{phase}"}],
      details: Map.merge(%{"tool" => "browser_exec", "phase" => phase}, details)
    })
  catch
    _, _ -> :ok
  end

  defp emit(_on_update, _phase, _details), do: :ok

  defp safe_reason(reason),
    do: reason |> inspect(limit: 8, printable_limit: 300) |> String.slice(0, 300)

  defp parameters do
    %{
      "type" => "object",
      "properties" => %{
        "steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_steps,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "action" => %{"type" => "string", "enum" => Map.keys(@actions) |> Enum.sort()},
              "args" => %{
                "type" => "object",
                "description" =>
                  "Arguments for the typed browser action. targetId may be $active to use the prior tab result."
              },
              "route" => %{"type" => "string", "enum" => ~w(auto public local)},
              "timeoutMs" => %{"type" => "integer", "minimum" => 1, "maximum" => 120_000}
            },
            "required" => ["action", "args"],
            "additionalProperties" => false
          }
        }
      },
      "required" => ["steps"],
      "additionalProperties" => false
    }
  end
end

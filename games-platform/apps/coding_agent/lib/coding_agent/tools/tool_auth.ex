defmodule CodingAgent.Tools.ToolAuth do
  @moduledoc """
  Authenticate a WASM tool using Ironclaw-style auth metadata.

  This tool checks a `<name>.capabilities.json` file for a top-level `auth`
  section, then:
  1. imports from `env_var` if configured,
  2. checks whether the configured secret already exists,
  3. returns manual setup instructions when a token is still needed.
  """

  alias AgentCore.AbortSignal
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent
  alias CodingAgent.Session
  alias CodingAgent.Wasm.Config, as: WasmConfig

  @type auth_result :: map()

  @doc """
  Returns the tool definition.
  """
  @spec tool(String.t(), keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    session_pid = Keyword.get(opts, :session_pid)
    settings_manager = Keyword.get(opts, :settings_manager)

    %AgentTool{
      name: "tool_auth",
      description: """
      Initiate authentication for a WASM tool using its capabilities metadata.

      For manual auth, this returns setup instructions and indicates `awaiting_token`.
      For env-backed auth, this can import the token into Lemon's secret store.
      """,
      label: "Tool Auth",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "WASM tool name to authenticate"
          }
        },
        "required" => ["name"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, session_pid, settings_manager)
    }
  end

  @spec execute(
          String.t(),
          map(),
          reference() | nil,
          (AgentToolResult.t() -> :ok) | nil,
          String.t(),
          pid() | nil,
          map() | nil
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, cwd, session_pid, settings_manager) do
    if AbortSignal.aborted?(signal) do
      {:error, "Operation aborted"}
    else
      with {:ok, name} <- extract_tool_name(params),
           :ok <- ensure_known_wasm_tool(name, session_pid),
           {:ok, result} <- authenticate_tool(name, cwd, settings_manager) do
        to_tool_result(result)
      else
        {:error, :invalid_name} ->
          {:error, "name is required"}

        {:error, :unknown_wasm_tool} ->
          {:error, "WASM tool is not loaded in this session"}

        {:error, {:capabilities_read_failed, reason}} ->
          {:error, "failed to read capabilities: #{inspect(reason)}"}

        {:error, {:capabilities_parse_failed, reason}} ->
          {:error, "failed to parse capabilities JSON: #{inspect(reason)}"}

        {:error, {:secret_store_failed, reason}} ->
          {:error, "failed to store secret: #{inspect(reason)}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp extract_tool_name(params) when is_map(params) do
    name = params["name"] || params[:name]

    if is_binary(name) and String.trim(name) != "" do
      {:ok, String.trim(name)}
    else
      {:error, :invalid_name}
    end
  end

  defp extract_tool_name(_), do: {:error, :invalid_name}

  defp ensure_known_wasm_tool(_name, nil), do: :ok

  defp ensure_known_wasm_tool(name, session_pid) when is_pid(session_pid) do
    if Process.alive?(session_pid) do
      state = Session.get_state(session_pid)

      if name in state.wasm_tool_names do
        :ok
      else
        {:error, :unknown_wasm_tool}
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp ensure_known_wasm_tool(_name, _), do: :ok

  defp authenticate_tool(name, cwd, settings_manager) do
    case find_capabilities_path(name, cwd, settings_manager) do
      nil ->
        {:ok, no_auth_required_result(name)}

      cap_path ->
        with {:ok, contents} <- safe_read(cap_path),
             {:ok, capabilities} <- safe_decode(contents) do
          auth = capabilities["auth"] || capabilities[:auth]

          case auth do
            auth when is_map(auth) ->
              handle_auth_config(name, auth)

            _ ->
              {:ok, no_auth_required_result(name)}
          end
        end
    end
  end

  defp handle_auth_config(name, auth) do
    secret_name = normalize_optional_string(auth["secret_name"] || auth[:secret_name])

    if is_nil(secret_name) do
      {:error, "invalid auth metadata: secret_name is required"}
    else
      provider = normalize_optional_string(auth["provider"] || auth[:provider]) || name

      display_name =
        normalize_optional_string(auth["display_name"] || auth[:display_name]) || name

      env_var = normalize_optional_string(auth["env_var"] || auth[:env_var])

      with :miss <- maybe_import_from_env(secret_name, env_var, provider),
           false <- secret_exists?(secret_name) do
        {:ok, awaiting_token_result(name, auth, secret_name, display_name)}
      else
        {:ok, :imported} ->
          {:ok, authenticated_result(name, display_name, secret_name)}

        true ->
          {:ok, authenticated_result(name, display_name, secret_name)}

        {:error, reason} ->
          {:error, {:secret_store_failed, reason}}
      end
    end
  end

  defp maybe_import_from_env(_secret_name, nil, _provider), do: :miss

  defp maybe_import_from_env(secret_name, env_var, provider) do
    case System.get_env(env_var) do
      value when is_binary(value) and value != "" ->
        case LemonCore.Secrets.set(secret_name, value, provider: provider) do
          {:ok, _metadata} -> {:ok, :imported}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        :miss
    end
  end

  defp secret_exists?(secret_name) do
    LemonCore.Secrets.exists?(secret_name, prefer_env: false, env_fallback: false)
  end

  defp awaiting_token_result(name, auth, secret_name, display_name) do
    setup_url = normalize_optional_string(auth["setup_url"] || auth[:setup_url])

    instructions =
      normalize_optional_string(auth["instructions"] || auth[:instructions]) ||
        default_instructions(display_name, secret_name)

    %{
      "name" => name,
      "kind" => "wasm_tool",
      "status" => "awaiting_token",
      "auth_url" => nil,
      "callback_type" => nil,
      "instructions" => instructions,
      "setup_url" => setup_url,
      "awaiting_token" => true
    }
  end

  defp authenticated_result(name, display_name, secret_name) do
    %{
      "name" => name,
      "kind" => "wasm_tool",
      "status" => "authenticated",
      "auth_url" => nil,
      "callback_type" => nil,
      "instructions" => nil,
      "setup_url" => nil,
      "awaiting_token" => false,
      "message" => "#{display_name} is authenticated",
      "secret_name" => secret_name
    }
  end

  defp no_auth_required_result(name) do
    %{
      "name" => name,
      "kind" => "wasm_tool",
      "status" => "no_auth_required",
      "auth_url" => nil,
      "callback_type" => nil,
      "instructions" => nil,
      "setup_url" => nil,
      "awaiting_token" => false
    }
  end

  defp default_instructions(display_name, secret_name) do
    "Provide your #{display_name} token by setting Lemon secret `#{secret_name}` and retrying tool_auth."
  end

  defp find_capabilities_path(name, cwd, settings_manager) do
    WasmConfig.load(cwd, settings_manager).discover_paths
    |> Enum.map(&Path.join(&1, "#{name}.capabilities.json"))
    |> Enum.find(&File.regular?/1)
  end

  defp safe_read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:capabilities_read_failed, reason}}
    end
  end

  defp safe_decode(contents) do
    case Jason.decode(contents) do
      {:ok, data} when is_map(data) -> {:ok, data}
      {:ok, _other} -> {:error, {:capabilities_parse_failed, :invalid_shape}}
      {:error, reason} -> {:error, {:capabilities_parse_failed, reason}}
    end
  end

  defp to_tool_result(result) do
    %AgentToolResult{
      content: [%TextContent{text: result_text(result)}],
      details: result
    }
  end

  defp result_text(%{"status" => "authenticated", "message" => message}) when is_binary(message),
    do: message

  defp result_text(%{"status" => "awaiting_token"} = result) do
    instructions = result["instructions"] || "Token setup is required."

    setup_line =
      case result["setup_url"] do
        url when is_binary(url) and url != "" -> "\nSetup URL: #{url}"
        _ -> ""
      end

    "Authentication required.\n#{instructions}#{setup_line}"
  end

  defp result_text(%{"status" => "no_auth_required"}), do: "No authentication is required."
  defp result_text(_), do: "Authentication check complete."

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil
end

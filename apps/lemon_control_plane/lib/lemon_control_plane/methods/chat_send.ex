defmodule LemonControlPlane.Methods.ChatSend do
  @moduledoc """
  Handler for the chat.send method.

  Sends a message to a session. An optional `profileId` inherits the profile's
  persona, model, node and workspace while retaining the caller's session key.
  An optional `cwd` must be an absolute existing directory; profile-bound and
  canonical profile sessions do not accept caller workspace overrides.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.{ChatSubmission, ImageInputs}

  @impl true
  def name, do: "chat.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    with {:ok, run_id} <- ChatSubmission.run_id(params),
         {:ok, images} <- ImageInputs.validate(Map.get(params, "images", [])) do
      submit(params, ctx, images, run_id)
    end
  end

  defp submit(params, ctx, images, run_id) do
    session_key = params["sessionKey"]
    prompt = params["prompt"] || params["message"]
    profile_id = params["profileId"]
    queue_mode = parse_queue_mode(params["queueMode"])
    router_mod = Map.get(ctx, :router_mod, LemonRouter)

    cond do
      is_nil(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      is_nil(prompt) ->
        {:error, {:invalid_request, "prompt is required", nil}}

      Map.has_key?(params, "profileId") and
          (not is_binary(profile_id) or profile_id == "") ->
        {:error, {:invalid_request, "profileId must be a nonempty string", nil}}

      Map.has_key?(params, "cwd") and not is_nil(profile_id) ->
        {:error, {:invalid_request, "cwd cannot override a profile workspace", nil}}

      Map.has_key?(params, "cwd") and not valid_cwd?(params["cwd"]) ->
        {:error, {:invalid_request, "cwd must be a nonempty absolute existing directory", nil}}

      Map.has_key?(params, "cwd") and profile_session?(session_key) ->
        {:error, {:invalid_request, "cwd cannot override a canonical profile session", nil}}

      true ->
        with {:ok, submit_params} <-
               build_request(params, profile_id, session_key, prompt, run_id, images, queue_mode) do
          submit_params =
            submit_params
            |> Map.merge(%{origin: :control_plane, images: images, queue_mode: queue_mode})
            |> Map.update(:meta, %{control_plane: true}, &Map.put(&1, :control_plane, true))

          dispatch(router_mod, submit_params, prompt, queue_mode)
        end
    end
  end

  defp build_request(params, nil, session_key, prompt, run_id, _images, _queue_mode) do
    request = %{
      run_id: run_id,
      session_key: session_key,
      agent_id: params["agentId"],
      prompt: prompt
    }

    {:ok, if(Map.has_key?(params, "cwd"), do: Map.put(request, :cwd, params["cwd"]), else: request)}
  end

  defp build_request(_params, profile_id, session_key, prompt, run_id, images, queue_mode) do
    case LemonCore.ProfileStore.get_for_execution(profile_id) do
      {:ok, profile} ->
        case LemonCore.ProfileStore.chat_request(profile, prompt,
               session_key: session_key,
               run_id: run_id,
               images: images,
               queue_mode: queue_mode
             ) do
          {:ok, request} -> {:ok, request}
          {:error, _} -> {:error, {:invalid_request, "Profile chat request is invalid", nil}}
        end

      {:error, :not_found} ->
        {:error, {:not_found, "Unknown profile", %{"profileId" => profile_id}}}

      {:error, :invalid_id} ->
        {:error, {:invalid_request, "Invalid profileId", nil}}

      {:error, _} ->
        {:error, {:unavailable, "Profile is unavailable", nil}}
    end
  end

  defp dispatch(router_mod, submit_params, prompt, queue_mode) do
    %{run_id: run_id, session_key: session_key, agent_id: agent_id} = submit_params

    with {:ok, receipt} <-
           ChatSubmission.submit(submit_params, &router_mod.submit_with_receipt/1) do
      {:ok, Map.put(receipt, "summary", summary(run_id, session_key, agent_id, prompt, queue_mode))}
    end
  end

  defp valid_cwd?(cwd) when is_binary(cwd) and cwd != "" do
    Path.type(cwd) == :absolute and File.dir?(cwd)
  end

  defp valid_cwd?(_cwd), do: false

  defp profile_session?(session_key) when is_binary(session_key) do
    case LemonCore.SessionKey.parse(session_key) do
      %{kind: :main, agent_id: id} ->
        case LemonCore.ProfileStore.get(id) do
          {:ok, profile} -> profile["canonicalSessionKey"] == session_key
          {:error, :not_found} -> false
          {:error, _} -> true
        end

      _ ->
        false
    end
  end

  defp profile_session?(_session_key), do: false

  defp parse_queue_mode(nil), do: :collect
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("redirect"), do: :redirect
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(_), do: :collect

  defp summary(run_id, session_key, agent_id, prompt, queue_mode) do
    %{
      "runId" => run_id,
      "sessionKey" => session_key,
      "agentId" => agent_id,
      "queueMode" => to_string(queue_mode),
      "promptBytes" => byte_size(to_string(prompt)),
      "cleanup" => %{
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end
end

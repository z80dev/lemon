defmodule LemonControlPlane.Methods.NodePairInvite do
  @moduledoc "Issues a short-lived, single-use invitation for a new node or generation-bound repair."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors
  require Logger

  @checkout_root Path.expand("../../../../..", __DIR__)
  @source_root if File.regular?(Path.join(@checkout_root, "bin/lemon")) and
                    File.regular?(Path.join(@checkout_root, "mix.exs")),
                  do: @checkout_root,
                  else: nil
  @release_base_url "https://github.com/z80dev/lemon"

  @impl true
  def name, do: "node.pair.invite"
  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, ctx) do
    Logger.info("node_io operation=node.pair.invite attempted=true redacted=true")
    node_name = params["nodeName"]
    purpose = Map.get(params, "purpose", "lemon_bot")
    labels = Map.get(params, "labels", %{})
    ttl = Map.get(params, "expiresInMs", 900_000)

    with :ok <- Authorize.authorize(ctx[:auth] || %{}, name(), scopes()),
         true <- valid_text?(node_name, 64),
         true <- valid_text?(purpose, 64),
         true <- valid_labels?(labels),
         true <- is_integer(ttl) and ttl in 1..86_400_000,
         {:ok, controller} <- controller_url(),
         {:ok, runtime} <- runtime_source(controller),
         {:ok, script_url} <- join_script_url(runtime),
         {:ok, binding, node} <- binding(params["nodeId"], String.trim(node_name)),
         purpose = metadata(params, "purpose", node, :purpose, String.trim(purpose)),
         labels = metadata(params, "labels", node, :labels, labels),
         true <- valid_text?(purpose, 64) and valid_labels?(labels) do
      code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      id = LemonCore.Id.uuid()
      expires_at = System.system_time(:millisecond) + ttl

      invite =
        Map.merge(binding, %{
          id: id,
          node_name: String.trim(node_name),
          purpose: purpose,
          labels: labels,
          expires_at_ms: expires_at
        })

      case NodeStore.put_invite(code, invite) do
        :ok ->
          {:ok,
           %{
             "inviteId" => id,
             "inviteCode" => code,
             "joinCommand" => join_command(script_url, runtime, controller, invite.node_name),
             "expiresAtMs" => expires_at,
             "summary" => %{
               "inviteId" => id,
               "expiresAtMs" => expires_at,
               "singleUse" => true,
               "includesOperatorCredentials" => false
             }
           }}

        {:error, _} ->
          {:error, Errors.unavailable("Enrollment invite store is unavailable")}
      end
    else
      false ->
        {:error, Errors.invalid_request("Invalid enrollment name, purpose, labels or expiry")}

      {:error, _} = error ->
        error
    end
  end

  defp binding(nil, _name), do: {:ok, %{}, nil}

  defp binding(node_id, name) when is_binary(node_id) and byte_size(node_id) in 1..128 do
    case NodeStore.repair_binding(node_id, name) do
      {:ok, binding, node} ->
        {:ok, binding, node}

      {:error, :not_found} ->
        {:error, Errors.not_found("Node repair identity was not found")}

      {:error, :invalid_binding} ->
        {:error,
         Errors.conflict("Node repair identity does not match its durable name or credential")}

      {:error, _} ->
        {:error, Errors.unavailable("Node repair identity store is unavailable")}
    end
  end

  defp binding(_id, _name), do: {:error, Errors.invalid_request("Invalid nodeId")}

  defp metadata(params, param, node, field, default) do
    if is_map(node) and not Map.has_key?(params, param),
      do: NodeStore.invite_field(node, field) || default,
      else: default
  end

  defp valid_labels?(labels) do
    is_map(labels) and not is_struct(labels) and map_size(labels) <= 32 and
      Enum.all?(labels, fn {key, value} ->
        valid_text?(key, 64) and is_binary(value) and String.valid?(value) and
          byte_size(value) <= 256 and not String.match?(value, ~r/[\x00-\x1f\x7f]/)
      end)
  end

  defp valid_text?(text, limit) do
    is_binary(text) and String.valid?(text) and byte_size(text) <= limit and
      String.trim(text) != "" and not String.match?(text, ~r/[\x00-\x1f\x7f]/)
  end

  defp controller_url do
    url =
      Application.get_env(:lemon_control_plane, :public_ws_url) ||
        System.get_env("LEMON_CONTROL_PLANE_PUBLIC_WS_URL") ||
        "ws://127.0.0.1:#{Application.get_env(:lemon_control_plane, :port, 4040)}/ws"

    if is_binary(url) and byte_size(url) <= 2048 do
      uri = URI.parse(url)

      if uri.scheme in ["ws", "wss"] and is_binary(uri.host) and uri.host != "" and
           uri.userinfo == nil and uri.query == nil and uri.fragment == nil and
           (uri.scheme == "wss" or uri.host in ["localhost", "127.0.0.1", "::1"]) do
        {:ok, url}
      else
        {:error, Errors.invalid_request("Configure a secure public control-plane WebSocket URL")}
      end
    else
      {:error, Errors.invalid_request("Configure a public control-plane WebSocket URL")}
    end
  end

  defp runtime_source(controller) do
    source_root = source_root()
    source = configured(:node_source_checkout, ["LEMON_NODE_SOURCE_CHECKOUT"])

    version =
      configured(:node_install_version, ["LEMON_NODE_INSTALL_VERSION", "LEMON_VERSION"]) ||
        if(is_nil(source_root), do: LemonCore.Update.Version.current())

    base_url =
      configured(:node_install_base_url, ["LEMON_NODE_INSTALL_BASE_URL", "LEMON_INSTALL_BASE_URL"]) ||
        if(is_nil(source_root), do: @release_base_url)

    cond do
      not is_nil(version) and not valid_version?(version) ->
        {:error, Errors.invalid_request("Configure an exact node install version")}

      not is_nil(source) and not is_nil(source_root) ->
        if valid_text?(source, 4096) and Path.type(source) == :absolute do
          {:ok, {:source, source, version}}
        else
          {:error,
           Errors.invalid_request("Configure an absolute destination node source checkout")}
        end

      source_checkout_available?(source_root) and
          URI.parse(controller).host in ["localhost", "127.0.0.1", "::1"] ->
        {:ok, {:source, source_root, version}}

      not is_nil(version) and valid_install_base_url?(base_url) ->
        {:ok, {:release, version, String.trim_trailing(base_url, "/")}}

      true ->
        {:error,
         Errors.invalid_request(
           "Configure a destination source checkout or an explicit node install version and HTTPS base URL"
         )}
    end
  end

  # A packaged release carries the checkout path of whichever machine compiled it,
  # so the compiled path is only meaningful while actually running from source.
  defp source_root do
    case System.get_env("RELEASE_VSN") do
      vsn when is_binary(vsn) and vsn != "" -> nil
      _ -> @source_root
    end
  end

  defp source_checkout_available?(nil), do: false

  defp source_checkout_available?(source_root) do
    File.regular?(Path.join(source_root, "bin/lemon")) and
      File.regular?(Path.join(source_root, "mix.exs"))
  end

  defp configured(key, env_names) do
    Application.get_env(:lemon_control_plane, key) ||
      Enum.find_value(env_names, &System.get_env/1)
  end

  defp valid_version?(version) do
    is_binary(version) and byte_size(version) <= 128 and
      Regex.match?(~r/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?\z/, version)
  end

  defp valid_install_base_url?(url) do
    if valid_text?(url, 2048) and not String.match?(url, ~r/\s/) do
      uri = URI.parse(url)

      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
        uri.userinfo == nil and uri.query == nil and uri.fragment == nil
    else
      false
    end
  rescue
    ArgumentError -> false
  end

  defp join_script_url({:source, source, _version}),
    do: {:ok, {:local, Path.join(source, "scripts/join-node.sh")}}

  defp join_script_url({:release, version, base_url}),
    do: {:ok, {:download, base_url <> "/releases/download/v" <> version <> "/join-node.sh"}}

  defp join_command(script_url, runtime, controller, node_name) do
    args = ["--name", node_name, "--controller", controller] ++ runtime_args(runtime)

    prefix =
      case script_url do
        {:local, path} ->
          "bash " <> quote_arg(path) <> " "

        {:download, url} ->
          "curl -fsSL --proto '=https' --proto-redir '=https' " <>
            quote_arg(url) <> " | bash -s -- "
      end

    prefix <> Enum.map_join(args, " ", &quote_arg/1)
  end

  defp runtime_args({:source, source, nil}), do: ["--source", source]

  defp runtime_args({:source, source, version}),
    do: ["--source", source, "--version", version]

  defp runtime_args({:release, version, base_url}),
    do: ["--version", version, "--base-url", base_url]

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

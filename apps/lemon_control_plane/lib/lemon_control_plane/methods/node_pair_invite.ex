defmodule LemonControlPlane.Methods.NodePairInvite do
  @moduledoc "Issues a short-lived, name-bound, single-use execution-node enrollment invite."
  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Protocol.Errors
  require Logger

  @impl true
  def name, do: "node.pair.invite"
  @impl true
  def scopes, do: [:pairing]

  @impl true
  def handle(params, ctx) do
    Logger.info("node_io operation=node.pair.invite attempted=true redacted=true")
    node_name = params["nodeName"]
    purpose = Map.get(params, "purpose", "lemon_bot")
    labels = Map.get(params, "labels", [])
    ttl = Map.get(params, "expiresInMs", 900_000)

    with :ok <- Authorize.authorize(ctx[:auth] || %{}, name(), scopes()),
         true <- valid_text?(node_name, 64),
         true <- valid_text?(purpose, 64),
         true <- is_list(labels) and length(labels) <= 16 and Enum.all?(labels, &valid_text?(&1, 64)),
         true <- is_integer(ttl) and ttl in 1..86_400_000,
         {:ok, controller} <- controller_url() do
      code = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      id = LemonCore.Id.uuid()
      expires_at = System.system_time(:millisecond) + ttl
      invite = %{
        id: id,
        node_name: String.trim(node_name),
        purpose: String.trim(purpose),
        labels: Enum.map(labels, &String.trim/1) |> Enum.uniq(),
        expires_at_ms: expires_at
      }

      case NodeStore.put_invite(code, invite) do
        :ok ->
          {:ok, %{
            "inviteId" => id,
            "inviteCode" => code,
            "joinCommand" => join_command(controller, invite.node_name, code),
            "expiresAtMs" => expires_at,
            "summary" => %{"inviteId" => id, "expiresAtMs" => expires_at, "singleUse" => true,
              "includesOperatorCredentials" => false}
          }}

        {:error, _} -> {:error, Errors.unavailable("Enrollment invite store is unavailable")}
      end
    else
      false -> {:error, Errors.invalid_request("Invalid enrollment name, purpose, labels or expiry")}
      {:error, _} = error -> error
    end
  end

  defp valid_text?(text, limit) do
    is_binary(text) and String.valid?(text) and byte_size(text) <= limit and
      String.trim(text) != "" and not String.match?(text, ~r/[\x00-\x1f\x7f]/)
  end

  defp controller_url do
    url = Application.get_env(:lemon_control_plane, :public_ws_url) ||
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

  defp join_command(controller, node_name, code) do
    "(if command -v lemon >/dev/null 2>&1; then lemon_bin=lemon; " <>
      "elif [ -x \"$HOME/.lemon/bin/lemon\" ]; then lemon_bin=\"$HOME/.lemon/bin/lemon\"; " <>
      "else installer=$(mktemp) && curl -fsSL --proto '=https' " <>
      "https://raw.githubusercontent.com/z80dev/lemon/main/install.sh -o \"$installer\" && " <>
      "sh \"$installer\" --skip-setup --no-modify-path; result=$?; rm -f \"$installer\"; " <>
      "[ \"$result\" -eq 0 ] || exit \"$result\"; lemon_bin=\"$HOME/.lemon/bin/lemon\"; fi; " <>
      "exec \"$lemon_bin\" node join --name #{quote_arg(node_name)} " <>
      "--controller #{quote_arg(controller)} --invite-code #{quote_arg(code)})"
  end

  defp quote_arg(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end

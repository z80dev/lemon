defmodule LemonControlPlane.Methods.NodeHostIOSupport do
  @moduledoc false

  alias LemonControlPlane.NodeIO
  alias LemonControlPlane.Protocol.Errors
  require Logger

  def handle(method, params, ctx) when is_map(params) do
    Logger.info("node_io operation=#{method} attempted=true redacted=true")
    with :ok <- string(params, "nodeId", 256),
         :ok <- validate(method, params) do
      NodeIO.invoke(params["nodeId"], method, Map.drop(params, ["nodeId"]), ctx)
    end
  end
  def handle(_, _, _), do: {:error, Errors.invalid_request("params must be an object")}

  defp validate("node.host.info", _), do: :ok
  defp validate("node.secrets.list", _), do: :ok
  defp validate("node.secrets.set", params) do
    with :ok <- string(params, "name", 256), do: string(params, "value", 1_048_576, true)
  end
  defp validate("node.secrets.delete", params), do: string(params, "name", 256)
  defp validate(method, params) do
    with :ok <- string(params, "path", 4096) do
      validate_file(method, params)
    end
  end
  defp validate_file("node.fs.list", params), do: boolean(params, "showHidden")
  defp validate_file("node.fs.read", params) do
    with :ok <- integer(params, "offset", 0, 9_007_199_254_740_991),
         do: integer(params, "length", 1, 1_048_576)
  end
  defp validate_file("node.fs.write", params) do
    with :ok <- string(params, "dataBase64", 1_398_104, true),
         :ok <- integer(params, "offset", 0, 9_007_199_254_740_991),
         :ok <- boolean(params, "truncate"),
         do: boolean(params, "mkdirs")
  end
  defp validate_file("node.fs.move", params), do: string(params, "destination", 4096)
  defp validate_file("node.fs.delete", params) do
    if params["confirm"] == params["path"],
      do: :ok,
      else: {:error, Errors.invalid_request("confirm must exactly equal path")}
  end
  defp validate_file(_, _), do: :ok

  defp string(params, field, max, empty \\ false) do
    value = params[field]
    if is_binary(value) and String.valid?(value) and byte_size(value) <= max and
         (empty or String.trim(value) != "") and (empty or not String.contains?(value, <<0>>)),
      do: :ok,
      else: {:error, Errors.invalid_request(field <> " must be a bounded string")}
  end
  defp boolean(params, field) do
    if not Map.has_key?(params, field) or is_boolean(params[field]),
      do: :ok,
      else: {:error, Errors.invalid_request(field <> " must be a boolean")}
  end
  defp integer(params, field, min, max) do
    value = params[field]
    if not Map.has_key?(params, field) or (is_integer(value) and value >= min and value <= max),
      do: :ok,
      else: {:error, Errors.invalid_request(field <> " must be a bounded integer")}
  end
end

defmodule LemonControlPlane.Methods.NodeHostInfo do
  @moduledoc "Destination-local host information."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.host.info"
  @impl true
  def scopes, do: [:read]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsList do
  @moduledoc "Bounded destination directory listing."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.list"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsStat do
  @moduledoc "Destination file metadata."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.stat"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsRead do
  @moduledoc "Bounded destination base64 file chunks."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.read"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsWrite do
  @moduledoc "Bounded destination file writes."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.write"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsMkdir do
  @moduledoc "Destination directory creation."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.mkdir"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsMove do
  @moduledoc "Destination-local move using path and destination."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.move"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeFsDelete do
  @moduledoc "Exact-caller-path-confirmed destination deletion."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.fs.delete"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeSecretsSet do
  @moduledoc "Write-only destination encrypted secret storage."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.secrets.set"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeSecretsList do
  @moduledoc "Bounded destination encrypted secret names, never values."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.secrets.list"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonControlPlane.Methods.NodeSecretsDelete do
  @moduledoc "Destination encrypted secret deletion."
  @behaviour LemonControlPlane.Method
  @impl true
  def name, do: "node.secrets.delete"
  @impl true
  def scopes, do: [:admin]
  @impl true
  def dispatch_mode, do: :async
  @impl true
  def handle(params, ctx), do: LemonControlPlane.Methods.NodeHostIOSupport.handle(name(), params, ctx)
end

defmodule LemonCore.WorkerStatus do
  @moduledoc "Canonical worker state location and redacted on-disk status contract."

  @states ~w(starting online reconnecting needs_reauthorization needs_enrollment conflict)
  @reasons ~w(session_expired session_invalid node_not_found credential_rejected credential_missing credential_unreadable controller_mismatch node_name_conflict node_identity_mismatch)

  def root(name, opts \\ []) do
    name = String.trim(name)
    if name == "", do: raise(ArgumentError, "worker name must not be blank")
    digest = :crypto.hash(:sha256, name) |> Base.encode16(case: :lower)
    Path.join([Keyword.get(opts, :home, System.user_home!()), ".lemon", "nodes", "state", digest])
  end

  def path(name, opts \\ []), do: Path.join(root(name, opts), "worker-status.json")

  def read(name, opts \\ []) do
    case File.read(path(name, opts)) do
      {:ok, bytes} ->
        with {:ok, map} <- Jason.decode(bytes),
             true <- valid?(map),
             true <- map["localName"] == String.trim(name) do
          {:ok, map}
        else
          _ -> {:error, :invalid}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      _ ->
        {:error, :invalid}
    end
  end

  def valid?(map) when is_map(map) do
    Enum.sort(Map.keys(map)) ==
      Enum.sort(~w(version localName state reason nodeId changedAtMs osPid)) and
      map["version"] == 1 and is_binary(map["localName"]) and map["state"] in @states and
      map["reason"] in [nil | @reasons] and (is_nil(map["nodeId"]) or is_binary(map["nodeId"])) and
      is_integer(map["changedAtMs"]) and map["changedAtMs"] >= 0 and is_integer(map["osPid"]) and
      map["osPid"] > 0
  end

  def valid?(_), do: false
end

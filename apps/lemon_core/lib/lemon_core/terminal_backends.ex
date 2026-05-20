defmodule LemonCore.TerminalBackends do
  @moduledoc """
  Registry for terminal execution backends.
  """

  @backends [
    LemonCore.TerminalBackends.Local,
    LemonCore.TerminalBackends.LocalPty,
    LemonCore.TerminalBackends.Docker,
    LemonCore.TerminalBackends.Ssh
  ]

  @doc """
  List registered terminal backends.
  """
  @spec list() :: [map()]
  def list do
    Enum.map(@backends, &backend_info/1)
  end

  @doc """
  Resolve backend metadata by id.
  """
  @spec get(atom() | String.t()) :: {:ok, map()} | {:error, :unknown_backend}
  def get(id) do
    normalized = normalize_id(id)

    case Enum.find(@backends, &(&1.id() == normalized)) do
      nil -> {:error, :unknown_backend}
      module -> {:ok, backend_info(module)}
    end
  end

  @doc """
  Validate and normalize a backend id.
  """
  @spec validate(atom() | String.t() | nil) :: {:ok, atom()} | {:error, :unknown_backend}
  def validate(nil), do: {:ok, :local}

  def validate(id) do
    normalized = normalize_id(id)

    case get(normalized) do
      {:ok, _} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Return backend capabilities for a validated id.
  """
  @spec capabilities(atom() | String.t() | nil) :: [atom()]
  def capabilities(id) do
    case get(id || :local) do
      {:ok, %{capabilities: capabilities}} -> capabilities
      {:error, _} -> []
    end
  end

  @doc """
  Return whether a backend is currently available on this host.
  """
  @spec available?(atom() | String.t() | nil) :: boolean()
  def available?(id) do
    case get(id || :local) do
      {:ok, %{available: true}} -> true
      _ -> false
    end
  end

  @doc """
  Return redacted diagnostics for first-party support surfaces.
  """
  @spec diagnostics() :: map()
  def diagnostics do
    backends = list()

    %{
      backends: backends,
      count: length(backends),
      default_backend: :local,
      policy: LemonCore.TerminalBackendPolicy.diagnostics(),
      cleanup: %{
        includes_commands: false,
        includes_environment: false,
        includes_process_output: false
      }
    }
  end

  defp backend_info(module) do
    module.metadata()
    |> Map.merge(%{
      id: module.id(),
      label: module.label(),
      available: module.available?(),
      policy: LemonCore.TerminalBackendPolicy.describe(module.id()),
      capabilities: module.capabilities()
    })
  end

  defp normalize_id(id) when is_atom(id), do: id

  defp normalize_id(id) when is_binary(id) do
    normalized =
      id
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    @backends
    |> Enum.map(& &1.id())
    |> Enum.find(:unknown, &(Atom.to_string(&1) == normalized))
  end

  defp normalize_id(_), do: :unknown
end

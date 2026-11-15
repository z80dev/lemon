defmodule LemonCore.ConfigReloader.Digest do
  @moduledoc """
  Change detection via source fingerprinting for the config reloader.

  Computes and compares digests for config sources (files, env, secrets)
  to determine whether a reload is necessary.

  File fingerprints combine mtime + size + content hash for reliable detection.
  Secret digests use the reloader's Bus-event revision, never secret values or lists.
  """

  @type source :: :files | :env | :secrets

  @type file_fingerprint :: %{
          path: String.t(),
          mtime: tuple() | nil,
          size: non_neg_integer() | nil,
          hash: binary() | nil,
          status: :ok | :missing | :error
        }

  @type source_digest :: %{
          source: source(),
          fingerprints: [file_fingerprint()] | [map()],
          computed_at_ms: non_neg_integer()
        }

  @type digest_set :: %{optional(source()) => source_digest()}

  # ---------------------------------------------------------------------------
  # File fingerprints
  # ---------------------------------------------------------------------------

  @doc """
  Compute a fingerprint for a single file path.

  Returns mtime, size, and a SHA-256 content hash.
  Missing or unreadable files are represented with status `:missing` or `:error`.
  """
  @spec file_fingerprint(String.t()) :: file_fingerprint()
  def file_fingerprint(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        hash = content_hash(expanded)

        %{
          path: expanded,
          mtime: mtime,
          size: size,
          hash: hash,
          status: :ok
        }

      {:error, _reason} ->
        %{
          path: expanded,
          mtime: nil,
          size: nil,
          hash: nil,
          status: :missing
        }
    end
  end

  @spec file_fingerprints([String.t()]) :: [file_fingerprint()]
  defp file_fingerprints(paths) when is_list(paths) do
    Enum.map(paths, &file_fingerprint/1)
  end

  @doc """
  Compute a full digest for the `:files` source.
  """
  @spec files_digest([String.t()]) :: source_digest()
  def files_digest(paths) do
    %{
      source: :files,
      fingerprints: file_fingerprints(paths),
      computed_at_ms: now_ms()
    }
  end

  # ---------------------------------------------------------------------------
  # Env digest (based on .env file fingerprint)
  # ---------------------------------------------------------------------------

  @doc """
  Compute a digest for the `:env` source.

  Tracks the `.env` file fingerprint as the change signal.
  """
  @spec env_digest(String.t() | nil) :: source_digest()
  def env_digest(dotenv_path) do
    fingerprints =
      if is_binary(dotenv_path) and dotenv_path != "" do
        [file_fingerprint(dotenv_path)]
      else
        []
      end

    %{
      source: :env,
      fingerprints: fingerprints,
      computed_at_ms: now_ms()
    }
  end

  # ---------------------------------------------------------------------------
  # Secrets digest (system Bus event revision)
  # ---------------------------------------------------------------------------

  @doc """
  Compute a digest for the `:secrets` source.

  The revision advances on each system Bus `:secret_changed` event. It is local
  to the reloader lifetime; startup takes a fresh configuration snapshot.
  """
  @spec secrets_digest(non_neg_integer()) :: source_digest()
  def secrets_digest(revision) when is_integer(revision) and revision >= 0 do
    %{
      source: :secrets,
      fingerprints: [%{revision: revision}],
      computed_at_ms: now_ms()
    }
  end

  # ---------------------------------------------------------------------------
  # Comparison
  # ---------------------------------------------------------------------------

  @doc """
  Compare two digest sets and return the list of sources that changed.

  Returns `{changed_sources, new_digest_set}`.
  """
  @spec compare(digest_set(), digest_set()) :: {[source()], digest_set()}
  def compare(old, new) when is_map(old) and is_map(new) do
    all_sources = MapSet.union(MapSet.new(Map.keys(old)), MapSet.new(Map.keys(new)))

    changed =
      all_sources
      |> Enum.filter(fn source ->
        source_changed?(Map.get(old, source), Map.get(new, source))
      end)
      |> Enum.sort()

    {changed, new}
  end

  @spec source_changed?(source_digest() | nil, source_digest() | nil) :: boolean()
  defp source_changed?(nil, nil), do: false
  defp source_changed?(nil, _new), do: true
  defp source_changed?(_old, nil), do: true

  defp source_changed?(old, new) do
    old.fingerprints != new.fingerprints
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp content_hash(path) do
    case File.read(path) do
      {:ok, content} -> :crypto.hash(:sha256, content)
      {:error, _} -> nil
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end

defmodule LemonCore.ConfigReloader.Digest do
  @moduledoc """
  Change detection via source fingerprinting for the config reloader.

  Computes and compares digests for config sources (files, env, secrets)
  to determine whether a reload is necessary.

  File fingerprints combine mtime and size, matching the config cache.
  Secret digests use metadata only (owner, name, updated_at, version) — never values.
  """

  @type source :: :files | :env | :secrets

  @type file_fingerprint :: %{
          path: String.t(),
          mtime: tuple() | nil,
          size: non_neg_integer() | nil,
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

  Returns mtime and size. Missing files are represented with status `:missing`.
  """
  @spec file_fingerprint(String.t()) :: file_fingerprint()
  def file_fingerprint(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{mtime: mtime, size: size}} ->
        %{
          path: expanded,
          mtime: mtime,
          size: size,
          status: :ok
        }

      {:error, _reason} ->
        %{
          path: expanded,
          mtime: nil,
          size: nil,
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
  # Secrets digest (metadata only)
  # ---------------------------------------------------------------------------

  @doc """
  Compute a digest for the `:secrets` source.

  Uses metadata only (owner, name, updated_at, version) — secret values are
  never included.
  """
  @spec secrets_digest([map()]) :: source_digest()
  def secrets_digest(secret_metadata_list) do
    fingerprints =
      secret_metadata_list
      |> Enum.map(fn meta ->
        %{
          owner: meta[:owner] || meta["owner"],
          name: meta[:name] || meta["name"],
          updated_at: meta[:updated_at] || meta["updated_at"],
          version: meta[:version] || meta["version"]
        }
      end)
      |> Enum.sort_by(&{&1.owner, &1.name})

    %{
      source: :secrets,
      fingerprints: fingerprints,
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

  defp now_ms, do: System.system_time(:millisecond)
end

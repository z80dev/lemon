defmodule LemonSkills.Sources.Git do
  @moduledoc """
  Source for skills hosted in git repositories.

  Accepts HTTPS, HTTP and SSH clone URLs. Every git command runs through
  `LemonSkills.GitRemote`: public destinations only, pinned, no redirects, a
  sanitized environment, a deadline and a size cap. Local paths, `file://`
  and helper transports are refused. Skills installed via git carry
  `:community` trust by default because they come from third-party
  repositories.

  ## Identifier forms

  - `"https://github.com/acme/k8s-skill"` — HTTPS clone URL
  - `"git@github.com:acme/k8s-skill.git"` — SSH clone URL
  - `"git+https://github.com/acme/k8s-skill"` — explicit git+ prefix (stripped by router)

  The canonical identifier is the bare clone URL (without `git+` prefix).
  """

  @behaviour LemonSkills.Source

  alias LemonSkills.{Entry, GitRemote, Manifest}

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def search(_query, _opts) do
    # Git source has no searchable index — use Sources.Github for discovery.
    []
  end

  @impl true
  def inspect(url, _opts) when is_binary(url) do
    # We cannot inspect a git repo without cloning; return the URL as metadata.
    {:ok, %{"url" => url, "source_kind" => "git"}}
  end

  @impl true
  def fetch(url, dest_dir, opts) when is_binary(url) do
    File.rm_rf(dest_dir)
    opts = Keyword.put_new(opts, :branch, "main")

    # `core.symlinks=false` checks symlinks out as plain files; the installer's
    # bundle scan then audits or rejects every entry of the fetched tree.
    case GitRemote.clone(url, dest_dir, opts) do
      :ok ->
        stripped(dest_dir)

      {:error, {:git_failed, output}} ->
        # Retry without --branch in case the default branch differs.
        case GitRemote.clone(url, dest_dir, Keyword.put(opts, :branch, nil)) do
          :ok -> stripped(dest_dir)
          {:error, {:git_failed, _}} -> {:error, {:clone_failed, output}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Remove .git to save space (provenance is tracked via lockfile).
  defp stripped(dest_dir) do
    File.rm_rf(Path.join(dest_dir, ".git"))
    {:ok, dest_dir}
  end

  @impl true
  def upstream_hash(url, opts) when is_binary(url) do
    # Fetch the latest commit hash of the default remote HEAD.
    case GitRemote.head(url, opts) do
      {:ok, hash} -> {:ok, hash}
      {:error, {:git_failed, output}} -> {:error, {:ls_remote_failed, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def trust_for_ref(_id), do: :community

  # ---------------------------------------------------------------------------
  # Private helpers used by installer (M2-04 will delegate here)
  # ---------------------------------------------------------------------------

  @doc false
  @spec load_from_dir(String.t(), boolean()) :: {:ok, Entry.t()} | {:error, term()}
  def load_from_dir(path, global) do
    source = if global, do: :global, else: :project
    entry = Entry.new(path, source: source, source_kind: :git, trust_level: :community)
    skill_file = Entry.skill_file(entry)

    case File.read(skill_file) do
      {:ok, content} ->
        case Manifest.parse_and_validate(content) do
          {:ok, manifest, _body} -> {:ok, Entry.with_manifest(entry, manifest)}
          {:error, reason} -> {:error, {:invalid_manifest, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end

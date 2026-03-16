defmodule LemonSkills.Sources.Git do
  @moduledoc """
  Source for skills hosted in git repositories.

  Accepts any git-cloneable URL including HTTPS and SSH forms.
  Skills installed via git carry `:community` trust by default because they
  come from third-party repositories.

  ## Identifier forms

  - `"https://github.com/acme/k8s-skill"` — HTTPS clone URL
  - `"git@github.com:acme/k8s-skill.git"` — SSH clone URL
  - `"git+https://github.com/acme/k8s-skill"` — explicit git+ prefix (stripped by router)

  The canonical identifier is the bare clone URL (without `git+` prefix).
  """

  @behaviour LemonSkills.Source

  alias LemonSkills.{Entry, Manifest}

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
    branch = Keyword.get(opts, :branch, "main")
    depth = Keyword.get(opts, :depth, 1)

    File.rm_rf(dest_dir)

    clone_args =
      ["clone", "--depth", to_string(depth), "--branch", branch, url, dest_dir]

    case System.cmd("git", clone_args, stderr_to_stdout: true) do
      {_out, 0} ->
        # Remove .git to save space (provenance is tracked via lockfile).
        File.rm_rf(Path.join(dest_dir, ".git"))
        {:ok, dest_dir}

      {output, _code} ->
        # Retry without --branch in case the default branch differs.
        retry_args = ["clone", "--depth", to_string(depth), url, dest_dir]

        case System.cmd("git", retry_args, stderr_to_stdout: true) do
          {_out2, 0} ->
            File.rm_rf(Path.join(dest_dir, ".git"))
            {:ok, dest_dir}

          {_, _} ->
            {:error, {:clone_failed, String.trim(output)}}
        end
    end
  end

  @impl true
  def upstream_hash(url, _opts) when is_binary(url) do
    # Fetch the latest commit hash of the default remote HEAD.
    case System.cmd("git", ["ls-remote", url, "HEAD"], stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(output, "\t", parts: 2) do
          [hash | _] -> {:ok, String.trim(hash)}
          _ -> {:error, :no_head}
        end

      {reason, _} ->
        {:error, {:ls_remote_failed, String.trim(reason)}}
    end
  end

  @impl true
  def trust_level, do: :community

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

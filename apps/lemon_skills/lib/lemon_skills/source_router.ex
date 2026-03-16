defmodule LemonSkills.SourceRouter do
  @moduledoc """
  Routes user-facing skill identifiers to the appropriate source module.

  ## Identifier forms

  | Pattern | Routed to | `source_kind` |
  |---------|-----------|--------------|
  | `"builtin"` | `Sources.Builtin` | `:builtin` |
  | Absolute path (`/…`) | `Sources.Local` | `:local` |
  | Relative path (`./…` or `../…`) | `Sources.Local` | `:local` |
  | `git+<url>` | `Sources.Git` | `:git` |
  | SSH git URL (`git@…`) | `Sources.Git` | `:git` |
  | `https://` or `http://` URL | `Sources.Git` | `:git` |
  | `gh:<owner>/<repo>` | `Sources.Github` | `:git` |
  | Registry ref (`<ns>/<cat>/<name>`) | `Sources.Registry` | `:registry` |

  ## Usage

      {:ok, mod, id} = LemonSkills.SourceRouter.resolve("https://github.com/acme/k8s-skill")
      # => {:ok, LemonSkills.Sources.Git, "https://github.com/acme/k8s-skill"}

      {:ok, mod, id} = LemonSkills.SourceRouter.resolve("official/devops/k8s-rollout")
      # => {:ok, LemonSkills.Sources.Registry, "official/devops/k8s-rollout"}

      {:ok, mod, id} = LemonSkills.SourceRouter.resolve("gh:acme/k8s-skill")
      # => {:ok, LemonSkills.Sources.Github, "acme/k8s-skill"}
  """

  alias LemonSkills.Sources.{Builtin, Git, Github, Local, Registry}

  @type routed :: {module(), String.t() | nil}

  @doc """
  Resolve a user-facing identifier into `{:ok, source_module, canonical_id}`.

  Returns `{:error, reason}` when the identifier cannot be mapped to any
  known source.
  """
  @spec resolve(String.t()) :: {:ok, module(), String.t() | nil} | {:error, String.t()}
  def resolve(id) when is_binary(id) do
    id = String.trim(id)

    cond do
      id == "builtin" ->
        {:ok, Builtin, nil}

      # Explicit git+ prefix strips the scheme prefix
      String.starts_with?(id, "git+") ->
        {:ok, Git, String.slice(id, 4, String.length(id))}

      # SSH git URL
      String.starts_with?(id, "git@") ->
        {:ok, Git, id}

      # GitHub shorthand  gh:owner/repo
      String.starts_with?(id, "gh:") ->
        {:ok, Github, String.slice(id, 3, String.length(id))}

      # HTTPS/HTTP URL — treat as git clone target
      String.starts_with?(id, "https://") or String.starts_with?(id, "http://") ->
        {:ok, Git, id}

      # Absolute filesystem path
      String.starts_with?(id, "/") ->
        {:ok, Local, Path.expand(id)}

      # Relative path
      String.starts_with?(id, "./") or String.starts_with?(id, "../") ->
        {:ok, Local, Path.expand(id)}

      # Registry ref: at least three slash-separated segments of lowercase
      # alphanumeric + hyphens/underscores, e.g. "official/devops/k8s-rollout"
      registry_ref?(id) ->
        {:ok, Registry, id}

      true ->
        {:error, "Cannot resolve skill identifier: #{inspect(id)}"}
    end
  end

  @doc """
  Return the `source_kind` atom for a given source module.

  Used to populate `LemonSkills.Entry.source_kind` after routing.
  """
  @spec source_kind(module()) :: LemonSkills.Entry.source_kind()
  def source_kind(Builtin), do: :builtin
  def source_kind(Local), do: :local
  def source_kind(Git), do: :git
  def source_kind(Github), do: :git
  def source_kind(Registry), do: :registry

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # A registry ref has ≥3 slash-separated segments, each matching [a-z0-9_-]+.
  defp registry_ref?(id) do
    parts = String.split(id, "/")

    length(parts) >= 3 and
      Enum.all?(parts, fn p -> String.match?(p, ~r/^[a-z0-9_-]+$/i) end)
  end
end

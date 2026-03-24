defmodule LemonSkills.Sources.Registry do
  @moduledoc """
  Source for skills from an official Lemon skill registry.

  Registry identifiers use a `<namespace>/<category>/<name>` form, e.g.
  `"official/devops/k8s-rollout"`.

  ## Trust

  The `official` namespace carries `:official` trust; all other namespaces
  default to `:community`.

  ## Registry URL

  By default the registry base is `https://skills.lemon.agent`. Override via:

      config :lemon_skills, :registry_url, "https://my-registry.example.com"
  """

  @behaviour LemonSkills.Source

  require Logger

  alias LemonSkills.{Entry, HttpClient}

  @default_registry_url "https://skills.lemon.agent"
  @user_agent "LemonAgent/1.0"

  # ---------------------------------------------------------------------------
  # Behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def search(query, opts) do
    base = registry_url(opts)
    url = "#{base}/search?q=#{URI.encode_www_form(query)}"

    case HttpClient.impl().fetch(url, [{"User-Agent", @user_agent}]) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"skills" => skills}} when is_list(skills) ->
            Enum.flat_map(skills, &registry_item_to_result(&1, base))

          _ ->
            []
        end

      {:error, reason} ->
        Logger.debug("[Sources.Registry] search failed: #{inspect(reason)}")
        []
    end
  end

  @impl true
  def inspect(ref, opts) when is_binary(ref) do
    base = registry_url(opts)
    url = "#{base}/skills/#{ref}"

    case HttpClient.impl().fetch(url, [{"User-Agent", @user_agent}]) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, info} -> {:ok, info}
          {:error, _} -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch(ref, dest_dir, opts) when is_binary(ref) do
    # Resolve to a git clone URL via the registry API, then delegate to Git.
    case resolve_clone_url(ref, opts) do
      {:ok, clone_url} ->
        LemonSkills.Sources.Git.fetch(clone_url, dest_dir, opts)

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def upstream_hash(ref, opts) when is_binary(ref) do
    case resolve_clone_url(ref, opts) do
      {:ok, clone_url} ->
        LemonSkills.Sources.Git.upstream_hash(clone_url, opts)

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def trust_level, do: :official

  @doc """
  Derive the trust level from the namespace of a registry ref.

  The `official` namespace carries `:official` trust; all other namespaces
  default to `:community`.

  ## Examples

      iex> LemonSkills.Sources.Registry.trust_for_ref("official/devops/k8s-rollout")
      :official

      iex> LemonSkills.Sources.Registry.trust_for_ref("community/tools/my-skill")
      :community
  """
  @spec trust_for_ref(String.t()) :: LemonSkills.Entry.trust_level()
  def trust_for_ref(ref) when is_binary(ref) do
    ref
    |> String.split("/")
    |> List.first("")
    |> trust_for_namespace()
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp registry_url(opts) do
    Keyword.get(opts, :registry_url) ||
      Application.get_env(:lemon_skills, :registry_url, @default_registry_url)
  end

  defp resolve_clone_url(ref, opts) do
    base = registry_url(opts)
    url = "#{base}/skills/#{ref}"

    case HttpClient.impl().fetch(url, [{"User-Agent", @user_agent}]) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"clone_url" => clone_url}} when is_binary(clone_url) ->
            {:ok, clone_url}

          {:ok, %{"url" => clone_url}} when is_binary(clone_url) ->
            {:ok, clone_url}

          _ ->
            {:error, {:no_clone_url, ref}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp trust_for_namespace("official"), do: :official
  defp trust_for_namespace(_), do: :community

  defp registry_item_to_result(item, base_url) do
    ref = item["ref"] || item["id"] || ""
    namespace = ref |> String.split("/") |> List.first() || ""
    trust = trust_for_namespace(namespace)

    skill_url = "#{base_url}/skills/#{ref}"

    manifest = %{
      "key" => String.replace(ref, "/", "-"),
      "name" => item["name"] || ref,
      "description" => item["description"] || ""
    }

    entry =
      Entry.from_manifest(manifest, skill_url,
        source: :registry,
        source_kind: :registry,
        trust_level: trust
      )

    [%{entry: entry, source: :registry, validated: false, url: skill_url}]
  end
end

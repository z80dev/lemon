defmodule LemonAutomation.Blueprint.Catalog do
  @moduledoc """
  Bounded catalog service for portable skill and automation blueprints.

  This module is the shared catalog boundary used by control-plane and Web
  clients. Callers supply only bundle IDs and profile IDs; filesystem paths are
  derived below the canonical local catalog. Every operation delegates content
  validation, redaction, digest confirmation, and create-once activation to
  `LemonAutomation.Blueprint`.
  """

  alias LemonAutomation.Blueprint

  @bundle_id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @type opts :: keyword()
  @type safe_error :: {atom(), String.t()}

  @doc "Return the canonical catalog directory for the supplied profile options."
  @spec root(opts()) :: String.t()
  def root(opts \\ []) do
    LemonCore.Paths.home_path(["bundles"], Keyword.get(opts, :profile_opts, []))
  end

  @doc "List valid, bounded catalog entries without returning paths or content."
  @spec list(opts()) :: {:ok, map()} | {:error, safe_error()}
  def list(opts \\ []) when is_list(opts), do: root(opts) |> Blueprint.list()

  @doc "Inspect one safe catalog bundle ID without returning paths or content."
  @spec inspect(String.t(), opts()) :: {:ok, map()} | {:error, safe_error()}
  def inspect(bundle_id, opts \\ []) when is_list(opts) do
    with {:ok, path} <- bundle_path(bundle_id, opts),
         {:ok, payload} <- Blueprint.inspect(path),
         :ok <- require_matching_id(payload, bundle_id) do
      {:ok, payload}
    end
  end

  @doc "Validate and audit one safe catalog bundle ID without mutation."
  @spec validate(String.t(), opts()) :: {:ok, map()} | {:error, safe_error()}
  def validate(bundle_id, opts \\ []) when is_list(opts) do
    with {:ok, path} <- bundle_path(bundle_id, opts),
         {:ok, payload} <- Blueprint.validate(path),
         :ok <- require_matching_id(payload, bundle_id) do
      {:ok, payload}
    end
  end

  @doc "Preview the exact digest-bound plan for a bundle and profile."
  @spec preview(String.t(), String.t(), opts()) :: {:ok, map()} | {:error, safe_error()}
  def preview(bundle_id, profile_id, opts \\ []) when is_list(opts) do
    with {:ok, path} <- bundle_path(bundle_id, opts) do
      Blueprint.preview(path, profile_id, service_opts(opts, bundle_id))
    end
  end

  @doc "Activate a freshly previewed plan using its exact confirmation digest."
  @spec activate(String.t(), String.t(), String.t(), opts()) ::
          {:ok, map()} | {:error, safe_error()}
  def activate(bundle_id, profile_id, confirmation_digest, opts \\ []) when is_list(opts) do
    with {:ok, path} <- bundle_path(bundle_id, opts) do
      Blueprint.activate(
        path,
        profile_id,
        confirmation_digest,
        service_opts(opts, bundle_id)
      )
    end
  end

  @doc false
  @spec bundle_path(String.t(), opts()) :: {:ok, String.t()} | {:error, safe_error()}
  def bundle_path(bundle_id, opts \\ [])

  def bundle_path(bundle_id, opts) when is_binary(bundle_id) and is_list(opts) do
    catalog_root = Path.expand(root(opts))
    candidate = Path.expand(bundle_id, catalog_root)

    with true <-
           Regex.match?(@bundle_id_regex, bundle_id) ||
             safe_error(:invalid_bundle_id, "Bundle ID is invalid"),
         true <-
           Path.dirname(candidate) == catalog_root ||
             safe_error(:invalid_bundle_id, "Bundle ID is invalid"),
         :ok <- require_directory(catalog_root, :invalid_catalog),
         :ok <- require_directory(candidate, :bundle_not_found) do
      {:ok, candidate}
    end
  end

  def bundle_path(_, _), do: safe_error(:invalid_bundle_id, "Bundle ID is required")

  defp service_opts(opts, bundle_id) do
    opts
    |> Keyword.drop([:catalog_root])
    |> Keyword.put(:expected_bundle_id, bundle_id)
  end

  defp require_matching_id(%{"id" => bundle_id}, bundle_id), do: :ok

  defp require_matching_id(_, _),
    do: safe_error(:bundle_id_mismatch, "Catalog bundle ID does not match its manifest")

  defp require_directory(path, missing_code) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        safe_error(:symlink_not_allowed, "Bundle catalog paths cannot be symlinks")

      _ ->
        safe_error(missing_code, "Bundle catalog entry is unavailable")
    end
  end

  defp safe_error(code, message), do: {:error, {code, message}}
end

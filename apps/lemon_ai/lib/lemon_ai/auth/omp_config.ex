defmodule LemonAi.Auth.OmpConfig do
  @moduledoc """
  Read-only view of omp's config root and the bearer-token files its auth
  broker and auth gateway write there.

  The root follows omp's `getConfigRootDir()`: `$HOME/<PI_CONFIG_DIR or .omp>`,
  plus `profiles/<name>` when `OMP_PROFILE` (else `PI_PROFILE`) selects a
  non-default profile. `omp auth-broker token` / `serve` create
  `auth-broker.token`; `omp auth-gateway token` / `serve` create
  `auth-gateway.token`. Lemon never creates, rotates or rewrites these files.
  """

  @token_files %{broker: "auth-broker.token", gateway: "auth-gateway.token"}
  @max_token_bytes 4_096
  @profile_name ~r/^[a-z0-9][a-z0-9._-]{0,63}$/

  @doc "omp's config root for the current environment."
  @spec config_root() :: String.t()
  def config_root do
    home = System.get_env("HOME") || System.user_home!()

    dir =
      case System.get_env("PI_CONFIG_DIR") do
        value when is_binary(value) and value != "" -> value
        _ -> ".omp"
      end

    # omp joins the directory name under the home directory, even when absolute.
    root = Path.join(home, dir)

    case profile() do
      nil -> root
      profile -> Path.join([root, "profiles", profile])
    end
  end

  @doc "Path of the broker or gateway bearer-token file."
  @spec token_path(:broker | :gateway) :: String.t()
  def token_path(kind) when is_map_key(@token_files, kind),
    do: Path.join(config_root(), Map.fetch!(@token_files, kind))

  @doc """
  The trimmed bearer token omp stored for its broker or gateway, or `nil` when
  the file is absent, empty, oversized or not a regular file.
  """
  @spec read_token(:broker | :gateway) :: String.t() | nil
  def read_token(kind) do
    path = token_path(kind)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_token_bytes <-
           File.stat(path),
         {:ok, raw} <- File.read(path),
         token when token != "" <- String.trim(raw),
         true <- String.valid?(token) and not String.contains?(token, ["\n", "\r", " "]) do
      token
    else
      _ -> nil
    end
  end

  # `OMP_PROFILE` wins even when explicitly empty (the default profile); the
  # `PI_PROFILE` compatibility name applies only when it is unset. Invalid
  # names, which omp itself rejects, select the default root.
  defp profile do
    raw =
      case System.get_env("OMP_PROFILE") do
        nil -> System.get_env("PI_PROFILE")
        value -> value
      end

    case raw && String.trim(raw) do
      nil -> nil
      "" -> nil
      "default" -> nil
      name -> if valid_profile?(name), do: name
    end
  end

  defp valid_profile?(name) do
    Regex.match?(@profile_name, name) and name not in [".", ".."] and
      not String.ends_with?(name, ".")
  end
end

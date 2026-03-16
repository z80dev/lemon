defmodule LemonCore.Update.Version do
  @moduledoc """
  CalVer version parsing and comparison for Lemon.

  Version format: `YYYY.MM.PATCH`

  Examples: `2026.03.0`, `2026.03.1`, `2026.04.0`

  The patch counter resets to 0 on each new month and increments for
  hotfixes and out-of-cycle releases.
  """

  @calver_regex ~r/^(\d{4})\.(\d{1,2})\.(\d+)(-[a-zA-Z0-9._-]+)?$/

  @type parsed :: {integer(), integer(), integer()}

  @doc """
  Returns the current Lemon version string, read from the OTP application spec.
  Falls back to the umbrella mix.exs version when running from source.
  """
  @spec current() :: String.t()
  def current do
    case Application.spec(:lemon_core, :vsn) do
      nil -> "0.1.0"
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Parses a version string into `{year, month, patch}` tuple.

  Returns `{:ok, {year, month, patch}}` or `:error`.
  """
  @spec parse(String.t()) :: {:ok, parsed()} | :error
  def parse(str) when is_binary(str) do
    case Regex.run(@calver_regex, String.trim(str), capture: :all_but_first) do
      [year, month, patch | _] ->
        {:ok, {String.to_integer(year), String.to_integer(month), String.to_integer(patch)}}

      _ ->
        :error
    end
  end

  def parse(_), do: :error

  @doc """
  Compares two CalVer strings.

  Returns `:lt`, `:eq`, or `:gt`.
  Falls back to string comparison if either version cannot be parsed.
  """
  @spec compare(String.t(), String.t()) :: :lt | :eq | :gt
  def compare(v1, v2) when is_binary(v1) and is_binary(v2) do
    with {:ok, t1} <- parse(v1),
         {:ok, t2} <- parse(v2) do
      cond do
        t1 < t2 -> :lt
        t1 > t2 -> :gt
        true -> :eq
      end
    else
      _ ->
        cond do
          v1 < v2 -> :lt
          v1 > v2 -> :gt
          true -> :eq
        end
    end
  end

  @doc """
  Returns `true` when `candidate` is strictly newer than `current`.
  """
  @spec newer?(String.t(), String.t()) :: boolean()
  def newer?(current, candidate), do: compare(current, candidate) == :lt

  @doc """
  Returns `true` when the version string matches CalVer format.
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(str), do: match?({:ok, _}, parse(str))
end

defmodule LemonAi.Providers.KimiCodeUsage do
  @moduledoc """
  Kimi Code subscription quota from `GET {base_url}/v1/usages`.

  Authenticates with a Kimi Code OAuth access token as a bearer plus the Kimi
  CLI fingerprint (`LemonAi.Auth.KimiCodeOAuth.request_headers/0`), as omp's
  usage probe does. An access token whose JWT `exp` has passed is not sent
  (`{:error, :token_expired}`). Errors carry only an atom or an HTTP status,
  never the token or response body.

  The response carries a `usages` map (`limit_5h`, `limit_month_total`,
  `limit_month_code`, each with `used_ratio` and `reset_time`) and a `limits`
  list of `{window: {duration, timeUnit}, detail: {limit, used, remaining,
  resetTime}}`. `usages` entries win; `limits` fill windows `usages` lacks.

  Options: `:base_url` (default `https://api.kimi.com/coding`), `:timeout_ms`
  (default 5000, applied to connect and receive), `:req_options`, `:now_ms`.
  """

  alias LemonAi.Auth.{KimiCodeOAuth, OAuthFlow}

  @default_base_url "https://api.kimi.com/coding"
  @default_timeout_ms 5_000

  @named_windows [
    {"limit_5h", "5h", "5h window"},
    {"limit_month_total", "month", "month"},
    {"limit_month_code", "month_code", "month (coding)"}
  ]

  @type window :: %{
          id: String.t(),
          label: String.t(),
          used_fraction: float(),
          resets_at: DateTime.t() | nil
        }

  @doc "Fetch the current quota windows for a Kimi Code access token."
  @spec fetch(String.t(), keyword()) :: {:ok, [window()]} | {:error, term()}
  def fetch(access_token, opts \\ [])

  def fetch(access_token, opts) when is_binary(access_token) and access_token != "" do
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

    if token_expired?(access_token, now_ms) do
      {:error, :token_expired}
    else
      url =
        (Keyword.get(opts, :base_url) || @default_base_url)
        |> String.trim_trailing("/")
        |> Kernel.<>("/v1/usages")

      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

      req_options =
        Keyword.merge(
          [receive_timeout: timeout_ms, connect_options: [timeout: timeout_ms]],
          Keyword.get(opts, :req_options, [])
        )

      headers = [{"authorization", "Bearer " <> access_token} | KimiCodeOAuth.request_headers()]

      case OAuthFlow.request(url, [method: :get, headers: headers], req_options: req_options) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          case parse(body) do
            [] -> {:error, :invalid_usage_response}
            windows -> {:ok, windows}
          end

        {:ok, %{status: 200}} ->
          {:error, :invalid_usage_response}

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, {:transport_error, reason}} ->
          {:error, {:transport_error, reason}}
      end
    end
  end

  def fetch(_access_token, _opts), do: {:error, :missing_access_token}

  @doc """
  Parse a usages response into windows ordered 5h, month, month (coding), then
  other limits. Unknown or malformed entries are skipped.
  """
  @spec parse(map()) :: [window()]
  def parse(body) when is_map(body) do
    named = named_windows(body["usages"])
    seen = MapSet.new(named, & &1.id)

    limits =
      body["limits"]
      |> limit_windows()
      |> Enum.reject(&MapSet.member?(seen, &1.id))
      |> Enum.uniq_by(& &1.id)

    named ++ limits
  end

  def parse(_), do: []

  @doc "One-line summary, e.g. `5h window: 76% used, resets 04:34Z; month: 57% used`."
  @spec format([window()]) :: String.t()
  def format(windows) do
    Enum.map_join(windows, "; ", fn window ->
      percent = round(window.used_fraction * 100)
      "#{window.label}: #{percent}% used" <> reset_suffix(window)
    end)
  end

  # Only the short window shows its reset; month resets are rarely actionable.
  defp reset_suffix(%{id: "5h", resets_at: %DateTime{} = at}),
    do: ", resets " <> Calendar.strftime(at, "%H:%MZ")

  defp reset_suffix(_), do: ""

  defp named_windows(usages) when is_map(usages) do
    for {key, id, label} <- @named_windows,
        %{} = entry <- [usages[key]],
        fraction when is_float(fraction) <- [ratio(entry["used_ratio"])] do
      %{id: id, label: label, used_fraction: fraction, resets_at: timestamp(entry["reset_time"])}
    end
  end

  defp named_windows(_), do: []

  defp limit_windows(limits) when is_list(limits) do
    for %{} = item <- limits,
        %{} = detail <- [item["detail"] || item],
        fraction when is_float(fraction) <- [limit_fraction(detail)],
        {id, label} <- [window_id(item["window"])] do
      %{
        id: id,
        label: label,
        used_fraction: fraction,
        resets_at: timestamp(detail["resetTime"] || detail["reset_time"])
      }
    end
  end

  defp limit_windows(_), do: []

  defp limit_fraction(detail) do
    limit = number(detail["limit"])
    used = number(detail["used"])
    remaining = number(detail["remaining"])

    used =
      if is_nil(used) and is_number(limit) and is_number(remaining),
        do: limit - remaining,
        else: used

    if is_number(limit) and limit > 0 and is_number(used), do: clamp(used / limit)
  end

  defp window_id(%{"duration" => duration, "timeUnit" => unit}) when is_binary(unit) do
    minutes =
      case {number(duration), String.upcase(unit)} do
        {nil, _} -> nil
        {n, u} -> unit_minutes(u, n)
      end

    cond do
      is_nil(minutes) or minutes <= 0 -> {"window", "usage window"}
      rem(trunc(minutes), 24 * 60) == 0 -> label("#{div(trunc(minutes), 24 * 60)}d")
      rem(trunc(minutes), 60) == 0 -> label("#{div(trunc(minutes), 60)}h")
      true -> label("#{trunc(minutes)}m")
    end
  end

  defp window_id(_), do: {"window", "usage window"}

  defp label(id), do: {id, "#{id} window"}

  defp unit_minutes(unit, n) do
    cond do
      String.contains?(unit, "MINUTE") -> n
      String.contains?(unit, "HOUR") -> n * 60
      String.contains?(unit, "DAY") -> n * 24 * 60
      true -> nil
    end
  end

  defp ratio(value) do
    case number(value) do
      nil -> nil
      n -> clamp(n / 1)
    end
  end

  defp clamp(fraction), do: fraction |> max(0.0) |> min(1.0) |> Kernel.*(1.0)

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil

  defp token_expired?(token, now_ms) do
    case OAuthFlow.jwt_claims(token) do
      %{"exp" => exp} when is_number(exp) -> exp * 1000 <= now_ms
      _ -> false
    end
  end
end

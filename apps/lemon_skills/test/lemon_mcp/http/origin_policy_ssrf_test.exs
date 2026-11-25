defmodule LemonMCP.HTTP.OriginPolicySsrfTest do
  use ExUnit.Case, async: true

  alias LemonMCP.HTTP.OriginPolicy

  defp approved(origin), do: %{allowed_origins: [origin], approved_private_origins: [origin]}

  test "metadata aliases, IPv4-mapped and 6to4 targets are rejected even when approved private" do
    for {url, origin} <- [
          {"http://169.254.169.254/mcp", "http://169.254.169.254"},
          {"http://[::ffff:169.254.169.254]/mcp", "http://[::ffff:169.254.169.254]"},
          {"http://[2002:a9fe:a9fe::]/mcp", "http://[2002:a9fe:a9fe::]"},
          {"http://[fd00:ec2::254]/mcp", "http://[fd00:ec2::254]"}
        ] do
      assert {:error, _} = OriginPolicy.pin(url, approved(origin)), url
    end
  end

  test "decimal and hex IPv4 hosts never pin as public destinations" do
    for {url, origin} <- [
          {"http://2852039166/mcp", "http://2852039166"},
          {"http://0xa9fea9fe/mcp", "http://0xa9fea9fe"}
        ] do
      assert {:error, _} =
               OriginPolicy.pin(url, %{allowed_origins: [origin]},
                 resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end
               ),
             url
    end
  end
end

defmodule LemonSkills.Context.URLFetcherSsrfTest do
  use ExUnit.Case, async: true

  alias LemonSkills.Context.URLFetcher

  test "metadata aliases, IPv4-mapped and 6to4 targets are rejected" do
    for url <- [
          "http://2852039166/",
          "http://0xA9FEA9FE/",
          "http://[::ffff:169.254.169.254]/",
          "http://[64:ff9b::a9fe:a9fe]/",
          "http://[2002:a9fe:a9fe::]/",
          "http://[2002:7f00:0001::]/"
        ] do
      assert {:error, :ssrf_blocked} = URLFetcher.fetch(url, timeout_ms: 500), url
    end
  end

  test "a 6to4 answer among public ones blocks the host" do
    assert {:error, :ssrf_blocked} =
             URLFetcher.fetch("https://rebind.example/",
               timeout_ms: 500,
               resolve_fun: fn _ ->
                 {:ok, [{93, 184, 216, 34}, {0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 1}]}
               end
             )
  end
end

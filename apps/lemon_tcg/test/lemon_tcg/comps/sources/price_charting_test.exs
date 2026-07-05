defmodule LemonTcg.Comps.Sources.PriceChartingTest do
  use ExUnit.Case, async: true

  alias LemonTcg.Comps.Comp
  alias LemonTcg.Comps.Sources.PriceCharting

  # Token comes from app env; set a test-local value and restore after.
  setup do
    previous = Application.get_env(:lemon_tcg, :pricecharting_api_token)
    Application.put_env(:lemon_tcg, :pricecharting_api_token, "test-token")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:lemon_tcg, :pricecharting_api_token)
        value -> Application.put_env(:lemon_tcg, :pricecharting_api_token, value)
      end
    end)

    :ok
  end

  defp req_opts(fun), do: [req_options: [plug: fun, retry: false]]

  test "parses pennies into grade buckets in USD" do
    plug = fn conn ->
      params = URI.decode_query(conn.query_string)
      assert params["t"] == "test-token"
      assert params["q"] == "charizard base set psa 10"

      Req.Test.json(conn, %{
        "status" => "success",
        "id" => 12_345,
        "product-name" => "Charizard #4",
        "console-name" => "Pokemon Base Set",
        "loose-price" => 25_000,
        "graded-price" => 60_000,
        "manual-only-price" => 425_000,
        "bgs-10-price" => 0,
        "box-only-price" => nil
      })
    end

    assert {:ok, %Comp{} = comp} =
             PriceCharting.comp("charizard base set psa 10", req_opts(plug))

    assert comp.prices == %{
             "ungraded" => 250.0,
             "grade_9" => 600.0,
             "psa_10" => 4250.0
           }

    assert comp.name == "Charizard #4"
    assert comp.set == "Pokemon Base Set"
    assert comp.source == "pricecharting"
  end

  test "product with no usable prices is an error" do
    plug = fn conn ->
      Req.Test.json(conn, %{"status" => "success", "id" => 1, "loose-price" => 0})
    end

    assert {:error, {:no_comp_prices, _}} = PriceCharting.comp("empty card", req_opts(plug))
  end

  test "api-level failure statuses surface the message" do
    plug = fn conn ->
      Req.Test.json(conn, %{"status" => "error", "error-message" => "No products found"})
    end

    assert {:error, {:comp_not_found, "ghost card", "No products found"}} =
             PriceCharting.comp("ghost card", req_opts(plug))
  end

  test "missing token is a clean error" do
    Application.delete_env(:lemon_tcg, :pricecharting_api_token)
    System.get_env("PRICECHARTING_API_TOKEN") && flunk("env token set in test environment")

    assert {:error, :missing_pricecharting_api_token} = PriceCharting.comp("anything", [])
  end
end

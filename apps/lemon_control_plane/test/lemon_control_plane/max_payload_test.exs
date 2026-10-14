defmodule LemonControlPlane.MaxPayloadTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.{ImageInputs, Protocol.Frames}

  setup do
    previous = Application.fetch_env(:lemon_control_plane, :max_payload)
    Application.delete_env(:lemon_control_plane, :max_payload)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:lemon_control_plane, :max_payload, value)
        :error -> Application.delete_env(:lemon_control_plane, :max_payload)
      end
    end)

    :ok
  end

  test "default WebSocket parse and advertisement admit the decoded image limit" do
    png_header = <<137, "PNG", 13, 10, 26, 10>>
    data = Base.encode64(png_header <> :binary.copy(<<0>>, 10_485_760 - byte_size(png_header)))
    images = [%{"type" => "image", "mime_type" => "image/png", "data" => data}]
    request = request(%{"prompt" => "", "images" => images})
    json = Jason.encode!(request)

    assert LemonControlPlane.max_payload() == 16_777_216
    assert LemonCore.JSONPayload.default_max_bytes() == 1_048_576
    assert byte_size(json) > LemonCore.JSONPayload.default_max_bytes()
    assert byte_size(json) < LemonControlPlane.max_payload()
    assert {:ok, %{params: params}} = Frames.parse(json)

    assert {:ok, [%LemonAi.Types.ImageContent{data: ^data}]} =
             ImageInputs.validate(params["images"])

    assert advertised_limit() == LemonControlPlane.max_payload()
    assert {:error, {:max_bytes, 1_048_576}} = LemonCore.JSONPayload.validate(request)
  end

  test "an explicit lower payload limit is enforced and advertised" do
    Application.put_env(:lemon_control_plane, :max_payload, 128)

    assert LemonControlPlane.max_payload() == 128
    assert advertised_limit() == 128
    assert {:ok, _frame} = Frames.parse(Jason.encode!(request(%{})))

    assert {:error, {:max_bytes, 128}} =
             Frames.parse(Jason.encode!(request(%{"prompt" => String.duplicate("x", 129)})))
  end

  test "invalid configured limits use the WebSocket fallback" do
    for value <- [nil, 0, -1, "128"] do
      Application.put_env(:lemon_control_plane, :max_payload, value)
      assert LemonControlPlane.max_payload() == 16_777_216
      assert advertised_limit() == 16_777_216
    end
  end

  test "larger byte allowance retains shared depth and item safety" do
    deeply_nested = Enum.reduce(1..40, true, fn index, value -> %{"level-#{index}" => value} end)
    max_depth = LemonCore.JSONPayload.default_max_depth()
    default_items = LemonCore.JSONPayload.default_max_items()
    execution_items = LemonCore.ToolPolicy.execution_max_items()

    assert {:error, {:max_depth, ^max_depth}} =
             Frames.parse(Jason.encode!(request(deeply_nested)))

    assert {:error, {:max_items, ^default_items}} =
             Frames.parse(
               Jason.encode!(
                 request(%{"items" => List.duplicate(nil, default_items + 1)}, "sessions.list")
               )
             )

    assert {:error, {:max_items, ^execution_items}} =
             Frames.parse(
               Jason.encode!(request(%{"items" => List.duplicate(nil, execution_items + 1)}))
             )

    assert {:error, {:max_bytes, 16_777_216}} =
             Frames.parse(
               Jason.encode!(request(%{"prompt" => String.duplicate("x", 16_777_216)}))
             )
  end

  defp request(params, method \\ "chat.send"),
    do: %{"type" => "req", "id" => "image-request", "method" => method, "params" => params}

  defp advertised_limit do
    Frames.encode_hello_ok([]) |> Jason.decode!() |> get_in(["policy", "maxPayload"])
  end
end

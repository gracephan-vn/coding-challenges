defmodule RideDispatch.Rides.RequestTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Rides.Request

  defp request do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 10, "longitude" => 106},
      "destination" => %{"latitude" => -90, "longitude" => 180}
    }
  end

  test "canonical identity preserves precision and equates integer and float coordinates" do
    assert {:ok, canonical} = Request.normalize(request())

    assert canonical == %{
             passengerId: "P001",
             pickup: %{latitude: 10.0, longitude: 106.0},
             destination: %{latitude: -90.0, longitude: 180.0}
           }

    assert Request.normalize(put_in(request(), ["pickup", "latitude"], 10.0)) === {:ok, canonical}

    assert {:ok, precise} =
             Request.normalize(put_in(request(), ["pickup", "latitude"], 10.000000001))

    assert precise.pickup.latitude === 10.000000001

    for value <- [-90, 90, 0, -0.0],
        do: assert({:ok, _} = Request.normalize(put_in(request(), ["pickup", "latitude"], value)))
  end

  test "rejects missing, unsupported and malformed fields at every level" do
    invalid = [
      nil,
      [],
      true,
      %{},
      Map.delete(request(), "passengerId"),
      Map.put(request(), "extra", 1),
      Map.put(request(), "passengerId", ""),
      Map.put(request(), "passengerId", 1),
      Map.put(request(), "pickup", []),
      put_in(request(), ["pickup", "extra"], 1)
    ]

    for body <- invalid, do: assert(Request.normalize(body) == {:error, :invalid_request})

    for field <- ["pickup", "destination"],
        coordinate <- ["latitude", "longitude"],
        value <- [nil, "10", true, [], %{}, 181, -181] do
      assert Request.normalize(put_in(request(), [field, coordinate], value)) ==
               {:error, :invalid_request}
    end

    for field <- ["pickup", "destination"] do
      assert Request.normalize(Map.delete(request(), field)) == {:error, :invalid_request}

      for coordinate <- ["latitude", "longitude"] do
        assert Request.normalize(Map.update!(request(), field, &Map.delete(&1, coordinate))) ==
                 {:error, :invalid_request}
      end
    end
  end

  test "keys are opaque nonblank strings including the challenge example" do
    for key <- ["7f4d9c2e-ride-request-001", "Key", " key "], do: assert(Request.valid_key?(key))
    for key <- [nil, "", " \t", [], 1], do: refute(Request.valid_key?(key))
  end
end

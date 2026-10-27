defmodule RideDispatch.DemoTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Demo
  alias RideDispatch.Dispatch.{Matcher, StateServer, Store}

  test "only explicit development opt-in supplies Drivers" do
    for env <- [:dev, :test, :prod], value <- [nil, "false"] do
      assert Demo.drivers(env, value) == []
    end

    for env <- [:test, :prod] do
      assert_raise ArgumentError, fn -> Demo.drivers(env, "true") end
    end

    for value <- ["1", "TRUE", "", "yes"] do
      assert_raise ArgumentError, fn -> Demo.drivers(:dev, value) end
    end
  end

  test "validated deterministic seeds restart cleanly and support A to B rematching" do
    drivers = Demo.drivers(:dev, "true")
    assert Enum.map(drivers, & &1.id) == ["D001", "D002", "D003"]
    assert Enum.all?(drivers, &(RideDispatch.Location.valid?(&1) and &1.status == :available))
    pickup = %{latitude: 10.7769, longitude: 106.7009}
    assert {:ok, %{id: "D001"}} = Matcher.nearest(pickup, drivers)
    assert {:ok, %{id: "D002"}} = Matcher.nearest(pickup, drivers, excluded_driver_ids: ["D001"])
    assert :none = Matcher.nearest(pickup, drivers, excluded_driver_ids: ["D001", "D002"])

    for _restart <- 1..2 do
      id = make_ref()

      server =
        start_supervised!(
          Supervisor.child_spec({StateServer, passengers: [%{id: "P001"}], drivers: drivers},
            id: id
          )
        )

      assert Store.list_available_drivers(server) == drivers
      assert Store.list_offers(server) == []
      assert Store.list_events(server) == []

      body = %{
        "passengerId" => "P001",
        "pickup" => %{"latitude" => pickup.latitude, "longitude" => pickup.longitude},
        "destination" => %{"latitude" => 10.78, "longitude" => 106.71}
      }

      assert {:ok, ride} = Store.create_ride(server, "demo", body)
      [created] = Store.list_events(server)
      assert {:ok, :processed} = Store.process_event(server, created.eventId)
      assert {:ok, :processed} = Store.process_event(server, "dispatch-" <> ride.id)

      assert {:ok, %{assignedDriverId: "D001", currentOfferId: offer_id}} =
               Store.get_ride(server, ride.id)

      assert {:ok, _} = Store.reject_offer(server, ride.id, "D001")
      assert {:ok, :processed} = Store.process_event(server, "redispatch-" <> offer_id)
      assert {:ok, %{assignedDriverId: "D002"}} = Store.get_ride(server, ride.id)
      assert {:ok, _} = Store.accept_offer(server, ride.id, "D002")
      assert {:ok, %{status: :completed}} = Store.complete_ride(server, ride.id)
      assert {:ok, %{status: :available}} = Store.get_driver(server, "D002")
      stop_supervised!(id)
    end
  end
end

defmodule RideDispatch.Rides.StateMachineTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Rides.StateMachine

  @states [:requested, :matching, :driver_assigned, :driver_accepted, :cancelled, :completed]

  for {action, source, target} <- [
        {:start_matching, :requested, :matching},
        {:create_offer, :matching, :driver_assigned},
        {:accept_offer, :driver_assigned, :driver_accepted},
        {:reject_offer, :driver_assigned, :matching},
        {:expire_offer, :driver_assigned, :matching},
        {:complete_ride, :driver_accepted, :completed}
      ] do
    test "#{action} permits only #{source} -> #{target}, preserving other fields" do
      original = ride(unquote(source))

      assert StateMachine.transition(original, unquote(action)) ==
               {:ok, %{original | status: unquote(target)}}

      assert original == ride(unquote(source))

      for invalid_source <- @states -- [unquote(source)] do
        assert StateMachine.transition(ride(invalid_source), unquote(action)) ==
                 {:error, :invalid_transition}
      end
    end
  end

  defp ride(status) do
    %{
      id: "R001",
      passengerId: "P001",
      status: status,
      assignedDriverId:
        if(status in [:driver_assigned, :driver_accepted, :completed], do: "D001", else: nil),
      pickup: %{latitude: 10.7769, longitude: 106.7009},
      destination: %{latitude: 10.8231, longitude: 106.6297},
      metadata: %{label: "preserved"}
    }
  end
end

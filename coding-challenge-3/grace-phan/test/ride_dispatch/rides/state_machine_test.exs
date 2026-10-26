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

  for source <- [:requested, :matching, :driver_assigned, :driver_accepted] do
    test "cancel_ride permits #{source} -> cancelled, preserving other fields" do
      original = ride(unquote(source))

      assert StateMachine.transition(original, :cancel_ride) ==
               {:ok, %{original | status: :cancelled}}
    end
  end

  test "cancelled and completed are terminal for all supported actions" do
    for status <- [:cancelled, :completed],
        action <- [
          :start_matching,
          :create_offer,
          :accept_offer,
          :reject_offer,
          :expire_offer,
          :complete_ride,
          :cancel_ride
        ] do
      assert StateMachine.transition(ride(status), action) == {:error, :invalid_transition}
    end
  end

  test "repeating an applied command is rejected without changing the result" do
    for {source, action} <- [
          {:requested, :start_matching},
          {:matching, :create_offer},
          {:driver_assigned, :accept_offer},
          {:driver_assigned, :reject_offer},
          {:driver_assigned, :expire_offer},
          {:driver_accepted, :complete_ride},
          {:requested, :cancel_ride},
          {:matching, :cancel_ride},
          {:driver_assigned, :cancel_ride},
          {:driver_accepted, :cancel_ride}
        ] do
      original = ride(source)
      assert {:ok, transitioned} = StateMachine.transition(original, action)
      snapshot = transitioned
      assert StateMachine.transition(transitioned, action) == {:error, :invalid_transition}
      assert transitioned == snapshot
      assert original == ride(source)
    end
  end

  test "missing or unknown current states return invalid_state" do
    for invalid <- [
          nil,
          [],
          :requested,
          %{},
          %{status: nil},
          %{status: :unknown},
          %{status: "REQUESTED"},
          %{status: 1}
        ],
        action <- [:start_matching, :cancel_ride, :unknown] do
      assert StateMachine.transition(invalid, action) == {:error, :invalid_state}
    end
  end

  test "unsupported actions are rejected in every known state" do
    for status <- @states,
        action <- [:unknown, nil, :driver_assigned, "cancel_ride", {:set_status, :completed}] do
      assert StateMachine.transition(ride(status), action) == {:error, :invalid_transition}
    end
  end

  test "state-only transitions need no offer details and are deterministic" do
    assert StateMachine.transition(%{status: :driver_assigned}, :accept_offer) ==
             {:ok, %{status: :driver_accepted}}

    original = %{status: :driver_assigned, assignedDriverId: "D001", expiresAt: :not_checked}
    expected = %{original | status: :matching}
    assert StateMachine.transition(original, :expire_offer) == {:ok, expected}
    assert StateMachine.transition(original, :expire_offer) == {:ok, expected}
    assert expected.assignedDriverId == "D001"
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

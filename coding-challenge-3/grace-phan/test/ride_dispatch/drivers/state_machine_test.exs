defmodule RideDispatch.Drivers.StateMachineTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Drivers.StateMachine

  test "enables an offline driver while preserving unrelated fields" do
    original = driver(:offline)

    assert StateMachine.transition(original, :enable_availability) ==
             {:ok, %{original | status: :available}}

    assert original.status == :offline
  end

  test "disables an available driver" do
    original = driver(:available)

    assert StateMachine.transition(original, :disable_availability) ==
             {:ok, %{original | status: :offline}}
  end

  test "repeated availability requests are successful no-ops" do
    for {status, action} <- [available: :enable_availability, offline: :disable_availability] do
      original = driver(status)
      assert StateMachine.transition(original, action) == {:ok, original}
    end
  end

  test "availability actions cannot release offered or busy drivers" do
    for status <- [:offered, :busy], action <- [:enable_availability, :disable_availability] do
      assert StateMachine.transition(driver(status), action) == {:error, :invalid_transition}
    end
  end

  test "status assignment is not a supported business action" do
    assert StateMachine.transition(driver(:offline), :available) == {:error, :invalid_transition}
    assert StateMachine.transition(driver(:available), :offline) == {:error, :invalid_transition}
  end

  for {action, source, target} <- [
        {:reserve_for_offer, :available, :offered},
        {:accept_offer, :offered, :busy},
        {:reject_offer, :offered, :available},
        {:expire_offer, :offered, :available},
        {:cancel_offer, :offered, :available},
        {:complete_ride, :busy, :available},
        {:cancel_accepted_ride, :busy, :available}
      ] do
    test "#{action} permits only #{source} -> #{target}, preserving other fields" do
      original = driver(unquote(source))

      assert StateMachine.transition(original, unquote(action)) ==
               {:ok, %{original | status: unquote(target)}}

      for invalid_source <- [:offline, :available, :offered, :busy] -- [unquote(source)] do
        assert StateMachine.transition(driver(invalid_source), unquote(action)) ==
                 {:error, :invalid_transition}
      end
    end
  end

  test "missing, unknown, and malformed current states return invalid_state" do
    for invalid <- [
          nil,
          [],
          :available,
          %{},
          %{status: nil},
          %{status: :unknown},
          %{status: "AVAILABLE"},
          %{status: 1}
        ],
        action <- [:enable_availability, :accept_offer, :unknown] do
      assert StateMachine.transition(invalid, action) == {:error, :invalid_state}
    end
  end

  test "unsupported actions return invalid_transition for every valid state" do
    for status <- [:offline, :available, :offered, :busy],
        action <- [:unknown, nil, "enable_availability", {:set_status, :available}] do
      assert StateMachine.transition(driver(status), action) == {:error, :invalid_transition}
    end
  end

  test "only state is examined; offer and driver record validation belong to Store" do
    assert StateMachine.transition(%{status: :offered}, :accept_offer) == {:ok, %{status: :busy}}
    original = %{status: :busy, latitude: :not_validated, offer_id: "unverified"}

    assert StateMachine.transition(original, :cancel_accepted_ride) ==
             {:ok, %{original | status: :available}}
  end

  defp driver(status) do
    %{
      id: "D001",
      status: status,
      latitude: 10.7769,
      longitude: 106.7009,
      label: "preserved",
      metadata: %{vehicle: "car"}
    }
  end
end

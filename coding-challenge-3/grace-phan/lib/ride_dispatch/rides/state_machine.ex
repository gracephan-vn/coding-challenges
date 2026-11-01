defmodule RideDispatch.Rides.StateMachine do
  @moduledoc """
  Pure state-only Ride transitions for AC-06, using lowercase status atoms.

  Actions are `:start_matching`, `:create_offer`, `:accept_offer`, `:reject_offer`,
  `:expire_offer`, `:complete_ride`, and `:cancel_ride`. Cancelled and completed
  states are terminal. Only the returned map's `:status` changes.

  Duplicate-command policy is a design choice: an action repeated after its
  transition returns `{:error, :invalid_transition}` when its source state no
  longer applies, preserving the input. This function has no command history
  and cannot identify stale duplicates when a later state permits the action.

  No Driver, Offer, or stored Ride is changed. Offer identity, ownership,
  deadlines, matching, reservation, and idempotency belong to atomic Store
  commands implemented by StateServer. Those commands persist transitions, clear
  `assignedDriverId` on rejection/timeout, and coordinate Driver release.
  This function intentionally preserves assignment fields even on rejection.
  """

  @states [:requested, :matching, :driver_assigned, :driver_accepted, :cancelled, :completed]

  @transitions %{
    {:requested, :start_matching} => :matching,
    {:matching, :create_offer} => :driver_assigned,
    {:driver_assigned, :accept_offer} => :driver_accepted,
    {:driver_assigned, :reject_offer} => :matching,
    {:driver_assigned, :expire_offer} => :matching,
    {:driver_accepted, :complete_ride} => :completed,
    {:requested, :cancel_ride} => :cancelled,
    {:matching, :cancel_ride} => :cancelled,
    {:driver_assigned, :cancel_ride} => :cancelled,
    {:driver_accepted, :cancel_ride} => :cancelled
  }

  @doc """
  Returns `{:ok, updated_ride}`, preserving all fields except `:status`.

  Unsupported actions and source/action combinations return
  `{:error, :invalid_transition}`. Malformed inputs or missing/unknown states
  return `{:error, :invalid_state}`, regardless of the action. Other Ride fields
  are not validated; a map containing a recognized `:status` is sufficient.
  """
  def transition(%{status: status} = ride, action) when status in @states do
    case Map.fetch(@transitions, {status, action}) do
      {:ok, next_status} -> {:ok, %{ride | status: next_status}}
      :error -> {:error, :invalid_transition}
    end
  end

  def transition(_ride, _action), do: {:error, :invalid_state}
end

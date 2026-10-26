defmodule RideDispatch.Rides.StateMachine do
  @transitions %{
    {:requested, :start_matching} => :matching,
    {:matching, :create_offer} => :driver_assigned,
    {:driver_assigned, :accept_offer} => :driver_accepted,
    {:driver_assigned, :reject_offer} => :matching,
    {:driver_assigned, :expire_offer} => :matching,
    {:driver_accepted, :complete_ride} => :completed
  }

  def transition(%{status: status} = ride, action) do
    case Map.fetch(@transitions, {status, action}) do
      {:ok, next_status} -> {:ok, %{ride | status: next_status}}
      :error -> {:error, :invalid_transition}
    end
  end
end

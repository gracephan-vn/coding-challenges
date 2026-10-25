defmodule RideDispatch.Drivers.StateMachine do
  @transitions %{
    {:offline, :enable_availability} => :available,
    {:available, :disable_availability} => :offline,
    {:available, :enable_availability} => :available,
    {:offline, :disable_availability} => :offline
  }

  def transition(%{status: status} = driver, action) do
    case Map.fetch(@transitions, {status, action}) do
      {:ok, next_status} -> {:ok, %{driver | status: next_status}}
      :error -> {:error, :invalid_transition}
    end
  end
end

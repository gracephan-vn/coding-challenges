defmodule RideDispatch.Drivers.StateMachine do
  @moduledoc """
  Pure, state-only Driver transitions for AC-02, AC-05, and AC-06.

  Availability actions are `:enable_availability` and `:disable_availability`.
  They apply only to offline/available drivers. As a design choice, repeating
  the already satisfied availability request succeeds without changing data;
  the challenge does not mandate this response contract.

  Internal dispatch actions are `:reserve_for_offer`, `:accept_offer`,
  `:reject_offer`, `:expire_offer`, `:cancel_offer`, `:complete_ride`, and
  `:cancel_accepted_ride`. They require their exact source state. Repeated internal
  actions that no longer fit the current state return an invalid transition.

  Actions describe intent, not caller authorization. This module does not check
  offer identity, deadlines, ride ownership, coordinates, or idempotency records,
  and it does not reserve a driver. Atomic Store commands implemented by StateServer
  enforce those checks, coordinate related records, and handle duplicate commands safely.
  """

  @transitions %{
    {:offline, :enable_availability} => :available,
    {:available, :disable_availability} => :offline,
    {:available, :enable_availability} => :available,
    {:offline, :disable_availability} => :offline,
    {:available, :reserve_for_offer} => :offered,
    {:offered, :accept_offer} => :busy,
    {:offered, :reject_offer} => :available,
    {:offered, :expire_offer} => :available,
    {:offered, :cancel_offer} => :available,
    {:busy, :complete_ride} => :available,
    {:busy, :cancel_accepted_ride} => :available
  }

  @doc """
  Returns `{:ok, updated_driver}`, preserving all fields except `:status`.

  Unsupported actions or source/action combinations return
  `{:error, :invalid_transition}`. Missing or unknown states (including malformed
  driver inputs) return `{:error, :invalid_state}`, regardless of the action.
  Internal states use atoms: `:offline`, `:available`, `:offered`, and `:busy`.
  """
  def transition(%{status: status} = driver, action)
      when status in [:offline, :available, :offered, :busy] do
    case Map.fetch(@transitions, {status, action}) do
      {:ok, next_status} -> {:ok, %{driver | status: next_status}}
      :error -> {:error, :invalid_transition}
    end
  end

  def transition(_driver, _action), do: {:error, :invalid_state}
end

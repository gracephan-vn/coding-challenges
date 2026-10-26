defmodule RideDispatch.Dispatch.Offer do
  @moduledoc """
  Offer deadline contract in owner monotonic milliseconds, within one VM lifetime.
  A passed deadline alone does not close an Offer or release its Driver.
  """

  def expired?(%{expires_at_ms: deadline}, now_ms)
      when is_integer(deadline) and is_integer(now_ms),
      do: now_ms >= deadline
end

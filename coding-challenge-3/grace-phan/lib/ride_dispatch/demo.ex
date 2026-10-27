defmodule RideDispatch.Demo do
  @moduledoc "Development-only startup seeds; all records still pass StateServer validation."

  def drivers(_environment, value) when value in [nil, "false"], do: []

  def drivers(:dev, "true") do
    [
      %{id: "D001", status: :available, latitude: 10.7769, longitude: 106.7009},
      %{id: "D002", status: :available, latitude: 10.7819, longitude: 106.7009},
      %{id: "D003", status: :available, latitude: 10.8169, longitude: 106.7009}
    ]
  end

  def drivers(_environment, _value) do
    raise ArgumentError,
          "RIDE_DISPATCH_DEMO must be unset or false; true is allowed only in MIX_ENV=dev"
  end
end

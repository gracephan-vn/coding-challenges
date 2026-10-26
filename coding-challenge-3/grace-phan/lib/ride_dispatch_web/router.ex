defmodule RideDispatchWeb.Router do
  use RideDispatchWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RideDispatchWeb do
    pipe_through :api

    put "/drivers/:id/availability", DriverController, :availability
    put "/drivers/:id/location", DriverController, :location
  end
end

defmodule RideDispatchWeb.Router do
  use RideDispatchWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RideDispatchWeb do
    pipe_through :api

    post "/rides", RideController, :create
    get "/rides/:rideId", RideController, :show
    post "/rides/:rideId/offers/:driverId/accept", RideController, :accept_offer

    put "/drivers/:id/availability", DriverController, :availability
    put "/drivers/:id/location", DriverController, :location
  end
end

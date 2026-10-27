defmodule RideDispatchWeb.Router do
  use RideDispatchWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", RideDispatchWeb do
    pipe_through :api

    post "/rides", RideController, :create
    get "/rides/:rideId", RideController, :show
    post "/rides/:rideId/cancel", RideController, :cancel
    post "/rides/:rideId/complete", RideController, :complete
    post "/rides/:rideId/offers/:driverId/accept", RideController, :accept_offer
    post "/rides/:rideId/offers/:driverId/reject", RideController, :reject_offer

    put "/drivers/:id/availability", DriverController, :availability
    put "/drivers/:id/location", DriverController, :location
  end
end

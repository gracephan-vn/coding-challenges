defmodule RideDispatch.OfferFixtures do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks
  alias RideDispatch.Dispatch.{StateServer, Store}

  def owner(opts \\ []) do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, Keyword.get(opts, :now, 0))

    options =
      Keyword.merge(
        [
          passengers: [%{id: "P"}],
          drivers: [
            %{id: "A", status: :available, latitude: 0, longitude: 0, label: "keep"},
            %{id: "B", status: :offline, latitude: 0.001, longitude: 0}
          ],
          clock: fn ->
            case :atomics.get(clock, 1) do
              -999_999 -> nil
              now -> now
            end
          end
        ],
        Keyword.drop(opts, [:now])
      )

    server = start_supervised!(Supervisor.child_spec({StateServer, options}, id: make_ref()))
    {server, clock}
  end

  def matching(server, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    event =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert {:ok, :processed} = Store.process_event(server, event.eventId)
    {ride, "dispatch-" <> ride.id}
  end

  def reserved(opts \\ []) do
    {server, clock} = owner(opts)
    {ride, event_id} = matching(server, "original")
    assert {:ok, :processed} = Store.process_event(server, event_id)
    {:ok, current} = Store.get_ride(server, ride.id)
    {:ok, offer} = Store.get_offer(server, current.currentOfferId)
    {server, ride, offer, clock}
  end

  def competing(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, _}, 1000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  def body do
    %{
      "passengerId" => "P",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end

  def listen(server) do
    parent = self()
    handler = make_ref()

    events = [
      [:ride_dispatch, :expiration, :result],
      [:ride_dispatch, :expiration, :idle],
      [:ride_dispatch, :event, :processed],
      [:ride_dispatch, :dispatcher, :idle]
    ]

    :telemetry.attach_many(
      handler,
      events,
      fn event, _, metadata, _ ->
        if metadata.server == server, do: send(parent, {List.to_tuple(event), metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defmodule CallbackOwner do
    @moduledoc false
    # Synthetic corruption fixtures only. Production StateServer has no seeded
    # runtime snapshots or mutation protocol; live workflow tests never use this.
    use GenServer
    alias RideDispatch.Dispatch.StateServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}

    def handle_call({:fixture_offer, id, record}, _, snapshot),
      do: {:reply, :ok, put_in(snapshot.offers[id], record)}

    def handle_call(message, from, snapshot), do: StateServer.handle_call(message, from, snapshot)
    def handle_continue(message, snapshot), do: StateServer.handle_continue(message, snapshot)
    def handle_cast(message, snapshot), do: StateServer.handle_cast(message, snapshot)
    def handle_info(message, snapshot), do: StateServer.handle_info(message, snapshot)
  end
end

defmodule TeslaMate.Repair do
  use GenServer

  require Logger
  import Ecto.Query

  alias TeslaMate.Log.{Drive, Position, ChargingProcess, Charge}
  alias TeslaMate.Locations.Address
  alias TeslaMate.{Repo, Locations, Log}

  # How quiet a charging process must go before it is considered abandoned. An active
  # charge writes a `charges` row every few seconds, so this cannot truncate one that is
  # still running; it only has to outlast the gap a restart leaves behind.
  @stale_after :timer.minutes(30)

  defmodule State do
    defstruct [:limit]
  end

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def trigger_run do
    GenServer.cast(__MODULE__, :repair)
  end

  @doc """
  Completes charging processes that were abandoned mid-charge.

  `Log.complete_charging_process/1` runs only from the live state machine, so a crash or
  power cut while charging leaves the row with a NULL `end_date` and no energy, battery
  levels or cost — permanently, because nothing revisits it. (Open `states` rows are
  resumed on boot; charging processes had no equivalent.)

  Everything needed to finish the row survives in `charges`, so the repair is simply to
  call `complete_charging_process/1`, which recomputes from those rows exactly as it would
  have at the time.

  Two guards keep this safe:

    * a process is only closed once it has gone quiet for `:stale_after` (default 30
      minutes), so a charge still in progress is never truncated;
    * processes with no `charges` rows at all are skipped. There is nothing to rebuild
      from, and `complete_charging_process/1` would fall back to stamping `end_date` with
      the current time — turning a months-old orphan into a months-long session.
  """
  def close_orphaned_charging_processes(opts \\ []) do
    limit = Keyword.get(opts, :limit, 250)

    cutoff =
      DateTime.add(
        DateTime.utc_now(),
        -Keyword.get(opts, :stale_after, @stale_after),
        :millisecond
      )

    any_charges =
      from ch in Charge,
        where: ch.charging_process_id == parent_as(:cproc).id,
        select: 1

    recent_charges =
      from ch in Charge,
        where: ch.charging_process_id == parent_as(:cproc).id and ch.date > ^cutoff,
        select: 1

    from(c in ChargingProcess,
      as: :cproc,
      where: is_nil(c.end_date),
      where: exists(any_charges),
      where: not exists(recent_charges),
      order_by: [asc: c.start_date],
      limit: ^limit
    )
    |> Repo.all()
    |> close_orphans()
  end

  @impl true
  def init(opts) do
    {:ok, _ref} =
      opts
      |> Keyword.get_lazy(:interval, fn -> :timer.hours(1) end)
      |> :timer.send_interval(self(), :repair)

    :ok = trigger_run()

    {:ok, %State{limit: Keyword.get(opts, :limit, 5000)}}
  end

  ## Repair

  @impl true
  def handle_cast(:repair, %State{limit: limit} = state) do
    from(d in Drive,
      join: sp in assoc(d, :start_position),
      join: ep in assoc(d, :end_position),
      select: [
        :id,
        :car_id,
        :start_date,
        {:start_position, [:id, :latitude, :longitude]},
        {:end_position, [:id, :latitude, :longitude]}
      ],
      where:
        (is_nil(d.start_address_id) or is_nil(d.end_address_id)) and
          (not is_nil(d.start_position_id) and not is_nil(d.end_position_id)),
      order_by: [desc: :id],
      preload: [start_position: sp, end_position: ep],
      limit: ^limit
    )
    |> Repo.all()
    |> repair()

    from(c in ChargingProcess,
      join: p in assoc(c, :position),
      select: [:id, :car_id, :start_date, {:position, [:id, :latitude, :longitude]}],
      where: is_nil(c.address_id) and not is_nil(c.position_id),
      order_by: [desc: :id],
      preload: [position: p],
      limit: ^limit
    )
    |> Repo.all()
    |> repair()

    close_orphaned_charging_processes(limit: limit)

    {:noreply, state}
  end

  @impl true
  def handle_info(:repair, state) do
    :ok = trigger_run()
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("Unexpected message: #{inspect(msg, pretty: true)}")
    {:noreply, state}
  end

  # Private

  defp close_orphans([]), do: :ok

  defp close_orphans([%ChargingProcess{} = cproc | rest]) do
    Logger.info("Completing abandoned charging process ##{cproc.id} ...")

    case Log.complete_charging_process(cproc) do
      {:ok, _cproc} -> Logger.info("OK")
      {:error, reason} -> Logger.warning("Failure: #{inspect(reason, pretty: true)}")
    end

    close_orphans(rest)
  end

  defp repair([]), do: :ok

  defp repair([entity | rest]) do
    case entity do
      %Drive{} = drive ->
        Logger.info("Repairing drive ##{drive.id} ...")

        drive
        |> Drive.changeset(%{
          start_address_id: get_address_id(drive.start_position),
          end_address_id: get_address_id(drive.end_position)
        })
        |> Repo.update()

      %ChargingProcess{} = charge ->
        Logger.info("Repairing charging process ##{charge.id} ...")

        charge
        |> ChargingProcess.changeset(%{address_id: get_address_id(charge.position)})
        |> Repo.update()
    end
    |> case do
      {:error, reason} -> Logger.warning("Failure: #{inspect(reason, pretty: true)}")
      {:ok, _entity} -> Logger.info("OK")
    end

    repair(rest)
  end

  defp get_address_id(nil), do: nil

  defp get_address_id(%Position{} = position) do
    case :fuse.ask(:addr_fuse, :sync) do
      :ok ->
        Process.sleep(1500)

        case Locations.find_address(position) do
          {:error, {:geocoding_failed, reason}} ->
            Logger.warning("Geocoding failed: #{reason}")
            nil

          {:error, reason} ->
            :fuse.melt(:addr_fuse)
            Logger.warning("Address not found: #{inspect(reason)}")
            nil

          {:ok, %Address{display_name: _name, id: id}} ->
            id
        end

      :blown ->
        nil

      {:error, :not_found} ->
        Logger.debug("Installing circuit-breaker :addr_fuse ...")

        :fuse.install(
          :addr_fuse,
          {{:standard, 5, :timer.minutes(3)}, {:reset, :timer.minutes(15)}}
        )

        get_address_id(position)
    end
  end
end

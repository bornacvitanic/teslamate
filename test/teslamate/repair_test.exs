defmodule TeslaMate.RepairTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.Log.{Car, ChargingProcess, Charge}
  alias TeslaMate.{Log, Repair, Repo}

  @pos %{date: DateTime.utc_now(), latitude: 0.0, longitude: 0.0}

  defp car_fixture do
    id = :rand.uniform(65_536)
    {:ok, car} = Log.create_car(%{eid: id, vid: id, vin: "vin_#{id}", model: "M3"})
    car
  end

  # Starts a charging process and inserts `n` samples ending `ago_minutes` in the past,
  # then reopens it — mimicking a charge interrupted by a power cut, where
  # complete_charging_process/1 never ran.
  defp abandoned_charge(car, opts) do
    ago = Keyword.get(opts, :ago_minutes, 120)
    n = Keyword.get(opts, :samples, 6)

    {:ok, cproc} = Log.start_charging_process(car, @pos)

    last = DateTime.add(DateTime.utc_now(), -ago * 60, :second)

    for i <- 0..(n - 1) do
      {:ok, %Charge{}} =
        Log.insert_charge(cproc, %{
          date: DateTime.add(last, -(n - 1 - i) * 300, :second),
          charge_energy_added: i * 1.0,
          charger_power: 11,
          charger_phases: nil,
          charger_actual_current: 0,
          charger_voltage: 1,
          battery_level: 50 + i,
          ideal_battery_range_km: 200 + i,
          rated_battery_range_km: 200 + i
        })
    end

    cproc
  end

  describe "close_orphaned_charging_processes/1" do
    test "completes a charge abandoned mid-session" do
      car = car_fixture()
      cproc = abandoned_charge(car, ago_minutes: 120, samples: 6)

      assert %ChargingProcess{end_date: nil, charge_energy_added: nil} =
               Repo.get!(ChargingProcess, cproc.id)

      :ok = Repair.close_orphaned_charging_processes()

      assert %ChargingProcess{} = done = Repo.get!(ChargingProcess, cproc.id)
      assert done.end_date != nil
      # 6 samples, charge_energy_added 0.0 -> 5.0
      assert Decimal.eq?(done.charge_energy_added, Decimal.new("5.0"))
      assert done.start_battery_level == 50
      assert done.end_battery_level == 55
      assert done.duration_min == 25
    end

    test "leaves a charge that is still running alone" do
      car = car_fixture()
      # last sample one minute ago — this charge is live
      cproc = abandoned_charge(car, ago_minutes: 1, samples: 6)

      :ok = Repair.close_orphaned_charging_processes()

      assert %ChargingProcess{end_date: nil, charge_energy_added: nil} =
               Repo.get!(ChargingProcess, cproc.id)
    end

    test "respects a custom staleness threshold" do
      car = car_fixture()
      cproc = abandoned_charge(car, ago_minutes: 45, samples: 6)

      # 45 minutes quiet is not stale enough at a 2 hour threshold
      :ok = Repair.close_orphaned_charging_processes(stale_after: :timer.hours(2))
      assert %ChargingProcess{end_date: nil} = Repo.get!(ChargingProcess, cproc.id)

      # ... but is at the default 30 minutes
      :ok = Repair.close_orphaned_charging_processes()
      assert %ChargingProcess{end_date: end_date} = Repo.get!(ChargingProcess, cproc.id)
      assert end_date != nil
    end

    test "skips a process that has no charges at all" do
      car = car_fixture()
      {:ok, cproc} = Log.start_charging_process(car, @pos)

      :ok = Repair.close_orphaned_charging_processes()

      # Nothing to rebuild from. complete_charging_process/1 would have stamped end_date
      # with the current time here, inventing a session of arbitrary length.
      assert %ChargingProcess{end_date: nil, charge_energy_added: nil} =
               Repo.get!(ChargingProcess, cproc.id)
    end

    test "is idempotent — an already completed process is not picked up again" do
      car = car_fixture()
      cproc = abandoned_charge(car, ago_minutes: 120, samples: 6)

      :ok = Repair.close_orphaned_charging_processes()

      # Plant a value the repair would overwrite: re-running it would recompute
      # duration_min from the charges (25), so surviving proves the row was skipped.
      {:ok, _} =
        ChargingProcess
        |> Repo.get!(cproc.id)
        |> Ecto.Changeset.change(duration_min: 999)
        |> Repo.update()

      :ok = Repair.close_orphaned_charging_processes()

      assert %ChargingProcess{duration_min: 999} = Repo.get!(ChargingProcess, cproc.id)
    end

    test "closes several abandoned processes and honours the limit" do
      car = car_fixture()
      for _ <- 1..3, do: abandoned_charge(car, ago_minutes: 120, samples: 4)

      :ok = Repair.close_orphaned_charging_processes(limit: 2)
      assert open_count(car) == 1

      :ok = Repair.close_orphaned_charging_processes()
      assert open_count(car) == 0
    end
  end

  defp open_count(%Car{id: id}) do
    import Ecto.Query

    Repo.one(
      from c in ChargingProcess,
        where: c.car_id == ^id and is_nil(c.end_date),
        select: count()
    )
  end
end

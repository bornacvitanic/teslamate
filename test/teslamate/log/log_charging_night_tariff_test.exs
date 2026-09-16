defmodule TeslaMate.LogChargingNightTariffTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.Log.{ChargingProcess, Charge}
  alias TeslaMate.Locations.GeoFence
  alias TeslaMate.{Log, Locations}

  @pos_attrs %{date: DateTime.utc_now(), latitude: 50.112198, longitude: 11.597669}

  # Nine samples 30 minutes apart, 19:00 -> 23:00 UTC at a constant 10 kW.
  #
  # Energy is integrated from the gap to the *previous* sample, so the first row
  # contributes nothing and each of the remaining eight contributes 5 kWh — 40 kWh
  # used in total, against 36 kWh added to the battery.
  #
  # With a 20:00-06:00 UTC night window only the 19:30 sample lands in the day
  # tariff, so the split is 35 kWh night / 5 kWh day.
  defp charges_spanning_night_boundary do
    for {time, added} <- [
          {"19:00:00.000", 0.0},
          {"19:30:00.000", 4.5},
          {"20:00:00.000", 9.0},
          {"20:30:00.000", 13.5},
          {"21:00:00.000", 18.0},
          {"21:30:00.000", 22.5},
          {"22:00:00.000", 27.0},
          {"22:30:00.000", 31.5},
          {"23:00:00.000", 36.0}
        ] do
      {"2024-01-15 " <> time, added, 10, 250, nil, 0, 1, "<invalid>"}
    end
  end

  defp car_fixture do
    id = :rand.uniform(1024)

    {:ok, car} =
      Log.create_car(%{eid: id, vid: id, vin: "vin_#{id}", model: "M3"})

    car
  end

  defp geofence_fixture(attrs) do
    {:ok, geofence} =
      attrs
      |> Enum.into(%{name: "home", latitude: 50.1121, longitude: 11.597, radius: 50})
      |> Locations.create_geofence()

    geofence
  end

  defp log_charging_process(charges, car) do
    {:ok, cproc} = Log.start_charging_process(car, @pos_attrs)

    for {date, added, power, range, phases, current, voltage, fc_type} <- charges do
      {:ok, %Charge{}} =
        Log.insert_charge(cproc, %{
          date: date,
          charge_energy_added: added,
          charger_power: power,
          ideal_battery_range_km: range,
          charger_phases: phases,
          charger_actual_current: current,
          charger_voltage: voltage,
          fast_charger_type: fc_type
        })
    end

    {:ok, %ChargingProcess{}} = Log.complete_charging_process(cproc)
  end

  describe "two-tariff charge costs" do
    test "splits energy across the night window and bills each part at its own rate" do
      car = car_fixture()

      assert %GeoFence{} =
               geofence_fixture(%{
                 billing_type: :per_kwh,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10,
                 night_start_utc: 20,
                 night_end_utc: 6
               })

      assert {:ok, cproc} = log_charging_process(charges_spanning_night_boundary(), car)

      assert Decimal.eq?(cproc.charge_energy_added, Decimal.new("36.0"))
      assert Decimal.eq?(cproc.charge_energy_used, Decimal.new("40.0"))

      # 35 kWh * 0.10 + 5 kWh * 0.20
      assert Decimal.eq?(cproc.cost, Decimal.new("4.50"))
    end

    test "adds the session fee on top of the split" do
      car = car_fixture()

      assert %GeoFence{} =
               geofence_fixture(%{
                 billing_type: :per_kwh,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10,
                 night_start_utc: 20,
                 night_end_utc: 6,
                 session_fee: 1.25
               })

      assert {:ok, cproc} = log_charging_process(charges_spanning_night_boundary(), car)

      assert Decimal.eq?(cproc.cost, Decimal.new("5.75"))
    end

    test "bills everything at the night rate when the window covers the whole session" do
      car = car_fixture()

      assert %GeoFence{} =
               geofence_fixture(%{
                 billing_type: :per_kwh,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10,
                 night_start_utc: 18,
                 night_end_utc: 6
               })

      assert {:ok, cproc} = log_charging_process(charges_spanning_night_boundary(), car)

      # 40 kWh * 0.10
      assert Decimal.eq?(cproc.cost, Decimal.new("4.00"))
    end

    test "falls back to the flat rate when no night rate is set" do
      car = car_fixture()

      assert %GeoFence{} =
               geofence_fixture(%{billing_type: :per_kwh, cost_per_unit: 0.20})

      assert {:ok, cproc} = log_charging_process(charges_spanning_night_boundary(), car)

      # 40 kWh * 0.20 — unchanged single-tariff behaviour
      assert Decimal.eq?(cproc.cost, Decimal.new("8.00"))
    end
  end

  describe "geofence night tariff validation" do
    test "accepts a night rate alongside a day rate" do
      assert {:ok, %GeoFence{} = geofence} =
               Locations.create_geofence(%{
                 name: "home",
                 latitude: 50.1,
                 longitude: 11.5,
                 radius: 50,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10
               })

      assert Decimal.eq?(geofence.cost_per_unit_night, Decimal.new("0.10"))
      assert geofence.night_start_utc == 20
      assert geofence.night_end_utc == 6
    end

    test "rejects a night rate without a day rate" do
      assert {:error, changeset} =
               Locations.create_geofence(%{
                 name: "home",
                 latitude: 50.1,
                 longitude: 11.5,
                 radius: 50,
                 cost_per_unit_night: 0.10
               })

      assert %{cost_per_unit: ["is required when a night rate is set"]} = errors_on(changeset)
    end

    test "rejects a night rate for per-minute billing" do
      assert {:error, changeset} =
               Locations.create_geofence(%{
                 name: "home",
                 latitude: 50.1,
                 longitude: 11.5,
                 radius: 50,
                 billing_type: :per_minute,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10
               })

      assert %{cost_per_unit_night: ["is only available for per kWh billing"]} =
               errors_on(changeset)
    end

    test "rejects an empty night window" do
      assert {:error, changeset} =
               Locations.create_geofence(%{
                 name: "home",
                 latitude: 50.1,
                 longitude: 11.5,
                 radius: 50,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10,
                 night_start_utc: 22,
                 night_end_utc: 22
               })

      assert %{night_end_utc: ["must differ from the night start hour"]} = errors_on(changeset)
    end

    test "rejects hours outside 0-23" do
      assert {:error, changeset} =
               Locations.create_geofence(%{
                 name: "home",
                 latitude: 50.1,
                 longitude: 11.5,
                 radius: 50,
                 cost_per_unit: 0.20,
                 cost_per_unit_night: 0.10,
                 night_start_utc: 24
               })

      assert %{night_start_utc: _} = errors_on(changeset)
    end

    test "leaves a plain single-rate geofence untouched" do
      assert {:ok, %GeoFence{} = geofence} =
               Locations.create_geofence(%{
                 name: "public charger",
                 latitude: 50.1,
                 longitude: 11.5,
                 radius: 50,
                 cost_per_unit: 0.49
               })

      assert geofence.cost_per_unit_night == nil
    end
  end
end

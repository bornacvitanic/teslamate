defmodule TeslaMateWeb.CarLive.Summary do
  use TeslaMateWeb, :live_view

  use Gettext, backend: TeslaMateWeb.Gettext

  import Ecto.Query

  alias TeslaMate.Vehicles.Vehicle.Summary
  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Log.{Drive, ChargingProcess}
  alias TeslaMate.{Vehicles, Convert, Repo}
  alias TeslaMateWeb.Widgets.Weather

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  # Where to evaluate "today" when the client timezone is unknown.
  # Fallback only — we use the browser-reported tz when available.
  @fallback_tz "Europe/Zagreb"
  @widget_refresh_ms :timer.minutes(5)
  @weather_refresh_ms :timer.hours(3)
  @weather_retry_ms :timer.minutes(15)

  @impl true
  def mount(_params, %{"summary" => %Summary{car: car} = summary} = session, socket) do
    tz =
      if connected?(socket) do
        get_connect_params(socket)["tz"] || @fallback_tz
      else
        @fallback_tz
      end

    if connected?(socket) do
      send(self(), :update_duration)
      send(self(), {:status, Vehicle.busy?(car.id)})
      send(self(), :refresh_widget_data)

      :ok = Vehicles.subscribe_to_summary(car.id)
      :ok = Vehicles.subscribe_to_fetch(car.id)
    end

    assigns = %{
      car: car,
      summary: summary,
      fetch_status: Vehicle.busy?(car.id),
      fetch_start: 0,
      fetch_timer: nil,
      settings: session["settings"],
      translate_state: &translate_state/1,
      duration: humanize_duration(summary.since),
      error: nil,
      error_timeout: nil,
      loading: false,
      tz: tz,
      widget: nil,
      weather: :loading
    }

    socket = assign(socket, assigns)

    # Always kick off a fetch when connected. If coords are nil at this point
    # (common for offline cars), Weather.forecast returns :error and we'll
    # retry once a fresh Summary with coords arrives.
    socket =
      if connected?(socket) do
        start_weather_fetch(socket, summary.latitude, summary.longitude)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("suspend_logging", _val, socket) do
    cancel_timer(socket.assigns.error_timeout)
    send(self(), :suspend_logging)
    {:noreply, assign(socket, loading: true)}
  end

  def handle_event("resume_logging", _val, socket) do
    send(self(), :resume_logging)
    {:noreply, assign(socket, loading: true)}
  end

  @impl true
  def handle_info(:update_duration, socket) do
    Process.send_after(self(), :update_duration, :timer.seconds(1))
    {:noreply, assign(socket, duration: humanize_duration(socket.assigns.summary.since))}
  end

  def handle_info(:resume_logging, socket) do
    :ok = Vehicles.resume_logging(socket.assigns.car.id)
    {:noreply, socket}
  end

  def handle_info(:suspend_logging, socket) do
    assigns =
      case Vehicles.suspend_logging(socket.assigns.car.id) do
        :ok ->
          %{error: nil, error_timeout: nil, loading: false}

        {:error, reason} ->
          %{
            error: error_to_str(reason),
            error_timeout: Process.send_after(self(), :hide_error, 5_000),
            loading: false
          }
      end

    {:noreply, assign(socket, assigns)}
  end

  def handle_info(:hide_error, socket) do
    {:noreply, assign(socket, error: nil, error_timeout: nil)}
  end

  def handle_info(%Summary{since: since} = summary, socket) do
    socket =
      assign(socket, summary: summary, duration: humanize_duration(since), loading: false)

    # If weather hasn't loaded yet and we now have valid coords, kick off a fetch.
    # This covers the offline-car case where the initial Summary had no lat/lng.
    socket =
      if socket.assigns.weather in [:loading, :error] and
           is_number(summary.latitude) and is_number(summary.longitude) do
        start_weather_fetch(socket, summary.latitude, summary.longitude)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:status, true}, socket) do
    cancel_timer(socket.assigns.fetch_timer)

    assigns = %{
      fetch_status: true,
      fetch_start: System.monotonic_time(),
      fetch_timer: nil
    }

    {:noreply, assign(socket, assigns)}
  end

  # Note: this must be smaller than the @driving_interval
  @min_spinner_visibility_ms 1000

  def handle_info({:status, false}, socket) do
    fetch_duration =
      (System.monotonic_time() - socket.assigns.fetch_start) /
        System.convert_time_unit(1, :millisecond, :native)

    assigns =
      case @min_spinner_visibility_ms - fetch_duration do
        diff when 0 < diff ->
          %{fetch_timer: Process.send_after(self(), :set_status_to_false, round(diff))}

        _ ->
          %{fetch_status: false}
      end

    {:noreply, assign(socket, assigns)}
  end

  def handle_info(:set_status_to_false, socket) do
    {:noreply, assign(socket, fetch_status: false)}
  end

  def format_tpms(bar, :psi) when is_number(bar) do
    "#{Float.round(bar * 14.5038, 1)} PSI"
  end

  def format_tpms(bar, :bar) when is_number(bar) do
    "#{Float.round(bar, 1)} Bar"
  end

  def format_temp(nil, _unit), do: "—"

  def format_temp(%Decimal{} = c, unit), do: format_temp(Decimal.to_float(c), unit)

  def format_temp(c, :F) when is_number(c) do
    "#{Convert.celsius_to_fahrenheit(c, 1)} °F"
  end

  def format_temp(c, _unit) when is_number(c) do
    "#{c} °C"
  end

  def format_eur(val), do: format_money(val, 2)
  def format_eur_km(val), do: format_money(val, 3)

  defp format_money(nil, dec), do: :erlang.float_to_binary(0.0, decimals: dec)

  defp format_money(%Decimal{} = d, dec),
    do: :erlang.float_to_binary(Decimal.to_float(d), decimals: dec)

  defp format_money(n, dec) when is_integer(n),
    do: :erlang.float_to_binary(n * 1.0, decimals: dec)

  defp format_money(n, dec) when is_float(n), do: :erlang.float_to_binary(n, decimals: dec)

  def format_duration(pairs) when is_list(pairs) do
    pairs |> Enum.map(&to_string/1) |> Enum.join(", ")
  end

  def format_duration(_), do: ""

  defp translate_state(:start), do: ""
  defp translate_state(:driving), do: gettext("driving")
  defp translate_state(:charging), do: gettext("charging")
  defp translate_state(:updating), do: gettext("updating")
  defp translate_state(:suspended), do: gettext("falling asleep")
  defp translate_state(:online), do: gettext("online")
  defp translate_state(:offline), do: gettext("offline")
  defp translate_state(:asleep), do: gettext("asleep")
  defp translate_state(:unavailable), do: gettext("unavailable")

  defp error_to_str(:unlocked), do: gettext("Car is unlocked")
  defp error_to_str(:doors_open), do: gettext("Doors are open")
  defp error_to_str(:trunk_open), do: gettext("Trunk is open")
  defp error_to_str(:sentry_mode), do: gettext("Sentry mode is enabled")
  defp error_to_str(:preconditioning), do: gettext("Preconditioning")
  defp error_to_str(:dogmode), do: gettext("Dog mode is enabled")
  defp error_to_str(:user_present), do: gettext("Driver present")
  defp error_to_str(:downloading_update), do: gettext("Downloading update")
  defp error_to_str(:update_in_progress), do: gettext("Update in progress")
  defp error_to_str(:timeout), do: gettext("Timeout")
  defp error_to_str(_other), do: gettext("An error occurred")

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)

  defp humanize_duration(nil), do: nil

  defp humanize_duration(date) do
    case DateTime.utc_now() |> DateTime.diff(date, :second) do
      dur when dur < 5 -> nil
      dur when dur > 60 -> dur |> Convert.sec_to_str() |> Enum.reject(&String.ends_with?(&1, "s"))
      dur -> dur |> Convert.sec_to_str()
    end
  end

  # ---- widget data (Phase 2b-i) ---------------------------------------------

  def handle_info(:refresh_widget_data, socket) do
    Process.send_after(self(), :refresh_widget_data, @widget_refresh_ms)

    data =
      try do
        fetch_widget_data(socket.assigns.car.id, socket.assigns.tz)
      rescue
        _ -> nil
      end

    {:noreply, assign(socket, widget: data)}
  end

  def handle_info(:refresh_weather, socket) do
    lat = socket.assigns.summary.latitude
    lng = socket.assigns.summary.longitude

    socket =
      if is_number(lat) and is_number(lng) do
        start_weather_fetch(socket, lat, lng)
      else
        # Still no coords — schedule another retry and mark offline.
        Process.send_after(self(), :refresh_weather, @weather_retry_ms)
        assign(socket, weather: :error)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_async(:weather, {:ok, {:ok, days}}, socket) do
    Process.send_after(self(), :refresh_weather, @weather_refresh_ms)
    {:noreply, assign(socket, weather: {:ok, days})}
  end

  def handle_async(:weather, _other, socket) do
    Process.send_after(self(), :refresh_weather, @weather_retry_ms)
    {:noreply, assign(socket, weather: :error)}
  end

  defp start_weather_fetch(socket, lat, lng) do
    start_async(socket, :weather, fn -> Weather.forecast(lat, lng) end)
  end

  # Assumed ICE consumption for "savings vs gas" — roughly a Model Y-sized SUV.
  @ice_l_per_100km 7.5

  defp fetch_widget_data(car_id, tz) do
    {today_start_utc, now} = today_window(tz)
    month_start_utc = month_start_utc(tz)

    today_raw =
      Repo.one(
        from d in Drive,
          where: d.car_id == ^car_id and d.start_date >= ^today_start_utc,
          select: %{
            km: sum(d.distance),
            trips: count(d.id),
            duration_min: sum(d.duration_min)
          }
      )

    today = %{
      km: to_int(today_raw && today_raw.km),
      trips: (today_raw && today_raw.trips) || 0,
      duration_min: to_int(today_raw && today_raw.duration_min)
    }

    last_drive =
      Repo.one(
        from d in Drive,
          where: d.car_id == ^car_id and not is_nil(d.end_date),
          order_by: [desc: d.start_date],
          limit: 1,
          preload: [:start_geofence, :end_geofence, :start_address, :end_address]
      )

    last_drive_at =
      Repo.one(from d in Drive, where: d.car_id == ^car_id, select: max(d.start_date))

    last_charge_at =
      Repo.one(
        from c in ChargingProcess, where: c.car_id == ^car_id, select: max(c.start_date)
      )

    # Monthly charging cost & kWh added
    month_charge =
      Repo.one(
        from c in ChargingProcess,
          where:
            c.car_id == ^car_id and c.start_date >= ^month_start_utc and not is_nil(c.cost),
          select: %{
            cost: coalesce(sum(c.cost), 0),
            kwh: coalesce(sum(c.charge_energy_added), 0),
            sessions: count(c.id)
          }
      )

    # km driven this month
    month_km =
      Repo.one(
        from d in Drive,
          where: d.car_id == ^car_id and d.start_date >= ^month_start_utc,
          select: coalesce(sum(d.distance), 0.0)
      )

    # Lifetime ICE-equivalent cost using actual fuel prices per drive
    ice_cost_lifetime =
      Repo.one(
        from d in Drive,
          join: dfp in "drive_fuel_price",
          on: dfp.drive_id == d.id and dfp.fuel_type == "eurosuper_95",
          where: d.car_id == ^car_id,
          select: coalesce(sum(d.distance * ^(@ice_l_per_100km / 100.0) * dfp.fuel_price_eur_l), 0)
      )

    # Lifetime charging cost
    ev_cost_lifetime =
      Repo.one(
        from c in ChargingProcess,
          where: c.car_id == ^car_id and not is_nil(c.cost),
          select: coalesce(sum(c.cost), 0)
      )

    # Manual payments (not car-scoped in their table, used lifetime)
    manual_cost =
      Repo.one(from m in "manual_payments", select: coalesce(sum(m.amount_paid), 0))

    savings = to_float(ice_cost_lifetime) - to_float(ev_cost_lifetime) - to_float(manual_cost)

    month_cost_eur = to_float(month_charge.cost)
    month_km_f = to_float(month_km)

    cost_per_km_month =
      if month_km_f > 0, do: month_cost_eur / month_km_f, else: nil

    # Current mounted tire set (if tyre_mounts table has an open mount)
    tire_info = fetch_tire_info(car_id)

    # Battery health: avg end-range-at-100% for first 10 vs last 10 charges
    battery_health = fetch_battery_health(car_id)

    # Efficiency: last drive's Wh/km vs lifetime average (using cars.efficiency)
    efficiency = fetch_efficiency(car_id, last_drive)

    %{
      today: today,
      last_drive: last_drive,
      days_since_drive: days_since(last_drive_at, now),
      days_since_charge: days_since(last_charge_at, now),
      last_drive_at: last_drive_at,
      last_charge_at: last_charge_at,
      cost: %{
        month_eur: month_cost_eur,
        month_kwh: to_float(month_charge.kwh),
        month_sessions: month_charge.sessions || 0,
        month_km: month_km_f,
        cost_per_km: cost_per_km_month,
        savings_lifetime: savings
      },
      tire: tire_info,
      battery_health: battery_health,
      efficiency: efficiency
    }
  end

  defp fetch_tire_info(car_id) do
    Repo.one(
      from m in "tyre_mounts",
        join: s in "tyre_sets",
        on: s.id == m.tyre_set_id,
        where: m.car_id == ^car_id and is_nil(m.unmounted_at),
        order_by: [desc: m.mounted_at],
        limit: 1,
        select: %{
          label: s.label,
          type: s.type,
          mounted_at: m.mounted_at,
          odometer_at_mount: m.odometer_at_mount
        }
    )
  end

  defp fetch_battery_health(car_id) do
    first10 =
      Repo.all(
        from c in ChargingProcess,
          where:
            c.car_id == ^car_id and not is_nil(c.end_rated_range_km) and
              not is_nil(c.end_battery_level) and c.end_battery_level >= 20,
          order_by: [asc: c.start_date],
          limit: 10,
          select: type(c.end_rated_range_km, :float) / c.end_battery_level * 100.0
      )

    last10 =
      Repo.all(
        from c in ChargingProcess,
          where:
            c.car_id == ^car_id and not is_nil(c.end_rated_range_km) and
              not is_nil(c.end_battery_level) and c.end_battery_level >= 20,
          order_by: [desc: c.start_date],
          limit: 10,
          select: type(c.end_rated_range_km, :float) / c.end_battery_level * 100.0
      )

    if length(first10) >= 3 and length(last10) >= 3 do
      original = Enum.sum(first10) / length(first10)
      current = Enum.sum(last10) / length(last10)

      if original > 0 and current > 0 do
        %{original_km: original, current_km: current, health_pct: current / original * 100.0}
      else
        nil
      end
    else
      nil
    end
  end

  defp fetch_efficiency(car_id, last_drive) do
    car_efficiency =
      Repo.one(
        from c in TeslaMate.Log.Car, where: c.id == ^car_id, select: c.efficiency
      )

    case car_efficiency do
      nil ->
        nil

      _ ->
        eff_f = to_float(car_efficiency)

        lifetime =
          Repo.one(
            from d in Drive,
              where:
                d.car_id == ^car_id and not is_nil(d.distance) and d.distance > 0.5 and
                  not is_nil(d.start_rated_range_km) and not is_nil(d.end_rated_range_km),
              select: %{
                range_delta: coalesce(sum(d.start_rated_range_km - d.end_rated_range_km), 0),
                km: coalesce(sum(d.distance), 0.0)
              }
          )

        km = to_float(lifetime.km)

        if km > 0 do
          lifetime_wh_km = to_float(lifetime.range_delta) / km * eff_f * 1000.0

          last_wh_km =
            case last_drive do
              %{
                distance: dist,
                start_rated_range_km: sr,
                end_rated_range_km: er
              }
              when not is_nil(dist) and dist > 0.5 and not is_nil(sr) and not is_nil(er) ->
                (to_float(sr) - to_float(er)) / dist * eff_f * 1000.0

              _ ->
                nil
            end

          %{lifetime_wh_km: lifetime_wh_km, last_wh_km: last_wh_km}
        else
          nil
        end
    end
  end

  defp month_start_utc(tz) do
    tz = if tz_valid?(tz), do: tz, else: @fallback_tz
    now_local = DateTime.now!(tz)
    %{year: y, month: m} = now_local
    DateTime.new!(Date.new!(y, m, 1), ~T[00:00:00], tz)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp to_float(nil), do: 0.0
  defp to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_float(n) when is_integer(n), do: n * 1.0
  defp to_float(n) when is_float(n), do: n

  # Coerce Ecto aggregate results (Decimal | float | integer | nil) to integer
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = d), do: d |> Decimal.round(0) |> Decimal.to_integer()
  defp to_int(n) when is_float(n), do: round(n)
  defp to_int(n) when is_integer(n), do: n

  defp today_window(tz) do
    tz = if tz_valid?(tz), do: tz, else: @fallback_tz
    now_local = DateTime.now!(tz)
    today_local = DateTime.new!(DateTime.to_date(now_local), ~T[00:00:00], tz)
    {DateTime.shift_zone!(today_local, "Etc/UTC"), DateTime.utc_now()}
  end

  defp tz_valid?(tz) when is_binary(tz) do
    case DateTime.now(tz) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp tz_valid?(_), do: false

  defp days_since(nil, _now), do: nil

  defp days_since(%DateTime{} = ts, now) do
    div(DateTime.diff(now, ts, :second), 86_400)
  end

  def drive_endpoint_name(drive) do
    cond do
      drive == nil -> nil
      not is_nil(drive.end_geofence) -> drive.end_geofence.name
      not is_nil(drive.end_address) -> trim_addr(drive.end_address)
      true -> nil
    end
  end

  def drive_origin_name(drive) do
    cond do
      drive == nil -> nil
      not is_nil(drive.start_geofence) -> drive.start_geofence.name
      not is_nil(drive.start_address) -> trim_addr(drive.start_address)
      true -> nil
    end
  end

  defp trim_addr(%{name: name}) when is_binary(name) and name != "", do: name
  defp trim_addr(%{city: city}) when is_binary(city) and city != "", do: city
  defp trim_addr(_), do: "—"
end

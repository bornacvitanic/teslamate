defmodule TeslaMate.Locations.GeoFence do
  use Ecto.Schema

  import Ecto.Changeset

  schema "geofences" do
    field :name, :string
    field :latitude, :decimal, read_after_writes: true
    field :longitude, :decimal, read_after_writes: true
    field :radius, :integer

    field :billing_type, Ecto.Enum, values: [:per_kwh, :per_minute], read_after_writes: true
    field :cost_per_unit, :decimal, read_after_writes: true
    field :session_fee, :decimal, read_after_writes: true

    # Optional two-tariff (day/night) pricing. When `cost_per_unit_night` is nil the
    # geofence is billed at the single flat `cost_per_unit`, exactly as before.
    # The window is expressed in UTC, matching `charges.date`.
    field :cost_per_unit_night, :decimal, read_after_writes: true
    field :night_start_utc, :integer, read_after_writes: true
    field :night_end_utc, :integer, read_after_writes: true

    # nil => the window hours are UTC (right for tariffs whose local window shifts
    # with DST, such as HEP's 21-07 winter / 22-08 summer). Set to an IANA zone to
    # pin the window to local wall-clock time instead (e.g. a Supercharger's
    # 16:00-20:00 peak), which then follows DST.
    field :night_timezone, :string

    timestamps()
  end

  @doc false
  def changeset(geofence, attrs) do
    geofence
    |> cast(attrs, [
      :name,
      :radius,
      :latitude,
      :longitude,
      :cost_per_unit,
      :session_fee,
      :billing_type,
      :cost_per_unit_night,
      :night_start_utc,
      :night_end_utc,
      :night_timezone
    ])
    |> validate_required([:name, :latitude, :longitude, :radius])
    |> validate_number(:radius, greater_than: 0, less_than: 5000)
    |> validate_number(:session_fee, greater_than_or_equal_to: 0)
    |> validate_number(:night_start_utc, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_number(:night_end_utc, greater_than_or_equal_to: 0, less_than_or_equal_to: 23)
    |> validate_night_tariff()
    |> validate_night_timezone()
    |> update_change(:name, &String.trim/1)
  end

  defp validate_night_timezone(changeset) do
    case get_field(changeset, :night_timezone) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :night_timezone, nil)

      timezone ->
        if Tzdata.zone_exists?(timezone) do
          changeset
        else
          add_error(changeset, :night_timezone, "is not a known time zone")
        end
    end
  end

  # A night rate only makes sense for per-kWh billing with a day rate to contrast it
  # with, and with a window that actually spans some hours.
  defp validate_night_tariff(changeset) do
    case get_field(changeset, :cost_per_unit_night) do
      nil ->
        changeset

      _night_rate ->
        changeset
        |> validate_per_kwh_billing()
        |> validate_day_rate_present()
        |> validate_window_not_empty()
    end
  end

  defp validate_per_kwh_billing(changeset) do
    case get_field(changeset, :billing_type) do
      :per_minute ->
        add_error(changeset, :cost_per_unit_night, "is only available for per kWh billing")

      _ ->
        changeset
    end
  end

  defp validate_day_rate_present(changeset) do
    case get_field(changeset, :cost_per_unit) do
      nil -> add_error(changeset, :cost_per_unit, "is required when a night rate is set")
      _ -> changeset
    end
  end

  defp validate_window_not_empty(changeset) do
    start_hour = get_field(changeset, :night_start_utc)
    end_hour = get_field(changeset, :night_end_utc)

    if is_integer(start_hour) and is_integer(end_hour) and start_hour == end_hour do
      add_error(changeset, :night_end_utc, "must differ from the night start hour")
    else
      changeset
    end
  end
end

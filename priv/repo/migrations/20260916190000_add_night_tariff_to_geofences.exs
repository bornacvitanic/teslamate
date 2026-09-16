defmodule TeslaMate.Repo.Migrations.AddNightTariffToGeofences do
  use Ecto.Migration

  # Optional two-tariff (day/night) pricing per geofence.
  #
  # All three columns are nullable with no default beyond the window hours, so every
  # existing geofence keeps its single flat `cost_per_unit` and its cost calculation
  # is untouched. Two-tariff pricing only kicks in once `cost_per_unit_night` is set.
  #
  # The window is stored in UTC because that is what `charges.date` holds. For the
  # Croatian HEP white tariff both seasons collapse to the same UTC window
  # (21-07 CET winter and 22-08 CEST summer are both 20:00-06:00 UTC), so no DST
  # handling is needed.

  def up do
    alter table(:geofences) do
      add :cost_per_unit_night, :decimal, precision: 6, scale: 4
      add :night_start_utc, :smallint, default: 20, null: false
      add :night_end_utc, :smallint, default: 6, null: false
    end

    create constraint(:geofences, :night_start_utc_range,
             check: "night_start_utc >= 0 AND night_start_utc <= 23"
           )

    create constraint(:geofences, :night_end_utc_range,
             check: "night_end_utc >= 0 AND night_end_utc <= 23"
           )
  end

  def down do
    drop constraint(:geofences, :night_start_utc_range)
    drop constraint(:geofences, :night_end_utc_range)

    alter table(:geofences) do
      remove :cost_per_unit_night
      remove :night_start_utc
      remove :night_end_utc
    end
  end
end

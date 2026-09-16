defmodule TeslaMate.Repo.Migrations.AddNightTimezoneToGeofences do
  use Ecto.Migration

  # Lets the night window be expressed in a local time zone instead of UTC.
  #
  # Some tariffs define their window in UTC-stable terms: the Croatian HEP household
  # tariff states 21-07 in winter and 22-08 in summer, which are the same 20:00-06:00
  # UTC window all year. Those geofences leave this NULL and keep comparing in UTC.
  #
  # Others define a window that is fixed on the local clock — Tesla Supercharger
  # peak/off-peak hours, for instance — which drifts by an hour against UTC at every
  # daylight-saving change. Setting a time zone here makes the window follow local
  # wall-clock time instead.
  #
  # NULL preserves the existing UTC behaviour, so no geofence changes meaning.

  def change do
    alter table(:geofences) do
      add :night_timezone, :string
    end
  end
end

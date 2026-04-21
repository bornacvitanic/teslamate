defmodule TeslaMateWeb.GeoFenceLive.Index do
  use TeslaMateWeb, :live_view

  import Ecto.Query

  alias TeslaMate.{Locations, Settings, Repo}
  alias TeslaMate.Locations.GeoFence
  alias TeslaMate.Log.{Drive, ChargingProcess}
  alias Settings.GlobalSettings

  alias TeslaMate.Convert

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"settings" => settings}, socket) do
    unit_of_length =
      case settings do
        %GlobalSettings{unit_of_length: :km} -> :m
        %GlobalSettings{unit_of_length: :mi} -> :ft
      end

    geofences = Locations.list_geofences()
    drive_counts = drive_count_map()
    charge_counts = charge_count_map()

    assigns = %{
      geofences: geofences,
      drive_counts: drive_counts,
      charge_counts: charge_counts,
      unit_of_length: unit_of_length,
      page_title: gettext("Geo-Fences"),
      selected_id: nil,
      geofences_json: to_map_json(geofences)
    }

    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, %{assigns: %{geofences: geofences}} = socket) do
    {:ok, deleted_geofence} =
      Locations.get_geofence!(id)
      |> Locations.delete_geofence()

    geofences = Enum.reject(geofences, &(&1.id == deleted_geofence.id))

    selected_id =
      if socket.assigns.selected_id == deleted_geofence.id,
        do: nil,
        else: socket.assigns.selected_id

    {:noreply,
     assign(socket,
       geofences: geofences,
       geofences_json: to_map_json(geofences),
       selected_id: selected_id
     )}
  end

  def handle_event("select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    new_sel = if socket.assigns.selected_id == id, do: nil, else: id
    {:noreply, assign(socket, selected_id: new_sel)}
  end

  defp drive_count_map do
    starts =
      Repo.all(
        from d in Drive,
          where: not is_nil(d.start_geofence_id),
          group_by: d.start_geofence_id,
          select: {d.start_geofence_id, count(d.id)}
      )

    ends =
      Repo.all(
        from d in Drive,
          where: not is_nil(d.end_geofence_id),
          group_by: d.end_geofence_id,
          select: {d.end_geofence_id, count(d.id)}
      )

    (starts ++ ends)
    |> Enum.reduce(%{}, fn {gid, n}, acc -> Map.update(acc, gid, n, &(&1 + n)) end)
  end

  defp charge_count_map do
    Repo.all(
      from c in ChargingProcess,
        where: not is_nil(c.geofence_id),
        group_by: c.geofence_id,
        select: {c.geofence_id, count(c.id)}
    )
    |> Map.new()
  end

  defp to_map_json(geofences) do
    geofences
    |> Enum.map(fn g ->
      %{
        id: g.id,
        name: g.name,
        lat: Decimal.to_float(g.latitude),
        lng: Decimal.to_float(g.longitude),
        radius: g.radius
      }
    end)
    |> Jason.encode!()
  end

  def format_cost(%{cost_per_unit: nil, session_fee: nil}), do: "—"

  def format_cost(%{cost_per_unit: nil, session_fee: fee}) when not is_nil(fee),
    do: "€#{fmt(fee, 2)} / session"

  def format_cost(%{billing_type: :per_kwh, cost_per_unit: c, session_fee: fee}),
    do: "€#{fmt(c, 4)} / kWh#{session_suffix(fee)}"

  def format_cost(%{billing_type: :per_minute, cost_per_unit: c, session_fee: fee}),
    do: "€#{fmt(c, 3)} / min#{session_suffix(fee)}"

  def format_cost(_), do: "—"

  defp session_suffix(nil), do: ""
  defp session_suffix(fee), do: " + €#{fmt(fee, 2)}"

  defp fmt(nil, dec), do: :erlang.float_to_binary(0.0, decimals: dec)
  defp fmt(%Decimal{} = d, dec), do: :erlang.float_to_binary(Decimal.to_float(d), decimals: dec)
  defp fmt(n, dec) when is_integer(n), do: :erlang.float_to_binary(n * 1.0, decimals: dec)
  defp fmt(n, dec) when is_float(n), do: :erlang.float_to_binary(n, decimals: dec)
end

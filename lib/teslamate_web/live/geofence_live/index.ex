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
      geofences_json: to_map_json(geofences),
      filter: "",
      sort_by: :name,
      sort_dir: :asc,
      selected_ids: MapSet.new(),
      import_open: false,
      import_error: nil
    }

    {:ok, assign(socket, assigns)}
  end

  # Presorted + filtered view, computed on demand from the base list.
  def visible_geofences(assigns) do
    assigns.geofences
    |> filter_by(assigns.filter)
    |> sort_by(assigns.sort_by, assigns.sort_dir, assigns.drive_counts, assigns.charge_counts)
  end

  defp filter_by(list, ""), do: list

  defp filter_by(list, q) do
    q = String.downcase(q)
    Enum.filter(list, &String.contains?(String.downcase(&1.name), q))
  end

  defp sort_by(list, :name, dir, _, _), do: by(list, & &1.name, dir)
  defp sort_by(list, :radius, dir, _, _), do: by(list, & &1.radius, dir)
  defp sort_by(list, :cost, dir, _, _), do: by(list, &decimal_num(&1.cost_per_unit), dir)

  defp sort_by(list, :visits, dir, dc, cc),
    do: by(list, &(Map.get(dc, &1.id, 0) + Map.get(cc, &1.id, 0)), dir)

  defp sort_by(list, _, dir, dc, cc), do: sort_by(list, :name, dir, dc, cc)

  defp by(list, key_fn, :asc), do: Enum.sort_by(list, key_fn)
  defp by(list, key_fn, :desc), do: Enum.sort_by(list, key_fn, :desc)

  defp decimal_num(nil), do: -1.0
  defp decimal_num(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_num(n) when is_number(n), do: n * 1.0

  def sort_icon(sort_by, sort_dir, col) when sort_by == col do
    if sort_dir == :asc, do: "mdi-chevron-up", else: "mdi-chevron-down"
  end

  def sort_icon(_, _, _), do: nil

  @impl true
  def handle_event("delete", %{"id" => id}, %{assigns: %{geofences: geofences}} = socket) do
    {:ok, deleted_geofence} =
      Locations.get_geofence!(id)
      |> Locations.delete_geofence()

    geofences = Enum.reject(geofences, &(&1.id == deleted_geofence.id))

    {:noreply,
     assign(socket,
       geofences: geofences,
       geofences_json: to_map_json(geofences),
       selected_id:
         if(socket.assigns.selected_id == deleted_geofence.id,
           do: nil,
           else: socket.assigns.selected_id
         ),
       selected_ids: MapSet.delete(socket.assigns.selected_ids, deleted_geofence.id)
     )}
  end

  def handle_event("select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    new_sel = if socket.assigns.selected_id == id, do: nil, else: id
    {:noreply, assign(socket, selected_id: new_sel)}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, filter: q)}
  end

  def handle_event("sort", %{"by" => by}, socket) do
    col = String.to_existing_atom(by)

    {new_by, new_dir} =
      if socket.assigns.sort_by == col do
        {col, toggle(socket.assigns.sort_dir)}
      else
        {col, :asc}
      end

    {:noreply, assign(socket, sort_by: new_by, sort_dir: new_dir)}
  end

  defp toggle(:asc), do: :desc
  defp toggle(:desc), do: :asc

  def handle_event("toggle_select", %{"id" => id}, socket) do
    id = String.to_integer(id)
    sel = socket.assigns.selected_ids

    sel =
      if MapSet.member?(sel, id), do: MapSet.delete(sel, id), else: MapSet.put(sel, id)

    {:noreply, assign(socket, selected_ids: sel)}
  end

  def handle_event("toggle_select_all", _, socket) do
    visible = visible_geofences(socket.assigns) |> Enum.map(& &1.id) |> MapSet.new()

    all_selected? = MapSet.subset?(visible, socket.assigns.selected_ids) and MapSet.size(visible) > 0

    new_sel = if all_selected?, do: MapSet.new(), else: visible
    {:noreply, assign(socket, selected_ids: new_sel)}
  end

  def handle_event("delete_selected", _, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)

    Enum.each(ids, fn id ->
      case Repo.get(GeoFence, id) do
        %GeoFence{} = g -> Locations.delete_geofence(g)
        _ -> :noop
      end
    end)

    geofences = Enum.reject(socket.assigns.geofences, &MapSet.member?(socket.assigns.selected_ids, &1.id))

    {:noreply,
     assign(socket,
       geofences: geofences,
       geofences_json: to_map_json(geofences),
       selected_ids: MapSet.new(),
       selected_id:
         if(MapSet.member?(socket.assigns.selected_ids, socket.assigns.selected_id || -1),
           do: nil,
           else: socket.assigns.selected_id
         )
     )}
  end

  def handle_event("export", _, socket) do
    payload =
      socket.assigns.geofences
      |> Enum.map(fn g ->
        %{
          name: g.name,
          latitude: Decimal.to_float(g.latitude),
          longitude: Decimal.to_float(g.longitude),
          radius: g.radius,
          billing_type: g.billing_type,
          cost_per_unit: g.cost_per_unit && Decimal.to_float(g.cost_per_unit),
          session_fee: g.session_fee && Decimal.to_float(g.session_fee)
        }
      end)
      |> Jason.encode!(pretty: true)

    {:noreply,
     push_event(socket, "download_file", %{
       filename: "geofences-#{Date.utc_today()}.json",
       content: payload,
       mime: "application/json"
     })}
  end

  def handle_event("open_import", _, socket) do
    {:noreply, assign(socket, import_open: true, import_error: nil)}
  end

  def handle_event("close_import", _, socket) do
    {:noreply, assign(socket, import_open: false, import_error: nil)}
  end

  def handle_event("import", %{"json" => json}, socket) do
    with {:ok, items} <- Jason.decode(json),
         true <- is_list(items),
         results <- Enum.map(items, &create_one/1),
         inserted <- Enum.count(results, &(&1 == :ok)),
         errors <- Enum.count(results, &(&1 == :error)) do
      geofences = Locations.list_geofences()

      msg =
        if errors > 0,
          do: "Imported #{inserted}, skipped #{errors} (duplicates or validation failures)",
          else: "Imported #{inserted} geofence(s)"

      {:noreply,
       assign(socket,
         geofences: geofences,
         geofences_json: to_map_json(geofences),
         drive_counts: drive_count_map(),
         charge_counts: charge_count_map(),
         import_open: false,
         import_error: if(inserted == 0, do: msg, else: nil)
       )
       |> put_flash(:info, msg)}
    else
      _ ->
        {:noreply,
         assign(socket, import_error: "Invalid JSON — expected an array of geofence objects.")}
    end
  end

  def handle_event("map_click", %{"lat" => lat, "lng" => lng}, socket) do
    path =
      "/geo-fences/new?" <>
        URI.encode_query(%{"lat" => to_string(lat), "lng" => to_string(lng)})

    {:noreply, push_navigate(socket, to: path)}
  end

  defp create_one(attrs) when is_map(attrs) do
    params = %{
      "name" => attrs["name"],
      "latitude" => attrs["latitude"],
      "longitude" => attrs["longitude"],
      "radius" => attrs["radius"],
      "billing_type" => attrs["billing_type"] || "per_kwh",
      "cost_per_unit" => attrs["cost_per_unit"],
      "session_fee" => attrs["session_fee"]
    }

    case Locations.create_geofence(params) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp create_one(_), do: :error

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

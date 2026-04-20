defmodule TeslaMateWeb.Widgets.Weather do
  @moduledoc """
  Open-Meteo forecast client for the summary page weather widget.
  Returns a 7-day forecast for the given lat/lng.
  Uses the TeslaMate.HTTP Finch pool, no API key required.
  """

  use Tesla, only: [:get]

  adapter(Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 10_000)

  plug(Tesla.Middleware.JSON)

  @base "https://api.open-meteo.com/v1/forecast"

  @doc """
  Fetches a 7-day forecast. Returns `{:ok, [day, ...]}` on success,
  `:error` on any failure (network, non-200, unexpected JSON).

  Each day: %{date: Date, code: integer, t_max: float, t_min: float, precip_mm: float}
  """
  def forecast(lat, lng) when is_number(lat) and is_number(lng) do
    params = [
      latitude: lat,
      longitude: lng,
      daily: "weathercode,temperature_2m_max,temperature_2m_min,precipitation_sum",
      timezone: "auto",
      forecast_days: 7
    ]

    with {:ok, %Tesla.Env{status: 200, body: body}} <- get(@base, query: params),
         {:ok, days} <- parse(body) do
      {:ok, days}
    else
      _ -> :error
    end
  end

  def forecast(_, _), do: :error

  defp parse(%{"daily" => d}) do
    dates = Enum.map(d["time"] || [], &Date.from_iso8601!/1)
    codes = d["weathercode"] || []
    hi = d["temperature_2m_max"] || []
    lo = d["temperature_2m_min"] || []
    pr = d["precipitation_sum"] || []
    n = min(length(dates), 7)

    days =
      for i <- 0..(n - 1),
          do: %{
            date: Enum.at(dates, i),
            code: Enum.at(codes, i) || 0,
            t_max: Enum.at(hi, i),
            t_min: Enum.at(lo, i),
            precip_mm: Enum.at(pr, i) || 0
          }

    if days == [], do: :error, else: {:ok, days}
  end

  defp parse(_), do: :error

  @doc """
  Maps an Open-Meteo WMO weather code to a Material Design Icon name
  and a short human label. Grouped broadly — no need for 60 distinct icons.
  """
  def icon_and_label(code) do
    cond do
      code == 0 -> {"mdi-weather-sunny", "Clear"}
      code in 1..2 -> {"mdi-weather-partly-cloudy", "Partly cloudy"}
      code == 3 -> {"mdi-weather-cloudy", "Cloudy"}
      code in 45..48 -> {"mdi-weather-fog", "Fog"}
      code in 51..57 -> {"mdi-weather-pouring", "Drizzle"}
      code in 61..67 -> {"mdi-weather-rainy", "Rain"}
      code in 71..77 -> {"mdi-weather-snowy", "Snow"}
      code in 80..82 -> {"mdi-weather-pouring", "Showers"}
      code in 85..86 -> {"mdi-weather-snowy-heavy", "Snow showers"}
      code in 95..99 -> {"mdi-weather-lightning-rainy", "Thunderstorm"}
      true -> {"mdi-weather-partly-cloudy", "—"}
    end
  end
end

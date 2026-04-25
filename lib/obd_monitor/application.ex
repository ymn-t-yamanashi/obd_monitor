defmodule ObdMonitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    obd_device = System.get_env("OBD_DEVICE", "/dev/ttyUSB0")
    obd_poll_ms = env_int("OBD_POLL_INTERVAL_MS", 200)
    dashboard_refresh_ms = env_int("DASHBOARD_REFRESH_MS", 100)

    children = [
      {ObdMonitor.Telemetry, device: obd_device, interval_ms: obd_poll_ms},
      {ObdMonitor.Dashboard, refresh_ms: dashboard_refresh_ms}
    ]

    opts = [strategy: :one_for_one, name: ObdMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp env_int(key, default) do
    key
    |> System.get_env()
    |> parse_positive_int(default)
  end

  defp parse_positive_int(nil, default), do: default
  defp parse_positive_int(value, default), do: parse_integer(Integer.parse(value), default)

  defp parse_integer({parsed, ""}, _default) when parsed > 0, do: parsed
  defp parse_integer(_parsed, default), do: default
end

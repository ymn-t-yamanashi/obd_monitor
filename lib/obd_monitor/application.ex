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
    case System.get_env(key) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end
    end
  end
end

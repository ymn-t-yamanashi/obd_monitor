defmodule ObdMonitor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    obd_device = System.get_env("OBD_DEVICE", "/dev/ttyUSB0")

    children = [
      {ObdMonitor.Telemetry, device: obd_device, interval_ms: 500},
      {ObdMonitor.Dashboard, []}
    ]

    opts = [strategy: :one_for_one, name: ObdMonitor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

defmodule ObdMonitor.Application do
  @moduledoc """
  アプリケーションのSupervisorツリーを起動するモジュールです。
  """

  use Application

  @impl true
  # TelemetryとDashboardを子プロセスとして起動する。
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

  # 環境変数を正の整数として読み取り、失敗時はデフォルト値を返す。
  defp env_int(key, default) do
    key
    |> System.get_env()
    |> parse_positive_int(default)
  end

  # 未設定時はデフォルト値を返す。
  defp parse_positive_int(nil, default), do: default
  # 設定値を整数パースして検証する。
  defp parse_positive_int(value, default), do: parse_integer(Integer.parse(value), default)

  # 正の整数なら採用する。
  defp parse_integer({parsed, ""}, _default) when parsed > 0, do: parsed
  # 不正値ならデフォルト値を返す。
  defp parse_integer(_parsed, default), do: default
end

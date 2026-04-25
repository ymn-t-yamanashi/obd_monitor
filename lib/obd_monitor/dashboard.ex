defmodule ObdMonitor.Dashboard do
  @moduledoc """
  Terminal dashboard powered by ExRatatui.
  """
  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Gauge, Paragraph}

  @default_refresh_ms 100

  @impl true
  def mount(opts) do
    refresh_ms = Keyword.get(opts, :refresh_ms, @default_refresh_ms)
    Process.send_after(self(), :refresh, refresh_ms)

    {:ok,
     %{
       refresh_ms: refresh_ms,
       rpm: nil,
       coolant_temp_c: nil,
       ignition_timing_deg: nil,
       intake_pressure_kpa: nil,
       battery_voltage_v: nil,
       status: "starting",
       last_error: nil
     }}
  end

  @impl true
  def render(state, frame) do
    rpm = state.rpm || 0
    temp = state.coolant_temp_c || 0
    rpm_ratio = clamp(rpm / 8_000)
    temp_ratio = clamp(temp / 120)

    top_height = 8
    gauge_height = 4

    rpm_text = if state.rpm, do: "#{state.rpm} rpm", else: "-- rpm"
    temp_text = if state.coolant_temp_c, do: "#{state.coolant_temp_c} C", else: "-- C"

    ignition_text =
      if state.ignition_timing_deg, do: :erlang.float_to_binary(state.ignition_timing_deg, decimals: 1), else: "--"

    intake_text = if state.intake_pressure_kpa, do: "#{state.intake_pressure_kpa} kPa", else: "-- kPa"

    battery_text =
      if state.battery_voltage_v, do: :erlang.float_to_binary(state.battery_voltage_v, decimals: 2), else: "--"

    overview =
      %Paragraph{
        text:
          "ND Roadster OBD monitor\nエンジン回転数: #{rpm_text}\n冷却水温: #{temp_text}\n点火時期進角: #{ignition_text} deg\n吸気管絶対圧: #{intake_text}\nバッテリー電圧: #{battery_text} V\n状態: #{state.status}",
        block: %Block{
          title: "リアルタイム値 (q: 終了)",
          borders: [:all]
        }
      }

    rpm_gauge =
      %Gauge{
        ratio: rpm_ratio,
        label: "#{rpm_text} / 8000",
        block: %Block{title: "エンジン回転数", borders: [:all]},
        gauge_style: %Style{fg: :green}
      }

    temp_gauge =
      %Gauge{
        ratio: temp_ratio,
        label: "#{temp_text} / 120C",
        block: %Block{title: "冷却水温", borders: [:all]},
        gauge_style: %Style{fg: :yellow}
      }

    error_text = state.last_error || "なし"

    footer =
      %Paragraph{
        text: "直近エラー: #{error_text}",
        block: %Block{title: "診断情報", borders: [:all]}
      }

    [
      {overview, %Rect{x: 0, y: 0, width: frame.width, height: min(top_height, frame.height)}},
      {rpm_gauge,
       %Rect{
         x: 0,
         y: min(top_height, frame.height),
         width: frame.width,
         height: min(gauge_height, max(frame.height - top_height, 0))
       }},
      {temp_gauge,
       %Rect{
         x: 0,
         y: min(top_height + gauge_height, frame.height),
         width: frame.width,
         height: min(gauge_height, max(frame.height - top_height - gauge_height, 0))
       }},
      {footer,
       %Rect{
         x: 0,
         y: min(top_height + gauge_height * 2, frame.height),
         width: frame.width,
         height: max(frame.height - (top_height + gauge_height * 2), 0)
       }}
    ]
  end

  @impl true
  def handle_event(%Event.Key{code: "q"}, state), do: {:stop, state}
  def handle_event(_event, state), do: {:noreply, state}

  @impl true
  def handle_info(:refresh, state) do
    snapshot = ObdMonitor.Telemetry.snapshot()
    Process.send_after(self(), :refresh, state.refresh_ms)
    {:noreply, Map.merge(state, snapshot)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp clamp(value) when value < 0, do: 0.0
  defp clamp(value) when value > 1, do: 1.0
  defp clamp(value), do: value * 1.0
end

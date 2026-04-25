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
    ignition = state.ignition_timing_deg || -64.0
    intake = state.intake_pressure_kpa || 0
    battery = state.battery_voltage_v || 0.0

    rpm_ratio = clamp(rpm / 8_000)
    temp_ratio = clamp(temp / 120)
    ignition_ratio = clamp((ignition + 64.0) / 127.5)
    intake_ratio = clamp(intake / 255)
    battery_ratio = clamp(battery / 18.0)

    top_height = 3
    gauge_height = 4

    rpm_text = if state.rpm, do: "#{state.rpm} rpm", else: "-- rpm"
    temp_text = if state.coolant_temp_c, do: "#{state.coolant_temp_c} C", else: "-- C"

    ignition_text =
      if state.ignition_timing_deg, do: :erlang.float_to_binary(state.ignition_timing_deg, decimals: 1), else: "--"

    intake_text = if state.intake_pressure_kpa, do: "#{state.intake_pressure_kpa} kPa", else: "-- kPa"

    battery_text =
      if state.battery_voltage_v, do: :erlang.float_to_binary(state.battery_voltage_v, decimals: 2), else: "--"

    status_panel =
      %Paragraph{
        text: "状態: #{state.status}  (q: 終了)",
        block: %Block{
          title: "ND Roadster OBD monitor",
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

    ignition_gauge =
      %Gauge{
        ratio: ignition_ratio,
        label: "#{ignition_text} deg / -64..63.5",
        block: %Block{title: "点火時期進角", borders: [:all]},
        gauge_style: %Style{fg: :cyan}
      }

    intake_gauge =
      %Gauge{
        ratio: intake_ratio,
        label: "#{intake_text} / 255kPa",
        block: %Block{title: "吸気管絶対圧", borders: [:all]},
        gauge_style: %Style{fg: :magenta}
      }

    battery_gauge =
      %Gauge{
        ratio: battery_ratio,
        label: "#{battery_text} V / 18.0V",
        block: %Block{title: "バッテリー電圧", borders: [:all]},
        gauge_style: %Style{fg: :blue}
      }

    error_text = state.last_error || "なし"

    footer =
      %Paragraph{
        text: "直近エラー: #{error_text}",
        block: %Block{title: "診断情報", borders: [:all]}
      }

    [
      {status_panel, %Rect{x: 0, y: 0, width: frame.width, height: min(top_height, frame.height)}},
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
      {ignition_gauge,
       %Rect{
         x: 0,
         y: min(top_height + gauge_height * 2, frame.height),
         width: frame.width,
         height: min(gauge_height, max(frame.height - top_height - gauge_height * 2, 0))
       }},
      {intake_gauge,
       %Rect{
         x: 0,
         y: min(top_height + gauge_height * 3, frame.height),
         width: frame.width,
         height: min(gauge_height, max(frame.height - top_height - gauge_height * 3, 0))
       }},
      {battery_gauge,
       %Rect{
         x: 0,
         y: min(top_height + gauge_height * 4, frame.height),
         width: frame.width,
         height: min(gauge_height, max(frame.height - top_height - gauge_height * 4, 0))
       }},
      {footer,
       %Rect{
         x: 0,
         y: min(top_height + gauge_height * 5, frame.height),
         width: frame.width,
         height: max(frame.height - (top_height + gauge_height * 5), 0)
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

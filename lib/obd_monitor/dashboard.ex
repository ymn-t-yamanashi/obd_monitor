defmodule ObdMonitor.Dashboard do
  @moduledoc """
  Terminal dashboard powered by ExRatatui.
  """
  use ExRatatui.App

  alias ExRatatui.Event
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Style
  alias ExRatatui.Widgets.{Block, Gauge, Paragraph}

  @refresh_ms 250

  @impl true
  def mount(_opts) do
    Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     %{
       rpm: nil,
       coolant_temp_c: nil,
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

    top_height = 5
    gauge_height = 4

    rpm_text = if state.rpm, do: "#{state.rpm} rpm", else: "-- rpm"
    temp_text = if state.coolant_temp_c, do: "#{state.coolant_temp_c} C", else: "-- C"

    overview =
      %Paragraph{
        text:
          "ND Roadster OBD monitor\nRPM: #{rpm_text}\nCoolant: #{temp_text}\nStatus: #{state.status}",
        block: %Block{
          title: "Live Values (q: quit)",
          borders: [:all]
        }
      }

    rpm_gauge =
      %Gauge{
        ratio: rpm_ratio,
        label: "#{rpm_text} / 8000",
        block: %Block{title: "Engine RPM", borders: [:all]},
        gauge_style: %Style{fg: :green}
      }

    temp_gauge =
      %Gauge{
        ratio: temp_ratio,
        label: "#{temp_text} / 120C",
        block: %Block{title: "Coolant Temp", borders: [:all]},
        gauge_style: %Style{fg: :yellow}
      }

    error_text = state.last_error || "none"

    footer =
      %Paragraph{
        text: "Last error: #{error_text}",
        block: %Block{title: "Diagnostics", borders: [:all]}
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
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, Map.merge(state, snapshot)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp clamp(value) when value < 0, do: 0.0
  defp clamp(value) when value > 1, do: 1.0
  defp clamp(value), do: value * 1.0
end

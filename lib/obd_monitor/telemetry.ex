defmodule ObdMonitor.Telemetry do
  @moduledoc """
  Polls OBD-II PIDs over an ELM327-compatible adapter (OBDLINK EX).
  """

  use GenServer
  require Logger

  alias Circuits.UART

  @default_speed 115_200
  @default_interval_ms 200
  @uart_read_timeout_ms 200

  defstruct uart: nil,
            device: "/dev/ttyUSB0",
            interval_ms: @default_interval_ms,
            rpm: nil,
            coolant_temp_c: nil,
            ignition_timing_deg: nil,
            intake_pressure_kpa: nil,
            status: "initializing...",
            last_error: nil

  @type snapshot :: %{
          rpm: non_neg_integer() | nil,
          coolant_temp_c: integer() | nil,
          ignition_timing_deg: float() | nil,
          intake_pressure_kpa: non_neg_integer() | nil,
          status: String.t(),
          last_error: String.t() | nil
        }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      device: Keyword.get(opts, :device, "/dev/ttyUSB0"),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, to_snapshot(state), state}
  end

  @impl true
  def handle_info(:connect, state) do
    case UART.start_link() do
      {:ok, uart} ->
        case UART.open(uart, state.device, speed: @default_speed, active: false) do
          :ok ->
            configured = initialize_adapter(uart)
            Process.send_after(self(), :poll, 50)
            {:noreply, %{state | uart: uart, status: configured}}

          {:error, reason} ->
            Logger.error("Failed to open #{state.device}: #{inspect(reason)}")
            schedule_reconnect()
            {:noreply, error_state(state, "open failed: #{inspect(reason)}")}
        end

      {:error, reason} ->
        Logger.error("Failed to start UART: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, error_state(state, "uart start failed: #{inspect(reason)}")}
    end
  end

  def handle_info(:poll, %{uart: nil} = state) do
    schedule_reconnect()
    {:noreply, error_state(state, "adapter unavailable")}
  end

  def handle_info(:poll, state) do
    started_at = System.monotonic_time(:millisecond)

    {rpm, rpm_err} = read_rpm(state.uart)
    {coolant, coolant_err} = read_coolant_temp(state.uart)
    {ignition, ignition_err} = read_ignition_timing(state.uart)
    {intake, intake_err} = read_intake_pressure(state.uart)

    {status, last_error} =
      case {rpm_err, coolant_err, ignition_err, intake_err} do
        {nil, nil, nil, nil} -> {"connected", nil}
        _ -> {"degraded", Enum.find([rpm_err, coolant_err, ignition_err, intake_err], & &1)}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    next_poll_ms = max(state.interval_ms - elapsed_ms, 0)
    Process.send_after(self(), :poll, next_poll_ms)

    {:noreply,
     %{
       state
       | rpm: rpm || state.rpm,
         coolant_temp_c: coolant || state.coolant_temp_c,
         ignition_timing_deg: ignition || state.ignition_timing_deg,
         intake_pressure_kpa: intake || state.intake_pressure_kpa,
         status: status,
         last_error: last_error
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp initialize_adapter(uart) do
    # Keep protocol auto-detect while disabling noisy formatting.
    case Enum.find(["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"], fn cmd ->
           match?({:error, _}, send_cmd(uart, cmd))
         end) do
      nil ->
        "connected"

      failed_cmd ->
        Logger.error("Adapter init failed on #{failed_cmd}")
        "init failed"
    end
  rescue
    error ->
      Logger.error("Adapter init crashed: #{Exception.message(error)}")
      "init failed"
  end

  defp read_rpm(uart) do
    with {:ok, raw} <- send_cmd(uart, "010C"),
         {:ok, a, b} <- extract_pid_bytes(raw, "0C", 2) do
      {div(a * 256 + b, 4), nil}
    else
      {:error, reason} -> {nil, "RPM: #{reason}"}
    end
  end

  defp read_coolant_temp(uart) do
    with {:ok, raw} <- send_cmd(uart, "0105"),
         {:ok, a} <- extract_pid_bytes(raw, "05", 1) do
      {a - 40, nil}
    else
      {:error, reason} -> {nil, "Coolant: #{reason}"}
    end
  end

  defp read_ignition_timing(uart) do
    with {:ok, raw} <- send_cmd(uart, "010E"),
         {:ok, a} <- extract_pid_bytes(raw, "0E", 1) do
      {a / 2 - 64, nil}
    else
      {:error, reason} -> {nil, "Ignition: #{reason}"}
    end
  end

  defp read_intake_pressure(uart) do
    with {:ok, raw} <- send_cmd(uart, "010B"),
         {:ok, a} <- extract_pid_bytes(raw, "0B", 1) do
      {a, nil}
    else
      {:error, reason} -> {nil, "Intake pressure: #{reason}"}
    end
  end

  defp send_cmd(uart, cmd) do
    :ok = UART.write(uart, cmd <> "\r")
    collect_response(uart, "")
  end

  defp collect_response(uart, acc) do
    case UART.read(uart, @uart_read_timeout_ms) do
      {:ok, data} ->
        next = acc <> data

        if String.contains?(next, ">") do
          {:ok, next}
        else
          collect_response(uart, next)
        end

      {:error, :timeout} ->
        {:error, "timeout"}

      {:error, reason} ->
        {:error, "uart error #{inspect(reason)}"}
    end
  end

  defp extract_pid_bytes(raw, pid, byte_count) do
    clean =
      raw
      |> String.upcase()
      |> String.replace(~r/[^0-9A-F]/u, "")

    parse_pid(clean, pid, byte_count)
  end

  defp parse_pid(clean, pid, 2) do
    case Regex.run(~r/41#{pid}([0-9A-F]{2})([0-9A-F]{2})/u, clean, capture: :all_but_first) do
      [a_hex, b_hex] -> {:ok, String.to_integer(a_hex, 16), String.to_integer(b_hex, 16)}
      _ -> {:error, "pid 01#{pid} parse failed (#{String.slice(clean, 0, 24)})"}
    end
  end

  defp parse_pid(clean, pid, 1) do
    case Regex.run(~r/41#{pid}([0-9A-F]{2})/u, clean, capture: :all_but_first) do
      [a_hex] -> {:ok, String.to_integer(a_hex, 16)}
      _ -> {:error, "pid 01#{pid} parse failed (#{String.slice(clean, 0, 24)})"}
    end
  end

  defp error_state(state, message) do
    %{state | status: "disconnected", last_error: message, uart: nil}
  end

  defp schedule_reconnect, do: Process.send_after(self(), :connect, 2_000)

  defp to_snapshot(state) do
    %{
      rpm: state.rpm,
      coolant_temp_c: state.coolant_temp_c,
      ignition_timing_deg: state.ignition_timing_deg,
      intake_pressure_kpa: state.intake_pressure_kpa,
      status: state.status,
      last_error: state.last_error
    }
  end
end

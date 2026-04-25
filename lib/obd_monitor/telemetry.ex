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
            battery_voltage_v: nil,
            status: "initializing...",
            last_error: nil

  @type snapshot :: %{
          rpm: non_neg_integer() | nil,
          coolant_temp_c: integer() | nil,
          ignition_timing_deg: float() | nil,
          intake_pressure_kpa: non_neg_integer() | nil,
          battery_voltage_v: float() | nil,
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
    with {:ok, uart} <- tagged_uart_start(),
         :ok <- tagged_uart_open(uart, state.device) do
      configured = initialize_adapter(uart)
      Process.send_after(self(), :poll, 50)
      {:noreply, %{state | uart: uart, status: configured}}
    else
      {:error, {:open_failed, reason}} ->
        Logger.error("Failed to open #{state.device}: #{inspect(reason)}")
        schedule_reconnect()
        {:noreply, error_state(state, "open failed: #{inspect(reason)}")}

      {:error, {:uart_start_failed, reason}} ->
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
    {battery, battery_err} = read_battery_voltage(state.uart)

    {status, last_error} =
      telemetry_health(rpm_err, coolant_err, ignition_err, intake_err, battery_err)

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
         battery_voltage_v: battery || state.battery_voltage_v,
         status: status,
         last_error: last_error
     }}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp tagged_uart_start do
    with {:ok, uart} <- UART.start_link() do
      {:ok, uart}
    else
      {:error, reason} -> {:error, {:uart_start_failed, reason}}
    end
  end

  defp tagged_uart_open(uart, device) do
    with :ok <- UART.open(uart, device, speed: @default_speed, active: false) do
      :ok
    else
      {:error, reason} -> {:error, {:open_failed, reason}}
    end
  end

  defp telemetry_health(nil, nil, nil, nil, nil), do: {"connected", nil}

  defp telemetry_health(rpm_err, coolant_err, ignition_err, intake_err, battery_err) do
    {"degraded", Enum.find([rpm_err, coolant_err, ignition_err, intake_err, battery_err], & &1)}
  end

  defp initialize_adapter(uart) do
    # Keep protocol auto-detect while disabling noisy formatting.
    ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]
    |> Enum.find(fn cmd -> match?({:error, _}, send_cmd(uart, cmd)) end)
    |> adapter_init_status()
  rescue
    error ->
      Logger.error("Adapter init crashed: #{Exception.message(error)}")
      "init failed"
  end

  defp adapter_init_status(nil), do: "connected"

  defp adapter_init_status(failed_cmd) do
    Logger.error("Adapter init failed on #{failed_cmd}")
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

  defp read_battery_voltage(uart) do
    with {:ok, raw} <- send_cmd(uart, "0142"),
         {:ok, a, b} <- extract_pid_bytes(raw, "42", 2) do
      {(a * 256 + b) / 1000, nil}
    else
      {:error, reason} -> {nil, "Battery voltage: #{reason}"}
    end
  end

  defp send_cmd(uart, cmd) do
    :ok = UART.write(uart, cmd <> "\r")
    collect_response(uart, "")
  end

  defp collect_response(uart, acc) do
    uart
    |> UART.read(@uart_read_timeout_ms)
    |> handle_uart_read(uart, acc)
  end

  defp handle_uart_read({:ok, data}, uart, acc), do: continue_or_done(uart, acc <> data)
  defp handle_uart_read({:error, :timeout}, _uart, _acc), do: {:error, "timeout"}

  defp handle_uart_read({:error, reason}, _uart, _acc),
    do: {:error, "uart error #{inspect(reason)}"}

  defp continue_or_done(uart, next) do
    next
    |> String.contains?(">")
    |> collect_or_return(uart, next)
  end

  defp collect_or_return(true, _uart, next), do: {:ok, next}
  defp collect_or_return(false, uart, next), do: collect_response(uart, next)

  defp extract_pid_bytes(raw, pid, byte_count) do
    clean =
      raw
      |> String.upcase()
      |> String.replace(~r/[^0-9A-F]/u, "")

    parse_pid(clean, pid, byte_count)
  end

  defp parse_pid(clean, pid, 2) do
    clean
    |> Regex.run(~r/41#{pid}([0-9A-F]{2})([0-9A-F]{2})/u, capture: :all_but_first)
    |> parse_two_byte_pid(clean, pid)
  end

  defp parse_pid(clean, pid, 1) do
    clean
    |> Regex.run(~r/41#{pid}([0-9A-F]{2})/u, capture: :all_but_first)
    |> parse_one_byte_pid(clean, pid)
  end

  defp parse_two_byte_pid([a_hex, b_hex], _clean, _pid) do
    {:ok, String.to_integer(a_hex, 16), String.to_integer(b_hex, 16)}
  end

  defp parse_two_byte_pid(_capture, clean, pid) do
    {:error, "pid 01#{pid} parse failed (#{String.slice(clean, 0, 24)})"}
  end

  defp parse_one_byte_pid([a_hex], _clean, _pid), do: {:ok, String.to_integer(a_hex, 16)}

  defp parse_one_byte_pid(_capture, clean, pid) do
    {:error, "pid 01#{pid} parse failed (#{String.slice(clean, 0, 24)})"}
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
      battery_voltage_v: state.battery_voltage_v,
      status: state.status,
      last_error: state.last_error
    }
  end
end

defmodule ObdMonitor.Telemetry do
  @moduledoc """
  ELM327互換アダプタからOBD-IIのPIDを定期取得するモジュールです。
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

  # Telemetryプロセスを起動する。
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # 現在のセンサー値スナップショットを返す。
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  # 初期状態を作成し、接続処理を開始する。
  def init(opts) do
    state = %__MODULE__{
      device: Keyword.get(opts, :device, "/dev/ttyUSB0"),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  # スナップショット要求に応答する。
  def handle_call(:snapshot, _from, state) do
    {:reply, to_snapshot(state), state}
  end

  @impl true
  # UART接続とアダプタ初期化を行う。
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

  # UART未接続時は再接続をスケジュールする。
  def handle_info(:poll, %{uart: nil} = state) do
    schedule_reconnect()
    {:noreply, error_state(state, "adapter unavailable")}
  end

  # 各PIDを取得して状態を更新する。
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

  # 未処理メッセージは無視する。
  def handle_info(_msg, state), do: {:noreply, state}

  # UART起動結果にエラー種別を付与する。
  defp tagged_uart_start do
    with {:ok, uart} <- UART.start_link() do
      {:ok, uart}
    else
      {:error, reason} -> {:error, {:uart_start_failed, reason}}
    end
  end

  # UARTオープン結果にエラー種別を付与する。
  defp tagged_uart_open(uart, device) do
    with :ok <- UART.open(uart, device, speed: @default_speed, active: false) do
      :ok
    else
      {:error, reason} -> {:error, {:open_failed, reason}}
    end
  end

  # 全センサー取得成功時の状態。
  defp telemetry_health(nil, nil, nil, nil, nil), do: {"connected", nil}

  # いずれか失敗時の状態。
  defp telemetry_health(rpm_err, coolant_err, ignition_err, intake_err, battery_err) do
    {"degraded", Enum.find([rpm_err, coolant_err, ignition_err, intake_err, battery_err], & &1)}
  end

  # アダプタ初期化コマンドを送信する。
  defp initialize_adapter(uart) do
    # プロトコル自動判定を維持しつつ、不要な装飾出力を無効化する。
    ["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]
    |> Enum.find(fn cmd -> match?({:error, _}, send_cmd(uart, cmd)) end)
    |> adapter_init_status()
  rescue
    error ->
      Logger.error("Adapter init crashed: #{Exception.message(error)}")
      "init failed"
  end

  # 初期化成功時の状態文字列を返す。
  defp adapter_init_status(nil), do: "connected"

  # 初期化失敗時の状態文字列を返す。
  defp adapter_init_status(failed_cmd) do
    Logger.error("Adapter init failed on #{failed_cmd}")
    "init failed"
  end

  # エンジン回転数(010C)を取得する。
  defp read_rpm(uart) do
    with {:ok, raw} <- send_cmd(uart, "010C"),
         {:ok, a, b} <- extract_pid_bytes(raw, "0C", 2) do
      {div(a * 256 + b, 4), nil}
    else
      {:error, reason} -> {nil, "RPM: #{reason}"}
    end
  end

  # 冷却水温(0105)を取得する。
  defp read_coolant_temp(uart) do
    with {:ok, raw} <- send_cmd(uart, "0105"),
         {:ok, a} <- extract_pid_bytes(raw, "05", 1) do
      {a - 40, nil}
    else
      {:error, reason} -> {nil, "Coolant: #{reason}"}
    end
  end

  # 点火時期進角(010E)を取得する。
  defp read_ignition_timing(uart) do
    with {:ok, raw} <- send_cmd(uart, "010E"),
         {:ok, a} <- extract_pid_bytes(raw, "0E", 1) do
      {a / 2 - 64, nil}
    else
      {:error, reason} -> {nil, "Ignition: #{reason}"}
    end
  end

  # 吸気管絶対圧(010B)を取得する。
  defp read_intake_pressure(uart) do
    with {:ok, raw} <- send_cmd(uart, "010B"),
         {:ok, a} <- extract_pid_bytes(raw, "0B", 1) do
      {a, nil}
    else
      {:error, reason} -> {nil, "Intake pressure: #{reason}"}
    end
  end

  # バッテリー電圧(0142)を取得する。
  defp read_battery_voltage(uart) do
    with {:ok, raw} <- send_cmd(uart, "0142"),
         {:ok, a, b} <- extract_pid_bytes(raw, "42", 2) do
      {(a * 256 + b) / 1000, nil}
    else
      {:error, reason} -> {nil, "Battery voltage: #{reason}"}
    end
  end

  # UARTへコマンドを書き込み応答を収集する。
  defp send_cmd(uart, cmd) do
    :ok = UART.write(uart, cmd <> "\r")
    collect_response(uart, "")
  end

  # 応答終端までUARTデータを読み進める。
  defp collect_response(uart, acc) do
    uart
    |> UART.read(@uart_read_timeout_ms)
    |> handle_uart_read(uart, acc)
  end

  # UART読み取り結果を分類する。
  defp handle_uart_read({:ok, data}, uart, acc), do: continue_or_done(uart, acc <> data)
  # タイムアウトをエラーとして返す。
  defp handle_uart_read({:error, :timeout}, _uart, _acc), do: {:error, "timeout"}

  # UARTエラーを文字列化して返す。
  defp handle_uart_read({:error, reason}, _uart, _acc),
    do: {:error, "uart error #{inspect(reason)}"}

  # 応答終端の有無で継続読み取りか完了を判定する。
  defp continue_or_done(uart, next) do
    next
    |> String.contains?(">")
    |> collect_or_return(uart, next)
  end

  # 応答が完了していれば結果を返す。
  defp collect_or_return(true, _uart, next), do: {:ok, next}
  # 応答が未完了なら再度読み取りを続ける。
  defp collect_or_return(false, uart, next), do: collect_response(uart, next)

  # 生の応答文字列から対象PIDのデータ部を抽出する。
  defp extract_pid_bytes(raw, pid, byte_count) do
    clean =
      raw
      |> String.upcase()
      |> String.replace(~r/[^0-9A-F]/u, "")

    parse_pid(clean, pid, byte_count)
  end

  # 2バイトPIDをパースする。
  defp parse_pid(clean, pid, 2) do
    clean
    |> Regex.run(~r/41#{pid}([0-9A-F]{2})([0-9A-F]{2})/u, capture: :all_but_first)
    |> parse_two_byte_pid(clean, pid)
  end

  # 1バイトPIDをパースする。
  defp parse_pid(clean, pid, 1) do
    clean
    |> Regex.run(~r/41#{pid}([0-9A-F]{2})/u, capture: :all_but_first)
    |> parse_one_byte_pid(clean, pid)
  end

  # 2バイトパース成功時の値を返す。
  defp parse_two_byte_pid([a_hex, b_hex], _clean, _pid) do
    {:ok, String.to_integer(a_hex, 16), String.to_integer(b_hex, 16)}
  end

  # 2バイトパース失敗時のエラーを返す。
  defp parse_two_byte_pid(_capture, clean, pid) do
    {:error, "pid 01#{pid} parse failed (#{String.slice(clean, 0, 24)})"}
  end

  # 1バイトパース成功時の値を返す。
  defp parse_one_byte_pid([a_hex], _clean, _pid), do: {:ok, String.to_integer(a_hex, 16)}

  # 1バイトパース失敗時のエラーを返す。
  defp parse_one_byte_pid(_capture, clean, pid) do
    {:error, "pid 01#{pid} parse failed (#{String.slice(clean, 0, 24)})"}
  end

  # 切断状態へ更新する。
  defp error_state(state, message) do
    %{state | status: "disconnected", last_error: message, uart: nil}
  end

  # 再接続処理を一定時間後に予約する。
  defp schedule_reconnect, do: Process.send_after(self(), :connect, 2_000)

  # 外部公開用のスナップショット形式へ変換する。
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

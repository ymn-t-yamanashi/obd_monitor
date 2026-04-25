# OBD Monitor (ND Roadster)

`OBDLINK EX USB` から OBD-II PID を読み、`ex_ratatui` で
エンジン回転数・水温・点火時期進角・吸気管絶対圧をリアルタイム表示するコンソールアプリです。

## Requirements

- Ubuntu 24.04
- OBDLINK EX USB
- `/dev/ttyUSB0` (必要なら環境変数で変更)
- `mise`

## Toolchain

`mise.toml`:

- `erlang = "27.2.1"`
- `elixir = "1.18.2-otp-27"`

## Run

```bash
cd obd_monitor
mise exec -- mix deps.get
mise exec -- mix run --no-halt
```

終了は `q` キーです。

## Device permission

`/dev/ttyUSB0` へのアクセス権がない場合:

```bash
sudo usermod -aG dialout $USER
newgrp dialout
```

## Environment variables

- `OBD_DEVICE` (default: `/dev/ttyUSB0`)
- `OBD_POLL_INTERVAL_MS` (default: `200`)
- `DASHBOARD_REFRESH_MS` (default: `100`)

例:

```bash
OBD_DEVICE=/dev/ttyUSB1 mise exec -- mix run --no-halt
```

応答をさらに速くしたい場合の例:

```bash
OBD_POLL_INTERVAL_MS=150 DASHBOARD_REFRESH_MS=80 mise exec -- mix run --no-halt
```

## OBD PIDs

- `010C`: Engine RPM
- `0105`: Coolant temperature
- `010E`: Ignition timing advance
- `010B`: Intake manifold absolute pressure

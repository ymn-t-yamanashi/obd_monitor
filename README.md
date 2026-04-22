# OBD Monitor (ND Roadster)

`OBDLINK EX USB` から OBD-II PID を読み、`ex_ratatui` で
エンジン回転数と水温をリアルタイム表示するコンソールアプリです。

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

例:

```bash
OBD_DEVICE=/dev/ttyUSB1 mise exec -- mix run --no-halt
```

## OBD PIDs

- `010C`: Engine RPM
- `0105`: Coolant temperature

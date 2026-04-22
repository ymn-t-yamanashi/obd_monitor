defmodule ObdMonitorTest do
  use ExUnit.Case
  doctest ObdMonitor

  test "greets the world" do
    assert ObdMonitor.hello() == :world
  end
end

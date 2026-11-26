# R1, minimal: one byte missing from listeners/streams.json, then a login. Under a supervisor with AtMcp.Supervisor's
# strategy (one_for_one, default intensity) holding AtMcp.Updates and AtMcp.Listeners, and a caller retrying
# Listeners.track every 2 s as AtMcp.Listen does, the supervisor shuts down within seconds: in the service, the
# application stops, for every account. Same with streams.json = "[]", or an account file whose "receipts" is null or
# whose "listeners" is [] (all JSON-valid). Prints REPRODUCED or NOT REPRODUCED.
dir = fresh_dir.("r1"); {_a, clock} = new_clock.(t0)
start_l.(dir, clock, []); :ok = Listeners.track(me, :me_fx); connect.(); stop.(Listeners); stop.(Updates)
p = Path.join([dir, "listeners", "streams.json"]); s = File.read!(p); File.write!(p, binary_part(s, 0, byte_size(s) - 1))
Process.flag(:trap_exit, true)
opts = [clock: clock, constellation: FC, repos: R, notifications: fn f, o -> N.read(f, o) end,
  profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end, recheck_ms: 3_600_000,
  notifications_poll_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"]
{:ok, sup} = Supervisor.start_link([{Updates, state_dir: dir, clock: clock}, {Listeners, opts}], strategy: :one_for_one)
spawn(fn -> for _ <- 1..4, do: (try do Listeners.track(me, :me_fx) catch :exit, _ -> :ok end; Process.sleep(2000)) end)
Process.sleep(9000)
r = receive do {:EXIT, ^sup, why} -> why after 0 -> :still_running end
report.("R1 supervisor after 9 s (streams.json missing its last byte)", r)
IO.puts(if r == :shutdown, do: "RESULT\tR1 verdict\tREPRODUCED", else: "RESULT\tR1 verdict\tNOT REPRODUCED")
IO.puts("DONE")

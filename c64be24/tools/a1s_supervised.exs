# A1s (axis 1): the A1 mutations that crashed a process, under supervision as in the service. AtMcp.Supervisor
# (lib/at_mcp/application.ex:108) is one_for_one with OTP's default intensity (3 restarts in 5 s) and holds
# AtMcp.Updates and AtMcp.Listeners among its children. AtMcp.Listen (lib/at_mcp/listen.ex:141-156) calls
# Listeners.track for a logged-in account, catches an exit, and tries again every @did_poll_ms (2 s).
# Here: a supervisor with the same strategy and intensity holding Updates and Listeners under their real names, and
# one Listen-like process per account retrying track every 2 s, catching exits. Simulated: the rest of the service
# (its other children, the MCP server, logins) is not started. Observed per mutation over 12 s: whether the
# supervisor survives, restarts of each child, each account's track results, and whether the undamaged account still
# saves a live record.
spec_f = %{"source" => "records", "authors" => [alice], "collections" => [post]}
room = %{"count" => 2000, "age_seconds" => 604_800}
base = fresh_dir.("base"); reset_fakes.()
{a, clock} = new_clock.(t0)
start_l.(base, clock, [])
for {did, fx} <- [{me, :me_fx}, {other, :other_fx}], do: (:ok = Listeners.track(did, fx); :ok = Listeners.listen(did, "f", spec_f, room))
connect.()
for i <- 1..3, do: (set_time.(a, t0 + i); rec_live.(tid.(t0 + i, i), t0 + i))
Process.sleep(300); for did <- [me, other], do: ack_all.(did, "f")
stop.(Listeners); stop.(Updates)
ldir = Path.join(base, "listeners")
acct = File.read!(Path.join(ldir, me <> ".json")); streams = File.read!(Path.join(ldir, "streams.json"))
j = Jason.decode!(acct)
setp = fn path, v -> Jason.encode!(put_in(j, Enum.map(path, &Access.key(&1, %{})), v)) end
mutations = [
  {"control: no damage", :none, nil},
  {"control: acct cut 50% (unreadable)", :acct, binary_part(acct, 0, div(byte_size(acct), 2))},
  {"acct receipts null", :acct, setp.(["receipts"], nil)},
  {"acct receipts []", :acct, setp.(["receipts"], [])},
  {"acct listeners []", :acct, setp.(["listeners"], [])},
  {"acct next_seq \"x\"", :acct, setp.(["next_seq"], "x")},
  {"acct settling \"x\"", :acct, setp.(["settling"], "x")},
  {"streams cut last byte", :streams, binary_part(streams, 0, byte_size(streams) - 1)},
  {"streams []", :streams, "[]"}
]
lopts = fn clock2 -> [clock: clock2, constellation: FC, repos: R, notifications: fn fx, o -> N.read(fx, o) end,
  profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end, batch_ms: 10, recheck_ms: 3_600_000,
  notifications_poll_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"] end
for {name, what, value} <- mutations do
  dir = fresh_dir.("m"); File.cp_r!(ldir, Path.join(dir, "listeners"))
  case what do
    :acct -> File.write!(Path.join([dir, "listeners", me <> ".json"]), value)
    :streams -> File.write!(Path.join([dir, "listeners", "streams.json"]), value)
    :none -> :ok
  end
  reset_fakes.(); {a2, clock2} = new_clock.(t0 + 100)
  Process.flag(:trap_exit, true)
  {:ok, sup} = Supervisor.start_link([{Updates, state_dir: dir, clock: clock2}, {Listeners, lopts.(clock2)}], strategy: :one_for_one)
  pids0 = {Process.whereis(Updates), Process.whereis(Listeners)}
  log = :ets.new(:log, [:public, :bag])
  retriers = for {did, fx} <- [{me, :me_fx}, {other, :other_fx}] do
    spawn(fn ->
      Enum.each(1..6, fn i ->
        r = try do Listeners.track(did, fx) catch :exit, e -> {:exit, elem(e, 0) |> inspect() |> String.slice(0, 60)} end
        :ets.insert(log, {did, i, r}); Process.sleep(2000)
      end)
    end)
  end
  Process.sleep(1500); send_ok = (if Process.whereis(Listeners), do: (send(Listeners, {:at_mcp_stream_connected, :test}); :sent), else: :no_listeners)
  Process.sleep(500); set_time.(a2, t0 + 101); k = tid.(t0 + 101, 7); rec_live.(k, t0 + 101)
  Process.sleep(10_000)
  sup_alive = Process.alive?(sup)
  exit_reason = receive do {:EXIT, ^sup, r} -> inspect(r) |> String.slice(0, 120) after 0 -> nil end
  pids1 = {Process.whereis(Updates), Process.whereis(Listeners)}
  other_held = safe.(fn -> h = held.(other, "f"); if is_list(h), do: Enum.member?(h, "at://#{alice}/#{post}/#{k}"), else: h end)
  tracks = for did <- [me, other], do: {did |> String.slice(8, 20), :ets.lookup(log, did) |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 2)) |> Enum.map(fn {:exit, s} -> {:exit, s}; x -> x end) |> Enum.dedup()}
  report.("A1s #{name}", %{supervisor_alive_after_12s: sup_alive, supervisor_exit: exit_reason, children_replaced: {elem(pids0, 0) != elem(pids1, 0), elem(pids0, 1) != elem(pids1, 1)}, connect: send_ok, other_saves_live_record: other_held, track_results_by_account: tracks})
  Enum.each(retriers, &Process.exit(&1, :kill))
  if Process.alive?(sup), do: Supervisor.stop(sup)
  Process.flag(:trap_exit, false); Agent.stop(a2); Process.sleep(100)
end
IO.puts("DONE")

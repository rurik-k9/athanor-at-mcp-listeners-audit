# F1, standalone: a damaged listeners/streams.json stops at_mcp's supervisor, for every account.
# Self-contained (no other test file needed). Run inside an at_mcp release in interactive mode:
#   RELEASE_MODE=interactive bin/at_mcp eval 'Code.eval_file("f1_streams_json.exs")'
# What it does: one account logs in (its listeners' state is written), the stream connects (the marks are written),
# then streams.json loses its last byte. A supervisor with AtMcp.Supervisor's strategy (one_for_one, OTP's default
# intensity: lib/at_mcp/application.ex) holds AtMcp.Updates and AtMcp.Listeners, and a caller retries
# Listeners.track every 2 s, catching exits, as AtMcp.Listen does (lib/at_mcp/listen.ex). Case "login": only logins.
# Case "connect": a login, then the stream announces it connected. Case "live save": the account has a records
# listener, and a live record is saved (which writes the stream's cursor to streams.json).
# Prints, per case: REPRODUCED if the supervisor exits within 9 s, else NOT REPRODUCED.
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
{:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
defmodule F1.Constellation do
  def sources(_), do: {:ok, []}
  def backlinks(_, _, _), do: {:ok, [], nil}
end
defmodule F1.Repos do
  def pds(_), do: {:ok, "https://pds.invalid"}
  def collections(_, _), do: {:ok, []}
  def records(_, _, _, _), do: {:ok, [], nil}
end
alias AtMcp.{Listeners, Updates}
did = "did:plc:f1account"
opts = fn clock -> [clock: clock, constellation: F1.Constellation, repos: F1.Repos, notifications: fn _e, _o -> {:ok, %{items: []}} end,
  profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end, batch_ms: 10, recheck_ms: 3_600_000, notifications_poll_ms: 3_600_000,
  relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"] end
clock = fn -> System.system_time(:second) end
kill = fn name -> if p = Process.whereis(name), do: (Process.unlink(p); r = Process.monitor(p); Process.exit(p, :kill); receive do {:DOWN, ^r, _, _, _} -> :ok end) end
live = fn k -> if Process.whereis(Listeners), do: send(Listeners, {:jetstream, %AtMcp.Stream.Event{kind: :commit, did: "did:plc:f1alice", collection: "town.delve.feed.post", rkey: k, operation: :create, cursor: System.os_time(:microsecond)}}) end
spec = %{"source" => "records", "authors" => ["did:plc:f1alice"], "collections" => ["town.delve.feed.post"]}
for {case_name, mode} <- [{"login", :login}, {"connect", :connect}, {"live save", :live}] do
  dir = Path.join(System.tmp_dir!(), "f1-#{System.unique_integer([:positive])}"); File.mkdir_p!(dir); File.chmod!(dir, 0o700)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(opts.(clock)); Process.unlink(l)
  :ok = Listeners.track(did, :f1_effects)
  if mode == :live, do: :ok = Listeners.listen(did, "f", spec, %{"count" => 2000, "age_seconds" => 604_800})
  send(Listeners, {:at_mcp_stream_connected, :f1}); Process.sleep(400)
  if mode == :live, do: (live.("3n7aaaaaaaaa2"); Process.sleep(300))
  kill.(Listeners); kill.(Updates)
  p = Path.join([dir, "listeners", "streams.json"]); s = File.read!(p); File.write!(p, binary_part(s, 0, byte_size(s) - 1))
  Process.flag(:trap_exit, true)
  {:ok, sup} = Supervisor.start_link([{Updates, state_dir: dir, clock: clock}, {Listeners, opts.(clock)}], strategy: :one_for_one)
  retry = spawn(fn -> for _ <- 1..4, do: (try do Listeners.track(did, :f1_effects) catch :exit, _ -> :ok end; Process.sleep(2000)) end)
  if mode in [:connect, :live], do: (Process.sleep(300); if(Process.whereis(Listeners), do: send(Listeners, {:at_mcp_stream_connected, :f1})))
  if mode == :live, do: (Process.sleep(300); live.("3n7aaaaaaaab2"))
  Process.sleep(9000)
  r = receive do {:EXIT, ^sup, why} -> why after 0 -> :still_running end
  IO.puts("RESULT\tF1 #{case_name}: supervisor after 9 s\t#{inspect(r)}\t#{if r == :shutdown, do: "REPRODUCED", else: "NOT REPRODUCED"}")
  Process.exit(retry, :kill); if Process.alive?(sup), do: Supervisor.stop(sup); Process.flag(:trap_exit, false)
end
IO.puts("DONE")

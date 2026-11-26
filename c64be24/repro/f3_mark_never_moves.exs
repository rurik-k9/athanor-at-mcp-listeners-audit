# F3, standalone: a subject whose sources can't be listed holds the account's mark "for up to three passes", but the
# tries restart at every unlisten (and every logout), so a loop of them keeps the gap uncounted and the mark still,
# for as long as the loop lasts. Self-contained. Run inside an at_mcp release:
#   RELEASE_MODE=interactive bin/at_mcp eval 'Code.eval_file("f3_mark_never_moves.exs")'
# Recheck interval 1 s here (5 min in the service), 10 intervals observed. The stream is announced connected by message
# (the relays are a closed port).
#   control  no loop: the gap is given up after three listings, counted, and the mark moves.  [reproduced as is]
#   F3a      unlisten + listen (same id, same spec) every interval.                            [reproduced as is]
#   F3b      logout + login every interval. A login changes the stream's filters, so the stream restarts; here it
#            can't reconnect by itself, so the "connected" announcement the service's stream would send is sent by
#            hand after each login. This case depends on that emulation.                     [partly simulated]
# Prints the mark (seconds after the first connect), unrecovered and listings, and REPRODUCED / NOT REPRODUCED.
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
{:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
defmodule F3.C do
  # Constellation: the subject under test fails to list while :persistent_term {:f3, :fail} is true.
  @subject "at://did:plc:f3other/town.delve.feed.post/3kroot"
  def sources(@subject) do
    :persistent_term.put({:f3, :listings}, :persistent_term.get({:f3, :listings}, 0) + 1)
    if :persistent_term.get({:f3, :fail}, false), do: {:error, {:http_status, 404}}, else: {:ok, ["town.delve.feed.post:reply.parent.uri"]}
  end
  def sources(_), do: {:ok, []}
  def backlinks(_, _, _), do: {:ok, [], nil}
end
defmodule F3.R do
  def pds(_), do: {:ok, "https://pds.invalid"}
  def collections(_, _), do: {:ok, []}
  def records(_, _, _, _), do: {:ok, [], nil}
end
alias AtMcp.{Listeners, Updates}
did = "did:plc:f3account"; root = "at://did:plc:f3other/town.delve.feed.post/3kroot"
spec = %{"source" => "links", "subjects" => [root]}; room = %{"count" => 2000, "age_seconds" => 604_800}
kill = fn name -> if p = Process.whereis(name), do: (Process.unlink(p); r = Process.monitor(p); Process.exit(p, :kill); receive do {:DOWN, ^r, _, _, _} -> :ok end) end
fx = fn -> spawn(fn -> Process.sleep(:infinity) end) end
run = fn mode ->
  :persistent_term.put({:f3, :fail}, false); :persistent_term.put({:f3, :listings}, 0)
  dir = Path.join(System.tmp_dir!(), "f3-#{System.unique_integer([:positive])}"); File.mkdir_p!(dir); File.chmod!(dir, 0o700)
  t0 = 1_800_000_000; {:ok, a} = Agent.start(fn -> t0 end); clock = fn -> Agent.get(a, & &1) end
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(clock: clock, constellation: F3.C, repos: F3.R, notifications: fn _e, _o -> {:ok, %{items: []}} end,
    profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end, recheck_ms: 1000, notifications_poll_ms: 3_600_000,
    relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"); Process.unlink(l)
  e = fx.(); :ok = Listeners.track(did, e); :ok = Listeners.listen(did, "g", spec, room)
  send(Listeners, {:at_mcp_stream_connected, :f3}); Process.sleep(300)
  Agent.update(a, fn _ -> t0 + 3600 end); :persistent_term.put({:f3, :fail}, true)       # a gap of an hour, listing failing
  send(Listeners, {:at_mcp_stream_connected, :f3})
  Enum.reduce(1..10, e, fn _, e ->
    e = case mode do
      :relisten -> :ok = Listeners.unlisten(did, "g"); :ok = Listeners.listen(did, "g", spec, room); e
      :relogin -> Process.exit(e, :kill); Process.sleep(20); n = fx.(); :ok = Listeners.track(did, n); send(Listeners, {:at_mcp_stream_connected, :f3}); n
      :none -> e
    end
    Process.sleep(1000); e
  end)
  mark = case Updates.stream_cursor("listeners_live:" <> did) do x when is_integer(x) -> x - t0; x -> x end
  unrec = get_in(Listeners.stats(did), ["g", :unrecovered])
  r = %{mark: mark, unrecovered: unrec, listings: :persistent_term.get({:f3, :listings})}
  kill.(Listeners); kill.(Updates); Agent.stop(a); r
end
c = run.(:none); a3 = run.(:relisten); b3 = run.(:relogin)
IO.puts("RESULT\tF3 control (no loop)\t#{inspect(c)}\t#{cond do c.mark == 3600 and c.unrecovered == 1 -> "given up and counted (the c64be24 rule)"; c.mark == 3600 -> "mark moved, gap not counted (the earlier behaviour: let go silently)"; true -> "UNEXPECTED" end}")
IO.puts("RESULT\tF3a unlisten+listen every interval\t#{inspect(a3)}\t#{if a3.mark == 0 and a3.unrecovered in [nil, 0], do: "REPRODUCED", else: "NOT REPRODUCED"}")
IO.puts("RESULT\tF3b logout+login every interval (reconnect sent by hand)\t#{inspect(b3)}\t#{if b3.mark == 0 and b3.unrecovered in [nil, 0], do: "REPRODUCED (partly simulated)", else: "NOT REPRODUCED"}")
IO.puts("DONE")

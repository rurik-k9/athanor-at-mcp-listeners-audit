# Black-box checks of AtMcp.Listeners backfill in the released 0.3.3-hum.6 beams.
# Fake Constellation, notifications and profiles; no network, no account.
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
# Normally created by the application supervisor, which this script does not start.
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
alias AtMcp.{Listeners, Updates}

defmodule FakeConstellation do
  def sources(_subject) do
    if :persistent_term.get(:services_up), do: {:ok, []}, else: {:error, :down}
  end

  def backlinks(_subject, _source, _cursor), do: {:error, :down}
end

did = "did:plc:testaccount"
t0 = 1_800_000_000
iso = fn t -> t |> DateTime.from_unix!() |> DateTime.to_iso8601() end
report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value)}") end

notif = fn n, at ->
  %{uri: "at://did:plc:sender/town.delve.feed.post/r#{n}", reason: "reply",
    author_did: "did:plc:sender", indexed_at: iso.(at)}
end

notifications = fn _effects, opts ->
  send(:calls, {:call, opts})
  Process.sleep(:persistent_term.get(:notif_delay))

  if :persistent_term.get(:services_up) do
    # Newest first, in real pages: the cursor is the offset of the next page.
    all = :persistent_term.get(:notifs) |> Enum.reverse()
    start = if opts[:cursor], do: String.to_integer(opts[:cursor]), else: 0
    next = start + opts[:limit]
    {:ok, %{items: Enum.slice(all, start, opts[:limit]), cursor: if(next < length(all), do: Integer.to_string(next))}}
  else
    {:error, :down}
  end
end

{:ok, calls} = Agent.start(fn -> [] end)
spawn(fn ->
  Process.register(self(), :calls)
  Stream.repeatedly(fn -> receive do {:call, o} -> Agent.update(calls, &[o | &1]) end end) |> Stream.run()
end)
Process.sleep(50)

stop = fn name ->
  if pid = Process.whereis(name) do
    Process.unlink(pid); r = Process.monitor(pid); Process.exit(pid, :kill)
    receive do {:DOWN, ^r, _, _, _} -> :ok end
  end
end

boot = fn dir, clock ->
  stop.(Listeners); stop.(Updates)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(clock: clock, constellation: FakeConstellation, notifications: notifications,
    profiles: fn _e, _s -> {:ok, %{items: []}} end, batch_ms: 10, recheck_ms: 3_600_000, relay: "ws://127.0.0.1:9/")
  Process.unlink(l)
  :ok = Listeners.track(did, :fake_effects)
end
connect = fn -> send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(350) end
held = fn -> {:ok, r} = Updates.read(did, peek: true, limit: 1000); length(r.updates) end

scenario = fn name ->
  dir = "/work/backfill-#{name}-#{System.unique_integer([:positive])}"; File.mkdir_p!(dir)
  {:ok, now} = Agent.start(fn -> t0 end)
  clock = fn -> Agent.get(now, & &1) end
  :persistent_term.put(:services_up, true); :persistent_term.put(:notif_delay, 0); :persistent_term.put(:notifs, [])
  boot.(dir, clock); connect.()
  {dir, now, clock}
end
at = fn now, t -> Agent.update(now, fn _ -> t end) end
gap_item = notif.(1, t0 + 1800)

# Control: a one-hour gap, services healthy at reconnect.
{dir, now, clock} = scenario.("control")
:persistent_term.put(:notifs, [gap_item]); at.(now, t0 + 3600); boot.(dir, clock); connect.()
report.("A control: mention in a 1 h gap recovered (expect 1)", held.())

# Backfill fails at the first reconnect, services are back at the next one.
{dir, now, clock} = scenario.("failed")
:persistent_term.put(:notifs, [gap_item]); :persistent_term.put(:services_up, false)
at.(now, t0 + 3600); boot.(dir, clock); connect.()
:persistent_term.put(:services_up, true)
at.(now, t0 + 3700); boot.(dir, clock); connect.()
report.("B backfill failed once, next start healthy: recovered (1 = ok, 0 = lost)", held.())

# Killed while the backfill is running.
{dir, now, clock} = scenario.("killed")
:persistent_term.put(:notifs, [gap_item]); :persistent_term.put(:notif_delay, 1500)
at.(now, t0 + 3600); boot.(dir, clock); send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(120)
:persistent_term.put(:notif_delay, 0)
at.(now, t0 + 3610); boot.(dir, clock); connect.()
report.("C restart during backfill: recovered (1 = ok, 0 = lost)", held.())

# More replies in the gap than one notifications page.
{dir, now, clock} = scenario.("page")
Agent.update(calls, fn _ -> [] end)
:persistent_term.put(:notifs, Enum.map(1..120, &notif.(&1, t0 + 1000 + &1)))
at.(now, t0 + 3600); boot.(dir, clock); connect.()
report.("D 120 replies in a gap: recovered (expect 120 if fully paged)", held.())
report.("D notification calls / any call with a cursor", {length(Agent.get(calls, & &1)), Enum.any?(Agent.get(calls, & &1), &Keyword.has_key?(&1, :cursor))})
IO.puts("DONE")

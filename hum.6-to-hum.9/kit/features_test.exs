# Black-box checks of the listener features added in 0.3.3-hum.7 and hum.8,
# on the released beams. Injected clock; fake Constellation, notifications,
# profiles and repositories; streams never connect (relay is a closed local port).
# No network, no account. Every number below is observed, nothing is asserted.
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
{:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
alias AtMcp.{Listeners, Updates}
alias AtMcp.Stream.Event

defmodule FakeConstellation do
  def sources(_subject), do: {:ok, []}
  def backlinks(_subject, _source, _cursor), do: {:ok, [], nil}
end

defmodule FakeRepos do
  # An author's records newest first, 100 per page like the real listRecords.
  def set(rkeys), do: :persistent_term.put(:repo, Enum.reverse(rkeys))
  def mode(m), do: :persistent_term.put(:repo_mode, m)
  def calls, do: :counters.get(:persistent_term.get(:repo_calls), 1)
  def pds(_did) do
    if :persistent_term.get(:repo_mode) == :down, do: {:error, :down}, else: {:ok, "https://pds.invalid"}
  end
  def collections(_pds, _did), do: {:ok, ["town.delve.feed.post"]}
  def records(_pds, did, collection, cursor) do
    :counters.add(:persistent_term.get(:repo_calls), 1, 1)
    start = if cursor, do: String.to_integer(cursor), else: 0
    page_no = div(start, 100) + 1
    case :persistent_term.get(:repo_mode) do
      {:fail_page, ^page_no} -> {:error, :boom}
      {:delay, ms} -> Process.sleep(ms); page(did, collection, start)
      _ -> page(did, collection, start)
    end
  end
  defp page(did, collection, start) do
    all = :persistent_term.get(:repo)
    rows = for k <- Enum.slice(all, start, 100), do: %{did: did, collection: collection, rkey: k}
    {:ok, rows, if(start + 100 < length(all), do: Integer.to_string(start + 100))}
  end
end

:persistent_term.put(:repo_calls, :counters.new(1, []))
FakeRepos.set([]); FakeRepos.mode(:ok)

report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 12)}") end
me = "did:plc:testaccount"; alice = "did:plc:alice"; bob = "did:plc:bob"; post = "town.delve.feed.post"
t0 = 1_800_000_000
alpha = ~c"234567abcdefghijklmnopqrstuvwxyz"
tid = fn sec, n ->
  v = Bitwise.bor(Bitwise.bsl(sec * 1_000_000 + n, 10), 1)
  for(i <- 12..0//-1, do: Enum.at(alpha, Bitwise.band(Bitwise.bsr(v, i * 5), 31))) |> to_string()
end
stop = fn name ->
  if pid = Process.whereis(name) do
    Process.unlink(pid); r = Process.monitor(pid); Process.exit(pid, :kill)
    receive do {:DOWN, ^r, _, _, _} -> :ok end
  end
end
boot = fn dir, clock ->
  stop.(Listeners); stop.(Updates)
  for key <- [Listeners.Records, Listeners.Spacedust], pid = Process.whereis(key), do: Process.exit(pid, :kill)
  Process.sleep(20)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(clock: clock, constellation: FakeConstellation, repos: FakeRepos,
    notifications: fn _e, _o -> {:ok, %{items: []}} end, profiles: fn _e, _s -> {:ok, %{items: []}} end,
    batch_ms: 10, recheck_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/")
  Process.unlink(l); :ok = Listeners.track(me, :fake_effects); Process.sleep(250)
end
fresh = fn name ->
  dir = "/work/f-#{name}-#{System.unique_integer([:positive])}"; File.mkdir_p!(dir)
  {:ok, now} = Agent.start(fn -> t0 end); FakeRepos.set([]); FakeRepos.mode(:ok)
  clock = fn -> Agent.get(now, & &1) end; boot.(dir, clock); {dir, now, clock}
end
at = fn now, t -> Agent.update(now, fn _ -> t end) end
held = fn id ->
  {:ok, r} = Updates.read(me, peek: true, limit: 5000, listener: id); Enum.map(r.updates, & &1["uri"])
end
link = fn from, key ->
  send(Listeners, {:jetstream, %{"kind" => "link", "link" => %{"operation" => "create",
    "source" => "town.delve.feed.post:reply.parent.uri", "source_record" => "at://#{from}/#{post}/#{key}",
    "source_rev" => key, "subject" => "at://#{me}/#{post}/3kmine222222a"}}})
end
rec = fn key, sec ->
  send(Listeners, {:jetstream, %Event{kind: :commit, did: alice, collection: post, rkey: key,
    operation: :create, cursor: sec * 1_000_000}})
end
drain = fn f -> f.(f, []) end
events = fn -> drain.(fn g, a -> receive do {:at_mcp_listen, e} -> g.(g, [e | a]) after 0 -> Enum.reverse(a) end end) end
wakes = fn es -> es |> Enum.flat_map(&Map.values(Map.get(&1, :wakes, %{}))) |> Enum.sum() end
try_ = fn name, f ->
  try do f.() rescue e -> report.("#{name} ERROR", Exception.message(e) |> String.slice(0, 120))
  catch k, v -> report.("#{name} ERROR", {k, v}) end
end
{:ok, _} = AtMcp.Listen.subscribe(:events)
has_records = function_exported?(AtMcp.Repos, :records, 4) or Code.ensure_loaded?(AtMcp.Repos)
report.("build has records listeners", has_records)

# ---- Per-sender wake limit (hum.7)
try_.("cap", fn ->
  {dir, now, clock} = fresh.("cap"); events.()
  for n <- 1..10, do: link.(alice, tid.(t0 + n, n))
  Process.sleep(250); e = events.()
  report.("S1 same sender, 10 replies: kept / wakes (expect 10 / 6)", {length(held.("references")), wakes.(e)})
  report.("S1 capped counter", get_in(Listeners.stats(me), ["references", :capped]))
  report.("S1 an event still goes out when all of a batch is capped (subscribers are told)",
    (for n <- 11..12, do: link.(alice, tid.(t0 + n, n)); Process.sleep(200); e2 = events.(); {length(e2), wakes.(e2)}))
  link.(bob, tid.(t0 + 20, 1)); Process.sleep(200)
  report.("S2 another sender still wakes (expect 1)", wakes.(events.()))
  at.(now, t0 + 3700); link.(alice, tid.(t0 + 3700, 1)); Process.sleep(200)
  report.("S3 same sender after one hour wakes again (expect 1)", wakes.(events.()))
  for n <- 1..6, do: link.(alice, tid.(t0 + 3700 + n, n + 10))
  Process.sleep(200); events.()
  boot.(dir, clock); events.()
  for n <- 1..6, do: link.(alice, tid.(t0 + 3720 + n, n + 40))
  Process.sleep(250)
  report.("S4 cap already spent, process restarted: wakes in the same hour (0 = persisted, 6 = reset)", wakes.(events.()))
end)

# ---- last_saved and the live mark (hum.7)
try_.("live", fn ->
  {dir, now, clock} = fresh.("live")
  send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(120)
  view = fn -> {:ok, v} = Listeners.listeners_view(me); Enum.find(v.items, &(&1.id == "references")) end
  report.("L1 last_saved before anything is caught (expect nil)", Map.get(view.(), :last_saved))
  k = tid.(t0 + 5, 1); at.(now, t0 + 5); link.(alice, k); Process.sleep(200)
  first = Map.get(view.(), :last_saved); report.("L2 last_saved after a match", first)
  at.(now, t0 + 50); link.(alice, k); Process.sleep(200)
  report.("L3 duplicate leaves last_saved unchanged", Map.get(view.(), :last_saved) == first)
  boot.(dir, clock); report.("L4 last_saved survives a restart", Map.get(view.(), :last_saved) == first)
  send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(120)
  at.(now, t0 + 7200)
  quiet = Updates.stream_cursor("listeners_live")
  stream = :sys.get_state(Listeners).stream
  send(Listeners, {:EXIT, stream, :test_stream_dead}); Process.sleep(80)
  dead = Updates.stream_cursor("listeners_live")
  report.("L5 stream_live_at, connected and quiet for 2 h: age in s", t0 + 7200 - quiet)
  report.("L6 stream_live_at, stream dead at the same time: age in s", t0 + 7200 - dead)
  report.("L7 can the two be told apart from stream_live_at? (false = no)", quiet != dead)
end)

# ---- Operator pause and from (hum.7)
try_.("pause", fn ->
  {dir, now, clock} = fresh.("pause")
  :ok = Listeners.listen(me, "t", %{"source" => "links", "subject_dids" => [me], "from" => [alice]}, %{})
  link.(alice, tid.(t0 + 1, 1)); link.(bob, tid.(t0 + 1, 2)); Process.sleep(200)
  report.("P1 from: only the named sender (expect 1)", length(held.("t")))
  Listeners.pause(me, "t", true)
  :ok = Listeners.listen(me, "t", %{"source" => "links", "subject_dids" => [me]}, %{})
  boot.(dir, clock); link.(alice, tid.(t0 + 2, 3)); Process.sleep(200)
  report.("P2 paused, agent re-listens, restart: nothing added (expect 1)", length(held.("t")))
  _ = now
end)

if has_records do
  # A records listener with room for every record, its cursor set by one live record at T.
  setup = fn name ->
    {dir, now, clock} = fresh.(name)
    :ok = Listeners.listen(me, "f", %{"source" => "records", "authors" => [alice], "collections" => [post]},
      %{"count" => 2000, "age_seconds" => 604_800})
    first = tid.(t0 + 1, 1); FakeRepos.set([first]); at.(now, t0 + 1); rec.(first, t0 + 1); Process.sleep(200)
    {dir, now, clock, first}
  end
  gap = fn first, base, n -> [first | for(i <- 1..n, do: tid.(base + i, i))] end
  stale = t0 + 40 * 3600

  try_.("R1", fn ->
    {dir, now, clock, first} = setup.("r1"); FakeRepos.set(gap.(first, t0 + 100, 3)); at.(now, stale); boot.(dir, clock)
    report.("R1 control, 40 h gap, 3 records, PDS healthy: held (expect 4)", length(held.("f")))
    boot.(dir, clock); report.("R1b restart again: no duplicate (expect 4)", length(held.("f")))
  end)
  try_.("R2", fn ->
    {dir, now, clock, first} = setup.("r2"); FakeRepos.set(gap.(first, t0 + 100, 3)); c0 = FakeRepos.calls()
    at.(now, t0 + 3600); boot.(dir, clock)
    report.("R2 1 h gap: PDS reads (expect 0, Jetstream replays it)", FakeRepos.calls() - c0)
    for {k, i} <- Enum.with_index(tl(gap.(first, t0 + 100, 3)), 1), do: rec.(k, t0 + 100 + i)
    Process.sleep(200); report.("R2b replayed records saved (expect 4)", length(held.("f")))
  end)
  try_.("R3", fn ->
    {dir, now, clock, first} = setup.("r3"); FakeRepos.set(gap.(first, t0 + 100, 250)); FakeRepos.mode({:fail_page, 2})
    at.(now, stale); boot.(dir, clock); Process.sleep(200)
    n1 = length(held.("f")); FakeRepos.mode(:ok); boot.(dir, clock); Process.sleep(300)
    report.("R3 250 in gap, page 2 fails once, then healthy restart: held after fail / after restart (expect 251)", {n1, length(held.("f"))})
    report.("R3b unrecovered counter", get_in(Listeners.stats(me), ["f", :unrecovered]))
  end)
  try_.("R4", fn ->
    {dir, now, clock, first} = setup.("r4"); g = gap.(first, t0 + 100, 3); FakeRepos.set(g); FakeRepos.mode(:down)
    at.(now, stale); boot.(dir, clock); FakeRepos.mode(:ok)
    live = tid.(stale + 60, 9); FakeRepos.set(g ++ [live]); at.(now, stale + 60); rec.(live, stale + 60); Process.sleep(200)
    at.(now, stale + 70); boot.(dir, clock); Process.sleep(250)
    report.("R4 PDS down on start, one live record, healthy restart: held (expect 5)", length(held.("f")))
    report.("R4b unrecovered counter", get_in(Listeners.stats(me), ["f", :unrecovered]))
  end)
  try_.("R5", fn ->
    {dir, now, clock, first} = setup.("r5"); g = gap.(first, t0 + 100, 3); live = tid.(stale + 1, 9)
    FakeRepos.set(g ++ [live]); FakeRepos.mode({:delay, 400}); at.(now, stale + 1)
    spawn(fn -> Process.sleep(120); if Process.whereis(Listeners), do: rec.(live, stale + 1) end)
    stop.(Listeners); stop.(Updates)
    {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
    {:ok, l} = Listeners.start_link(clock: clock, constellation: FakeConstellation, repos: FakeRepos,
      notifications: fn _e, _o -> {:ok, %{items: []}} end, profiles: fn _e, _s -> {:ok, %{items: []}} end,
      batch_ms: 10, recheck_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/")
    Process.unlink(l); :ok = Listeners.track(me, :fake_effects); Process.sleep(1000)
    report.("R5 a live record is saved while the PDS read runs: held (expect 5)", length(held.("f")))
  end)
  try_.("R5c", fn ->
    {dir, now, clock, first} = setup.("r5c"); FakeRepos.set(gap.(first, t0 + 100, 3)); FakeRepos.mode({:delay, 400}); at.(now, stale + 1)
    boot.(dir, clock); Process.sleep(1000)
    report.("R5c control, same slow PDS read, no live record meanwhile: held (expect 4)", length(held.("f")))
  end)
  try_.("R6", fn ->
    {dir, now, clock, first} = setup.("r6"); FakeRepos.set(gap.(first, t0 + 100, 650)); at.(now, stale); boot.(dir, clock); Process.sleep(500)
    a = length(held.("f")); u = get_in(Listeners.stats(me), ["f", :unrecovered])
    boot.(dir, clock); Process.sleep(400)
    report.("R6 650 in gap, 5-page bound: held / unrecovered counter", {a, u})
    report.("R6b after a restart: held / unrecovered counter (the 150 past the bound stay lost)",
      {length(held.("f")), get_in(Listeners.stats(me), ["f", :unrecovered])})
  end)
end
IO.puts("DONE")

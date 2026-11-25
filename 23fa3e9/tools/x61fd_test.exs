# Checks for commit 61fd227 (records bound, seen_through, damaged lists), on released or overlaid beams.
# Injected clock; fake Constellation, notifications, profiles and repositories;
# streams never connect (relay is a closed local port). No network, no account.
# Values are observed, not asserted.
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

defmodule R do
  def reset, do: :persistent_term.put(:r, %{repo: [], down: false, fail_page: nil, delay: 0})
  def put(k, v), do: :persistent_term.put(:r, Map.put(:persistent_term.get(:r), k, v))
  def get(k), do: Map.get(:persistent_term.get(:r), k)
  def repo(oldest_first), do: put(:repo, Enum.reverse(oldest_first))
  def pds(_did), do: if(get(:down), do: {:error, :down}, else: {:ok, "https://pds.invalid"})
  def collections(_pds, _did), do: {:ok, ["town.delve.feed.post"]}
  def records(_pds, did, collection, cursor) do
    if get(:delay) > 0, do: Process.sleep(get(:delay))
    start = if cursor, do: String.to_integer(cursor), else: 0
    if get(:fail_page) == div(start, 100) + 1 do
      {:error, :boom}
    else
      all = get(:repo)
      {:ok, for(k <- Enum.slice(all, start, 100), do: %{did: did, collection: collection, rkey: k}),
       if(start + 100 < length(all), do: Integer.to_string(start + 100))}
    end
  end
end

defmodule N do
  # Notifications per account (keyed by its effects), newest first, real pages.
  def reset, do: :persistent_term.put(:n, %{items: %{}, fail: MapSet.new(), fail_page: nil})
  def put(k, v), do: :persistent_term.put(:n, Map.put(:persistent_term.get(:n), k, v))
  def get(k), do: Map.get(:persistent_term.get(:n), k)
  def add(fx, item), do: put(:items, Map.update(get(:items), fx, [item], &[item | &1]))
  def fail(fx, on?), do: put(:fail, if(on?, do: MapSet.put(get(:fail), fx), else: MapSet.delete(get(:fail), fx)))
  def read(fx, opts) do
    start = if opts[:cursor], do: String.to_integer(opts[:cursor]), else: 0
    page = div(start, opts[:limit]) + 1
    if MapSet.member?(get(:fail), fx) or get(:fail_page) == page do
      {:error, :down}
    else
      all = Map.get(get(:items), fx, [])
      next = start + opts[:limit]
      {:ok, %{items: Enum.slice(all, start, opts[:limit]), cursor: if(next < length(all), do: Integer.to_string(next))}}
    end
  end
end

report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 14)}") end
me = "did:plc:testaccount"; other = "did:plc:otheraccount"; alice = "did:plc:alice"; bob = "did:plc:bob"
post = "town.delve.feed.post"; t0 = 1_800_000_000; stale = t0 + 40 * 3600
alpha = ~c"234567abcdefghijklmnopqrstuvwxyz"
tid = fn sec, n ->
  v = Bitwise.bor(Bitwise.bsl(sec * 1_000_000 + n, 10), 1)
  for(i <- 12..0//-1, do: Enum.at(alpha, Bitwise.band(Bitwise.bsr(v, i * 5), 31))) |> to_string()
end
iso = fn t -> t |> DateTime.from_unix!() |> DateTime.to_iso8601() end
mention = fn fx, at, n ->
  N.add(fx, %{uri: "at://#{bob}/#{post}/#{tid.(at, n)}", reason: "mention", author_did: bob, indexed_at: iso.(at)})
end
stop = fn name ->
  if pid = Process.whereis(name) do
    Process.unlink(pid); r = Process.monitor(pid); Process.exit(pid, :kill)
    receive do {:DOWN, ^r, _, _, _} -> :ok end
  end
end
start_l = fn dir, clock, opts ->
  stop.(Listeners); stop.(Updates)
  for key <- [Listeners.Records, Listeners.Spacedust], pid = Process.whereis(key), do: Process.exit(pid, :kill)
  Process.sleep(20)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(clock: clock, constellation: FakeConstellation, repos: R,
    notifications: fn fx, o -> N.read(fx, o) end, profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end,
    batch_ms: 10, recheck_ms: Keyword.get(opts, :recheck_ms, 3_600_000), notifications_poll_ms: 3_600_000,
    relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/")
  Process.unlink(l)
end
connect = fn -> send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(400) end
boot = fn dir, clock, accounts, opts ->
  start_l.(dir, clock, opts)
  for {did, fx} <- accounts, do: :ok = Listeners.track(did, fx)
  Process.sleep(60); connect.()
end
both = [{me, :me_fx}, {other, :other_fx}]
fresh = fn name, accounts ->
  dir = "/work/v-#{name}-#{System.unique_integer([:positive])}"; File.mkdir_p!(dir)
  {:ok, now} = Agent.start(fn -> t0 end); R.reset(); N.reset()
  clock = fn -> Agent.get(now, & &1) end; boot.(dir, clock, accounts, []); {dir, now, clock}
end
at = fn now, t -> Agent.update(now, fn _ -> t end) end
held = fn did, id ->
  {:ok, r} = Updates.read(did, peek: true, limit: 5000, listener: id); r.updates |> Enum.map(& &1["uri"])
end
count = fn did, id -> u = held.(did, id); {length(u), length(u) - length(Enum.uniq(u))} end
mark = fn -> case Updates.stream_cursor("listeners_live") do x when is_integer(x) -> x - t0; x -> x end end
stat = fn did, id, k -> get_in(Listeners.stats(did), [id, k]) end
rec = fn key, sec ->
  send(Listeners, {:jetstream, %Event{kind: :commit, did: alice, collection: post, rkey: key, operation: :create, cursor: sec * 1_000_000}})
end
room = %{"count" => 2000, "age_seconds" => 604_800}
setup = fn name ->
  {dir, now, clock} = fresh.(name, [{me, :me_fx}])
  :ok = Listeners.listen(me, "f", %{"source" => "records", "authors" => [alice], "collections" => [post]}, room)
  first = tid.(t0 + 1, 1); R.repo([first]); at.(now, t0 + 1); rec.(first, t0 + 1); Process.sleep(200)
  {dir, now, clock, first}
end
gap = fn first, base, n -> [first | for(i <- 1..n, do: tid.(base + i, i))] end
one = [{me, :me_fx}]
try_ = fn name, f ->
  try do f.() rescue e -> report.("#{name} ERROR", Exception.message(e) |> String.slice(0, 130))
  catch k, v -> report.("#{name} ERROR", {k, v}) end
end

amark = fn did -> case Updates.stream_cursor("listeners_live:" <> did) do x when is_integer(x) -> x - t0; x -> x end end
ack_all = fn did, id ->
  {:ok, r} = Updates.read(did, limit: 5000, listener: id)
  if r.updates != [], do: Updates.ack(did, List.last(r.updates)["seq"], id)
end
gapkeys = fn ks -> Enum.map(ks, &"at://#{alice}/#{post}/#{&1}") end

try_.("Y1", fn ->
  # N2 beyond the reads bound: 5,100 live records already held, newer than a 3-record gap (51 pages).
  {dir, now, clock, first} = setup.("y1"); g = gap.(first, t0 + 100, 3); R.repo(g); R.put(:down, true); at.(now, stale)
  boot.(dir, clock, one, []); Process.sleep(200)
  live = for i <- 1..5100, do: tid.(stale + 10 + div(i, 100), 10_000 + i)
  for k <- live, do: rec.(k, stale + 70)
  Process.sleep(2500); R.repo(g ++ live); R.put(:down, false)
  at.(now, stale + 200); boot.(dir, clock, one, []); Process.sleep(4000)
  gk = gapkeys.(Enum.slice(g, 1, 3)); u = held.(me, "f")
  report.("Y1 PDS down, 5,100 live records held (51 pages), back, restart: gap held (of 3) / unrecovered / held total (design: reads bound 50)",
    {Enum.count(gk, &(&1 in u)), stat.(me, "f", :unrecovered), length(u)})
end)

try_.("Y2", fn ->
  # N2 resumed several times in one process: 1,300 new records (13 pages) after an outage, recheck every 0.3 s.
  {dir, now, clock, first} = setup.("y2"); g = gap.(first, t0 + 100, 1300); R.repo(g); R.put(:down, true); at.(now, stale)
  boot.(dir, clock, one, recheck_ms: 300); Process.sleep(400); R.put(:down, false); Process.sleep(6000)
  report.("Y2 1,300 new records after an outage, no restart: held, dup / unrecovered (expect {1301, 0} / counted, F4)", {count.(me, "f"), stat.(me, "f", :unrecovered)})
end)

try_.("Y3", fn ->
  # N2 resumed across restarts, with no recheck in between: each start reads at most five pages of new records.
  {dir, now, clock, first} = setup.("y3"); g = gap.(first, t0 + 100, 1300); R.repo(g); at.(now, stale)
  boot.(dir, clock, one, []); Process.sleep(1500); a = count.(me, "f")
  at.(now, stale + 100); boot.(dir, clock, one, []); Process.sleep(1500); b = count.(me, "f")
  at.(now, stale + 200); boot.(dir, clock, one, []); Process.sleep(1500)
  report.("Y3 1,300 new records, three starts, no recheck: held, dup after each (expect 501, 1001, 1301; no duplicate)", {a, b, count.(me, "f")})
end)

try_.("Y4", fn ->
  # N2 when both bounds meet: the PDS is down at start; 1,200 live records are saved (12 held pages); behind them, 600
  # records made while at_mcp was stopped and the 3-record gap. Then the PDS is back; recheck every 0.3 s.
  {dir, now, clock, first} = setup.("y4"); oldgap = gap.(first, t0 + 100, 3)
  down = for i <- 1..600, do: tid.(t0 + 1000 + i, 1000 + i)
  R.repo(oldgap ++ down); R.put(:down, true); at.(now, stale)
  boot.(dir, clock, one, recheck_ms: 300); Process.sleep(200)
  live = for i <- 1..1200, do: tid.(stale + 10 + div(i, 100), 5000 + i)
  for k <- live, do: rec.(k, stale + 30)
  Process.sleep(1200); R.repo(oldgap ++ down ++ live); R.put(:down, false); Process.sleep(6000)
  u = held.(me, "f")
  report.("Y4 held 1,200 newest, then 600 made while stopped, then a 3-record gap; recheck: made-while-stopped held (of 600) / gap held (of 3) / duplicates (expect 600 / 3 / 0)",
    {Enum.count(gapkeys.(down), &(&1 in u)), Enum.count(gapkeys.(Enum.slice(oldgap, 1, 3)), &(&1 in u)), length(u) - length(Enum.uniq(u))})
end)

try_.("Y5", fn ->
  # seen_through of the oldest-first read at its edges (AtMcp.NotificationsOldest.read with a fake page).
  if function_exported?(AtMcp.NotificationsOldest, :read, 2) do
    mk = fn stamps, seen ->
      items = for {s, i} <- Enum.with_index(stamps), do: %{uri: "at://#{bob}/#{post}/n#{i}", reason: "mention", is_read: false, indexed_at: s}
      fn _size, _cursor -> {:ok, %{items: Enum.reverse(items), seen_at: seen, cursor: nil}} end
    end
    run = fn stamps, limit ->
      case AtMcp.NotificationsOldest.read(mk.(stamps, "2026-01-01T00:00:00.000Z"), limit: limit, now: ~U[2026-06-01 00:00:00Z]) do
        {:ok, r} -> {Map.get(r, :seen_through) || Map.get(r, "seen_through"), length(Map.get(r, :items, []))}
        e -> e
      end
    end
    report.("Y5a two unread 1 ms apart, read one: seen_through / shown (strictly before the second: 05.000 is the first's own time)",
      run.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.001Z"], 1))
    report.("Y5b two unread 2 ms apart, read one: seen_through / shown", run.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.002Z"], 1))
    report.("Y5c two unread at the same time, read one: seen_through / shown (an equal group is not split)", run.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.000Z"], 1))
    report.("Y5d microsecond stamps 1 us apart, read one: seen_through / shown", run.(["2026-03-01T00:00:05.000400Z", "2026-03-01T00:00:05.000401Z"], 1))
    report.("Y5e ms then us 0.4 ms later, read one: seen_through / shown", run.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.000400Z"], 1))
    report.("Y5f all read: seen_through / shown", run.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.001Z"], 5))
    # Several reads in a row, each acknowledged with the seen_through it gave, against a service whose read is strict
    # (earlier than seenAt) or not (at or before it): does the reader reach every notification?
    walk = fn stamps, limit, strict? ->
      Enum.reduce_while(1..6, {"2026-01-01T00:00:00.000Z", []}, fn _, {seen, shown} ->
        {:ok, seen_dt, _} = DateTime.from_iso8601(seen)
        items = for {s, i} <- Enum.with_index(stamps) do
          {:ok, at, _} = DateTime.from_iso8601(s)
          read? = if strict?, do: DateTime.compare(at, seen_dt) == :lt, else: DateTime.compare(at, seen_dt) != :gt
          %{uri: "n#{i}", reason: "mention", is_read: read?, indexed_at: s}
        end
        {:ok, r} = AtMcp.NotificationsOldest.read(fn _s, _c -> {:ok, %{items: Enum.reverse(items), seen_at: seen, cursor: nil}} end, limit: limit, now: ~U[2026-06-01 00:00:00Z])
        names = Enum.map(Map.get(r, :items, []), &(&1[:uri] || &1["uri"]))
        st = Map.get(r, :seen_through)
        if names == [] or st == nil, do: {:halt, {seen, shown}}, else: {:cont, {st, shown ++ [names]}}
      end) |> elem(1)
    end
    report.("Y5h three unread, 1 ms apart, read one at a time, strict service: what each of six reads shows (expect n0, n1, n2, then nothing)",
      walk.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.001Z", "2026-03-01T00:00:05.002Z"], 1, true))
    report.("Y5i the same, service not strict (at or before seenAt counts read)", walk.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.001Z", "2026-03-01T00:00:05.002Z"], 1, false))
    report.("Y5j three unread, 2 ms apart, read one at a time, strict service", walk.(["2026-03-01T00:00:05.000Z", "2026-03-01T00:00:05.002Z", "2026-03-01T00:00:05.004Z"], 1, true))
    report.("Y5g just_before / next_after on ms and us stamps",
      {AtMcp.NotificationsOldest |> function_exported?(:just_before, 1) &&
         Enum.map([~U[2026-03-01 00:00:05.000Z], ~U[2026-03-01 00:00:05.000400Z]], &{DateTime.to_iso8601(AtMcp.NotificationsOldest.just_before(&1)), DateTime.to_iso8601(AtMcp.NotificationsOldest.next_after(&1))})})
  else
    report.("Y5 seen_through", :no_oldest_first_read_in_this_build)
  end
end)

try_.("Y6", fn ->
  # Review F3: a damaged receipt list of a listener the account file no longer has, then a start.
  {dir, now, clock} = fresh.("y6", one); mention.(:me_fx, t0 + 1800, 1); at.(now, t0 + 3600); boot.(dir, clock, one, []); Process.sleep(200)
  stop.(Listeners); stop.(Updates)
  file = Path.join([dir, "listeners", me <> ".json"]); data = Jason.decode!(File.read!(file))
  data = put_in(data, ["receipts", "ghost"], [String.duplicate("a", 32), "short"])
  File.write!(file, Jason.encode!(data))
  if File.exists?(Path.join([dir, "listeners", "streams.json"])) do
    s = Jason.decode!(File.read!(Path.join([dir, "listeners", "streams.json"])))
    File.write!(Path.join([dir, "listeners", "streams.json"]), Jason.encode!(update_in(s, ["streams"], &Map.put(&1 || %{}, "listeners_live_split", t0))))
  end
  mention.(:me_fx, t0 + 3650, 2); at.(now, t0 + 3700)
  r = try do
    boot.(dir, clock, one, []); Process.sleep(300); {:started, length(held.(me, "references"))}
  rescue e -> {:raised, Exception.message(e) |> String.slice(0, 80)}
  catch k, v -> {k, inspect(v) |> String.slice(0, 80)}
  end
  report.("Y6 damaged receipts of a missing listener, then a start: outcome (expect started, 2 held)", r)
end)
IO.puts("DONE")

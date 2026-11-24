# Supplementary checks around commit 335b95e, on released or overlaid beams.
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

try_.("V1", fn ->
  {dir, now, clock} = fresh.("v1", one); mention.(:me_fx, t0 + 1800, 1); N.fail(:me_fx, true)
  at.(now, t0 + 3600); boot.(dir, clock, one, []); m1 = mark.()
  N.fail(:me_fx, false); at.(now, t0 + 3700); boot.(dir, clock, one, [])
  report.("V1 live mark after a failed backfill / held after healthy restart / mark after success (expect 0 / 1 / 3700)", {m1, length(held.(me, "references")), mark.()})
  at.(now, t0 + 3800); boot.(dir, clock, one, [])
  report.("V1b another restart: held, duplicates (expect 1, 0)", count.(me, "references"))
end)

try_.("V2", fn ->
  {dir, now, clock} = fresh.("v2", one); mention.(:me_fx, t0 + 1800, 1); N.fail(:me_fx, true); at.(now, t0 + 3600)
  boot.(dir, clock, one, recheck_ms: 700); N.fail(:me_fx, false); Process.sleep(900)
  report.("V2 failed connect, recheck in the same process: held / mark (expect 1 / 3600)", {length(held.(me, "references")), mark.()})
end)

try_.("V3", fn ->
  {dir, now, clock} = fresh.("v3", one); for i <- 1..120, do: mention.(:me_fx, t0 + 1000 + i, i)
  N.put(:fail_page, 2); at.(now, t0 + 3600); boot.(dir, clock, one, []); a = length(held.(me, "references")); m = mark.()
  N.put(:fail_page, nil); at.(now, t0 + 3700); boot.(dir, clock, one, [])
  report.("V3 120 mentions, notifications page 2 fails, healthy restart: held before / mark before / held, duplicates after (expect 50 / 0 / {120, 0})", {a, m, count.(me, "references")})
end)

try_.("V4", fn ->
  # A notifications listener with room for all 300: the built-in listener keeps only 200.
  {dir, now, clock} = fresh.("v4", one)
  :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, room)
  for i <- 1..300, do: mention.(:me_fx, t0 + 1000 + i, i)
  at.(now, t0 + 3600); boot.(dir, clock, one, [])
  a = length(held.(me, "n")); u = stat.(me, "n", :unrecovered); m = mark.()
  at.(now, t0 + 3700); boot.(dir, clock, one, [])
  report.("V4 300 mentions, 5-page bound: held / unrecovered / mark / held after restart (expect the cut to be counted)", {a, u, m, length(held.(me, "n"))})
end)

try_.("V5", fn ->
  {dir, now, clock} = fresh.("v5", both); mention.(:other_fx, t0 + 1800, 1); at.(now, t0 + 3600); boot.(dir, clock, one, [])
  m = mark.(); at.(now, t0 + 3700); boot.(dir, clock, both, [])
  report.("V5 two accounts; B absent from one run while A succeeds: mark / B's gap held (expect 0 / 1)", {m, length(held.(other, "references"))})
end)

try_.("V6", fn ->
  {dir, now, clock} = fresh.("v6", both); mention.(:me_fx, t0 + 1800, 1); mention.(:other_fx, t0 + 1800, 2); N.fail(:other_fx, true)
  at.(now, t0 + 3600); boot.(dir, clock, both, []); m1 = mark.()
  at.(now, t0 + 3700); boot.(dir, clock, both, []); a = count.(me, "references")
  N.fail(:other_fx, false); at.(now, t0 + 3800); boot.(dir, clock, both, [])
  report.("V6 B's backfill fails twice, A healthy: mark held / A held, dup / B held after recovery / mark (expect 0 / {1,0} / 1 / 3800)", {m1, a, length(held.(other, "references")), mark.()})
end)

try_.("V7", fn ->
  {dir, now, clock, first} = setup.("v7"); g = gap.(first, t0 + 100, 3); R.repo(g); R.put(:down, true); at.(now, stale); boot.(dir, clock, one, [])
  u = stat.(me, "f", :unrecovered); R.put(:down, false); live = tid.(stale + 60, 9); R.repo(g ++ [live]); at.(now, stale + 60); rec.(live, stale + 60); Process.sleep(200)
  at.(now, stale + 70); boot.(dir, clock, one, []); Process.sleep(200); a = count.(me, "f")
  at.(now, stale + 80); boot.(dir, clock, one, []); Process.sleep(200)
  report.("V7 PDS not found, live record, two healthy restarts: unrecovered / held, dup / held, dup (expect 1 / {5,0} / {5,0})", {u, a, count.(me, "f")})
end)

try_.("V8", fn ->
  {dir, now, clock, first} = setup.("v8"); g = gap.(first, t0 + 100, 250); R.repo(g); R.put(:fail_page, 2); at.(now, stale); boot.(dir, clock, one, []); Process.sleep(200)
  l1 = tid.(stale + 60, 8); R.repo(g ++ [l1]); at.(now, stale + 60); rec.(l1, stale + 60); Process.sleep(200)
  at.(now, stale + 70); boot.(dir, clock, one, []); Process.sleep(200)
  l2 = tid.(stale + 130, 9); R.repo(g ++ [l1, l2]); at.(now, stale + 130); rec.(l2, stale + 130); Process.sleep(200)
  R.put(:fail_page, nil); at.(now, stale + 140); boot.(dir, clock, one, []); Process.sleep(500)
  report.("V8 page 2 fails on two starts, a live record after each, then healthy: held, dup (expect {253, 0})", count.(me, "f"))
end)

try_.("V9", fn ->
  {dir, now, clock, first} = setup.("v9"); R.repo(gap.(first, t0 + 100, 3)); R.put(:delay, 500); at.(now, stale)
  start_l.(dir, clock, []); :ok = Listeners.track(me, :me_fx); Process.sleep(120)
  R.put(:delay, 0); at.(now, stale + 10); boot.(dir, clock, one, []); Process.sleep(300)
  report.("V9 restart during a records backfill: held, dup (expect {4, 0})", count.(me, "f"))
end)

try_.("V10", fn ->
  {dir, now, clock, first} = setup.("v10"); R.repo(gap.(first, t0 + 100, 3)); R.put(:down, true); at.(now, stale)
  boot.(dir, clock, one, recheck_ms: 500); R.put(:down, false); Process.sleep(1000)
  report.("V10 records backfill fails, PDS returns, no restart: held after the recheck (4 = retried in-process)", length(held.(me, "f")))
end)
IO.puts("DONE")

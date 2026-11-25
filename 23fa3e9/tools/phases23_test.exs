# Multi-phase M2 checks for 23fa3e9 (D-019): the room an upgrade keeps for its timed receipts, across saves, restarts, kinds of listener and operator actions. STEP runs in a fresh process.
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

report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 40)}") end
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


test = System.get_env("TEST"); step = System.get_env("STEP"); k_saves = String.to_integer(System.get_env("K") || "0")
dir = "/work/q-state"; File.mkdir_p!(dir)
{:ok, now} = Agent.start(fn -> t0 end); R.reset(); N.reset(); clock = fn -> Agent.get(now, & &1) end
floor = fn did, id -> if function_exported?(Updates, :forgotten_through, 3), do: (case Updates.forgotten_through(did, id) do {:ok, x} when is_integer(x) -> x - t0; {:ok, x} -> x; e -> e end), else: :absent end
ack_all = fn did, id ->
  {:ok, r} = Updates.read(did, limit: 5000, listener: id)
  if r.updates != [], do: Updates.ack(did, List.last(r.updates)["seq"], id)
end
uri_m = fn at, n -> "at://#{bob}/#{post}/#{tid.(at, n)}" end
uri_r = fn at, n -> "at://#{alice}/#{post}/#{tid.(at, n)}" end
files = fn -> Path.wildcard(Path.join([dir, "listeners", "did:*.json"])) end
touch = fn t -> for f <- files.(), do: File.touch!(f, t) end
add_sorted = fn pairs -> pairs |> Enum.sort() |> Enum.each(fn {a, n} -> mention.(:me_fx, t0 + a, n) end) end
# The account file as saved: receipts held, how many still carry the upgrade's stamp, settling, floor.
file = fn -> case Enum.find(files.(), &String.contains?(&1, me)) do nil -> %{}; f -> Jason.decode!(File.read!(f)) end end
rstate = fn id, stamp ->
  d = file.(); rs = get_in(d, ["receipts", id]) || []
  {length(rs), Enum.count(rs, &String.ends_with?(&1, ":#{t0 + stamp}")), get_in(d, ["settling", id]) |> then(fn %{} = m -> Map.update(m, "at", nil, &(&1 - t0)); x when is_integer(x) -> {:stamp, x - t0}; x -> x end),
   floor.(me, id)}
end
start = fn accounts, at_t ->
  at.(now, at_t); start_l.(dir, clock, [])
  for {did, fx} <- accounts, do: :ok = Listeners.track(did, fx)
  Process.sleep(60); connect.(); Process.sleep(600)
end
save_live = fn id, n0, k, at0 ->
  for i <- 1..k//1 do
    at.(now, at0 + div(i, 10))
    {:ok, _} = Updates.commit([{me, id, %{"uri" => "at://#{bob}/#{post}/live-#{n0 + i}", "source" => "links", "from" => bob}}], nil)
  end
end
old = for i <- 1..1500, do: {1000 + i, i}
sweep = for a <- 1950..2700//50, do: {a, 7000 + a}
held_sweep = fn u -> Enum.filter(sweep, fn {a, n} -> MapSet.member?(u, uri_m.(t0 + a, n)) end) |> Enum.map(&elem(&1, 0)) end
earlier = fn extra ->
  # hum.11: 1,500 mentions acknowledged, 1,000 receipts kept (its limit), shared mark 2600, last write 2650.
  add_sorted.(old); boot.(dir, clock, one, []); Process.sleep(200); ack_all.(me, "references")
  extra.()
  {:ok, _} = Updates.commit(for({a, i} <- old, do: {me, "references", %{"uri" => uri_m.(t0 + a, i), "receipt_only" => true}}), nil)
  {:ok, _} = Updates.commit([], {"listeners_live", t0 + 2600}); stop.(Listeners); stop.(Updates); touch.(t0 + 2650)
end
case {test, step} do
  # S: K live saves before the first backfill since the upgrade succeeds (the service is down), then it succeeds.
  {"sat", "1"} -> earlier.(fn -> :ok end); report.("S1 earlier state written", rstate.("references", 2650))
  {"sat", "2"} ->
    N.fail(:me_fx, true); add_sorted.(old ++ sweep); start.(one, t0 + 3600)
    report.("S2 first start, backfill failing: receipts / at the stamp / settling / floor", rstate.("references", 2650))
    save_live.("references", 0, k_saves, t0 + 3600)
    report.("S2 after #{k_saves} live saves: receipts / at the stamp / settling / floor", rstate.("references", 2650))
  {"sat", "3"} ->
    add_sorted.(old ++ sweep); start.(one, t0 + 3700)
    u = MapSet.new(held.(me, "references"))
    od = Enum.filter(old, fn {a, i} -> MapSet.member?(u, uri_m.(t0 + a, i)) end) |> Enum.map(&elem(&1, 0))
    report.("S3 old delivered again: earliest / latest date / count", {Enum.min(od, fn -> nil end), Enum.max(od, fn -> nil end), length(od)})
    report.("S3 backfill succeeds: late mentions held (dated 1950..2700; hum.11 last wrote at 2650, its shared mark 2600, margin from 2000) / old delivered again / unrecovered / receipts, stamp, settling, floor",
      {held_sweep.(u), Enum.count(old, fn {a, i} -> MapSet.member?(u, uri_m.(t0 + a, i)) end), stat.(me, "references", :unrecovered), rstate.("references", 2650)})
    save_live.("references", 100_000, 1100, t0 + 3800)
    report.("S3 then 1,100 live saves: receipts, stamp, settling, floor", rstate.("references", 2650))
  {"sat", "4"} ->
    add_sorted.(old ++ sweep); start.(one, t0 + 4000)
    u = held.(me, "references")
    report.("S4 next start: held, duplicates / old delivered again / floor", {{length(u), length(u) - length(Enum.uniq(u))}, Enum.count(old, fn {a, i} -> uri_m.(t0 + a, i) in u end), floor.(me, "references")})

  # C: is the room released after a first backfill that was cut? Starts with the service up, no live saves.
  {"cutrel", "1"} -> earlier.(fn -> :ok end); report.("C1 earlier state written", :ok)
  {"cutrel", s} ->
    i = String.to_integer(s); add_sorted.(old ++ sweep); start.(one, t0 + 3500 + 100 * i); Process.sleep(1500)
    u = MapSet.new(held.(me, "references"))
    report.("C#{s} start #{i - 1} at #{3500 + 100 * i}, service up: late mentions held so far / unrecovered / receipts, stamp, settling, floor / live mark",
      {held_sweep.(u), stat.(me, "references", :unrecovered), rstate.("references", 2650), mark.()})
  # T: restarts before the backfill succeeds, with saves in between; then it succeeds; then saves let the timed ones go.
  {"restart", "1"} -> earlier.(fn -> :ok end); report.("T1 earlier state written", :ok)
  {"restart", s} when s in ["2", "3", "4"] ->
    N.fail(:me_fx, true); add_sorted.(old ++ sweep); start.(one, t0 + 3500 + 10 * String.to_integer(s))
    report.("T#{s} start #{String.to_integer(s) - 1}, backfill failing: receipts / at the stamp / settling / floor", rstate.("references", 2650))
    save_live.("references", 1000 * String.to_integer(s), 300, t0 + 3500 + 10 * String.to_integer(s))
    report.("T#{s} after 300 more live saves", rstate.("references", 2650))
  {"restart", "5"} ->
    add_sorted.(old ++ sweep); start.(one, t0 + 3700)
    u = MapSet.new(held.(me, "references"))
    report.("T5 backfill succeeds: late mentions held / old delivered again / receipts, stamp, settling, floor",
      {held_sweep.(u), Enum.count(old, fn {a, i} -> MapSet.member?(u, uri_m.(t0 + a, i)) end), rstate.("references", 2650)})
  {"restart", "6"} ->
    add_sorted.(old ++ sweep); start.(one, t0 + 3800)
    save_live.("references", 50_000, 1000, t0 + 3800)
    report.("T6 next start, then 1,000 live saves: receipts, stamp, settling, floor", rstate.("references", 2650))
    stop.(Listeners); stop.(Updates); start.(one, t0 + 3900)
    u = held.(me, "references")
    report.("T6 restart: held, duplicates / old or swept delivered twice", {{length(u), length(u) - length(Enum.uniq(u))}, length(u) - length(Enum.uniq(u))})

  # L: a records listener and the live listener of one account; the live backfill succeeds, the records backfill fails.
  {"records", "1"} ->
    earlier.(fn ->
      :ok = Listeners.listen(me, "f", %{"source" => "records", "authors" => [alice], "collections" => [post]}, %{"count" => 200, "age_seconds" => 604_800})
      Process.sleep(100)
      {:ok, _} = Updates.commit(for(i <- 1..1000, do: {me, "f", %{"uri" => uri_r.(t0 + 1000 + i, i), "receipt_only" => true}}), nil)
    end)
    report.("L1 earlier state: references and records listener f, 1,000 receipts each", {rstate.("references", 2650), rstate.("f", 2650)})
  {"records", "2"} ->
    R.put(:down, true); add_sorted.(old); start.(one, t0 + 3600)
    report.("L2 first start, live backfill ok, records PDS down: references / f (receipts, stamp, settling, floor)", {rstate.("references", 2650), rstate.("f", 2650)})
    for i <- 1..k_saves//1 do at.(now, t0 + 3600 + div(i, 10)); {:ok, _} = Updates.commit([{me, "f", %{"uri" => uri_r.(t0 + 3600, 50_000 + i), "source" => "records", "from" => alice}}], nil) end
    report.("L2 after #{k_saves} live records saved on f: f", rstate.("f", 2650))
  {"records", "3"} ->
    R.repo(for i <- 1..20, do: tid.(t0 + 2300 + i, 9000 + i)); add_sorted.(old); start.(one, t0 + 3700); Process.sleep(1500)
    report.("L3 records PDS back: f (receipts, stamp, settling, floor) / records dated 2301..2320 held (of 20) / unrecovered", {rstate.("f", 2650), (hf = MapSet.new(held.(me, "f")); Enum.count(1..20, &MapSet.member?(hf, uri_r.(t0 + 2300 + &1, 9000 + &1)))), stat.(me, "f", :unrecovered)})

  # P: a paused listener keeps its room; resumed, the next backfill releases it. U: a listener removed while settling.
  {"pause", "1"} ->
    earlier.(fn ->
      :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 200, "age_seconds" => 604_800})
      Process.sleep(100)
      {:ok, _} = Updates.commit(for(i <- 1..1000, do: {me, "n", %{"uri" => uri_m.(t0 + 1000 + i, 20_000 + i), "receipt_only" => true}}), nil)
      if function_exported?(Listeners, :pause, 4), do: Listeners.pause(me, "n", true), else: :absent
    end)
    report.("P1 earlier state: n paused, 1,000 receipts", rstate.("n", 2650))
  {"pause", "2"} ->
    add_sorted.(old); start.(one, t0 + 3600)
    report.("P2 first start, n paused, backfill ok: references settling / n (receipts, stamp, settling, floor)", {elem(rstate.("references", 2650), 2), rstate.("n", 2650)})
    :ok = Listeners.pause(me, "n", false); Process.sleep(300)
    report.("P2 n resumed (same process): n", rstate.("n", 2650))
  {"pause", "3"} ->
    add_sorted.(old); start.(one, t0 + 3700)
    report.("P3 next start, n not paused, backfill ok: n", rstate.("n", 2650))
  {"unlisten", "1"} -> earlier.(fn -> :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 200, "age_seconds" => 604_800}); Process.sleep(100)
      {:ok, _} = Updates.commit(for(i <- 1..1000, do: {me, "n", %{"uri" => uri_m.(t0 + 1000 + i, 20_000 + i), "receipt_only" => true}}), nil) end)
    report.("U1 earlier state", rstate.("n", 2650))
  {"unlisten", "2"} ->
    N.fail(:me_fx, true); start.(one, t0 + 3600)
    report.("U2 first start, backfill failing: n", rstate.("n", 2650))
    r1 = Listeners.unlisten(me, "n"); Process.sleep(100)
    report.("U2 n removed: result / settling keys left in the file", {r1, Map.keys(file.()["settling"] || %{})})
    :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 200, "age_seconds" => 604_800}); Process.sleep(100)
    save_live.("n", 0, 1100, t0 + 3600)
    report.("U2 n added again, 1,100 saves: n (receipts, stamp, settling, floor)", rstate.("n", 2650))

  # B: the listener's count lowered while it settles (1,000 receipts, count 500 -> limit 2,000, then count 250 -> 1,000).
  {"bounds", "1"} -> earlier.(fn -> :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 500, "age_seconds" => 604_800}); Process.sleep(100)
      {:ok, _} = Updates.commit(for(i <- 1..2000, do: {me, "n", %{"uri" => uri_m.(t0 + 1000 + i, 20_000 + i), "receipt_only" => true}}), nil) end)
    report.("B1 earlier state: n count 500", rstate.("n", 2650))
  {"bounds", "2"} ->
    N.fail(:me_fx, true); start.(one, t0 + 3600)
    report.("B2 first start, backfill failing: n", rstate.("n", 2650))
    :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 250, "age_seconds" => 604_800}); Process.sleep(100)
    save_live.("n", 0, 1, t0 + 3600)
    report.("B2 count lowered to 250, one save: n", rstate.("n", 2650))
    save_live.("n", 10, 50, t0 + 3601)
    report.("B2 50 more saves: n", rstate.("n", 2650))
end
IO.puts("DONE")

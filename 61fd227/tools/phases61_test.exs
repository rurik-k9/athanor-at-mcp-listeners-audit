# Multi-phase checks for 61fd227: review duplicates F1 and F2 across builds, and the M2 margin limit. STEP runs in a fresh process.
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

test = System.get_env("TEST"); step = System.get_env("STEP"); live? = System.get_env("LIVE") == "1"
dir = "/work/q-state"; File.mkdir_p!(dir)
{:ok, now} = Agent.start(fn -> t0 end); R.reset(); N.reset(); clock = fn -> Agent.get(now, & &1) end
floor = fn did, id -> if function_exported?(Updates, :forgotten_through, 3), do: (case Updates.forgotten_through(did, id) do {:ok, x} when is_integer(x) -> x - t0; {:ok, x} -> x; e -> e end), else: :absent end
ack_all = fn did, id ->
  {:ok, r} = Updates.read(did, limit: 5000, listener: id)
  if r.updates != [], do: Updates.ack(did, List.last(r.updates)["seq"], id)
end
uri_m = fn at, n -> "at://#{bob}/#{post}/#{tid.(at, n)}" end
files = fn -> Path.wildcard(Path.join([dir, "listeners", "did:*.json"])) end
touch = fn t -> for f <- files.(), do: File.touch!(f, t) end
add_sorted = fn pairs -> pairs |> Enum.sort() |> Enum.each(fn {a, n} -> mention.(:me_fx, t0 + a, n) end) end
start = fn accounts, at_t ->
  at.(now, at_t); start_l.(dir, clock, [])
  for {did, fx} <- accounts, do: :ok = Listeners.track(did, fx)
  if live?, do: {:ok, _} = Updates.commit([{me, "references", %{"uri" => "at://#{bob}/#{post}/live-before-backfill", "source" => "links", "from" => bob}}], nil)
  Process.sleep(60); connect.(); Process.sleep(400)
end
old = for i <- 1..1500, do: {1000 + i, i}
sweep = for a <- 1950..2700//50, do: {a, 7000 + a}
case {test, step} do
  {"m2", "1"} ->
    add_sorted.(old); boot.(dir, clock, one, []); Process.sleep(200); ack_all.(me, "references")
    {:ok, _} = Updates.commit(for({a, i} <- old, do: {me, "references", %{"uri" => uri_m.(t0 + a, i), "receipt_only" => true}}), nil)
    {:ok, _} = Updates.commit([], {"listeners_live", t0 + 2600}); stop.(Listeners); stop.(Updates); touch.(t0 + 2650)
    report.("Q1 earlier state: 1,500 acknowledged, shared mark 2600, last write 2650", :ok)
  {"m2", "2"} ->
    add_sorted.(old ++ sweep ++ [{3000, 9001}]); start.(one, t0 + 3600)
    u = MapSet.new(held.(me, "references"))
    report.("Q2 first start#{if live?, do: ", live save first", else: ""}: late mentions held by date (1950..2700, margin starts 2000, last write 2650) / 3000 / old delivered again / floor / unrecovered",
      {Enum.filter(sweep, fn {a, n} -> MapSet.member?(u, uri_m.(t0 + a, n)) end) |> Enum.map(&elem(&1, 0)), MapSet.member?(u, uri_m.(t0 + 3000, 9001)),
       Enum.count(old, fn {a, i} -> MapSet.member?(u, uri_m.(t0 + a, i)) end), floor.(me, "references"), stat.(me, "references", :unrecovered)})
  {"m2", "3"} ->
    add_sorted.(old ++ sweep ++ [{3000, 9001}]); start.(one, t0 + 3700)
    u = held.(me, "references")
    report.("Q3 next start: unread, duplicates / old delivered again / floor (expect no duplicate, old 0)",
      {{length(u), length(u) - length(Enum.uniq(u))}, Enum.count(old, fn {a, i} -> uri_m.(t0 + a, i) in u end), floor.(me, "references")})
  {"f1", "1"} ->
    # The new build: the listener begins at 100; X (dated 200) delivered at 300, not acknowledged; the marker is written.
    start.(one, t0 + 100); stop.(Listeners); stop.(Updates)
    add_sorted.([{200, 1}]); start.(one, t0 + 300)
    report.("F1a new build: X held", uri_m.(t0 + 200, 1) in held.(me, "references"))
  {"f1", "2"} ->
    # hum.11 (rollback): a receipt for a record dated 900, then 999 more, then X again as a moderation drop: bare receipts.
    # The store only, as live moderation drops are saved: nothing is read back here.
    at.(now, t0 + 1000); {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
    {:ok, _} = Updates.commit([{me, "references", %{"uri" => uri_m.(t0 + 900, 900), "receipt_only" => true}}], nil)
    for i <- 1..999 do at.(now, t0 + 1000 + 4 * i); {:ok, _} = Updates.commit([{me, "references", %{"uri" => uri_m.(t0 + 1000 + 4 * i, 2000 + i), "receipt_only" => true}}], nil) end
    at.(now, t0 + 5000); {:ok, _} = Updates.commit([{me, "references", %{"uri" => uri_m.(t0 + 200, 1), "receipt_only" => true}}], nil)
    stop.(Listeners); stop.(Updates); touch.(t0 + 5000)
    report.("F1b earlier build: receipts written", :ok)
  {"f1", "3"} ->
    add_sorted.([{200, 1}, {900, 900}, {5050, 5050}]); start.(one, t0 + 5100)
    u = held.(me, "references")
    report.("F1c upgrade again: record dated 900 (acknowledged under hum.11, receipt let go) delivered again / new mention 5050 held / floor (expect false / true)",
      {uri_m.(t0 + 900, 900) in u, uri_m.(t0 + 5050, 5050) in u, floor.(me, "references")})
  {"f2", "1"} ->
    start.(one, t0 + 100)
    :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 200, "age_seconds" => 604_800})
    Process.sleep(200); report.("F2a new build: listener n with count 200", :ok)
  {"f2", "2"} ->
    # hum.11: 1,100 mentions delivered and acknowledged in n (the oldest 100 receipts let go at 1,000), then count raised to 300.
    start.(one, t0 + 200)
    for i <- 1..1100 do at.(now, t0 + 1000 + i); {:ok, _} = Updates.commit([{me, "n", %{"uri" => uri_m.(t0 + 1000 + i, 3000 + i), "receipt_only" => true}}], nil) end
    :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, %{"count" => 300, "age_seconds" => 604_800})
    stop.(Listeners); stop.(Updates); touch.(t0 + 2200)
    report.("F2b earlier build: 1,100 receipts, bounds raised", :ok)
  {"f2", "3"} ->
    add_sorted.((for i <- 1..1100, do: {1000 + i, 3000 + i}) ++ [{4000, 4000}]); start.(one, t0 + 5100)
    {:ok, r} = Updates.read(me, peek: true, limit: 5000, listener: "n"); u = Enum.map(r.updates, & &1["uri"])
    report.("F2c upgrade again: acknowledged under hum.11 delivered again (of the 100 let go) / new mention 4000 held / floor (expect 0 / true)",
      {Enum.count(1..100, &(uri_m.(t0 + 1000 + &1, 3000 + &1) in u)), uri_m.(t0 + 4000, 4000) in u, floor.(me, "n")})
end
IO.puts("DONE")

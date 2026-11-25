# Multi-phase checks (migration, rollback): each STEP runs in a fresh process, possibly under another build.
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

# TEST=migrate|rollback, STEP=1..4, LIVE=1 adds a live save before the first backfill. State stays in /work/p-state.
test = System.get_env("TEST"); step = System.get_env("STEP"); live? = System.get_env("LIVE") == "1"
dir = "/work/p-state"; File.mkdir_p!(dir)
{:ok, now} = Agent.start(fn -> t0 end); R.reset(); N.reset(); clock = fn -> Agent.get(now, & &1) end
floor = fn did, id -> if function_exported?(Updates, :forgotten_through, 3), do: (case Updates.forgotten_through(did, id) do {:ok, x} when is_integer(x) -> x - t0; {:ok, x} -> x; e -> e end), else: :absent end
amark = fn did -> case Updates.stream_cursor("listeners_live:" <> did) do x when is_integer(x) -> x - t0; x -> x end end
ack_all = fn did, id ->
  {:ok, r} = Updates.read(did, limit: 5000, listener: id)
  if r.updates != [], do: Updates.ack(did, List.last(r.updates)["seq"], id)
end
uri_m = fn at, n -> "at://#{bob}/#{post}/#{tid.(at, n)}" end
files = fn -> Path.wildcard(Path.join([dir, "listeners", "did:*.json"])) end
touch = fn t -> for f <- files.(), do: File.touch!(f, t) end
old = for i <- 1..1500, do: {t0 + 1000 + i, i}
for {at, i} <- old, do: mention.(:me_fx, at, i)
old_uris = MapSet.new(old, fn {at, i} -> uri_m.(at, i) end)
summary = fn did, extra ->
  u = held.(did, "references")
  {length(u), Enum.count(u, &MapSet.member?(old_uris, &1)), Enum.filter(extra, fn {_, x} -> x in u end) |> Enum.map(&elem(&1, 0))}
end
seed = fn accounts ->
  # The state an earlier build leaves: 1,500 acknowledged mentions (receipts), the shared mark, files last written at 2650.
  boot.(dir, clock, accounts, []); Process.sleep(200); ack_all.(me, "references")
  {:ok, _} = Updates.commit(for({at, i} <- old, do: {me, "references", %{"uri" => uri_m.(at, i), "receipt_only" => true}}), nil)
  {:ok, _} = Updates.commit([], {"listeners_live", t0 + 2600}); shared = Updates.stream_cursor("listeners_live") - t0
  stop.(Listeners); stop.(Updates); touch.(t0 + 2650); shared
end
start_new = fn accounts, at_t ->
  at.(now, at_t); start_l.(dir, clock, [])
  for {did, fx} <- accounts, do: :ok = Listeners.track(did, fx)
  if live?, do: {:ok, _} = Updates.commit([{me, "references", %{"uri" => "at://#{bob}/#{post}/live-before-backfill", "source" => "links", "from" => bob}}], nil)
  Process.sleep(60); connect.(); Process.sleep(300)
end
case {test, step} do
  {"migrate", "1"} -> s = seed.(both); report.("M1 earlier state written: files / shared mark", {length(files.()), s})
  {"migrate", "2"} ->
    mention.(:me_fx, t0 + 2550, 2001); mention.(:me_fx, t0 + 3000, 2002); mention.(:other_fx, t0 + 3100, 2003)
    start_new.(one, t0 + 3600)
    report.("M2 first start, B absent#{if live?, do: ", live save first", else: ""}: A unread / of which old / held of [2550 margin, 3000 gap] / A floor / marks A, B / A unrecovered (expect {2,0,[2550,3000]} or +1 live; B mark 2600)",
      {summary.(me, [{2550, uri_m.(t0 + 2550, 2001)}, {3000, uri_m.(t0 + 3000, 2002)}]), floor.(me, "references"), {amark.(me), amark.(other)}, stat.(me, "references", :unrecovered)})
  {"migrate", s} when s in ["3", "4"] ->
    mention.(:me_fx, t0 + 2550, 2001); mention.(:me_fx, t0 + 3000, 2002); mention.(:other_fx, t0 + 3100, 2003)
    start_new.(both, t0 + 3600 + 100 * String.to_integer(s))
    report.("M#{s} start #{String.to_integer(s) - 1} of the new build, both accounts: A held, dup / B held 3100 / floors A, B / marks A, B (expect A unchanged, B's 3100 held, no duplicate)",
      {count.(me, "references"), uri_m.(t0 + 3100, 2003) in held.(other, "references"), {floor.(me, "references"), floor.(other, "references")}, {amark.(me), amark.(other)}})
  {"selfstate", "1"} ->
    # U's own-build case done realistically: receipts saved after the records they stand for are dated.
    N.put(:items, %{}); boot.(dir, clock, one, []); Process.sleep(200); at.(now, t0 + 2600)
    {:ok, _} = Updates.commit(for({at, i} <- old, do: {me, "references", %{"uri" => uri_m.(at, i), "receipt_only" => true}}), nil)
    r = {amark.(me), floor.(me, "references")}; stop.(Listeners); stop.(Updates)
    report.("S1 state written by the same build, receipts saved at 2600: own mark / floor", r)
  {"selfstate", "2"} ->
    mention.(:me_fx, t0 + 2550, 9999); start_new.(one, t0 + 3600)
    report.("S2 start, a late mention at 2550 in the gap: unread / of which old / held of [2550] / floor / unrecovered (U: expect old = 0)", {summary.(me, [{2550, uri_m.(t0 + 2550, 9999)}]), floor.(me, "references"), stat.(me, "references", :unrecovered)})
  {"rollback", "1"} -> s = seed.(one); report.("R1 earlier state written: files / shared mark", {length(files.()), s})
  {"rollback", "2"} ->
    mention.(:me_fx, t0 + 3000, 3001); start_new.(one, t0 + 3600)
    r = summary.(me, [{3000, uri_m.(t0 + 3000, 3001)}]); ack_all.(me, "references")
    report.("R2 upgrade: unread / of which old / held of [3000] (expect {1, 0, [3000]})", r)
  {"rollback", "3"} ->
    mention.(:me_fx, t0 + 3000, 3001); mention.(:me_fx, t0 + 4000, 3002); start_new.(one, t0 + 4600)
    r = summary.(me, [{3000, uri_m.(t0 + 3000, 3001)}, {4000, uri_m.(t0 + 4000, 3002)}]); ack_all.(me, "references")
    # The earlier build then delivers 1,100 more (dated 3700-4250), acknowledged: its receipts push out older ones without a trace.
    {:ok, _} = Updates.commit(for(i <- 1..1100, do: {me, "references", %{"uri" => uri_m.(t0 + 3700 + div(i, 2), 4000 + i), "receipt_only" => true}}), nil)
    stop.(Listeners); stop.(Updates); touch.(t0 + 4650)
    report.("R3 rollback to the earlier build: unread / of which old / held of [3000 again, 4000] (duplicates of 3000 expected by hum's changelog)", r)
  {"rollback", "4"} ->
    # Added oldest first, as the fake service serves them newest first by insertion.
    ([{3000, 3001}, {4000, 3002}, {4550, 3003}, {5000, 3004}] ++ for(i <- 1..1100, do: {3700 + div(i, 2), 4000 + i}))
    |> Enum.sort() |> Enum.each(fn {a, n} -> mention.(:me_fx, t0 + a, n) end)
    burst = MapSet.new(1..1100, &uri_m.(t0 + 3700 + div(&1, 2), 4000 + &1))
    start_new.(one, t0 + 5600)
    u = held.(me, "references")
    report.("R4 upgrade again: unread / of which old / held of [3000, 4000, 4550 late in margin, 5000] / acknowledged under the earlier build delivered again / floor / unrecovered (expect {2, 0, [4550, 5000]}, 0)",
      {summary.(me, [{3000, uri_m.(t0 + 3000, 3001)}, {4000, uri_m.(t0 + 4000, 3002)}, {4550, uri_m.(t0 + 4550, 3003)}, {5000, uri_m.(t0 + 5000, 3004)}]),
       Enum.count(u, &MapSet.member?(burst, &1)), floor.(me, "references"), stat.(me, "references", :unrecovered)})
end
IO.puts("DONE")

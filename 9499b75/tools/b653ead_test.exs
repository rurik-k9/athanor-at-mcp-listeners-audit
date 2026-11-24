# Checks for commit b653ead (per-account live marks, cut and records retries), on released or overlaid beams.
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

try_.("W1", fn ->
  # V1 with the per-account mark: a failed first backfill must not move the account's own mark.
  {dir, now, clock} = fresh.("w1", one); mention.(:me_fx, t0 + 1800, 1); N.fail(:me_fx, true)
  at.(now, t0 + 3600); boot.(dir, clock, one, []); m1 = amark.(me)
  N.fail(:me_fx, false); at.(now, t0 + 3700); boot.(dir, clock, one, []); Process.sleep(200)
  report.("W1 failed first backfill: own mark / held after healthy restart / own mark after (expect nil / 1 / 3700)", {m1, length(held.(me, "references")), amark.(me)})
end)

try_.("W2", fn ->
  # Fix 1 (V4): a cut read is counted, holds the mark, and retries step past held pages.
  {dir, now, clock} = fresh.("w2", one)
  :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, room)
  for i <- 1..600, do: mention.(:me_fx, t0 + 1000 + i, i)
  at.(now, t0 + 3600); boot.(dir, clock, one, []); Process.sleep(200)
  a = count.(me, "n"); u = stat.(me, "n", :unrecovered); m = amark.(me)
  at.(now, t0 + 3700); boot.(dir, clock, one, []); Process.sleep(200); b = count.(me, "n")
  at.(now, t0 + 3800); boot.(dir, clock, one, []); Process.sleep(200)
  report.("W2 600 mentions, three starts: held,dup / unrecovered / mark / held,dup / held,dup, mark (expect {250,0} / >=1 / held / {500,0} / {600,0}, 3800)",
    {a, u, m, b, {count.(me, "n"), amark.(me)}})
end)

try_.("W3", fn ->
  # Fix 1 without a restart: the 5-minute recheck should reach the rest.
  {dir, now, clock} = fresh.("w3", one)
  :ok = Listeners.listen(me, "n", %{"source" => "notifications", "reasons" => ["mention"]}, room)
  for i <- 1..400, do: mention.(:me_fx, t0 + 1000 + i, i)
  at.(now, t0 + 3600); boot.(dir, clock, one, recheck_ms: 600); Process.sleep(2500)
  report.("W3 400 mentions, recheck every 0.6 s, no restart: held, dup / own mark (expect {400, 0} / an integer)", {count.(me, "n"), amark.(me)})
end)

try_.("W4", fn ->
  # Fix 2 (V5) and the per-account marks.
  {dir, now, clock} = fresh.("w4", both); mention.(:other_fx, t0 + 1800, 1); at.(now, t0 + 3600); boot.(dir, clock, one, []); Process.sleep(100)
  a = {amark.(me), amark.(other)}
  at.(now, t0 + 3700); boot.(dir, clock, both, []); Process.sleep(200)
  report.("W4 B absent from one run: marks (A, B) after it / B held / marks after B returns (expect {3600, 0 or nil} / 1 / {3700, 3700})", {a, length(held.(other, "references")), {amark.(me), amark.(other)}})
end)

try_.("W5", fn ->
  # Fix 3 (V10) repeated: PDS down across several rechecks, then back.
  {dir, now, clock, first} = setup.("w5"); R.repo(gap.(first, t0 + 100, 3)); R.put(:down, true); at.(now, stale)
  boot.(dir, clock, one, recheck_ms: 300); Process.sleep(1300); u = stat.(me, "f", :unrecovered)
  R.put(:down, false); Process.sleep(900)
  report.("W5 PDS down for about 4 rechecks, then back, no restart: unrecovered while down / held, dup after (observed / expect {4, 0})", {u, count.(me, "f")})
end)

try_.("W6", fn ->
  # An account tracked after the stream connected, with a mention in its gap.
  {dir, now, clock} = fresh.("w6", one); at.(now, t0 + 3600); boot.(dir, clock, one, []); Process.sleep(100)
  mention.(:other_fx, t0 + 3500, 1); :ok = Listeners.track(other, :other_fx); Process.sleep(600)
  a = length(held.(other, "references")); m = amark.(other)
  at.(now, t0 + 3700); boot.(dir, clock, both, []); Process.sleep(200)
  report.("W6 B tracked while connected: B held / B mark in that run / B held after a restart (expect 0 or 1 / not past an uncovered gap / 0 or 1, no loss across both)", {a, m, length(held.(other, "references"))})
end)

try_.("W7", fn ->
  # V2 under b653ead: a failed connect backfill, recovered by the recheck in the same process.
  {dir, now, clock} = fresh.("w7", one); mention.(:me_fx, t0 + 1800, 1); N.fail(:me_fx, true); at.(now, t0 + 3600)
  boot.(dir, clock, one, recheck_ms: 500); m1 = amark.(me); N.fail(:me_fx, false); Process.sleep(900)
  report.("W7 failed connect, recheck in the same process: own mark before / held / own mark after (expect nil / 1 / 3600)", {m1, length(held.(me, "references")), amark.(me)})
end)

try_.("W8", fn ->
  # Two accounts, both healthy: one backfill each, both marks set, nothing duplicated.
  {dir, now, clock} = fresh.("w8", both); mention.(:me_fx, t0 + 1800, 1); mention.(:other_fx, t0 + 1800, 2)
  at.(now, t0 + 3600); boot.(dir, clock, both, []); Process.sleep(200)
  at.(now, t0 + 3700); boot.(dir, clock, both, []); Process.sleep(200)
  report.("W8 two healthy accounts, two starts: A held,dup / B held,dup / marks (expect {1,0} / {1,0} / {3700, 3700})", {count.(me, "references"), count.(other, "references"), {amark.(me), amark.(other)}})
end)
IO.puts("DONE")

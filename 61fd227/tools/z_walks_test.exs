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


# ---- Supplement: the oldest-first read walked against a strict service (Delvetown's, per hum's ticket) and a non-strict one.
try_.("Z", fn ->
  if function_exported?(AtMcp.NotificationsOldest, :read, 2) do
    walk = fn stamps, limit, strict?, reads ->
      Enum.reduce_while(1..reads, {"2026-01-01T00:00:00.000Z", []}, fn _, {seen, shown} ->
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
    # reads used / items shown in total / distinct items shown / all reached (of n)
    sum = fn shown, n -> all = List.flatten(shown); {length(shown), length(all), length(Enum.uniq(all)), length(Enum.uniq(all)) == n} end
    ms = fn base_ms, offsets -> for o <- offsets, do: "2026-03-01T00:00:05." <> String.pad_leading("#{base_ms + o}", 3, "0") <> "Z" end
    report.("Z1 two at the same time, a third 1 ms later, limit 1, strict: reads (of 6) / shown / distinct / all reached",
      sum.(walk.(ms.(0, [0, 0, 1]), 1, true, 6), 3))
    report.("Z2 ten 1 ms apart, limit 4, strict: reads (of 10) / shown / distinct / all reached",
      sum.(walk.(ms.(0, Enum.to_list(0..9)), 4, true, 10), 10))
    report.("Z3 ten 1 ms apart, limit 4, not strict: reads (of 10) / shown / distinct / all reached",
      sum.(walk.(ms.(0, Enum.to_list(0..9)), 4, false, 10), 10))
    report.("Z4 a burst: 30 in 12 ms (pairs at equal times), limit 5, strict: reads (of 20) / shown / distinct / all reached",
      sum.(walk.(ms.(0, Enum.map(0..29, &(div(&1 * 2, 5)))), 5, true, 20), 30))
    report.("Z5 the same burst, not strict", sum.(walk.(ms.(0, Enum.map(0..29, &(div(&1 * 2, 5)))), 5, false, 20), 30))
    report.("Z6 three 1 ms apart, limit 1, strict, the reads shown", walk.(ms.(0, [0, 1, 2]), 1, true, 6))
  else
    report.("Z oldest-first read", :absent)
  end
end)
IO.puts("DONE")

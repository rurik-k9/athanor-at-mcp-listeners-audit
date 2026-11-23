# Independent black-box checks of the nine defects in hum's review (issue
# 3n2yk5n4k6dpi) and of cases next to them, on the released beams. Injected
# clock; fake repositories, notifications and profiles; streams never connect
# (relay is a closed local port). No network, no account. seenAt (defect 6)
# needs the real tool and is in e2e_stdio.py. Values are observed, not asserted.
for app <- [:crypto, :ssl, :gun, :cowboy, :req], do: Application.ensure_all_started(app)
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
  # Repositories per author, newest first, 100 records per page.
  def reset, do: :persistent_term.put(:r, %{repos: %{}, raise: [], down: false, fail_page: nil, pds_delay: 0})
  def put(k, v), do: :persistent_term.put(:r, Map.put(:persistent_term.get(:r), k, v))
  def get(k), do: Map.get(:persistent_term.get(:r), k)
  def repo(did, oldest_first), do: put(:repos, Map.put(get(:repos), did, Enum.reverse(oldest_first)))
  def pds(_did) do
    if get(:pds_delay) > 0, do: Process.sleep(get(:pds_delay))
    if get(:down), do: {:error, :down}, else: {:ok, "https://pds.invalid"}
  end
  def collections(_pds, _did), do: {:ok, ["town.delve.feed.post"]}
  def records(_pds, did, collection, cursor) do
    if did in get(:raise), do: raise(FunctionClauseError)
    start = if cursor, do: String.to_integer(cursor), else: 0
    if get(:fail_page) == div(start, 100) + 1 do
      {:error, :boom}
    else
      all = Map.get(get(:repos), did, [])
      {:ok, for(k <- Enum.slice(all, start, 100), do: %{did: did, collection: collection, rkey: k}),
       if(start + 100 < length(all), do: Integer.to_string(start + 100))}
    end
  end
end

defmodule BadPds do
  def init(req, state) do
    body = Jason.encode!(%{"records" => [%{"uri" => 1, "value" => %{}}], "cursor" => "x"})
    {:ok, :cowboy_req.reply(200, %{"content-type" => "application/json"}, body, req), state}
  end
end

report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 14)}") end
me = "did:plc:testaccount"; other = "did:plc:otheraccount"; alice = "did:plc:alice"; bob = "did:plc:bob"
carol = "did:plc:carol"; post = "town.delve.feed.post"; t0 = 1_800_000_000; stale = t0 + 40 * 3600
alpha = ~c"234567abcdefghijklmnopqrstuvwxyz"
tid = fn sec, n ->
  v = Bitwise.bor(Bitwise.bsl(sec * 1_000_000 + n, 10), 1)
  for(i <- 12..0//-1, do: Enum.at(alpha, Bitwise.band(Bitwise.bsr(v, i * 5), 31))) |> to_string()
end
iso = fn t -> t |> DateTime.from_unix!() |> DateTime.to_iso8601() end
stop = fn name ->
  if pid = Process.whereis(name) do
    Process.unlink(pid); r = Process.monitor(pid); Process.exit(pid, :kill)
    receive do {:DOWN, ^r, _, _, _} -> :ok end
  end
end
:persistent_term.put(:notifs, %{items: [], fail: false, calls: 0, hook: false})
nset = fn m -> :persistent_term.put(:notifs, Map.merge(:persistent_term.get(:notifs), m)) end
notifications = fn _e, opts ->
  s = :persistent_term.get(:notifs)
  :persistent_term.put(:notifs, %{s | calls: s.calls + 1, hook: false})
  if s.hook, do: :sys.suspend(Updates)
  if s.fail do
    {:error, :down}
  else
    {:ok, %{items: (if opts[:reasons], do: Enum.filter(s.items, &(&1.reason in opts[:reasons])), else: s.items), cursor: nil}}
  end
end
boot = fn dir, clock, opts ->
  stop.(Listeners); stop.(Updates)
  for key <- [Listeners.Records, Listeners.Spacedust], pid = Process.whereis(key), do: Process.exit(pid, :kill)
  Process.sleep(20)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link([clock: clock, constellation: FakeConstellation, repos: R, notifications: notifications,
    profiles: fn _e, dids -> {:ok, %{items: Enum.map(dids, &%{did: &1, viewer: %{}})}} end, batch_ms: 10,
    recheck_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"] ++
    Keyword.merge([notifications_poll_ms: 3_600_000], opts))
  Process.unlink(l)
  :ok = Listeners.track(me, Keyword.get(opts, :effects, :fake_effects)); Process.sleep(250)
end
fresh = fn name, opts ->
  dir = "/work/r-#{name}-#{System.unique_integer([:positive])}"; File.mkdir_p!(dir)
  {:ok, now} = Agent.start(fn -> t0 end); R.reset(); nset.(%{items: [], fail: false, calls: 0, hook: false})
  clock = fn -> Agent.get(now, & &1) end; boot.(dir, clock, opts); {dir, now, clock}
end
at = fn now, t -> Agent.update(now, fn _ -> t end) end
held = fn id ->
  {:ok, r} = Updates.read(me, peek: true, limit: 5000, listener: id); Enum.map(r.updates, & &1["uri"])
end
rec = fn key, sec, record ->
  send(Listeners, {:jetstream, %Event{kind: :commit, did: alice, collection: post, rkey: key,
    operation: :create, cursor: sec * 1_000_000, record: record}})
end
spec = fn authors -> %{"source" => "records", "authors" => authors, "collections" => [post]} end
room = %{"count" => 2000, "age_seconds" => 604_800}
setup = fn name ->
  {dir, now, clock} = fresh.(name, [])
  :ok = Listeners.listen(me, "f", spec.([alice]), room)
  first = tid.(t0 + 1, 1); R.repo(alice, [first]); at.(now, t0 + 1); rec.(first, t0 + 1, nil); Process.sleep(200)
  {dir, now, clock, first}
end
gap = fn first, base, n -> [first | for(i <- 1..n, do: tid.(base + i, i))] end
unrec = fn -> get_in(Listeners.stats(me), ["f", :unrecovered]) end
try_ = fn name, f ->
  try do f.() rescue e -> report.("#{name} ERROR", Exception.message(e) |> String.slice(0, 130))
  catch k, v -> report.("#{name} ERROR", {k, v}) end
end
holder = fn -> spawn(fn -> receive do :done -> :ok end end) end
has_poll = Map.has_key?(:sys.get_state(elem(Listeners.start_link(name: :probe, relay: "ws://127.0.0.1:9/"), 1)), :notifications_poll_ms)
report.("build has the notifications poll", has_poll)

try_.("H1", fn ->
  {dir, now, clock, first} = setup.("h1"); g = gap.(first, t0 + 100, 2); live = tid.(stale + 1, 9)
  R.repo(alice, g ++ [live]); R.put(:pds_delay, 400); at.(now, stale + 1)
  spawn(fn -> Process.sleep(120); rec.(live, stale + 1, nil) end)
  boot.(dir, clock, []); Process.sleep(900)
  report.("H1 live record saved while the DID is resolved: held (expect 4)", length(held.("f")))
end)

try_.("H2", fn ->
  h0 = holder.(); {dir, now, clock} = fresh.("h2", effects: h0)
  :ok = Listeners.listen(me, "f", spec.([alice]), room); at.(now, t0 + 10)
  {:ok, _} = Updates.commit([], {"listeners_records", (t0 + 10) * 1_000_000})
  {:ok, _} = Updates.commit([], {"records_through:" <> me, t0 + 10})
  h1 = holder.(); boot.(dir, clock, effects: h1)
  o = holder.(); :ok = Listeners.track(other, o)
  :ok = Listeners.listen(other, "b", spec.([bob]), room); Process.sleep(150)
  Process.exit(h1, :kill); Process.sleep(200)
  k = tid.(t0 + 20, 1); R.repo(alice, [k]); at.(now, t0 + 30)
  :ok = Listeners.track(me, holder.()); Process.sleep(500)
  report.("H2 logout and login while another account holds the stream: gap record held (expect 1)", length(held.("f")))
end)

old_record = fn name, mark ->
  {dir, now, clock} = fresh.(name, [])
  # Default bounds, as hum's test: a larger count would also keep more receipts.
  :ok = Listeners.listen(me, "f", spec.([alice, bob]), %{})
  old = tid.(t0 + 1, 1)
  {:ok, [_]} = Updates.commit([{me, "f", %{"uri" => "at://#{alice}/#{post}/#{old}", "source" => "records:#{post}", "from" => alice}}], nil)
  {:ok, %{updates: [%{"seq" => seq}]}} = Updates.read(me, listener: "f")
  {:ok, :ok} = Updates.ack(me, seq, "f")
  {:ok, _} = Updates.commit(for(i <- 1..1000, do: {me, "f", %{"uri" => "at://#{bob}/#{post}/b#{i}", "receipt_only" => true}}), nil)
  at.(now, t0 + 3600)
  if mark, do: {:ok, _} = Updates.commit([], {"records_through:" <> me, t0 + 3000})
  R.repo(alice, [old]); boot.(dir, clock, []); Process.sleep(300)
  length(held.("f"))
end
try_.("H3", fn -> report.("H3 old record behind 1,000 receipts, coverage mark present: delivered again (expect 0)", old_record.("h3", true)) end)
try_.("N1", fn -> report.("N1 same, state from an older build, no coverage mark yet: delivered again (expect 0)", old_record.("n1", false)) end)

try_.("H4a", fn ->
  ref = :bad_pds
  d = :cowboy_router.compile([{:_, [{"/xrpc/com.atproto.repo.listRecords", BadPds, []}]}])
  {:ok, _} = :cowboy.start_clear(ref, [port: 0, ip: {127, 0, 0, 1}], %{env: %{dispatch: d}})
  r = try do AtMcp.Repos.records("http://127.0.0.1:#{:ranch.get_port(ref)}", alice, post) rescue e -> {:raised, e.__struct__} end
  report.("H4a real Repos.records on a non-string uri (expect {:error, _})", r)
end)
try_.("H4b", fn ->
  {dir, now, clock} = fresh.("h4", [])
  :ok = Listeners.listen(me, "f", spec.([alice, carol]), room); at.(now, t0 + 10)
  R.repo(alice, [tid.(t0 + 5, 1)]); R.put(:raise, [carol]); at.(now, stale); boot.(dir, clock, []); Process.sleep(500)
  report.("H4b one author's reader raises: other author's record held / unrecovered (expect 1 / 1)", {length(held.("f")), unrec.()})
end)

if has_poll do
  try_.("H5", fn ->
    {_dir, _now, _clock} = fresh.("h5", notifications_poll_ms: 100)
    Process.sleep(300); nset.(%{hook: true}); Process.sleep(5_800); :sys.resume(Updates); Process.sleep(200)
    c = :persistent_term.get(:notifs).calls; Process.sleep(1000)
    report.("H5 a poll task exits (store busy past 5 s): polls in the next second (expect > 0)", :persistent_term.get(:notifs).calls - c)
  end)
  try_.("H7", fn ->
    {_dir, now, _clock} = fresh.("h7", notifications_poll_ms: 100)
    nset.(%{fail: true})
    :ok = Listeners.listen(me, "likes", %{"source" => "notifications", "reasons" => ["like"]}, %{})
    nset.(%{items: [%{reason: "like", uri: "at://#{bob}/app.bsky.feed.like/#{tid.(t0 + 120, 1)}", author_did: bob, indexed_at: iso.(t0 + 120)}]})
    Process.sleep(300); at.(now, t0 + 600); nset.(%{fail: false}); Process.sleep(700)
    report.("H7 notification during a 10 min poll outage: held (expect 1)", length(held.("likes")))
  end)
else
  report.("H5 a poll task exits (store busy past 5 s): polls in the next second (expect > 0)", :no_poll_in_this_build)
  report.("H7 notification during a 10 min poll outage: held (expect 1)", :no_poll_in_this_build)
end

try_.("H8", fn ->
  {_dir, _now, _clock, _first} = setup.("h8")
  p1 = :sys.get_state(Listeners).records_stream
  Process.exit(p1, :kill); Process.sleep(700)
  p2 = :sys.get_state(Listeners).records_stream
  report.("H8 records client killed: a new live client (expect true)", is_pid(p2) and p2 != p1 and Process.alive?(p2))
end)

try_.("H9", fn ->
  {_dir, _now, _clock} = fresh.("h9", [])
  :ok = Listeners.listen(me, "f", spec.([alice]), room)
  rec.(tid.(t0 + 2, 1), t0 + 2, %{"indexed_at" => "2099-01-01T00:00:00Z"}); Process.sleep(250)
  {:ok, r} = Updates.read(me, peek: true, listener: "f")
  report.("H9 indexed_at taken from the author's record (expect false)", Enum.any?(r.updates, &Map.has_key?(&1, "indexed_at")))
end)

try_.("N2", fn ->
  {dir, now, clock, first} = setup.("n2"); g = gap.(first, t0 + 100, 250); R.repo(alice, g); R.put(:fail_page, 2)
  at.(now, stale); boot.(dir, clock, []); Process.sleep(300)
  live = tid.(stale + 60, 9); R.repo(alice, g ++ [live]); R.put(:fail_page, nil); at.(now, stale + 60); rec.(live, stale + 60, nil); Process.sleep(250)
  at.(now, stale + 70); boot.(dir, clock, []); Process.sleep(500)
  report.("N2 page 2 fails, one live record, healthy restart: held (expect 252)", length(held.("f")))
end)
try_.("N3", fn ->
  {dir, now, clock, first} = setup.("n3"); R.repo(alice, gap.(first, t0 + 100, 3)); R.put(:fail_page, 1)
  at.(now, stale); boot.(dir, clock, []); Process.sleep(300)
  report.("N3 listRecords answers an error: unrecovered counter (expect 1)", unrec.())
  R.put(:fail_page, nil); boot.(dir, clock, []); Process.sleep(300)
  report.("N3b healthy restart, no live record in between: held (expect 4)", length(held.("f")))
end)

try_.("N4", fn ->
  for h <- ["localhost", "127.0.0.1", "foo.localhost", "127.1", "0x7f.1", "0x7f.0.0.1", "example.test"] do
    r = try do AtMcp.Repos.pds("did:web:" <> h) rescue e -> {:raised, e.__struct__} end
    addr = if h == "example.test", do: nil, else: (case :inet.getaddr(String.to_charlist(h), :inet) do {:ok, a} -> a |> Tuple.to_list() |> Enum.join("."); _ -> nil end)
    report.("N4 did:web host #{h}: refused by the name check / address from :inet.getaddr", {r == {:error, :unsupported_did}, addr})
  end
end)
IO.puts("DONE")

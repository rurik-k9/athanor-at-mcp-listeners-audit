# Prelude for the c64be24 round (D-019 Trial by Fire). Evaluated first by every test script (Code.eval_file).
# Injected clock; programmable fake Constellation, repositories and notifications; the streams never connect (their
# relays are a closed local port) and "connected" is announced by message. No network, no account. Values are
# observed and printed as RESULT lines; nothing is asserted.
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
{:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)

defmodule KV do
  # A small global store for the fakes (persistent_term: readable from any process, tasks included).
  def put(k, v), do: :persistent_term.put({:kv, k}, v)
  def get(k, d \\ nil), do: :persistent_term.get({:kv, k}, d)
  def bump(k), do: put(k, get(k, 0) + 1)
end

defmodule FC do
  # Programmable Constellation. Modes (KV :fc_mode): :normal (KV :links, %{{subject, source} => [records newest first]},
  # pages of KV :fc_page), :sources_fail, and per-backlinks behaviours (KV :fc_pages):
  #   :infinite_new  every page brings 2 records never seen, dated KV :fc_date, cursor never nil
  #   :same_cursor   the same page and the same cursor forever
  #   :empty_forever empty pages, cursor never nil
  # Only the subject under test (KV :fc_subject, when set) gets the programmed sources and pages; any other subject
  # (the built-in listener's own DID, for one) gets what KV :links holds for it, normally nothing.
  def sources(subject) do
    KV.bump(:fc_sources_calls); if subject == KV.get(:fc_subject), do: KV.bump(:fc_subject_listings)
    case (if KV.get(:fc_subject) in [nil, subject], do: KV.get(:fc_sources), else: nil) do
      :fail -> {:error, {:http_status, 404}}
      nil -> {:ok, KV.get(:links, %{}) |> Map.keys() |> Enum.filter(&(elem(&1, 0) == subject)) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()}
      list when is_list(list) -> {:ok, list}
    end
  end

  def backlinks(subject, source, cursor) do
    KV.bump(:fc_backlinks_calls)
    page = KV.get(:fc_page, 2)
    case (if KV.get(:fc_subject) in [nil, subject], do: KV.get(:fc_pages), else: nil) do
      :infinite_new ->
        n = KV.get(:fc_serial, 0); KV.put(:fc_serial, n + page)
        recs = for i <- 1..page, do: %{did: KV.get(:fc_author), collection: "town.delve.feed.post", rkey: KV.get(:tid).(KV.get(:fc_date), n + i)}
        {:ok, recs, "c#{n + page}"}
      :same_cursor ->
        {:ok, Enum.take(Map.get(KV.get(:links, %{}), {subject, source}, []), page), "loop"}
      :empty_forever ->
        {:ok, [], "e#{(cursor || "0") |> String.replace(~r/\D/, "") |> then(&(if &1 == "", do: 0, else: String.to_integer(&1))) |> Kernel.+(1)}"}
      _ ->
        all = Map.get(KV.get(:links, %{}), {subject, source}, [])
        start = if cursor, do: String.to_integer(cursor), else: 0
        next = if start + page < length(all), do: Integer.to_string(start + page)
        {:ok, Enum.slice(all, start, page), next}
    end
  end
end

defmodule R do
  # Repositories (records listeners): KV :repo, newest first; KV :repo_down.
  def pds(_did), do: if(KV.get(:repo_down), do: {:error, :down}, else: {:ok, "https://pds.invalid"})
  def collections(_pds, _did), do: {:ok, ["town.delve.feed.post"]}
  def records(_pds, did, collection, cursor) do
    KV.bump(:repo_calls)
    start = if cursor, do: String.to_integer(cursor), else: 0
    all = KV.get(:repo, [])
    {:ok, for(k <- Enum.slice(all, start, 100), do: %{did: did, collection: collection, rkey: k}),
     if(start + 100 < length(all), do: Integer.to_string(start + 100))}
  end
end

defmodule N do
  # Notifications per account effects (KV {:notes, fx}, newest first); counts reads per effects.
  def read(fx, opts) do
    KV.bump({:nreads, fx})
    start = if opts[:cursor], do: String.to_integer(opts[:cursor]), else: 0
    all = KV.get({:notes, fx}, [])
    next = start + opts[:limit]
    {:ok, %{items: Enum.slice(all, start, opts[:limit]), cursor: if(next < length(all), do: Integer.to_string(next))}}
  end
end

alias AtMcp.{Listeners, Updates}
alias AtMcp.Stream.Event
report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 40, printable_limit: 400)}") end
me = "did:plc:testaccount"; other = "did:plc:otheraccount"; alice = "did:plc:alice"; bob = "did:plc:bob"
post = "town.delve.feed.post"; t0 = 1_800_000_000
alpha = ~c"234567abcdefghijklmnopqrstuvwxyz"
tid = fn sec, n ->
  v = Bitwise.bor(Bitwise.bsl(sec * 1_000_000 + n, 10), 1)
  for(i <- 12..0//-1, do: Enum.at(alpha, Bitwise.band(Bitwise.bsr(v, i * 5), 31))) |> to_string()
end
KV.put(:tid, tid)
iso = fn t -> t |> DateTime.from_unix!() |> DateTime.to_iso8601() end
stop = fn name ->
  if pid = Process.whereis(name) do
    Process.unlink(pid); r = Process.monitor(pid); Process.exit(pid, :kill)
    receive do {:DOWN, ^r, _, _, _} -> :ok after 2000 -> :ok end
  end
end
start_l = fn dir, clock, opts ->
  stop.(Listeners); stop.(Updates)
  for key <- [Listeners.Records, Listeners.Spacedust], pid = Process.whereis(key), do: Process.exit(pid, :kill)
  Process.sleep(20)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(clock: clock, constellation: FC, repos: R,
    notifications: fn fx, o -> N.read(fx, o) end, profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end,
    batch_ms: 10, recheck_ms: Keyword.get(opts, :recheck_ms, 3_600_000), notifications_poll_ms: Keyword.get(opts, :poll_ms, 3_600_000),
    relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/")
  Process.unlink(l)
  {u, l}
end
connect = fn -> if Process.whereis(Listeners), do: send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(300) end
fresh_dir = fn name -> d = "/work/s-#{name}-#{System.unique_integer([:positive])}"; File.mkdir_p!(d); File.chmod!(d, 0o700); d end
new_clock = fn t -> {:ok, a} = Agent.start(fn -> t end); {a, fn -> Agent.get(a, & &1) end} end
set_time = fn a, t -> Agent.update(a, fn _ -> t end) end
held = fn did, id ->
  case Updates.read(did, peek: true, limit: 5000, listener: id) do
    {:ok, r} -> Enum.map(r.updates, & &1["uri"])
    e -> e
  end
end
dups = fn uris -> if is_list(uris), do: length(uris) - length(Enum.uniq(uris)), else: uris end
stat = fn did, id, k -> try do get_in(Listeners.stats(did), [id, k]) catch _, _ -> :listeners_down end end
amark = fn did -> try do (case Updates.stream_cursor("listeners_live:" <> did) do x when is_integer(x) -> x - t0; x -> x end) catch k, v -> {k, elem(v, 0)} end end
floor_of = fn did, id -> try do (case Updates.forgotten_through(did, id) do {:ok, x} when is_integer(x) -> x - t0; x -> x end) catch k, _ -> k end end
lstate = fn -> try do :sys.get_state(Listeners) catch _, _ -> nil end end
alive = fn name -> (p = Process.whereis(name)) != nil and Process.alive?(p) end
safe = fn f -> try do f.() rescue e -> {:raised, Exception.message(e) |> String.slice(0, 120)} catch k, v -> {k, inspect(v) |> String.slice(0, 120)} end end
rec_live = fn key, sec ->
  Process.whereis(Listeners) && send(Listeners, {:jetstream, %Event{kind: :commit, did: alice, collection: post, rkey: key, operation: :create, cursor: sec * 1_000_000}})
end
ack_all = fn did, id ->
  case Updates.read(did, limit: 5000, listener: id) do
    {:ok, %{updates: [_ | _] = u}} -> Updates.ack(did, List.last(u)["seq"], id)
    _ -> :ok
  end
end
reset_fakes = fn ->
  for k <- [:fc_mode, :fc_subject, :fc_subject_listings, :fc_sources, :fc_pages, :fc_serial, :links, :repo, :repo_down, :fc_sources_calls, :fc_backlinks_calls, :repo_calls],
      do: :persistent_term.erase({:kv, k})
  KV.put(:fc_page, 2); KV.put(:fc_author, bob)
end

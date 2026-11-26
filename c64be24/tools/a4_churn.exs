# A4 (axis 3): recheck under churn. Hum: "listen/unlisten and login/logout in quick loops; look for a second recheck
# chain or a mark that never moves".
# Docs (c64be24): "One pass is pending at a time: each carries its timer's token"; a connect "replaces whatever pass
# was pending"; "An account tracked later is read again on its own five minutes later ... without delaying a pending
# pass"; a subject whose sources can't be listed "holds the account's mark for up to three passes in a row (a quarter
# hour, counted afresh after a logout or unlisten) ... after that its gap is counted as unrecovered and let go, so one
# that lasts ... can't hold the mark for good"; review of aa73b9e: "two misses land per pass, so a subject's sources
# are given up after two passes, not three" (the bug c64be24 says it fixes: "one read per login").
# Recheck interval 1,000 ms here (5 min in the service). Listings of the subject under test (not of its author's DID,
# which the listener also reads) are counted per interval. Harness limit: the relays are closed, so a live stream that
# restarts after a filter change never reconnects by itself; where the service's stream would reconnect, the
# announcement {:at_mcp_stream_connected, _} is sent by hand (C1, C3).
root = "at://#{other}/#{post}/3kroot"; src = "town.delve.feed.post:reply.parent.uri"
room = %{"count" => 2000, "age_seconds" => 604_800}
interval = 1000
fx = fn -> spawn(fn -> Process.sleep(:infinity) end) end
base = fn name ->
  reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src])
  dir = fresh_dir.(name); {a, clock} = new_clock.(t0)
  start_l.(dir, clock, recheck_ms: interval)
  f = fx.(); :ok = Listeners.track(me, f); :ok = Listeners.listen(me, "g", %{"source" => "links", "subjects" => [root]}, room)
  connect.(); set_time.(a, t0 + 3600)
  {dir, a, f}
end
listings_per_interval = fn n, each ->
  for p <- 1..n do
    before = KV.get(:fc_subject_listings, 0); each.(p); Process.sleep(interval)
    {KV.get(:fc_subject_listings, 0) - before, amark.(me), stat.(me, "g", :unrecovered)}
  end
end

# C1: the subject's listing fails for good; the account logs out and in every interval (an agent session that ends
# and starts again, or a flapping connection).
for {label, churn?} <- [{"control: no churn", false}, {"logout and login every interval", true}] do
  {_dir, _a, f0} = base.("c1")
  KV.put(:fc_sources, :fail); connect.()
  cur = :persistent_term.put(:cur_fx, f0)
  rows = listings_per_interval.(12, fn _p ->
    if churn? do
      Process.exit(:persistent_term.get(:cur_fx), :kill); Process.sleep(20)
      nf = fx.(); :persistent_term.put(:cur_fx, nf); :ok = Listeners.track(me, nf)
      # The account's filters changed, so the live stream restarts; in the service it then connects again and says so.
      # The relays here are closed, so that announcement is sent by hand.
      send(Listeners, {:at_mcp_stream_connected, :test})
    end
  end)
  s = lstate.()
  report.("A4 C1 subject never listed, #{label}", %{per_interval_listings_mark_unrecovered: rows, recheck_pending_at_end: s && is_reference(Map.get(s, :recheck)), account_held_at_end: s && MapSet.member?(s.live_hold, me)})
  _ = cur
end

# C2: the same, with unlisten and listen again (same id, same spec) every interval.
for {label, churn?} <- [{"control: no churn", false}, {"unlisten and listen every interval", true}] do
  {_dir, _a, _f} = base.("c2")
  KV.put(:fc_sources, :fail); connect.()
  rows = listings_per_interval.(12, fn _p ->
    if churn?, do: (:ok = Listeners.unlisten(me, "g"); :ok = Listeners.listen(me, "g", %{"source" => "links", "subjects" => [root]}, room))
  end)
  s = lstate.()
  report.("A4 C2 subject never listed, #{label}", %{per_interval_listings_mark_unrecovered: rows, recheck_pending_at_end: s && is_reference(Map.get(s, :recheck)), account_held_at_end: s && MapSet.member?(s.live_hold, me)})
end

# C3: a login shortly before the stream reconnects (delta ms): the login's own read a recheck later and the
# connect's pass over every account land in the same interval. A subject whose listing fails from the login on:
# listings per interval, and the interval in which its gap is given up (unrecovered becomes 1).
for delta <- [50, 300, 500] do
  reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src])
  dir = fresh_dir.("c3"); {a, clock} = new_clock.(t0)
  start_l.(dir, clock, recheck_ms: interval)
  :ok = Listeners.track(me, fx.()); :ok = Listeners.listen(me, "g", %{"source" => "links", "subjects" => [root]}, room)
  connect.(); Process.sleep(2 * interval)                        # healthy, the recheck has stopped
  set_time.(a, t0 + 3600); KV.put(:fc_sources, :fail); KV.put(:fc_sources_calls, 0)
  :ok = Listeners.track(other, fx.())                            # a login (another account; no listener of its own)
  first = fx.(); Process.exit(first, :normal)
  # `me` logs out and in (its login), then the stream reconnects `delta` ms later.
  s0 = lstate.(); [{_, acc}] = Enum.filter(s0.accounts, fn {d, _} -> d == me end)
  Process.exit(acc.effects, :kill); Process.sleep(20); :ok = Listeners.track(me, fx.())
  Process.sleep(delta); send(Listeners, {:at_mcp_stream_connected, :test})
  rows = listings_per_interval.(5, fn _ -> :ok end)
  given_up_in = Enum.find_index(rows, fn {_, _, u} -> u == 1 end)
  report.("A4 C3 login #{delta} ms before a reconnect, subject's listing failing", %{per_interval_listings_mark_unrecovered: rows,
    subject_listings_until_given_up: rows |> Enum.take((given_up_in || 4) + 1) |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
    intervals_until_given_up: given_up_in && given_up_in + 1, docs_promise: "three passes (listings) before the gap is given up"})
  stop.(Listeners); stop.(Updates); Agent.stop(a)
end

# C4: a login storm: 20 logout/login cycles of the same account within one interval while connected, with 4 records
# in the gap. Reads of the subject in the following intervals (one chain, one read per login?) and duplicates saved.
reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src])
dir = fresh_dir.("c4"); {a, clock} = new_clock.(t0)
start_l.(dir, clock, recheck_ms: interval)
f = fx.(); :ok = Listeners.track(me, f); :ok = Listeners.listen(me, "g", %{"source" => "links", "subjects" => [root]}, room)
connect.(); Process.sleep(2 * interval)
set_time.(a, t0 + 3600); KV.put(:links, %{{root, src} => (for i <- 4..1//-1, do: %{did: bob, collection: post, rkey: tid.(t0 + 1800, i)})})
KV.put(:fc_sources_calls, 0); KV.put(:fc_backlinks_calls, 0)
cur = Enum.reduce(1..20, f, fn _, prev -> Process.exit(prev, :kill); Process.sleep(5); nf = fx.(); :ok = Listeners.track(me, nf); nf end)
rows = for _ <- 1..5 do b = KV.get(:fc_backlinks_calls, 0); Process.sleep(interval); KV.get(:fc_backlinks_calls, 0) - b end
u = held.(me, "g")
s = lstate.()
report.("A4 C4 20 logins of one account within one interval", %{backlinks_reads_per_interval_after: rows, saved: (if is_list(u), do: length(u), else: u), duplicates_saved: dups.(u), recheck_pending_at_end: s && is_reference(Map.get(s, :recheck))})
_ = cur; stop.(Listeners); stop.(Updates); Agent.stop(a)

# C5: a reconnect storm: 20 connects within one interval. Passes per interval afterwards (one chain?).
reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src])
dir = fresh_dir.("c5"); {a, clock} = new_clock.(t0)
start_l.(dir, clock, recheck_ms: interval)
:ok = Listeners.track(me, fx.()); :ok = Listeners.listen(me, "g", %{"source" => "links", "subjects" => [root]}, room)
connect.(); KV.put(:fc_sources, :fail)                    # held for its three passes, so passes keep coming for a while
KV.put(:fc_subject_listings, 0)
for _ <- 1..20, do: (send(Listeners, {:at_mcp_stream_connected, :test}); Process.sleep(10))
rows = for _ <- 1..5 do b = KV.get(:fc_subject_listings, 0); Process.sleep(interval); KV.get(:fc_subject_listings, 0) - b end
report.("A4 C5 20 reconnects within one interval, subject failing", %{listings_per_interval_after: rows, unrecovered: stat.(me, "g", :unrecovered)})
IO.puts("DONE")

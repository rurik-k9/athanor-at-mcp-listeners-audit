# A3b (axis 2): pass-by-pass traces of the two A3 cases that need more than end states:
#  (1) a subject unlisted for 10 listings in a row from the gap's connect, then listed again: the docs say its gap is
#      held for up to three passes, then counted and let go (the account's mark moves past it);
#  (2) pages that never run dry, every record left out by the listener's `from` filter: the docs say a read that spends
#      its fifty reads short of the gap's end gives up and counts as complete.
# Each is run with the recheck at 300 ms and at 3,000 ms, so that a backfill outlasting the interval (passes
# overlapping) can be told from the code's own behaviour. Per pass: account mark (seconds after t0), unrecovered,
# misses held for the subject, whether the account is held, backlinks calls so far.
root = "at://#{other}/#{post}/3kroot"; src = "town.delve.feed.post:reply.parent.uri"
room = %{"count" => 2000, "age_seconds" => 604_800}
mk = fn n, at -> for i <- n..1//-1, do: %{did: bob, collection: post, rkey: tid.(at, i)} end
trace = fn name, interval, spec, setup_fakes, during, each_pass, passes ->
  reset_fakes.(); dir = fresh_dir.(name); {a, clock} = new_clock.(t0)
  KV.put(:fc_subject, root); setup_fakes.()
  start_l.(dir, clock, recheck_ms: interval)
  :ok = Listeners.track(me, :me_fx); :ok = Listeners.listen(me, "g", spec, room)
  connect.(); m0 = amark.(me)
  set_time.(a, t0 + 3600); KV.put(:fc_date, t0 + 1800); KV.put(:fc_backlinks_calls, 0); during.()
  connect.()
  rows = for p <- 1..passes do
    each_pass.(p); Process.sleep(interval)
    s = lstate.()
    misses = s && (Map.get(s, :sources_misses, %{}) |> Enum.filter(fn {{d, _, _}, _} -> d == me end) |> Enum.map(&elem(&1, 1)))
    {p, amark.(me), stat.(me, "g", :unrecovered), misses, s && MapSet.member?(s.live_hold, me), KV.get(:fc_backlinks_calls, 0)}
  end
  IO.puts("RESULT\tA3b #{name}, recheck #{interval} ms\t" <> inspect(%{rows: rows}, limit: :infinity))
  report.("A3b #{name}, recheck #{interval} ms (summary)", %{mark_before_gap: m0, per_pass_mark_unrecovered_misses_held_calls: rows,
    updates_saved: (case held.(me, "g") do l when is_list(l) -> length(l); e -> e end)})
  stop.(Listeners); stop.(Updates); Agent.stop(a)
end
for interval <- [300, 3000] do
  trace.("subject unlisted for 10 listings, then listed", interval, %{"source" => "links", "subjects" => [root]},
    fn -> KV.put(:fc_sources, [src]) end,
    fn -> KV.put(:links, %{{root, src} => mk.(6, t0 + 1800)}); KV.put(:fc_sources, :fail) end,
    fn p -> if p >= 10, do: KV.put(:fc_sources, [src]) end, 12)
  trace.("pages never dry, every record left out by `from`", interval, %{"source" => "links", "subjects" => [root], "from" => [alice]},
    fn -> KV.put(:fc_sources, [src]) end,
    fn -> KV.put(:fc_pages, :infinite_new) end,
    fn _ -> :ok end, 6)
end
IO.puts("DONE")

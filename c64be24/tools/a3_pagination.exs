# A3 (axis 2): pagination ending. Hum: "link pages that never run dry, unlisted subjects, read caps".
# Docs (c64be24): a links backfill reads newest first "until a record older than `since`, the last page, or
# @max_pages pages that brought something this listener takes" (5), "fifty reads in all"; "A Constellation backfill
# cut by its page bound no longer reports success: the gap is counted as `unrecovered` and the account's mark stays
# put so the recheck reads on"; "a read that spends its fifty reads short of the gap's end gives up, counted"; "A
# subject whose sources couldn't be listed holds the mark for up to three passes, then its gap is counted and let go";
# the recheck "stops when there are none" (no account held).
# Invariants probed: (P-a) every read ends (bounded reads per pass); (P-b) an unfinished gap is counted, never silent;
# (P-c) the account's mark eventually moves, or the reason it can't is counted; (P-d) the recheck chain stops once
# nothing can progress. Each scenario: a links listener on one subject, a connect, then passes of the recheck
# (recheck_ms 300) observed for ~10 passes.
root = "at://#{other}/#{post}/3kroot"
spec_g = %{"source" => "links", "subjects" => [root]}
room = %{"count" => 2000, "age_seconds" => 604_800}
src = "town.delve.feed.post:reply.parent.uri"
interval = 300
run = fn name, setup_fakes, opts ->
  reset_fakes.(); dir = fresh_dir.(name); {a, clock} = new_clock.(t0)
  KV.put(:fc_subject, root); setup_fakes.()
  start_l.(dir, clock, recheck_ms: interval)
  :ok = Listeners.track(me, :me_fx); :ok = Listeners.listen(me, "g", Map.merge(spec_g, opts[:spec] || %{}), room)
  connect.()                                    # first connect: writes the account's mark
  m0 = amark.(me)
  set_time.(a, t0 + 3600)                        # an hour later the stream reconnects: a gap of one hour
  KV.put(:fc_date, t0 + 1800); KV.put(:fc_backlinks_calls, 0); KV.put(:fc_sources_calls, 0)
  if f = opts[:during], do: f.()
  connect.()
  calls = for p <- 1..10 do
    if f = opts[:each_pass], do: f.(p)
    before = KV.get(:fc_backlinks_calls, 0); Process.sleep(interval)
    KV.get(:fc_backlinks_calls, 0) - before
  end
  s = lstate.()
  report.("A3 #{name}", %{mark_before_gap: m0, mark_after: amark.(me), unrecovered: stat.(me, "g", :unrecovered),
    backlinks_calls_per_pass: calls, total_backlinks_calls: KV.get(:fc_backlinks_calls, 0), sources_calls: KV.get(:fc_sources_calls, 0),
    recheck_pending_at_end: s && is_reference(Map.get(s, :recheck)), account_held_at_end: s && MapSet.member?(s.live_hold, me),
    updates_saved: (case held.(me, "g") do l when is_list(l) -> length(l); e -> e end)})
  Agent.stop(a)
end
mk = fn n, at -> for i <- n..1//-1, do: %{did: bob, collection: post, rkey: tid.(at, i)} end   # newest first
run.("control: 6 records in the gap, all read", fn -> KV.put(:fc_sources, [src]) end, during: fn -> KV.put(:links, %{{root, src} => mk.(6, t0 + 1800)}) end)
run.("pages never run dry, every page new (taken)", fn -> KV.put(:fc_sources, [src]); KV.put(:fc_pages, :infinite_new) end, [])
run.("pages never run dry, the same page and cursor forever", fn -> KV.put(:fc_sources, [src]); KV.put(:fc_pages, :same_cursor); KV.put(:links, %{{root, src} => mk.(2, t0 + 1800)}) end, [])
run.("pages never run dry, empty pages forever", fn -> KV.put(:fc_sources, [src]); KV.put(:fc_pages, :empty_forever) end, [])
run.("pages never run dry, every page new but from an author the listener's from filter leaves out", fn -> KV.put(:fc_sources, [src]); KV.put(:fc_pages, :infinite_new) end, spec: %{"from" => [alice]})
for k <- [1, 2, 3, 4, 10] do
  # Listing fails from the gap's connect on: k failed listings (the connect's, then the first passes), then it works.
  run.("sources unlisted for #{k} listing(s) from the gap's connect, 6 records in the gap",
    fn -> KV.put(:fc_sources, [src]) end,
    during: fn -> KV.put(:links, %{{root, src} => mk.(6, t0 + 1800)}); KV.put(:fc_sources, :fail) end,
    each_pass: fn p -> if p >= k, do: KV.put(:fc_sources, [src]) end)
end
IO.puts("DONE")

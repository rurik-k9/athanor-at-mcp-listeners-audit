# R2, minimal: a links listener whose subject's sources can't be listed, and the agent unlistening and listening again
# (same id, same spec) once per recheck interval. The docs say such a subject holds the account's mark "for up to
# three passes in a row ... after that its gap is counted as unrecovered and let go, so one that lasts ... can't hold
# the mark for good". Here the tries restart at each unlisten (as the docs also say, "counted afresh after a logout
# or unlisten"), so the gap is never counted and the mark never moves, for as long as the loop lasts; the recheck
# reads the account every interval. Control: the same without the loop (given up after three listings).
# Recheck 1,000 ms (5 min in the service). Prints REPRODUCED or NOT REPRODUCED.
root = "at://#{other}/#{post}/3kroot"; src = "town.delve.feed.post:reply.parent.uri"
spec = %{"source" => "links", "subjects" => [root]}; room = %{"count" => 2000, "age_seconds" => 604_800}
go = fn loop? ->
  reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src])
  dir = fresh_dir.("r2"); {a, clock} = new_clock.(t0)
  start_l.(dir, clock, recheck_ms: 1000)
  :ok = Listeners.track(me, spawn(fn -> Process.sleep(:infinity) end)); :ok = Listeners.listen(me, "g", spec, room)
  connect.(); set_time.(a, t0 + 3600); KV.put(:fc_sources, :fail); connect.()
  for _ <- 1..10, do: (if loop?, do: (:ok = Listeners.unlisten(me, "g"); :ok = Listeners.listen(me, "g", spec, room)); Process.sleep(1000))
  r = %{mark_after_10_intervals: amark.(me), unrecovered: stat.(me, "g", :unrecovered), subject_listings: KV.get(:fc_subject_listings, 0)}
  stop.(Listeners); stop.(Updates); Agent.stop(a); r
end
control = go.(false); looped = go.(true)
report.("R2 control (no loop)", control); report.("R2 unlisten/listen every interval", looped)
ok = control.mark_after_10_intervals == 3600 and control.unrecovered == 1 and looped.mark_after_10_intervals == 0 and looped.unrecovered in [nil, 0]
IO.puts("RESULT\tR2 verdict\t" <> if(ok, do: "REPRODUCED", else: "NOT REPRODUCED"))
IO.puts("DONE")

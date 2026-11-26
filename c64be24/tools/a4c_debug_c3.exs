# A4c: what C3 (login shortly before a reconnect, the subject's listing failing) counts, and when. Every 100 ms:
# subject listings so far, misses for the subject, the gaps counted as unrecovered (their kind), the account's mark.
root = "at://#{other}/#{post}/3kroot"; src = "town.delve.feed.post:reply.parent.uri"
room = %{"count" => 2000, "age_seconds" => 604_800}; interval = 1000
fx = fn -> spawn(fn -> Process.sleep(:infinity) end) end
reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src])
dir = fresh_dir.("c3d"); {a, clock} = new_clock.(t0)
start_l.(dir, clock, recheck_ms: interval)
f = fx.(); :ok = Listeners.track(me, f); :ok = Listeners.listen(me, "g", %{"source" => "links", "subjects" => [root]}, room)
connect.(); Process.sleep(2 * interval)
set_time.(a, t0 + 3600); KV.put(:fc_sources, :fail); KV.put(:fc_subject_listings, 0)
Process.exit(f, :kill); Process.sleep(20); :ok = Listeners.track(me, fx.())
s = lstate.(); report.("C3d after re-login", %{connected: s.connected?, recheck: is_reference(Map.get(s, :recheck)), misses: s.sources_misses})
Process.sleep(50); send(Listeners, {:at_mcp_stream_connected, :test})
for t <- 1..25 do
  Process.sleep(100); s = lstate.()
  gaps = s.unrecovered_gaps |> Map.get(me, MapSet.new()) |> Enum.map(fn {id, g} -> {id, elem(g, 0)}; x -> x end)
  IO.puts("RESULT\tC3d t=#{t * 100}ms\t" <> inspect(%{listings: KV.get(:fc_subject_listings, 0), misses: s.sources_misses |> Map.values(), gaps: gaps, mark: amark.(me), held: MapSet.member?(s.live_hold, me)}))
end
IO.puts("DONE")

# A5: whole-build stress, after the three axes. Seeded random sequences over 4 accounts mixing: logout/login, unlisten/
# listen, reconnects, the subject's listing failing or working, live records (some dated ahead up to a day), records
# appearing in Constellation for gaps, and clock steps. Then a quiet phase (no churn, listings working) to see whether
# everything converges. Recheck 200 ms.
# Invariants checked at the end of each seed: (S1) Updates and Listeners alive throughout; (S2) no record saved twice
# for one listener; (S3) after the quiet phase, the recheck has stopped and no account is held; (S4) no account mark
# or listener floor past the clock; (S5) listings per interval in the quiet phase are bounded (one chain).
# SEEDS (env, default "1 2 3 4 5"), STEPS (default 150).
seeds = (System.get_env("SEEDS") || "1 2 3 4 5") |> String.split() |> Enum.map(&String.to_integer/1)
steps = String.to_integer(System.get_env("STEPS") || "150")
root = "at://#{other}/#{post}/3kroot"; src = "town.delve.feed.post:reply.parent.uri"
room = %{"count" => 2000, "age_seconds" => 604_800}; interval = 200
accounts = for i <- 1..4, do: "did:plc:stress#{i}"
fx = fn -> spawn(fn -> Process.sleep(:infinity) end) end
spec_g = %{"source" => "links", "subjects" => [root]}
spec_f = %{"source" => "records", "authors" => [alice], "collections" => [post]}
for seed <- seeds do
  :rand.seed(:exsss, {seed, 23, 5})
  reset_fakes.(); KV.put(:fc_subject, root); KV.put(:fc_sources, [src]); KV.put(:links, %{{root, src} => []})
  dir = fresh_dir.("st"); {a, clock} = new_clock.(t0)
  {u0, l0} = start_l.(dir, clock, recheck_ms: interval)
  efx = Map.new(accounts, fn d -> {d, fx.()} end)
  for d <- accounts, do: (:ok = Listeners.track(d, efx[d]); :ok = Listeners.listen(d, "g", spec_g, room); :ok = Listeners.listen(d, "f", spec_f, room))
  connect.()
  st = %{efx: efx, now: t0, serial: 0, log: %{}, crash: nil}
  st = Enum.reduce(1..steps, st, fn step, st ->
    d = Enum.random(accounts)
    st = case :rand.uniform(10) do
      1 -> Process.exit(st.efx[d], :kill); Process.sleep(5); nf = fx.(); r = safe.(fn -> Listeners.track(d, nf) end)
           if Process.whereis(Listeners), do: send(Listeners, {:at_mcp_stream_connected, :test})
           %{st | efx: Map.put(st.efx, d, nf), log: Map.update(st.log, :login, 1, &(&1 + 1))} |> Map.put(:last, r)
      2 -> safe.(fn -> Listeners.unlisten(d, "g") end); safe.(fn -> Listeners.listen(d, "g", spec_g, room) end); Map.update(st, :log, %{}, &Map.update(&1, :relisten, 1, fn n -> n + 1 end))
      3 -> if Process.whereis(Listeners), do: send(Listeners, {:at_mcp_stream_connected, :test}); Map.update(st, :log, %{}, &Map.update(&1, :reconnect, 1, fn n -> n + 1 end))
      4 -> KV.put(:fc_sources, if(:rand.uniform(2) == 1, do: :fail, else: [src])); st
      5 -> n = st.serial + 1; k = tid.(st.now - :rand.uniform(1800), n)
           KV.put(:links, Map.update(KV.get(:links), {root, src}, [], &[%{did: bob, collection: post, rkey: k} | &1])); %{st | serial: n}
      6 -> now = st.now + :rand.uniform(120); set_time.(a, now); %{st | now: now}
      _ -> n = st.serial + 1; ahead = if :rand.uniform(5) == 1, do: :rand.uniform(86_400), else: 0
           rec_live.(tid.(st.now + ahead, n), st.now); %{st | serial: n}
    end
    Process.sleep(15)
    if st.crash == nil and not (alive.(Updates) and alive.(Listeners)), do: %{st | crash: step}, else: st
  end)
  # Quiet phase: listings work, no churn, the clock moves on.
  KV.put(:fc_sources, [src]); set_time.(a, st.now + 60); Process.sleep(8 * interval)
  quiet = for _ <- 1..5 do b = KV.get(:fc_subject_listings, 0); Process.sleep(interval); KV.get(:fc_subject_listings, 0) - b end
  s = lstate.(); now = clock.()
  per = for d <- accounts do
    g = held.(d, "g"); f = held.(d, "f")
    fl = for id <- ["g", "f"], do: (case safe.(fn -> Updates.forgotten_through(d, id) end) do {:ok, x} when is_integer(x) -> x - now; x -> x end)
    m = case safe.(fn -> Updates.stream_cursor("listeners_live:" <> d) end) do x when is_integer(x) -> x - now; x -> x end
    %{dups_g: dups.(g), dups_f: dups.(f), mark_minus_now: m, floors_minus_now: fl}
  end
  report.("A5 seed #{seed}", %{steps: steps, churn: st.log, crashed_at_step: st.crash, alive_at_end: {alive.(Updates), alive.(Listeners)},
    same_processes: {Process.whereis(Updates) == u0, Process.whereis(Listeners) == l0},
    recheck_pending_after_quiet: s && is_reference(Map.get(s, :recheck)), accounts_held_after_quiet: s && MapSet.size(s.live_hold),
    quiet_listings_per_interval: quiet, per_account: per})
  stop.(Listeners); stop.(Updates); Agent.stop(a)
end
IO.puts("DONE")

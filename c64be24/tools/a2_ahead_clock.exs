# A2 (axis 1, receipts): records dated in the future, and this host's clock behind its sources.
# Docs (c64be24, docs/listeners.md): "a record dated after its save is noted by digest with its later date ('ahead'
# in the account's file) and counts as held until the floor reaches that date. The floor itself never passes the
# receipts' saves"; "no date a client writes can move a listener's floor past now"; known limit: "duplicates come back
# when records dated after their saves are let go faster than the bound holds them: ... this host's clock behind its
# sources by more than the limit's worth of saves (at the default limit, 5 minutes behind at more than 3.3 saves a
# second, or a minute behind at more than 16.7)".
# Method: a records listener (bounds count 10, so the receipt limit is the minimum, 1,000); live records saved through
# the Jetstream path at a controlled rate on an injected clock. A record would come back as a duplicate if a read that
# pages by its date (the records backfill) meets it while it is neither held by a receipt nor by a note: measured
# directly with Updates.held/4 and the floor (forgotten_through), then confirmed by a real records backfill.
room = %{"count" => 10, "age_seconds" => 604_800}
spec_f = %{"source" => "records", "authors" => [alice], "collections" => [post]}
uri = fn k -> "at://#{alice}/#{post}/#{k}" end
date_of = fn k -> AtMcp.Listeners.tid_seconds(k) end
setup = fn name ->
  reset_fakes.(); dir = fresh_dir.(name); {a, clock} = new_clock.(t0)
  start_l.(dir, clock, []); :ok = Listeners.track(me, :me_fx); :ok = Listeners.listen(me, "f", spec_f, room); connect.()
  {dir, a, clock}
end
# Saves `n` records at `rate` per second (rate >= 1, whole seconds on the clock); record i is dated `skew` seconds
# after the clock when it is saved. Returns the keys, oldest first.
feed = fn a, start, n, rate, skew ->
  for i <- 1..n do
    now = start + div(i - 1, rate)
    if rem(i - 1, rate) == 0, do: (set_time.(a, now); Process.sleep(12))
    k = tid.(now + skew, i); rec_live.(k, now); k
  end
end
settle = fn -> Process.sleep(400) end
seq_of = fn dir -> case File.read(Path.join([dir, "listeners", me <> ".json"])) do {:ok, t} -> Jason.decode!(t)["next_seq"]; e -> e end end
probe = fn keys, now ->
  {:ok, h} = Updates.held(me, "f", Enum.map(keys, uri), Updates)
  fl = case Updates.forgotten_through(me, "f") do {:ok, x} when is_integer(x) -> x; _ -> nil end
  exposed = Enum.count(keys, fn k -> not MapSet.member?(h, uri.(k)) and is_integer(fl) and date_of.(k) > fl end)
  %{floor_minus_now: if(fl, do: fl - now), held: MapSet.size(h), exposed_to_a_dated_read: exposed}
end

# S1: one record far ahead, then enough ordinary saves to let its receipt go.
for {label, mk} <- [{"1 hour ahead", &tid.(&1 + 3600, 1)}, {"1 day ahead", &tid.(&1 + 86_400, 1)}, {"1 year ahead", &tid.(&1 + 31_536_000, 1)},
                    {"100 years ahead", &tid.(&1 + 3_153_600_000, 1)}, {"largest 13-char key (zzzzzzzzzzzzz)", fn _ -> "zzzzzzzzzzzzz" end},
                    {"top bit set (k22222222222)", fn _ -> "k222222222222" end}] do
  {dir, a, clock} = setup.("s1")
  ahead = mk.(t0); set_time.(a, t0); rec_live.(ahead, t0); settle.()
  ordinary = feed.(a, t0 + 1, 1100, 10, 0); settle.()
  now = clock.()
  p = probe.([ahead], now)
  # A real records backfill: the repository holds everything; a restart makes the listener read it.
  KV.put(:repo, Enum.reverse([ahead | ordinary]))
  before = seq_of.(dir)
  stop.(Listeners); start_l.(dir, clock, []); :ok = Listeners.track(me, :me_fx); connect.(); Process.sleep(1500)
  u = held.(me, "f")
  report.("A2 S1 #{label}", Map.merge(p, %{date_of_key: date_of.(ahead), saved_again_by_backfill: seq_of.(dir) - before, ahead_record_in_last_updates: (if is_list(u), do: Enum.count(u, &(&1 == uri.(ahead))), else: u), account_mark_minus_now: (case amark.(me) do x when is_integer(x) -> x + t0 - now; x -> x end)}))
end

# S2: the clock behind the sources by 300 s; every record is dated 300 s after its save. Rates in saves per second.
# Documented threshold: duplicates above 1000 / 300 = 3.33 saves per second.
for rate <- [1, 2, 3, 4, 5, 8] do
  {dir, a, clock} = setup.("s2")
  keys = feed.(a, t0 + 1, 2500, rate, 300); settle.()
  p = probe.(keys, clock.())
  predicted = if rate > 1000 / 300, do: :duplicates, else: :none
  observed = if p.exposed_to_a_dated_read > 0, do: :duplicates, else: :none
  verdict = cond do predicted == observed -> "HOLDS"; observed == :none -> "IMPROVED"; true -> "DETERIORATED" end
  KV.put(:repo, Enum.reverse(keys)); before = seq_of.(dir)
  stop.(Listeners); start_l.(dir, clock, []); :ok = Listeners.track(me, :me_fx); connect.(); Process.sleep(2500)
  report.("A2 S2 clock 300 s behind, #{rate} saves/s", Map.merge(p, %{predicted: predicted, verdict: verdict, saved_again_by_backfill: seq_of.(dir) - before, repo_pages_read: KV.get(:repo_calls, 0)}))
end
IO.puts("DONE")

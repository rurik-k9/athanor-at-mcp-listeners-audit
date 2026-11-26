# A6 (axis 1, receipts): the two clock cases left open in this round's first pass.
# K1: this host's clock runs ahead, receipts are saved and let go under it (the floor is its time), then the clock is
#     stepped back to the right time while the service runs (an NTP step, a VM resumed). Docs: the poll "passes and
#     counts" a notification it finds not held "at or before the floor"; settle_future fixes a floor past now only at
#     start.
# K2: this host's clock constantly ahead of the AppView by delta, notifications saved at a steady rate. A new
#     notification is passed if its indexed_at is at or before the floor, the save time (host clock) of the newest
#     receipt let go, about L/rate seconds before now on the host clock. Predicted: losses (counted) iff
#     rate >= L / delta. This is the mirror of the documented duplicates limit (host clock *behind*), and is not in
#     the docs.
# Built-in listener ("references"), its notifications read by the poll, triggered by hand (poll_ms very long), one
# page per read (at most 100 items), so no cursor is involved. Clock near real time (settle_future compares with the
# files' real mtime). Loss is measured with Updates.held/4: a notification the AppView has that the store doesn't hold.
real = System.system_time(:second)
page = 100
mention = fn i, at -> %{uri: "at://#{bob}/#{post}/#{tid.(at, i)}", reason: "mention", author_did: bob, indexed_at: iso.(at),
                         author: %{did: bob, handle: "bob.test"}} end
poll = fn -> send(Listeners, :poll_notifications); Process.sleep(60) end
limit_of = fn dir -> case File.read(Path.join([dir, "listeners", me <> ".json"])) do
    {:ok, t} -> j = Jason.decode!(t); c = get_in(j, ["listeners", "references", "bounds", "count"]); if is_integer(c), do: max(c * 4, 1000), else: {:no_count, c}
    e -> e end end
held_n = fn uris -> {:ok, h} = Updates.held(me, "references", uris, Updates); MapSet.size(h) end
setup = fn name, host0 ->
  reset_fakes.(); dir = fresh_dir.(name); {a, clock} = new_clock.(host0)
  start_l.(dir, clock, poll_ms: 3_600_000)
  :ok = Listeners.track(me, :me_fx); connect.()
  {dir, a, clock}
end
# Feeds `n` mentions, `per` per host second, indexed at host - skew; polls once per host second. Returns their uris.
feed = fn a, host_start, n, per, skew, serial ->
  {uris, _} = Enum.map_reduce(1..n, [], fn i, recent ->
    host = host_start + div(i - 1, per)
    m = mention.(serial + i, host - skew)
    recent = Enum.take([m | recent], page)
    if rem(i, per) == 0 or i == n do
      set_time.(a, host); KV.put({:notes, :me_fx}, recent); poll.()
    end
    {m.uri, recent}
  end)
  uris
end

# K1
{dir, a, clock} = setup.("k1", real + 3600)
old = feed.(a, real + 3600, 1300, 10, 3600, 0)         # host 1 h ahead; mentions indexed at the real time
Process.sleep(300)
fl1 = if function_exported?(Updates, :forgotten_through, 3), do: (case Updates.forgotten_through(me, "references") do {:ok, x} when is_integer(x) -> x; x -> x end), else: :absent_in_this_build
set_time.(a, real + 140)                                 # the clock is corrected while running
new = feed.(a, real + 140, 50, 5, 0, 5000)
Process.sleep(300)
report.("A6 K1 clock 1 h ahead, then stepped back while running", %{receipt_limit: limit_of.(dir), old_held: held_n.(old), floor_minus_corrected_now: (if is_integer(fl1), do: fl1 - (real + 150), else: fl1),
  new_after_step: length(new), new_held: held_n.(new), new_lost: length(new) - held_n.(new), unrecovered_counted: stat.(me, "references", :unrecovered)})
stop.(Listeners); stop.(Updates); Agent.stop(a)

# K1 control: the same restart-free sequence with the clock right throughout.
{dir, a, _clock} = setup.("k1c", real)
old = feed.(a, real, 1300, 10, 0, 0); Process.sleep(300)
new = feed.(a, real + 140, 50, 5, 0, 5000); Process.sleep(300)
report.("A6 K1 control: clock right throughout", %{old_held: held_n.(old), new_held: held_n.(new), new_lost: length(new) - held_n.(new), unrecovered_counted: stat.(me, "references", :unrecovered)})
stop.(Listeners); stop.(Updates); Agent.stop(a)

if System.get_env("K1_ONLY") == "1", do: (IO.puts("DONE"); System.halt(0))
# K2: constant skew of 120 s, rates around the predicted threshold L / 120.
for per <- [4, 6, 8, 10, 12, 16] do
  {dir, a, _clock} = setup.("k2", real)
  warm = feed.(a, real, 1200, per, 120, 0)              # fills the receipts past the limit
  Process.sleep(300)
  probe = feed.(a, real + div(1200, per) + 1, 200, per, 120, 10_000)
  Process.sleep(300)
  l = limit_of.(dir)
  predicted = if is_integer(l) and per >= l / 120, do: :losses, else: :none
  lost = length(probe) - held_n.(probe)
  report.("A6 K2 clock 120 s ahead of the AppView, #{per} saves/s", %{receipt_limit: l, predicted: predicted, probe: length(probe), probe_lost: lost,
    warm_held: held_n.(warm), unrecovered_counted: stat.(me, "references", :unrecovered),
    verdict: cond do (lost > 0) == (predicted == :losses) -> "AS PREDICTED"; lost > 0 -> "LOSSES BELOW THE PREDICTED THRESHOLD"; true -> "NO LOSS ABOVE IT" end})
  stop.(Listeners); stop.(Updates); Agent.stop(a)
end
IO.puts("DONE")

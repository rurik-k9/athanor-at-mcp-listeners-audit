# F4, standalone: the built-in listener's notifications poll reads from `notified_through - 300 s`, and
# `notified_through` starts at this host's clock at login and only moves forward (lib/at_mcp/listeners.ex, track and
# handle_info({:notified, ...})); later it moves only with the notifications' own dates, capped at now. A host clock
# ahead of the AppView by more than the 300 s overlap *at login* (including a clock stepped back later, if the login
# happened while it was ahead) makes the poll filter out every notification indexed before that point: none is
# saved, and none is counted (they are dropped before the floor check that counts). A clock that runs ahead only
# after a correct login does not do it (negative control below). Self-contained. Run inside an at_mcp release:
#   RELEASE_MODE=interactive bin/at_mcp eval 'Code.eval_file("f4_poll_clock_ahead.exs")'
# Only the poll path is modelled: no live stream, no backfill (which may deliver some of these by another path).
#   control  clock right: 20 mentions polled, all saved.
#   ahead    clock 1 h ahead at login: 20 mentions indexed at the real time, polled: saved? counted?
#   after    negative control: clock right at login, 1 h ahead for one poll, then right again: 20 new mentions.
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
{:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
defmodule F4.C do
  def sources(_), do: {:ok, []}
  def backlinks(_, _, _), do: {:ok, [], nil}
end
defmodule F4.R do
  def pds(_), do: {:ok, "https://pds.invalid"}
  def collections(_, _), do: {:ok, []}
  def records(_, _, _, _), do: {:ok, [], nil}
end
alias AtMcp.{Listeners, Updates}
did = "did:plc:f4account"; bob = "did:plc:f4bob"; post = "town.delve.feed.post"
alpha = ~c"234567abcdefghijklmnopqrstuvwxyz"
tid = fn sec, n -> v = Bitwise.bor(Bitwise.bsl(sec * 1_000_000 + n, 10), 1); for(i <- 12..0//-1, do: Enum.at(alpha, Bitwise.band(Bitwise.bsr(v, i * 5), 31))) |> to_string() end
iso = fn t -> t |> DateTime.from_unix!() |> DateTime.to_iso8601() end
kill = fn name -> if p = Process.whereis(name), do: (Process.unlink(p); r = Process.monitor(p); Process.exit(p, :kill); receive do {:DOWN, ^r, _, _, _} -> :ok end) end
real = System.system_time(:second)
run = fn host_at_login, host_later, serial ->
  dir = Path.join(System.tmp_dir!(), "f4-#{System.unique_integer([:positive])}"); File.mkdir_p!(dir); File.chmod!(dir, 0o700)
  {:ok, a} = Agent.start(fn -> host_at_login end); clock = fn -> Agent.get(a, & &1) end
  :persistent_term.put(:f4_items, [])
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(clock: clock, constellation: F4.C, repos: F4.R,
    notifications: fn _e, _o -> {:ok, %{items: :persistent_term.get(:f4_items)}} end,
    profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end, batch_ms: 10, recheck_ms: 3_600_000,
    notifications_poll_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"); Process.unlink(l)
  :ok = Listeners.track(did, :f4_effects); send(Listeners, {:at_mcp_stream_connected, :f4}); Process.sleep(300)
  # One poll while the host clock reads host_later (for "stepped": the clock runs ahead a while)
  Agent.update(a, fn _ -> host_later end); send(Listeners, :poll_notifications); Process.sleep(200)
  # The clock right again; 20 mentions indexed at the real time, then a poll.
  Agent.update(a, fn _ -> real + 120 end)
  items = for i <- 20..1//-1, do: %{uri: "at://#{bob}/#{post}/#{tid.(real + 60 + i, serial + i)}", reason: "mention", author_did: bob, indexed_at: iso.(real + 60 + i), author: %{did: bob, handle: "bob.test"}}
  :persistent_term.put(:f4_items, items); send(Listeners, :poll_notifications); Process.sleep(500)
  {:ok, h} = Updates.held(did, "references", Enum.map(items, & &1.uri))
  r = %{saved: MapSet.size(h), of: 20, unrecovered: get_in(Listeners.stats(did), ["references", :unrecovered])}
  kill.(Listeners); kill.(Updates); Agent.stop(a); r
end
c = run.(real, real + 1, 0)
ahead = run.(real + 3600, real + 3600, 100)
stepped = run.(real, real + 3600, 200)
IO.puts("RESULT\tF4 control (clock right)\t#{inspect(c)}\t#{if c.saved == 20, do: "all saved", else: "UNEXPECTED"}")
IO.puts("RESULT\tF4 clock 1 h ahead at login\t#{inspect(ahead)}\t#{if ahead.saved == 0 and ahead.unrecovered in [nil, 0], do: "REPRODUCED (none saved, none counted)", else: "NOT REPRODUCED"}")
IO.puts("RESULT\tF4 negative control: clock right at login, ahead for one poll only\t#{inspect(stepped)}\t#{if stepped.saved == 20, do: "not affected, as expected (the cause is the start at login)", else: "AFFECTED (unexpected)"}")
IO.puts("DONE")

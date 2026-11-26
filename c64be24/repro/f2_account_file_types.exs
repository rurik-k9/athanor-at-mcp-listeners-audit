# F2, standalone: an account file that is valid JSON with a field of the wrong type crashes at_mcp's store on use; for
# some fields the supervisor gives up, for every account. Self-contained. Run inside an at_mcp release:
#   RELEASE_MODE=interactive bin/at_mcp eval 'Code.eval_file("f2_account_file_types.exs")'
# Two accounts log in, each with a records listener; one account's file is then edited (one field), and the store
# starts again under a supervisor like AtMcp.Supervisor (one_for_one, default intensity) with a caller retrying
# Listeners.track every 2 s for each account, as AtMcp.Listen does. Per case: whether the supervisor survives 12 s,
# and whether the undamaged account still saves a live record.
# Cases: "listeners": [] (down on every build back to the 0.3.3-hum.11 release: pre-existing);
#        "receipts": null (regression from 9499b75: down 8 of 8 runs on 9499b75 and on c64be24; survives on the
#        0.3.3-hum.11 release, b653ead, 3d43966 and 11add1b; on 9281970 it survived 6 of 7 runs, one run went down,
#        a timing effect we did not explain);
#        "next_seq": "x" (children restart, supervisor survives); control (no edit).
for app <- [:crypto, :ssl, :gun], do: Application.ensure_all_started(app)
Logger.configure(level: :none)
:ets.new(AtMcp.Stream.Filters, [:named_table, :public, :set])
{:ok, _} = Registry.start_link(keys: :duplicate, name: AtMcp.Listen.Registry)
defmodule F2.Constellation do
  def sources(_), do: {:ok, []}
  def backlinks(_, _, _), do: {:ok, [], nil}
end
defmodule F2.Repos do
  def pds(_), do: {:ok, "https://pds.invalid"}
  def collections(_, _), do: {:ok, ["town.delve.feed.post"]}
  def records(_, _, _, _), do: {:ok, [], nil}
end
alias AtMcp.{Listeners, Updates}
alias AtMcp.Stream.Event
damaged = "did:plc:f2damaged"; healthy = "did:plc:f2healthy"; alice = "did:plc:f2alice"; post = "town.delve.feed.post"
spec = %{"source" => "records", "authors" => [alice], "collections" => [post]}; room = %{"count" => 2000, "age_seconds" => 604_800}
alpha = ~c"234567abcdefghijklmnopqrstuvwxyz"
tid = fn sec, n -> v = Bitwise.bor(Bitwise.bsl(sec * 1_000_000 + n, 10), 1); for(i <- 12..0//-1, do: Enum.at(alpha, Bitwise.band(Bitwise.bsr(v, i * 5), 31))) |> to_string() end
clock = fn -> System.system_time(:second) end
opts = [clock: clock, constellation: F2.Constellation, repos: F2.Repos, notifications: fn _e, _o -> {:ok, %{items: []}} end,
  profiles: fn _e, d -> {:ok, %{items: Enum.map(d, &%{did: &1, viewer: %{}})}} end, batch_ms: 10, recheck_ms: 3_600_000,
  notifications_poll_ms: 3_600_000, relay: "ws://127.0.0.1:9/", records_relay: "ws://127.0.0.1:9/"]
kill = fn name -> if p = Process.whereis(name), do: (Process.unlink(p); r = Process.monitor(p); Process.exit(p, :kill); receive do {:DOWN, ^r, _, _, _} -> :ok end) end
live = fn k -> if Process.whereis(Listeners), do: send(Listeners, {:jetstream, %Event{kind: :commit, did: alice, collection: post, rkey: k, operation: :create, cursor: System.os_time(:microsecond)}}) end
for {name, edit} <- [{"control (no edit)", nil}, {"listeners: [] (pre-existing)", {["listeners"], []}},
                     {"receipts: null (regression from 9499b75)", {["receipts"], nil}}, {"next_seq: \"x\"", {["next_seq"], "x"}}] do
  dir = Path.join(System.tmp_dir!(), "f2-#{System.unique_integer([:positive])}"); File.mkdir_p!(dir); File.chmod!(dir, 0o700)
  {:ok, u} = Updates.start_link(state_dir: dir, clock: clock); Process.unlink(u)
  {:ok, l} = Listeners.start_link(opts); Process.unlink(l)
  for d <- [damaged, healthy], do: (:ok = Listeners.track(d, :"fx_#{d}"); :ok = Listeners.listen(d, "f", spec, room))
  send(Listeners, {:at_mcp_stream_connected, :f2}); Process.sleep(300); live.(tid.(clock.(), 1)); Process.sleep(300)
  kill.(Listeners); kill.(Updates)
  if edit do
    {path, value} = edit; f = Path.join([dir, "listeners", damaged <> ".json"])
    File.write!(f, Jason.encode!(put_in(Jason.decode!(File.read!(f)), path, value)))
  end
  Process.flag(:trap_exit, true)
  {:ok, sup} = Supervisor.start_link([{Updates, state_dir: dir, clock: clock}, {Listeners, opts}], strategy: :one_for_one)
  retries = for d <- [damaged, healthy], do: spawn(fn -> for _ <- 1..6, do: (try do Listeners.track(d, :"fx_#{d}") catch :exit, _ -> :ok end; Process.sleep(2000)) end)
  Process.sleep(1500); if Process.whereis(Listeners), do: send(Listeners, {:at_mcp_stream_connected, :f2})
  Process.sleep(500); k = tid.(clock.(), 2); live.(k); Process.sleep(10_000)
  up = Process.alive?(sup)
  saved = try do (case Updates.read(healthy, peek: true, limit: 100, listener: "f") do {:ok, r} -> Enum.any?(r.updates, &(&1["uri"] == "at://#{alice}/#{post}/#{k}")); e -> e end) catch _, _ -> :store_down end
  IO.puts("RESULT\tF2 #{name}\t#{inspect(%{supervisor_alive_after_12s: up, healthy_account_saved_live_record: saved})}\t#{if up, do: "supervisor survives", else: "SUPERVISOR DOWN"}")
  Enum.each(retries, &Process.exit(&1, :kill)); if Process.alive?(sup), do: Supervisor.stop(sup); Process.flag(:trap_exit, false)
  receive do {:EXIT, ^sup, _} -> :ok after 100 -> :ok end
end
IO.puts("DONE")

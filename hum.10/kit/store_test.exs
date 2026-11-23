# Black-box checks of AtMcp.Updates in the released 0.3.3-hum.6 beams.
# Run inside bwrap: no network, no home directory, no account, temporary state.
{:ok, _} = Application.ensure_all_started(:crypto)
alias AtMcp.Updates

did = "did:plc:testaccount"
base = "/work/state-#{System.unique_integer([:positive])}"
File.mkdir_p!(base)

uri = fn n -> "at://did:plc:sender/town.delve.feed.post/#{n}" end
item = fn n -> %{"uri" => uri.(n), "source" => "links", "from" => "did:plc:sender"} end
put = fn id, b -> :ok = (case Updates.put_listener(did, id, %{"source" => "links"}, b) do {:ok, :ok} -> :ok; o -> o end) end
report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 12)}") end
restart = fn opts ->
  pid = Process.whereis(Updates)
  if pid do
    Process.unlink(pid)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    receive do {:DOWN, ^ref, _, _, _} -> :ok end
  end
  {:ok, p} = Updates.start_link(opts)
  Process.unlink(p)
end
fresh = fn name, clock ->
  dir = Path.join(base, name)
  File.mkdir_p!(dir)
  o = [state_dir: dir] ++ if(clock, do: [clock: clock], else: [])
  restart.(o)
  o
end
seqs = fn r -> Enum.map(r.updates, & &1["seq"]) end

# 1. Unread survives a hard kill; ack without a read after restart moves nothing.
o = fresh.("persist", nil); put.("references", %{})
{:ok, _} = Updates.commit(Enum.map(1..3, &{did, "references", item.(&1)}))
restart.(o)
{:ok, r} = Updates.read(did, peek: true); report.("1a unread after kill (expect 3)", length(r.updates))
restart.(o); Updates.ack(did, 3)
{:ok, r} = Updates.read(did, peek: true); report.("1b ack with no read after restart keeps unread (expect 3)", length(r.updates))

# 2. Cumulative ack: only what was shown.
{:ok, r} = Updates.read(did, limit: 2); Updates.ack(did, 3)
{:ok, r2} = Updates.read(did, peek: true); report.("2a ack past shown stops at shown (expect [3])", seqs.(r2))
_ = r

# 3. Crash between read and ack: redelivered.
o = fresh.("redeliver", nil); put.("references", %{})
{:ok, _} = Updates.commit([{did, "references", item.(1)}])
{:ok, _} = Updates.read(did); restart.(o)
{:ok, r} = Updates.read(did, peek: true); report.("3 read, crash, no ack: redelivered (expect 1)", length(r.updates))

# 4. Same record, same listener: deduplicated, also after ack.
{:ok, a} = Updates.commit([{did, "references", item.(1)}]); report.("4a same uri again adds (expect 0)", length(a))
{:ok, _} = Updates.read(did); Updates.ack(did, 1)
{:ok, a} = Updates.commit([{did, "references", item.(1)}]); report.("4b same uri after ack adds (expect 0)", length(a))

# 5. Same record matched by two listeners.
fresh.("two", nil); put.("references", %{}); put.("thread", %{})
{:ok, a} = Updates.commit([{did, "references", item.(1)}, {did, "thread", item.(1)}])
{:ok, r} = Updates.read(did, peek: true)
report.("5 one post, two listeners: updates for the same uri", {length(a), r.updates |> Enum.map(& &1["uri"]) |> Enum.uniq() |> length()})

# 6. Count bound drops unread updates, and the receipt blocks their return.
fresh.("bound", nil); put.("references", %{"count" => 5})
{:ok, _} = Updates.commit(Enum.map(1..8, &{did, "references", item.(&1)}))
{:ok, r} = Updates.read(did, peek: true, limit: 100)
report.("6a 8 unread, bound 5: kept / dropped count", {length(r.updates), r.dropped})
report.("6b oldest kept uri", r.updates |> hd() |> Map.get("uri"))
{:ok, a} = Updates.commit([{did, "references", item.(1)}]); report.("6c dropped unread re-offered by backfill: re-added (0 = lost)", length(a))
{:ok, r} = Updates.read(did, limit: 100); Updates.ack(did, r.updates |> List.last() |> Map.get("seq"))
{:ok, r} = Updates.read(did, peek: true); report.("6d dropped counter after ack", r.dropped)

# 7. Age bound drops unread updates at the next commit.
{:ok, now} = Agent.start_link(fn -> 1_000_000 end)
clock = fn -> Agent.get(now, & &1) end
fresh.("age", clock); put.("references", %{})
{:ok, _} = Updates.commit([{did, "references", item.(1)}])
Agent.update(now, &(&1 + 7 * 24 * 3600 + 1))
{:ok, r} = Updates.read(did, peek: true); report.("7a unread past 7 days, before next commit", length(r.updates))
{:ok, _} = Updates.commit([{did, "references", item.(2)}])
{:ok, r} = Updates.read(did, peek: true); report.("7b after next commit: uris kept / dropped", {length(r.updates), r.dropped})

# 8. Receipt window: an old acknowledged record offered again.
fresh.("receipts", nil); put.("references", %{})
{:ok, _} = Updates.commit([{did, "references", item.(0)}])
{:ok, _} = Updates.read(did); Updates.ack(did, 1)
Enum.chunk_every(1..1000, 100) |> Enum.each(fn c ->
  {:ok, _} = Updates.commit(Enum.map(c, &{did, "references", item.(&1)}))
end)
{:ok, a} = Updates.commit([{did, "references", item.(0)}]); report.("8 acked record re-offered after 1000 newer: re-added (1 = duplicate)", length(a))

# 9. Per-item decisions: a deferred oldest item and a later urgent one.
fresh.("defer", nil); put.("references", %{})
{:ok, _} = Updates.commit(Enum.map(1..3, &{did, "references", item.(&1)}))
{:ok, _} = Updates.read(did); Updates.ack(did, 3)
{:ok, r} = Updates.read(did, peek: true); report.("9a ack 3 with item 1 still undecided: unread left (0 = item 1 no longer tracked)", length(r.updates))
fresh.("defer2", nil); put.("references", %{})
{:ok, _} = Updates.commit(Enum.map(1..3, &{did, "references", item.(&1)}))
{:ok, _} = Updates.read(did); Updates.ack(did, 0)
{:ok, r} = Updates.read(did, peek: true); report.("9b keep item 1: items 2,3 also stay unread", seqs.(r))

# 10. Write cost at the default bound.
o = fresh.("perf", nil); put.("references", %{})
{:ok, _} = Updates.commit(Enum.map(1..200, &{did, "references", item.(&1)}))
{us, {:ok, _}} = :timer.tc(fn -> Updates.commit([{did, "references", item.(201)}]) end)
report.("10 one commit with 200 held (ms)", div(us, 1000)); _ = o
IO.puts("DONE")

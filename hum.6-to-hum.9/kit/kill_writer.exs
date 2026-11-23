# Writer for the kill -9 test: commits one update at a time and records each
# acknowledged commit in an fsynced journal.
{:ok, _} = Application.ensure_all_started(:crypto)
alias AtMcp.Updates
did = "did:plc:testaccount"
dir = System.fetch_env!("KILL_DIR")
start = String.to_integer(System.fetch_env!("KILL_START"))
{:ok, _} = Updates.start_link(state_dir: dir)
Updates.put_listener(did, "references", %{"source" => "links"}, %{"count" => 100_000})
{:ok, j} = :file.open(Path.join(dir, "journal"), [:append, :raw, :binary])
Stream.iterate(start, &(&1 + 1)) |> Enum.each(fn n ->
  uri = "at://did:plc:sender/town.delve.feed.post/#{n}"
  {:ok, _} = Updates.commit([{did, "references", %{"uri" => uri, "source" => "links", "from" => "did:plc:sender"}}])
  :ok = :file.write(j, uri <> "\n")
  :ok = :file.sync(j)
end)

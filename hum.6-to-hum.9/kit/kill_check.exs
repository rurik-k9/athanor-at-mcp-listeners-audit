# After the kills: the file must decode and hold every journaled update exactly once.
{:ok, _} = Application.ensure_all_started(:crypto)
alias AtMcp.Updates
did = "did:plc:testaccount"
dir = System.fetch_env!("KILL_DIR")
{:ok, _} = Updates.start_link(state_dir: dir)
{:ok, r} = Updates.read(did, peek: true, limit: 1_000_000)
held = Enum.map(r.updates, & &1["uri"])
journal = Path.join(dir, "journal") |> File.read!() |> String.split("\n", trim: true)
missing = journal -- held
IO.puts("RESULT\tkill-9: journaled=#{length(journal)} held=#{length(held)} missing=#{length(missing)} duplicates=#{length(held) - length(Enum.uniq(held))}")

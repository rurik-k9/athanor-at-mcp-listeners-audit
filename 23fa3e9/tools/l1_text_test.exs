# L1 through the tool's own path (D-019, 23fa3e9): get_notifications order: oldest, since: last_read, as
# AtMcp.MCP.Tools.page/5 runs it, in text (cut to the 40,000-character bound by oldest_fitted, NotificationsOldest.cut)
# and in json. Seeded walks under a strict service whose notifications carry texts from 200 to 45,000 characters,
# with equal-time groups and one-unit gaps. When a text page has no seen_through and says over_bound, the walk reads
# that page again with format json, as the reading tells the agent to. Checked as l1_fuzz.exs (safe, progress, ends),
# plus: over_bound only when the cut page is longer than one item, and the text names json. Values are observed.
Logger.configure(level: :none)
Application.put_env(:at_mcp, :notifications_settle_ms, 3)
alias AtMcp.NotificationsOldest, as: NO
report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 30)}") end
base = ~U[2026-11-20 10:00:00.000000Z]
us_of = fn iso -> {:ok, t} = NO.stamp(%{indexed_at: iso}); DateTime.diff(t, base, :microsecond) end
render = fn us, prec ->
  t = DateTime.add(base, us, :microsecond)
  if prec == :ms and rem(us, 1000) == 0, do: DateTime.to_iso8601(%{t | microsecond: {elem(t.microsecond, 0), 3}}),
    else: DateTime.to_iso8601(%{t | microsecond: {elem(t.microsecond, 0), 6}})
end
pick = fn l -> Enum.at(l, :rand.uniform(length(l)) - 1) end
gen = fn seed ->
  :rand.seed(:exsss, {seed, 7_919, 31})
  n = 2 + :rand.uniform(30)
  {its, _} = Enum.map_reduce(0..(n - 1), 0, fn i, us ->
    us = us + pick.([0, 0, 1, 1_000, 1_000, 2_000, 1_000_000]); prec = pick.([:ms, :ms, :us])
    s = render.(us, prec)
    {%{i: i, uri: "at://did:plc:bbbbbbbbbbbbbbbbbbbbbbbb/town.delve.feed.post/n#{i}", reason: pick.(["mention", "reply"]),
       us: us_of.(s), shown: s, len: pick.([200, 200, 5_000, 15_000, 25_000, 45_000])}, us}
  end)
  {its, pick.([1, 2, 3, 5, 10, 20])}
end
walk = fn {items, limit} ->
  {:ok, store} = Agent.start_link(fn -> "2026-11-20T09:00:00.000Z" end)
  read? = fn it, seen -> it.us < us_of.(seen) end
  fetch = fn _l, _c ->
    seen = Agent.get(store, & &1)
    page = items |> Enum.sort_by(&{&1.us, &1.i}, :desc) |> Enum.map(fn it ->
      %{uri: it.uri, reason: it.reason, indexed_at: it.shown, created_at: it.shown, is_read: read?.(it, seen),
        text: String.duplicate("x", it.len), author: %{did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", handle: "b.test"}}
    end)
    {:ok, %{items: page, cursor: nil, seen_at: seen}}
  end
  newest = items |> Enum.map(& &1.us) |> Enum.max()
  Enum.reduce_while(0..(20 * length(items) + 200), %{shown: %{}, now: newest + 10_000, stats: %{reads: 0, over_bound: 0, json: 0, wasted: 0, no_json_hint: 0, ob_single: 0}, fail: nil}, fn _, st ->
    seen = Agent.get(store, & &1)
    unread = Enum.reject(items, &read?.(&1, seen))
    cond do
      unread == [] -> {:halt, Map.put(st, :end, :done)}
      # A loop: 50 reads in a row that made nothing read.
      Map.get(st, :idle, 0) >= 50 -> {:halt, Map.put(st, :end, :loop)}
      true ->
      args = %{order: "oldest", since: "last_read", limit: limit}
      {:ok, %{structuredContent: sc} = res, _} = AtMcp.MCP.Tools.page(fetch, args, %{}, :notifications, "notifications")
      st = update_in(st.stats.reads, &(&1 + 1))
      {sc, st} =
        if sc["over_bound"] == true do
          text = inspect(res, limit: :infinity, printable_limit: :infinity)
          st = update_in(st.stats.over_bound, &(&1 + 1))
          st = if String.contains?(text, "format json"), do: st, else: update_in(st.stats.no_json_hint, &(&1 + 1))
          st = if length(sc["items"]) <= 1, do: update_in(st.stats.ob_single, &(&1 + 1)), else: st
          {:ok, %{structuredContent: j}, _} = AtMcp.MCP.Tools.page(fetch, Map.put(args, :format, "json"), %{format: "json"}, :notifications, "notifications")
          {j, update_in(st.stats.json, &(&1 + 1))}
        else
          {sc, st}
        end
      uris = Enum.map(sc["items"] || [], & &1["uri"])
      st = %{st | shown: Enum.reduce(uris, st.shown, fn u, m -> Map.update(m, u, 1, &(&1 + 1)) end)}
      case sc["seen_through"] do
        through when is_binary(through) ->
          newly = Enum.filter(unread, &read?.(&1, through))
          passed = for i <- newly, not Map.has_key?(st.shown, i.uri), do: i.uri
          st = if passed != [] and st.fail == nil, do: %{st | fail: {:safe, through, passed}}, else: st
          st = if newly == [], do: update_in(st.stats.wasted, &(&1 + 1)), else: st
          st = if newly == [] and st.fail == nil and (sc["held_back"] || 0) == 0, do: %{st | fail: {:progress, through, uris}}, else: st
          if us_of.(through) > us_of.(seen), do: Agent.update(store, fn _ -> through end)
          {:cont, Map.put(st, :idle, if(newly == [], do: Map.get(st, :idle, 0) + 1, else: 0))}
        _ ->
          {:cont, if(st.fail == nil, do: %{st | fail: {:no_seen_through, Map.drop(sc, ["items"])}}, else: st) |> Map.put(:idle, Map.get(st, :idle, 0) + 1)}
      end
    end
  end)
  |> Map.put_new(:end, :no_end)
end
seeds = String.to_integer(System.get_env("TEXT_SEEDS") || "150")
rs = for seed <- 1..seeds, do: {seed, walk.(gen.(seed))}
report.("L1 text: walks / ended / failures by kind", {seeds, Enum.frequencies_by(rs, fn {_, r} -> r.end end), Enum.frequencies_by(for({_, r} <- rs, r.fail, do: r), &elem(&1.fail, 0))})
tot = fn k -> rs |> Enum.map(fn {_, r} -> r.stats[k] end) |> Enum.sum() end
report.("L1 text: reads / over_bound pages / json re-reads / over_bound with one item / over_bound text not naming json / reads acknowledging nothing",
  {tot.(:reads), tot.(:over_bound), tot.(:json), tot.(:ob_single), tot.(:no_json_hint), tot.(:wasted)})
report.("L1 text: notifications / shown again / most shows of one",
  {rs |> Enum.map(fn {s, _} -> length(elem(gen.(s), 0)) end) |> Enum.sum(),
   rs |> Enum.map(fn {_, r} -> r.shown |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum() end) |> Enum.sum(),
   rs |> Enum.map(fn {_, r} -> r.shown |> Map.values() |> Enum.max(fn -> 0 end) end) |> Enum.max()})
for {seed, r} <- Enum.filter(rs, fn {_, r} -> r.fail end) |> Enum.take(4), do: report.("L1 text: example seed #{seed}", r.fail)
IO.puts("DONE")

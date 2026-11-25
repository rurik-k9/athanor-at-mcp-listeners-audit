# L1 campaign for at_mcp 23fa3e9 (D-019): seeded random walks of oldest-first reads, on released or overlaid beams.
# Pure: AtMcp.NotificationsOldest.read/2 and cut/2 against a simulated notifications service. No network, no account.
# Every walk reads, optionally cuts the page as the text reading would, falls back to a full (json) read when the cut
# gives no seen_through (over_bound), acknowledges with seen_through, and reads again, with notifications arriving
# while it walks. Checked at every read:
#   safe     nothing unshown, of the chosen reasons, becomes read through an acknowledgement;
#   settled  nothing stamped within settle_ms of the read is shown;
#   progress a page with a seen_through makes at least one unread notification read (hum's property, 754a231);
#   ends     the walk reaches "nothing unread" within 20 n + 200 reads, or stops on a reported too_many_unread.
# Families vary the population, the service's comparison, its paging and its page size. Values are observed, not asserted.
# Env: FUZZ_SEEDS (per family, default 400), FUZZ_FAMILIES (comma list, default all), FUZZ_OUT (jsonl of failures).
Logger.configure(level: :none)
alias AtMcp.NotificationsOldest, as: NO

defmodule Svc do
  @base ~U[2026-11-20 10:00:00.000000Z]
  def base, do: @base
  def at(us), do: DateTime.add(@base, us, :microsecond)

  # The time written in a notification, at a precision the stamp allows.
  def render(us, prec) do
    t = at(us)
    cond do
      prec == :s and rem(us, 1_000_000) == 0 -> t |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      prec in [:s, :ms, :ms_off] and rem(us, 1_000) == 0 ->
        s = %{t | microsecond: {elem(t.microsecond, 0), 3}} |> DateTime.to_iso8601()
        if prec == :ms_off, do: String.replace_suffix(s, "Z", "+00:00"), else: s
      prec == :us6 -> %{t | microsecond: {elem(t.microsecond, 0), 6}} |> DateTime.to_iso8601()
      true -> %{t | microsecond: {elem(t.microsecond, 0), 6}} |> DateTime.to_iso8601()
    end
  end

  # Shown to the millisecond, whatever the service holds (variant :hidden_us).
  def render_ms(us), do: (t = at(us); %{t | microsecond: {div(elem(t.microsecond, 0), 1000) * 1000, 3}} |> DateTime.to_iso8601())

  def us_of(iso) do
    {:ok, t} = NO.stamp(%{indexed_at: iso})
    DateTime.diff(t, @base, :microsecond)
  end

  # Whether the service counts an item read against its stored seenAt.
  def read?(_item, nil, _cmp), do: false
  def read?(item, seen, :strict), do: item.us < us_of(seen)
  def read?(item, seen, :nonstrict), do: item.us <= us_of(seen)
  def read?(item, seen, :lex), do: item.shown < seen
  def read?(item, seen, :trunc_ms), do: item.us < div(floor_div(us_of(seen), 1000), 1) * 1000
  def read?(item, seen, :hidden_us), do: item.us < us_of(seen)
  defp floor_div(a, b), do: if(a >= 0, do: div(a, b), else: -div(-a + b - 1, b))
end

defmodule Walk do
  # opts: cmp, paging (:offset | :keyset | :time_lt | :time_le), psize, is_read (bool), forward (bool)
  def fetch(items_now, seen, o) do
    sorted = Enum.sort_by(items_now, &{&1.us, &1.i}, :desc)
    fn size, cursor ->
      ps = min(size, o.psize)
      {page, next} =
        case o.paging do
          :offset ->
            from = String.to_integer(cursor || "0")
            pg = sorted |> Enum.drop(from) |> Enum.take(ps)
            {pg, if(from + ps < length(sorted), do: Integer.to_string(from + ps))}
          :keyset ->
            # Proper keyset: time and a tie-breaker, as an opaque cursor.
            rest = case cursor do nil -> sorted; c -> [u, i] = String.split(c, "~") |> Enum.map(&String.to_integer/1); Enum.filter(sorted, &({&1.us, &1.i} < {u, i})) end
            pg = Enum.take(rest, ps)
            {pg, if(length(rest) > ps, do: (l = List.last(pg); "#{l.us}~#{l.i}"))}
          k when k in [:time_lt, :time_le] ->
            # Cursor: the shown time of the page's oldest; next page strictly before it (lt) or at or before it (le).
            rest = case cursor do nil -> sorted; c -> cu = Svc.us_of(c); Enum.filter(sorted, &(if k == :time_lt, do: &1.us < cu, else: &1.us <= cu)) end
            pg = Enum.take(rest, ps)
            {pg, if(length(rest) > ps, do: List.last(pg).shown)}
        end
      items = for it <- page do
        m = %{uri: it.uri, reason: it.reason, indexed_at: it.shown}
        if o.is_read, do: Map.put(m, :is_read, Svc.read?(it, seen, o.cmp)), else: m
      end
      {:ok, %{items: items, cursor: next, seen_at: seen}}
    end
  end

  def run(w) do
    Application.put_env(:at_mcp, :notifications_settle_ms, w.settle_ms)
    st = %{seen: w.seen0, now: w.now0, shown: %{}, reads: 0, idle: 0, stats: %{wasted: 0, no_st: 0, over_bound: 0, json: 0, max_page: 0, dup_in_page: 0},
           fail: nil, end: nil}
    loop(w, st)
  end

  defp visible(w, now), do: Enum.filter(w.items, &(&1.arrive <= now))
  defp unread(w, vis, seen), do: Enum.reject(vis, &Svc.read?(&1, seen, w.o.cmp))

  defp loop(w, st) do
    vis = visible(w, st.now)
    un = unread(w, vis, st.seen)
    all_arrived = length(vis) == length(w.items)
    cond do
      un == [] and all_arrived -> %{st | end: :done}
      st.reads > 20 * length(w.items) + 200 -> %{st | end: :no_end, fail: st.fail || {:ends, "#{length(un)} unread after #{st.reads} reads"}}
      # A loop: 50 reads in a row that made nothing read while nothing was held back or still to arrive.
      st.idle >= 50 -> %{st | end: :loop, fail: st.fail || {:ends, "loop: #{length(un)} unread, 50 reads in a row read nothing, at read #{st.reads}"}}
      true -> step(w, st, vis, un)
    end
  end

  defp step(w, st, vis, un) do
    now_dt = Svc.at(st.now)
    reasons = w.reasons
    res = NO.read(fetch(vis, st.seen, w.o), limit: w.limit, reasons: reasons, now: now_dt)
    case res do
      {:ok, page0} ->
        {page, st} =
          if w.cut && length(page0.items) > w.cut do
            c = NO.cut(page0, w.cut)
            if c[:over_bound], do: {page0, bump(bump(st, :over_bound), :json)}, else: {c, st}
          else
            {page0, st}
          end
        uris = Enum.map(page.items, & &1[:uri])
        if w[:trace], do: IO.puts("TRACE read #{st.reads} now #{st.now} seen #{st.seen} -> #{inspect(Map.drop(page, [:items]) |> Map.put(:shown, uris))}")
        st = put_in(st.stats.max_page, max(st.stats.max_page, length(uris)))
        st = if length(uris) != length(Enum.uniq(uris)), do: bump(st, :dup_in_page), else: st
        settled_by = st.now - w.settle_ms * 1000
        unsettled = for i <- page.items, Svc.us_of(i[:indexed_at]) > settled_by, do: i[:uri]
        st = if unsettled != [] and st.fail == nil, do: %{st | fail: {:settled, "shown unsettled #{inspect(unsettled)} at read #{st.reads}"}}, else: st
        shown = Enum.reduce(uris, st.shown, fn u, m -> Map.update(m, u, 1, &(&1 + 1)) end)
        st = %{st | shown: shown}
        cond do
          is_binary(page[:seen_through]) ->
            through = page.seen_through
            newseen = if w.o.forward and st.seen != nil and Svc.us_of(through) < Svc.us_of(st.seen), do: st.seen, else: through
            after_ = unread(w, vis, newseen) |> Enum.map(& &1.uri) |> MapSet.new()
            newly = for i <- un, not MapSet.member?(after_, i.uri), do: i
            passed = for i <- newly, reasons == nil or i.reason in reasons, not Map.has_key?(shown, i.uri), do: i.uri
            st = if passed != [] and st.fail == nil, do: %{st | fail: {:safe, "#{through} marks unshown #{inspect(Enum.take(passed, 4))} at read #{st.reads}"}}, else: st
            st = if newly == [], do: bump(st, :wasted), else: st
            st = if newly == [] and w.o.cmp in [:strict] and st.fail == nil and w.check_progress,
                   do: %{st | fail: {(if Map.get(page, :held_back, 0) > 0, do: :progress_held, else: :progress), "page #{inspect(Enum.take(uris, 4))} st #{through} reads nothing, held #{Map.get(page, :held_back, 0)}, read #{st.reads}"}}, else: st
            idle = if newly == [] and Map.get(page, :held_back, 0) == 0 and length(vis) == length(w.items), do: st.idle + 1, else: 0
            loop(w, %{st | seen: newseen, now: st.now + w.tick.(st.reads), reads: st.reads + 1, idle: idle})
          Map.has_key?(page, :too_many_unread) ->
            %{st | end: :too_long}
          true ->
            # No seen_through: only while something is unsettled (held back).
            held = Map.get(page, :held_back, 0)
            st = bump(st, :no_st)
            st = if held == 0 and page[:over_bound] != true and length(un) > 0 and st.fail == nil and Enum.all?(vis, &(&1.us <= settled_by)),
                   do: %{st | fail: {:stall, "no seen_through, nothing held, #{length(un)} unread, read #{st.reads}"}}, else: st
            loop(w, %{st | now: st.now + w.tick.(st.reads), reads: st.reads + 1})
        end
      {:error, e} -> %{st | end: {:error, e}, fail: st.fail || {:error, inspect(e)}}
    end
  end

  defp bump(st, k), do: update_in(st.stats[k], &(&1 + 1))
end

defmodule Gen do
  def pick(l), do: Enum.at(l, :rand.uniform(length(l)) - 1)

  # One walk's description from a family and a seed.
  def walk(fam, seed) do
    :rand.seed(:exsss, {fam_id(fam), seed, 104_729})
    base = %{o: %{cmp: :strict, paging: :offset, psize: 100, is_read: true, forward: true}, settle_ms: 3, cut: nil,
             reasons: nil, check_progress: true, seen0: "2026-11-20T09:00:00.000Z", tick: fn _ -> 1_000 end}
    {items, w} = population(fam, base)
    newest = items |> Enum.map(& &1.us) |> Enum.max(fn -> 0 end)
    now0 = w[:now0] || newest + pick([3_000_000, 3_000, 2_000, 1_000])
    items = for it <- items, do: Map.put_new(it, :arrive, -10_000_000_000)
    Map.merge(w, %{items: items, now0: now0, fam: fam, seed: seed})
  end

  defp fam_id(f), do: :erlang.phash2(f)

  defp stamps(n, steps, precs) do
    {its, _} = Enum.map_reduce(0..(n - 1), 0, fn i, us ->
      us = us + pick(steps); prec = pick(precs)
      {%{i: i, uri: "n#{i}", reason: pick(["mention", "reply", "like"]), us: us, shown: Svc.render(us, prec)}, us}
    end)
    # A stamp that could not be written at its precision is written finer; its time is the one written.
    for it <- its, do: %{it | us: Svc.us_of(it.shown)}
  end

  @hum_steps [0, 0, 1, 1_000, 1_000, 1_000, 2_000, 999, 1_001, 500, 1_000_000]
  defp common(w), do: %{w | limit: pick([1, 1, 2, 3, 5, 10]), reasons: pick([nil, nil, ["mention"], ["reply", "like"]]), cut: pick([nil, nil, 1, 2, 3])}

  # A: hum's population (review_l_walk_test.exs), our generator: the same steps, precisions, limits, reasons, cuts.
  def population(:hum, w) do
    n = 1 + :rand.uniform(60) - 1
    {stamps(n, @hum_steps, [:s, :ms, :ms, :us]), common(Map.put(w, :limit, 1))}
  end
  # B: one-unit edges: steps of 0, 1 µs, 1 ms, 999/1001 µs; every precision, offsets other than Z; no cut.
  def population(:edges, w) do
    n = :rand.uniform(40)
    its = stamps(n, [0, 0, 1, 1, 2, 999, 1_000, 1_000, 1_001, 1_000_000], [:s, :ms, :ms_off, :us, :us6])
    {its, %{w | reasons: pick([nil, nil, ["mention"]])} |> Map.put(:limit, pick([1, 1, 1, 2, 3]))}
  end
  # C: large groups of equal times, at or beyond the limit, and the text cut.
  def population(:groups, w) do
    n = 5 + :rand.uniform(80)
    its = stamps(n, [0, 0, 0, 0, 0, 1_000, 1, 1_000_000], [:ms, :us])
    {its, %{w | cut: pick([nil, 1, 2, 4, 8])} |> Map.put(:limit, pick([1, 2, 3, 5, 10, 20]))}
  end
  # D: pagination: up to 600 notifications, the service's page from 3 to 100, offset or proper keyset cursors.
  def population(:pages, w) do
    n = 20 + :rand.uniform(580)
    its = stamps(n, @hum_steps, [:ms, :ms, :us])
    o = %{w.o | psize: pick([3, 7, 25, 100]), paging: pick([:offset, :keyset])}
    {its, %{w | o: o} |> Map.put(:limit, pick([1, 5, 20, 50]))}
  end
  # E: Delvetown-like time cursors (the time of the page's oldest): strictly before it, or at or before it.
  def population(tc, w) when tc in [:time_lt, :time_le] do
    n = 20 + :rand.uniform(300)
    its = stamps(n, [0, 0, 1_000, 1, 999, 1_001, 2_000], [:ms, :ms, :us])
    o = %{w.o | psize: pick([3, 7, 25, 100]), paging: tc}
    {its, %{w | o: o} |> Map.put(:limit, pick([1, 3, 20]))}
  end
  # F: live: notifications arrive while the walk goes on, settle_ms 60 s, reads every 1 to 90 s, some stamped late.
  def population(:live, w) do
    n = 5 + :rand.uniform(80)
    {its, _} = Enum.map_reduce(0..(n - 1), 0, fn i, us ->
      us = us + pick([0, 1, 1_000, 1_000, 5_000_000, 30_000_000, 61_000_000]); prec = pick([:ms, :ms, :us])
      lag = pick([0, 0, 200_000, 2_000_000, 59_000_000])
      {%{i: i, uri: "n#{i}", reason: pick(["mention", "reply"]), us: us, shown: Svc.render(us, prec), arrive: us + lag}, us}
    end)
    its = for it <- its, do: %{it | us: Svc.us_of(it.shown)}
    w = %{w | settle_ms: 60_000, tick: fn _ -> pick([1_000_000, 10_000_000, 61_000_000, 90_000_000]) end}
    {its, w |> Map.put(:limit, pick([1, 2, 5, 20])) |> Map.put(:now0, 0) |> Map.put(:reasons, pick([nil, ["mention"]]))}
  end
  # G: the service compares differently from Delvetown's documented rule (hypotheses, not Delvetown).
  def population({:service, cmp, isr}, w) do
    {its, w} = population(pick([:hum, :edges]), w)
    its = if cmp == :hidden_us do
      # The service keeps microseconds but shows milliseconds.
      for it <- its do us = it.us + pick([0, 0, 1, 400, 999]); %{it | us: us, shown: Svc.render_ms(us)} end
    else its end
    {its, %{w | o: %{w.o | cmp: cmp, is_read: isr}, check_progress: cmp == :strict}}
  end
end

report = fn name, value -> IO.puts("RESULT\t#{name}\t#{inspect(value, limit: 30)}") end
if System.get_env("FUZZ_CASES") do
  # Deterministic minimal cases (W1-W8). items: {name, iso, reason, arrive_us}; times as written.
  mk = fn specs -> for {{u, iso, reason}, i} <- Enum.with_index(specs), do: %{i: i, uri: u, reason: reason, us: Svc.us_of(iso), shown: iso, arrive: -10_000_000_000} end
  basew = %{o: %{cmp: :strict, paging: :offset, psize: 100, is_read: true, forward: true}, settle_ms: 3, cut: nil, reasons: nil, check_progress: true,
            seen0: "2026-11-20T09:00:00.000Z", tick: fn _ -> 1_000 end, limit: 1}
  t = "2026-11-20T10:00:"
  cases = [
    {"W1 one notification to the microsecond (.000400), strict service", mk.([{"n0", t <> "05.000400Z", "mention"}]), %{}},
    {"W2 the same, a service that keeps seenAt to the millisecond (hypothesis)", mk.([{"n0", t <> "05.000400Z", "mention"}]), %{cmp: :trunc_ms}},
    {"W3 one notification to the second (05Z), a service comparing strings (hypothesis)", mk.([{"n0", t <> "05Z", "mention"}]), %{cmp: :lex}},
    {"W4 one notification with offset +00:00, a service comparing strings (hypothesis)", mk.([{"n0", t <> "05.000+00:00", "mention"}]), %{cmp: :lex}},
    {"W5 three at one time across a page of 2, cursor = oldest time, next page strictly before it", mk.([{"n0", t <> "05.000Z", "mention"}, {"n1", t <> "05.000Z", "mention"}, {"n2", t <> "05.000Z", "mention"}, {"n3", t <> "05.001Z", "mention"}, {"n4", t <> "05.002Z", "mention"}]), %{paging: :time_lt, psize: 2, limit: 5}},
    {"W6 the same, next page at or before it", mk.([{"n0", t <> "05.000Z", "mention"}, {"n1", t <> "05.000Z", "mention"}, {"n2", t <> "05.000Z", "mention"}, {"n3", t <> "05.001Z", "mention"}, {"n4", t <> "05.002Z", "mention"}]), %{paging: :time_le, psize: 2, limit: 5}}
  ]
  for {name, items, o} <- cases do
    w = Map.merge(basew, %{items: items, o: Map.merge(basew.o, Map.drop(o, [:limit])), limit: Map.get(o, :limit, 1), now0: Svc.us_of(t <> "10Z"), fam: :cases, seed: 0})
    r = Walk.run(w)
    report.(name <> ": end / reads / shown (distinct of n) / first failure", {r.end, r.reads, map_size(r.shown), length(items), r.fail})
  end
  # W7: the held-back cap. n0 settled at .001, n1 at .002 still within settle_ms (60 s here): pages before it settles.
  items = mk.([{"n0", t <> "05.001Z", "mention"}, {"n1", t <> "05.002Z", "mention"}])
  for {label, off, tick} <- [{"the read falls in the 1 ms between n0 and n1 settling, then a read every 10 s", 60_000_500, 10_000_000},
                             {"the same, a read every 0.1 ms", 60_000_100, 100}, {"n1 still well within settle_ms, a read every 10 s", 30_000_000, 10_000_000}] do
    w = Map.merge(basew, %{items: items, settle_ms: 60_000, check_progress: true, now0: Svc.us_of(t <> "05.001Z") + off, tick: fn _ -> tick end, fam: :cases, seed: 0})
    r = Walk.run(w)
    report.("W7 n0 at .001, n1 at .002, settle 60 s; #{label}: end / reads / reads acknowledging nothing / first failure", {r.end, r.reads, r.stats.wasted, r.fail})
  end
  System.halt(0)
end
if tr = System.get_env("FUZZ_TRACE") do
  [f, sd] = String.split(tr, ":"); fam = if String.starts_with?(f, "service-"), do: (["service", c | r] = String.split(f, "-"); {:service, String.to_atom(c), r == []}), else: String.to_atom(f)
  w = Gen.walk(fam, String.to_integer(sd)) |> Map.put(:trace, true)
  IO.puts("TRACE walk limit #{w.limit} cut #{inspect(w.cut)} reasons #{inspect(w.reasons)} now0 #{w.now0} #{inspect(w.o)}")
  for it <- Enum.sort_by(w.items, & &1.us), do: IO.puts("TRACE item #{it.uri} #{it.reason} #{it.shown} us=#{it.us} arrive=#{it.arrive}")
  r = Walk.run(w); IO.puts("TRACE end #{inspect(r.end)} fail #{inspect(r.fail)}"); System.halt(0)
end
families =
  case System.get_env("FUZZ_FAMILIES") do
    nil -> [:hum, :edges, :groups, :pages, :time_lt, :time_le, :live,
            {:service, :strict, false}, {:service, :nonstrict, true}, {:service, :lex, true},
            {:service, :trunc_ms, true}, {:service, :hidden_us, true}]
    s -> s |> String.split(",") |> Enum.map(&String.to_atom/1)
  end
seeds = String.to_integer(System.get_env("FUZZ_SEEDS") || "400")
out = System.get_env("FUZZ_OUT")
if out, do: File.write!(out, "")
fname = fn {:service, c, r} -> "service-#{c}#{if r, do: "", else: "-noisread"}"; f -> to_string(f) end

report.("L1 fuzz build", (case File.read("/rel/BUILD") do {:ok, b} -> String.trim(b); _ -> :unknown end))
for fam <- families do
  t0 = System.monotonic_time(:millisecond)
  rs = for seed <- 1..seeds do
    w = Gen.walk(fam, seed)
    r = try do Walk.run(w) rescue e -> %{end: :crash, fail: {:crash, Exception.message(e) |> String.slice(0, 160)}, reads: 0, shown: %{}, stats: %{}} end
    {w, r}
  end
  fails = for {w, r} <- rs, r.fail != nil, do: {elem(r.fail, 0), w, r}
  by = Enum.frequencies_by(fails, &elem(&1, 0))
  ends = Enum.frequencies_by(rs, fn {_, r} -> r.end end)
  sum = fn k -> rs |> Enum.map(fn {_, r} -> Map.get(r.stats, k, 0) end) |> Enum.sum() end
  reads = rs |> Enum.map(fn {_, r} -> r.reads end)
  items = rs |> Enum.map(fn {w, _} -> length(w.items) end) |> Enum.sum()
  reshown = rs |> Enum.map(fn {_, r} -> r.shown |> Map.values() |> Enum.map(&(&1 - 1)) |> Enum.sum() end) |> Enum.sum()
  maxshow = rs |> Enum.map(fn {_, r} -> r.shown |> Map.values() |> Enum.max(fn -> 0 end) end) |> Enum.max()
  report.("#{fname.(fam)}: walks / notifications / failures by property", {seeds, items, by})
  report.("#{fname.(fam)}: how walks ended", ends)
  report.("#{fname.(fam)}: reads total, max / shown again total, most shows of one / reads acknowledging nothing / pages without seen_through / over_bound->json / pages with a duplicate",
    {Enum.sum(reads), Enum.max(reads), reshown, maxshow, sum.(:wasted), sum.(:no_st), sum.(:over_bound), sum.(:dup_in_page)})
  for {k, w, r} <- fails |> Enum.group_by(&elem(&1, 0)) |> Enum.flat_map(fn {_, l} -> Enum.take(l, 2) end) do
    report.("#{fname.(fam)}: example #{k}, seed #{w.seed}", {length(w.items), w.limit, w.cut, w.reasons, w.o.paging, w.o.psize, elem(r.fail, 1)})
  end
  if out do
    for {k, w, r} <- fails do
      File.write!(out, Jason.encode!(%{family: fname.(fam), seed: w.seed, property: k, detail: elem(r.fail, 1), n: length(w.items), limit: w.limit,
        cut: w.cut, reasons: w.reasons, paging: w.o.paging, psize: w.o.psize, cmp: w.o.cmp}) <> "\n", [:append])
    end
  end
  report.("#{fname.(fam)}: ms", System.monotonic_time(:millisecond) - t0)
end
IO.puts("DONE")

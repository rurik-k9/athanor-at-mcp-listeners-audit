# A1 (axis 1, receipts): a damaged or truncated listener state file at start. Hum: "a damaged or truncated listener
# state file at start". Docs (c64be24): "a damaged account file doesn't stop the start" (b2629d7); "A damaged entry
# holds nothing and is dropped at the next save"; settle_future: "One account's file that can't be settled is left as
# it is, with a warning: it must not stop the start for every account".
# Invariants probed, per mutation: (I1) Updates and Listeners are up after the start and after use; (I2) the other,
# undamaged account keeps working (track, save, read); (I3) the damaged account either works or fails visibly (an
# error from track/read, never a silent loss: a live record it should take is held, or the failure is reported);
# (I4) nothing crashes later (a save, a connect, a read).
# Baseline: two accounts (me, other), each with a records listener "f" (author alice), 3 records saved and
# acknowledged, a connect (marks written). Then the files are copied, one mutation applied, and the store restarted.
seed = String.to_integer(System.get_env("SEED") || "1"); :rand.seed(:exsss, {seed, 11, 7})
spec_f = %{"source" => "records", "authors" => [alice], "collections" => [post]}
room = %{"count" => 2000, "age_seconds" => 604_800}
base = fresh_dir.("base"); reset_fakes.()
{a, clock} = new_clock.(t0)
start_l.(base, clock, [])
for {did, fx} <- [{me, :me_fx}, {other, :other_fx}] do
  :ok = Listeners.track(did, fx); :ok = Listeners.listen(did, "f", spec_f, room)
end
connect.()
for i <- 1..3, do: (set_time.(a, t0 + i); rec_live.(tid.(t0 + i, i), t0 + i))
Process.sleep(300)
for did <- [me, other], do: ack_all.(did, "f")
set_time.(a, t0 + 10); connect.()
stop.(Listeners); stop.(Updates)
ldir = Path.join(base, "listeners")
files = File.ls!(ldir) |> Enum.sort()
report.("A1 baseline files", files)
acct = File.read!(Path.join(ldir, me <> ".json")); streams = File.read!(Path.join(ldir, "streams.json"))
report.("A1 baseline sizes (account, streams)", {byte_size(acct), byte_size(streams)})
j = Jason.decode!(acct)
report.("A1 baseline account keys / listener keys", {Map.keys(j) |> Enum.sort(), Map.keys(j["listeners"]["f"]) |> Enum.sort()})
setp = fn path, v -> Jason.encode!(put_in(j, Enum.map(path, &Access.key(&1, %{})), v)) end
cut = fn s, frac -> binary_part(s, 0, trunc(byte_size(s) * frac)) end
flip = fn s -> i = :rand.uniform(byte_size(s)) - 1; <<pre::binary-size(i), b, post::binary>> = s; pre <> <<Bitwise.bxor(b, 1 + :rand.uniform(254))>> <> post end
mutations =
  [ # the account file of `me`
    {"acct empty", :acct, ""}, {"acct 1 byte", :acct, cut.(acct, 0.001)}, {"acct cut 10%", :acct, cut.(acct, 0.1)},
    {"acct cut 50%", :acct, cut.(acct, 0.5)}, {"acct cut 90%", :acct, cut.(acct, 0.9)}, {"acct cut last byte", :acct, binary_part(acct, 0, byte_size(acct) - 1)},
    {"acct byte flipped (seeded)", :acct, flip.(acct)}, {"acct NUL padded", :acct, acct <> :binary.copy(<<0>>, 64)},
    {"acct top-level list", :acct, "[]"}, {"acct null", :acct, "null"}, {"acct version 999", :acct, setp.(["version"], 999)},
    {"acct receipts []", :acct, setp.(["receipts"], [])}, {"acct receipts null", :acct, setp.(["receipts"], nil)},
    {"acct receipts \"x\"", :acct, setp.(["receipts"], "x")}, {"acct receipts.f \"x\"", :acct, setp.(["receipts", "f"], "x")},
    {"acct receipts.f [1]", :acct, setp.(["receipts", "f"], [1])}, {"acct receipts.f [null]", :acct, setp.(["receipts", "f"], [nil])},
    {"acct receipts.f [\"short\"]", :acct, setp.(["receipts", "f"], ["short"])},
    {"acct listeners []", :acct, setp.(["listeners"], [])}, {"acct listeners null", :acct, setp.(["listeners"], nil)},
    {"acct listeners.f \"x\"", :acct, setp.(["listeners", "f"], "x")}, {"acct listeners.f.spec \"x\"", :acct, setp.(["listeners", "f", "spec"], "x")},
    {"acct listeners.f.spec.source bogus", :acct, setp.(["listeners", "f", "spec", "source"], "bogus")},
    {"acct listeners.f.forgotten_through \"x\"", :acct, setp.(["listeners", "f", "forgotten_through"], "x")},
    {"acct listeners.f.forgotten_through far future", :acct, setp.(["listeners", "f", "forgotten_through"], 99_999_999_999)},
    {"acct listeners.f.forgotten_through -5", :acct, setp.(["listeners", "f", "forgotten_through"], -5)},
    {"acct listeners.f.cursor \"x\"", :acct, setp.(["listeners", "f", "cursor"], "x")},
    {"acct listeners.f.bounds \"x\"", :acct, setp.(["listeners", "f", "bounds"], "x")},
    {"acct next_seq \"x\"", :acct, setp.(["next_seq"], "x")}, {"acct next_seq null", :acct, setp.(["next_seq"], nil)},
    {"acct updates \"x\"", :acct, setp.(["updates"], "x")}, {"acct updates [1]", :acct, setp.(["updates"], [1])},
    {"acct ahead \"x\"", :acct, setp.(["ahead"], "x")}, {"acct ahead.f \"x\"", :acct, setp.(["ahead", "f"], "x")},
    {"acct settling \"x\"", :acct, setp.(["settling"], "x")}, {"acct settling.f \"x\"", :acct, setp.(["settling", "f"], "x")},
    {"acct mode 0644", :acct_mode, 0o644}, {"acct is a directory", :acct_dir, nil},
    # the shared streams file
    {"streams empty", :streams, ""}, {"streams cut 50%", :streams, cut.(streams, 0.5)}, {"streams cut last byte", :streams, binary_part(streams, 0, byte_size(streams) - 1)},
    {"streams []", :streams, "[]"}, {"streams null", :streams, "null"}, {"streams {}", :streams, "{}"},
    {"streams.streams []", :streams, ~s({"version":1,"streams":[]})}, {"streams.streams \"x\"", :streams, ~s({"version":1,"streams":"x"})},
    {"streams live mark \"x\"", :streams, Jason.encode!(put_in(Jason.decode!(streams), ["streams", "listeners_live:" <> me], "x"))},
    {"streams live mark far future", :streams, Jason.encode!(put_in(Jason.decode!(streams), ["streams", "listeners_live:" <> me], 99_999_999_999))},
    {"streams mode 0644", :streams_mode, 0o644}, {"streams is a directory", :streams_dir, nil}
  ]
for {name, what, value} <- mutations do
  dir = fresh_dir.("m"); File.cp_r!(ldir, Path.join(dir, "listeners"))
  ap = Path.join([dir, "listeners", me <> ".json"]); sp = Path.join([dir, "listeners", "streams.json"])
  case what do
    :acct -> File.write!(ap, value)
    :streams -> File.write!(sp, value)
    :acct_mode -> File.chmod!(ap, value)
    :streams_mode -> File.chmod!(sp, value)
    :acct_dir -> (File.rm!(ap); File.mkdir!(ap))
    :streams_dir -> (File.rm!(sp); File.mkdir!(sp))
  end
  reset_fakes.()
  {a2, clock2} = new_clock.(t0 + 100)
  started = safe.(fn -> start_l.(dir, clock2, []); :ok end)
  Process.sleep(200)
  up1 = {alive.(Updates), alive.(Listeners)}
  pids1 = {Process.whereis(Updates), Process.whereis(Listeners)}
  tr = for {did, fx} <- [{me, :me_fx}, {other, :other_fx}], do: safe.(fn -> Listeners.track(did, fx) end)
  connect.()
  set_time.(a2, t0 + 101); k = tid.(t0 + 101, 7); rec_live.(k, t0 + 101); Process.sleep(400)
  got = for did <- [me, other], do: (h = safe.(fn -> held.(did, "f") end); if(is_list(h), do: Enum.member?(h, "at://#{alice}/#{post}/#{k}"), else: h))
  up2 = {alive.(Updates), alive.(Listeners)}
  restarted = pids1 != {Process.whereis(Updates), Process.whereis(Listeners)}
  marks = {safe.(fn -> amark.(me) end), safe.(fn -> amark.(other) end)}
  unrec = {stat.(me, "f", :unrecovered), stat.(other, "f", :unrecovered)}
  after_file = case File.read(ap) do {:ok, t} -> (case Jason.decode(t) do {:ok, _} -> if(t == value, do: :unchanged_valid, else: :rewritten_valid); _ -> if(t == value, do: :unchanged_damaged, else: :rewritten_damaged) end); e -> e end
  report.("A1 #{name}", %{start: started, up_after_start: up1, track_me_other: tr, new_record_held_me_other: got, up_after_use: up2, pid_changed: restarted, marks_me_other: marks, unrecovered_me_other: unrec, me_file_after: after_file})
  stop.(Listeners); stop.(Updates); Agent.stop(a2)
end
IO.puts("DONE")

# Testing someone else's fix: methods learned in D-019 (at_mcp 23fa3e9, "Trial by Fire")

Written by Claude Code for Athanor, 25 Nov 2026, at the operator's request, after the independent validation of hum's
at_mcp commit 23fa3e9. It records how the campaign was run and what went wrong in our own method, so that you can
use, criticise or discard it. It is a working note, not a rule: none of it is a directive.

## 1. A property that is claimed must also be checked

hum's random-walk test (review_l_walk_test.exs) says in its description that every page with a seen_through reads at
least one notification. Its code checks safety and termination, but not that property. Our walks checked it and found
the one case where it fails: the page stops before a notification still being held back. The failure is harmless and
bounded, but nobody would have known from the test, which claimed more than it checked.

*Practice:* for each property a document or test claims, find the line that would fail if it were false. If there is
none, the claim is only a hope.

## 2. A test of a known limit should be able to fail both ways

hum's principle: a test that pins a known limit should report when the limit gets worse, and also when it disappears,
so that the documentation can be corrected. Our X3 test therefore predicts each case from the documented rule and gives
a verdict: HOLDS, IMPROVED or DETERIORATED.

The first run said IMPROVED everywhere, and the fault was ours. The scenario left out the save that sets the floor, so
the late mention arrived before any floor existed. A one-sided test (lost or counted) would have passed quietly. The
two-sided verdict exposed the mistake at once.

*Practice:* when a result looks like good news, check the scenario's preconditions before believing it.

## 3. Print the state after setting it up

One M2 scenario first reported 191 duplicates: notifications acknowledged under the old build appeared to come back. In
fact our setup never acknowledged them, so they were simply still pending. A detailed rerun, with the dates of the
supposed duplicates, showed the error within minutes.

*Practice:* after each setup phase, print the facts the later phases depend on: what is acknowledged, what is held, and
the marks and floors. Then a mistake in the setup cannot pass for a finding.

## 4. Separate the code from its model of the outside world

The oldest-first read relies on several assumptions about the service:
- the service compares times, not strings;
- the comparison is strict;
- seenAt is kept at full precision;
- its cursor is a time;
- notifications with the same time are not lost between two pages.

Our simulated service can make each of these assumptions false, one at a time. The walks loop or lose notifications when:
- the service compares strings;
- the service keeps seenAt only to the millisecond;
- its cursor skips notifications with the same time at a page boundary.

These results apply to every build, the older ones included. They are not regressions. They are hypotheses about
Delvetown that can only be checked on the real service, and they are reported as such.

*Practice:* list the assumptions about the outside world, give each one a variant, and keep "the code is wrong" apart
from "the code is right if the world is as it assumes".

## 5. Run the intermediate commits, not just the last one

We built 61fd227, 754a231, 74f9c34 and 23fa3e9 separately, together with our own earlier proposal. This showed which
commit fixed what:
- L1 is fixed by 754a231 alone;
- 74f9c34's room for timed receipts shrinks under repeated saves;
- 23fa3e9 fixes that.

It also showed that our own earlier proposal still looped when the text reading cut a page, because it never changed
`cut/2`. hum's version does.

*Practice:* compare with your own earlier proposal as you would with anyone else's. Being wrong is information.

## 6. Seeds, small cases, and limits on cost

- Every random walk comes from a family name and a seed, so any failure can be replayed exactly (FUZZ_TRACE=family:seed).
- Each kind of failure got a small deterministic case (W1 to W7), which is easier to discuss than a seed.
- A first version capped each walk at 20 n + 200 reads. On the looping build that took most of an hour. Detecting a
  loop instead (50 reads in a row with no progress, nothing held back) gave the same verdict in seconds.
- All runs were on the CPU, at the lowest scheduling priority, with no model calls, so your sessions were not affected.

*Practice:* make the stopping rule match the question. To show a walk loops, you do not need to wait for ever.

## 7. Report counts as their definitions say

`unrecovered` means "could not be checked", not "lost". Our X3 cases count 1 where the mention was in fact delivered,
which errs on the safe side. Saying "1 lost" would have been false.

## 8. What was simulated, and what was not

Everything ran against fake services, on overlays compiled onto the 0.3.3-hum.11 release, in a sandbox without
network. No live PDS, no real account, and no Delvetown endpoint were touched. A result here shows what the code does
under the conditions we built. It does not show what Delvetown does.

## Files

The campaign's report, tools, seeds and raw results are in governance/reports/at_mcp-23fa3e9-validation/, and once the
operator approves, in the public audit repository under 23fa3e9/. The L1 random walks are in tools/l1_fuzz.exs, the
text-path walks in tools/l1_text_test.exs, the M2 phases in tools/phases23_test.exs, and the two-sided X3 test in
tools/x3_limit_test.exs.

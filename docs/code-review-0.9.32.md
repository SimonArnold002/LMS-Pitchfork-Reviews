# Code review — 0.9.32

Round following 0.9.31. Scope: `36d7820` (0.9.32, the "one carrier" refactor) — the only
unreviewed commit ahead of `origin/dev`, since 0.9.28/0.9.29/0.9.31 each already carry a
`docs/code-review-*.md`. Read the whole 0.9.32 hunk set (`Browse.pm`, `t_releaserank.pl`,
`t_perf.pl`) plus the surrounding `_findPlayable` / `$finish` / `$resolve` closures.

**Two findings raised, both marked PLAUSIBLE rather than CONFIRMED. One was WITHDRAWN under
challenge; the other was CORRECTED — its stated blast radius was wrong — and then fixed in
0.9.33.** Recorded in full because the corrections are the useful part: both findings were
overstated in the same direction, and the mechanism that bounds them (`_streamTtl`'s
all-unavailable branch) is one both a reviewer and a fixer need to know about.

---

## Verified sound (checked, and deliberately NOT reported)

- **`_streamTtl` is behaviourally equivalent to the 0.9.31 ladder.** Worked the no-winner path
  by hand: `$outcome[$i] ne ANSWERED` implies `$res` was undef which, with `@leg1` empty on
  that path, is exactly the old post-merge `!defined $res`. The "`@outcome` is complete by
  construction" claim holds on the no-match path (the `$resolve` loop returns on the first
  undef `$result[$i]`); on the win path it is truncated at `$win`, but only `$outcome[$win]`
  is read. `_dedupeStreamItems` cannot empty a non-empty list, so the `$win`-defined /
  `$nitems == 0` corner is unreachable.
- **The test suite is load-bearing, not decorative.** Anti-tested: folding `UNAVAILABLE` into
  `ERRORED` inside `_streamTtl` fails 7 assertions (both coverage assertions by name);
  moving the `$outcome[$i]` recording past the merge fails 13.
- **Build hygiene.** `install.xml` / `repo.xml` / `README.html` all at 0.9.32, `repo.xml <sha>`
  matched the zip, every file in the zip byte-identical to the tree, `STREAM_KEY_VERSION`
  24→25 with `PARSE_VERSION` held at 3.
- **Ledger items re-checked and not re-reported:** the per-album `search errored` warn
  (deliberate — `$once` is for the standing case only), per-client keying of `%UNAVAIL_SINCE`,
  the leg-1-leads merge order, and the removed `_attachReviewLink` early return (its call site
  is inside `if (my $al = $it->{_album})`, so it really is matched-only).

---

## Finding 1 — CORRECTED, then FIXED in 0.9.33. The grace window used a wall clock

### As reported

`_svcNoHandler` measured the grace window with `time()`, while `SVC_UNAVAILABLE_GRACE`'s own
note says the window is relative to *this process's uptime* — which is the whole reason
`%UNAVAIL_SINCE` lives in process memory rather than the kv store. An RTC-less host (most of
the fleet: Pi / dietpi) restores the clock at boot from the last shutdown stamp
(fake-hwclock / systemd-timesyncd), and NTP then **steps** it forward to true time once the
network is up. The step size is the length of the downtime, and it lands inside the exact
window the grace exists to cover — between the plugin's startup warm and the services
authenticating.

### What was wrong with the report

Two things, both found by pushback rather than by the reviewer:

1. **The blast radius was overstated.** The report said a startup race would pin "every
   unmatched album in that warm" at `STREAM_NOMATCH_TTL` (24h). That is false.
   `_streamTtl` reads:

   ```perl
   my $unavail = grep { ($_ // '') eq OUTCOME_UNAVAILABLE } @$outcome;
   return STREAM_INCONCLUSIVE_TTL if $unavail >= $nadapters;
   ```

   In a **pure** startup race nothing is authenticated, so every adapter is UNAVAILABLE, the
   guard fires, and the answer is INCONCLUSIVE — never the 24h pin. The defect only bites in
   the **mixed** case (one service authenticated and searching, another not yet), where the
   misclassification flips what would have been INCONCLUSIVE into a confirmed-miss pin.
2. **The "backwards step" half did not hold up at all.** The restore is always to a *past*
   value (the last shutdown), so boot steps go **forward**. The claim that a backwards step
   would hold a signed-out service as transient forever was wrong and is withdrawn.

Also worth recording, because it was raised as an objection: NTP being universal on a Pi is
what **causes** the step, not what prevents it. The finding never depended on NTP being
absent — the report's wording invited that reading and was at fault.

### The fix (0.9.33)

`_monoNow()` — `Time::HiRes::clock_gettime(CLOCK_MONOTONIC)`, with a documented `time()`
fallback where the platform has no monotonic clock. `Time::HiRes` was already imported and
`$now` was already injectable, so the tests needed no signature change.

### Two things the fix's own tests caught

- **Clock mixing is a real hazard.** 3f's `signed_out_long` helper seeded `%UNAVAIL_SINCE`
  with `time() - 86400` while the code under test now compared against a monotonic reading,
  so the delta went hugely NEGATIVE and a service seeded as long-signed-out read as
  *transient* — 4 assertions red. Anything that WRITES that hash must use the clock that
  READS it.
- **The obvious assertion is vacuous.** Asserting that `_monoNow` exists and never runs
  backwards passes unchanged if someone reverts `_svcNoHandler`'s default to `time()` and
  leaves the helper sitting unused in the file — verified by anti-test, 139/139 green on that
  revert. The assertion now probes **at the consuming end**: seed on the wall clock, call with
  no `$now`, and let the verdict name the clock the sub actually reads. Both revert shapes
  (sneaky and full) now fail.

---

## Finding 2 — WITHDRAWN. A stale `%UNAVAIL_SINCE` record skipping its grace window

### As reported

The record is cleared only by `_svcHasHandler`, which needs a resolve leg to actually reach an
adapter that has a handler. Against a warm store that may not happen for hours, so a
mid-session handler gap (credentials saved, plugin re-init) could compute a delta of hours and
be classified STANDING at age zero — warning "still unavailable after 600s" and pinning real
misses for 24h.

### Why it was withdrawn

Raised by Simon: *a refresh streaming match would fix this*. Checked, and correct — twice over:

1. `_refreshMatchRow` calls `_findPlayable` with `$force`, which runs the adapters; any adapter
   that now has a handler hits `_svcHasHandler`, which deletes the stale record.
2. The `$force` path skips the cache READ but still WRITES, so the same action rewrites the
   cached entry past the bad TTL.

`Browse.pm:72` already names that escape hatch for exactly this class of problem. On top of
that the scenario is compound — it needs a handler to appear *and* vanish with no resolve in
between, *and* the new outage to be a fast-self-healing transient. A one-click recovery for a
compound coincidence is not a defect worth carrying.

**Do not re-report this.** It is recorded in Review Ledger B.

---

## Outcome

| Finding | Verdict |
|---|---|
| 1 — wall-clock grace window | Blast radius corrected; **fixed in 0.9.33** (`_monoNow`, CLOCK_MONOTONIC) |
| 2 — stale `%UNAVAIL_SINCE` record | **Withdrawn** — `Refresh streaming match` clears the record and rewrites the entry |

Nothing else in the 0.9.32 diff was found wanting.

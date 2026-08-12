# Code review — 0.9.25 → 0.9.26

Reviewed: **only the code written after `docs/code-review-0.9.25.md`**, not the whole
working-tree diff again. `dev` == `origin/dev` and everything is still uncommitted, so the
0.9.25 baseline was reconstructed rather than assumed — `git archive HEAD` plus the three
diff files that review session took at 08:32, then diffed against the tree as it stands
(08:58–09:00). That delta is exactly **two hunks in two files**, both of them the fixes for
the two findings 0.9.25 raised:

| | where | what |
|---|---|---|
| 0.9.25 finding 1 | `API.pm` `getYearList`/`getLatestYear` + `Browse.pm` `_refreshRow` | new `resweep` option; the Refresh row's two jobs re-ordered |
| 0.9.25 finding 2 | `API.pm` `_parseYear` | the non-`h2` skip clears the pending cover/rank |

Nothing else moved. `strings.txt` shows in a naive diff only because it predates the
reconstructed baseline (mtime 7 Aug); it is untouched by this pass.

**Packaging is deliberately OUT OF SCOPE**, as briefed — `install.xml`/`repo.xml`/the zip are
still 0.9.24 while the source comments already say 0.9.26. Not a finding. Worth one line
for whoever builds: **`CLAUDE.md` has no `## Status: 0.9.26` section yet**, so the two fixes
below are currently recorded only in the source comments.

**Both fixes are correct, and both were traced rather than read.**

*The `resweep` fix.* The three cases that matter were walked end to end against the real
subs. Refresh on a **closed** year: one forced `getYearList($y)` download, then the probe
walks `_topYear` down and answers from the permanent store — one article per tap, against
two before. Refresh on the **newest** year: the re-pull happens first, so by the time the
probe reaches `$y` the store holds a copy written moments earlier and the probe cannot
duplicate it — which is precisely what makes 0.9.24's `$probed` shortcut unnecessary rather
than merely wrong, exactly as the new comment claims. Refresh in **December against a newly
published year**: the probe's candidate above the stored answer has nothing stored, so
`resweep` carries it past the year-miss marker and the promotion still lands on the tap.
The marker is still obeyed by every non-`resweep` caller, so the sweep storm it bounds stays
bounded. `$probeOpts{resweep} = 1 if delete $probeOpts{force}` also behaves correctly for an
explicit `force => 0` (deletes, returns false, sets nothing) and for `force` absent.

Two things checked specifically because they are how this shape usually breaks. `$reload`
is now `getLatestYear`'s callback rather than `getYearList`'s, so it is handed a **year**
where it used to be handed an **arrayref** — harmless, it ignores its arguments and emits
the empty `nextWindow => 'refresh'` response either way. And the recursion in `getLatestYear`
cannot deepen now that probes answer synchronously from the DB: a store hit is non-empty by
construction (`putList` is never reached with zero items), so a synchronous answer always
`return`s instead of recursing.

*The `_parseYear` fix.* The clear is safely placed: `inline-embed` is handled and `next`ed
above the heading branch, so the block that SETS `$cover` can never reach the new clear —
the failure mode that would have wiped every cover on every page. The bare-number rank
test still runs first, so a rank marker (including 2017's `h2`-shaped one) is unaffected.
Re-verified empirically rather than by inspection: all ten live years 2016–2025 were
re-parsed through the pre-fix and post-fix `_parseYear` and the dumps are **byte-identical**
(481,766 bytes each), so the documented trade is not being paid on any current page.

**Tests: 839 assertions across the eleven suites, 0 failures** (was 819). `t_perf` gains
section 21, which pins the closed year, the newest year, a never-stored year, the marker
not silencing a manual re-probe, and — the one that keeps `resweep` honest — the marker
still being obeyed by an ordinary probe.

One finding. It is a narrow consequence of the `resweep` fix that the fix's own comment does
not mention, and it is not a live defect on a healthy server.

---

## 1. The Refresh row's probe now joins the coalescing queue it used to be exempt from

**Severity:** low (latent). **Where:** `PitchforkReviews/API.pm:483`.

```perl
my %probeOpts = %opts;
$probeOpts{resweep} = 1 if delete $probeOpts{force};
getYearList($probe, sub { ... }, %probeOpts);
```

Deleting `force` fixes the fetch, but `force` was carrying a **second** meaning that went
with it. `_shareFetch`'s own header states it as a contract:

```perl
# COALESCING. ... `force` bypasses the queue (a forced refresh must actually
# refetch, and must not be answered by an already-running normal fetch).
```

and the code enforces it in two places — the stale-serve (`!$opts->{force} && !$opts->{nostale}`)
and the queue itself (`if (!$opts->{force}) { if ($PENDING{$key}) { push ...; return } }`).
A probe carrying only `resweep` fails both tests, so from this change onward the Refresh
row's probe **can be adopted by an in-flight ordinary fetch** and **can be answered from the
stale copy**, neither of which was reachable before.

Being served stale is harmless here and worth having — the probe only asks "does this year
have a list?", and a stale non-empty answer answers it correctly. **Adoption is the part
that is not free.** `$reload` is the tail of a chain the user tapped, and it is what emits
the empty `nextWindow => 'refresh'` response. If the probe is adopted by a `year:N` slot that
never reaches its `$done`, nothing else will ever answer it: the Refresh tap simply never
completes, and Material sits on its three-dot placeholder until the user navigates away.
Under 0.9.25 the same stranded slot could not touch the Refresh row at all, because every
call it made carried `force`.

**Not reachable on a healthy server**, and that is the honest weight of it: `%PENDING` strands
are what `_issueFetch`, the eval'd parse/store and 0.9.25's `$done` fan-out guard exist to
prevent, and 0.9.25 argued every path to `$done` is now covered. But this file's own history
is that a `%PENDING` strand has been found and closed **four separate times** (0.8.9, 0.9.0,
0.9.23, 0.9.25), and the manual retry button is the one surface that should keep working
when the automatic paths have wedged — which is exactly why it forced in the first place.
This quietly removes it from that protected set.

**Fix,** if it is judged worth the line: give the probe the exemption without giving it the
fetch, i.e. keep it out of the queue and off the stale path while still honouring the store.
The cheapest form is to let `resweep` stand alongside `force` in `_shareFetch`'s two tests:

```perl
my $solo = $opts->{force} || $opts->{resweep};
if (!$solo && !$opts->{nostale}) { ... }
if (!$solo) { ... adopt or claim ... }
```

Note what that costs and decide accordingly: a probe that neither joins nor claims will
issue its **own** request when the year is genuinely uncached and something else is already
fetching it — a duplicate download in exactly the window coalescing exists to collapse.
That is the same trade `force` has always made, and it is only reachable on a year that has
never been stored, so the duplicate is bounded to a cold probe rather than a per-tap cost.

**Either way it wants asserting in both directions**, because the two properties pull against
each other and a future "simplification" will otherwise pick one: a probe must not be left
unanswered by a stranded slot, and an ordinary (non-`resweep`) probe must still coalesce.

### RESOLVED — fixed, but NOT with the patch above

`resweep` is now solo in `_shareFetch` at **all three** sites: the stale test, the queue test
and **`$done`**. The `$solo` sketch above touches only the two tests and is incomplete in a
way that matters: with no slot claimed, the fan-out `$done` runs `delete $PENDING{$key}`,
finds nothing and calls nobody — **the probe is never answered, on every tap** rather than
only against a strand — and where another caller owns that key it deletes their slot and
fires THEIR waiters with the probe's items, i.e. 0.9.23's orphaned-owner defect
manufactured by this fix. Applied as written it fails 8 assertions.

The stale-serve goes with it rather than being kept as suggested: keeping it while `$done`
is the raw `$cb` **double-answers** the caller (stale, then fresh) — `force` is safe from
that only because it skips the stale path — and it costs nothing reachable, since the only
shape that reaches `_shareFetch` with a stale year is the current year past `YEAR_TTL`, by
which point the Refresh row's forced re-pull has already stored it.

Pinned in both directions plus the half-applied case, `t_perf` section 22 (12 assertions,
suite 839 → 851). See `CLAUDE.md` → **Status: 0.9.26** item 3.

---

## Cleared, no action needed

* **The re-ordering answers `$reload` exactly once** on every path — `getYearList`'s callback
  is guaranteed (the store read, the marker read, `_shareFetch`'s adoption, `_issueFetch`'s
  throw path and all three fetch outcomes each end at exactly one `$cb`), and
  `getLatestYear`'s sweep ends at one `$cb` per completed walk.
* **No double fetch survives on the failure path either.** A forced re-pull of `$y` that
  fails leaves nothing stored, so the probe would sweep `$y` again — but that is the same
  count 0.9.24's `$probed` shortcut produced in the same state (`$probed` read false when the
  probe had answered with an older year), so it is not a regression, and both fetches are
  404s or a page that parsed to nothing.
* **`resweep` reaches exactly one caller.** `getLatestYear` is called from `_viewYear`
  (`Browse.pm:480`, no opts), `yearsAvailable` (no opts) and `_refreshRow` (`force => 1`);
  no other call site can produce a `resweep` probe.
* **The `_parseYear` clear cannot mis-fire on the rank marker.** The bare-number test
  precedes it, so `div.heading-h3` "50." and 2017's `h2`-shaped rank both still set
  `$printed` and `next` without clearing.
* **The direction test is not weakened by the new clear.** `@printed` is collected off the
  pushed entries, and the block run puts the rank marker immediately before its own `h2`, so
  a decorative sub-heading falls between an entry's `p` and the *next* entry's embed — where
  `$cover`/`$printed` are already `undef`.
* **`_latestTtl($probe, $top)` called without `$now`** still defaults correctly through
  `_secsToWindow`'s own `shift // time`. Pre-existing, re-checked because the probe's answer
  is now derived from the store and cached for up to 30 days.

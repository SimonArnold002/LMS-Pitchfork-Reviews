# Code review — 0.9.31

Round following 0.9.30. Scope: the five commits ahead of `origin/dev` —
`155e3e4` (0.9.27), `46dc305` (field confirmation), `f8101ac` (0.9.28),
`3ac3603` (0.9.29), `d43a2f3` (0.9.30). Working tree clean at review time.

**Two findings, both fixed.** Both are defects the 0.9.27–0.9.30 series *introduced or
left behind*, not pre-existing ones — which is the point of reviewing a series rather
than a commit. Neither is in ledger sections A/B.

---

## Finding 1 — FIXED. The merge order decided the row whenever nothing was exact

### The defect

0.9.27 merges the two search legs in `$finish`:

```perl
$res = (defined $res && ref $res eq 'ARRAY') ? [ @$res, @leg1 ] : [ @leg1 ];
```

Leg 2 (the album-title query) leads, and the comment justifies that with *"the promotion
in `$resolve` then decides"*. The promotion is:

```perl
if (@$items > 1) {
    my ($ex) = grep { _exactFolded($album, $items->[$_]) } 0 .. $#$items;
    unshift @$items, splice(@$items, $ex, 1) if $ex;
}
```

It decides only when there is something to decide **between**. When no candidate is
folded-exact, `$ex` is `undef` and the promotion does nothing at all — so the merge
**order** silently became the adjudicator.

That is the worst possible default for this case. Leg 1 is the **artist** query: every row
it returns is already the right artist, and its titles are what `_albumMatches` judged.
Leg 2 is the **title** query — it exists for *recall*, reaching releases the artist search
buried, and its relevance order is title-first, which is exactly how a like-named rival
gets to the front. So with both legs loose, leg 2's arbitrary first hit took the row.

And it was pinned. Leg 2 *having answered* is precisely what marks a row validated
(0.9.29), so the wrong release got `STREAM_FOUND_TTL` — **thirty days**.

### Why it is a regression, not an old wart

Before 0.9.27 the retry gate was `!@$res` — the leg only fired when leg 1 came back
**empty**. A loose-only leg 1 never ran leg 2 at all, so its match took the row unopposed.
Confirmed against `155e3e4^`:

```perl
if ($wantAlbumLeg && !$legs++ && defined $res && ref $res eq 'ARRAY' && !@$res) {
```

Widening that gate to loose-only is right — it is the Interpol fix, and it stays. But it
routed a whole new class of resolve through a merge order that was only ever justified for
the exact case.

### Reproduced

Review *A – Foo*; artist leg returns `Foo (feat. X)` (the reviewed record), retry leg
returns `Foo (Remix)`. Neither is folded-exact.

| | before | after |
|---|---|---|
| row | `Foo (Remix)` | `Foo (feat. X)` |
| ttl | 2592000 (30d) | 2592000 (30d) |

The TTL is *correct* in both columns — leg 2 answered, so the row really is validated.
Only the release is wrong, which is what makes this invisible in a log.

### The fix, and the fix that was discarded

```perl
$res = (defined $res && ref $res eq 'ARRAY') ? [ @leg1, @$res ] : [ @leg1 ];
```

A conditional — *lead with leg 2 when leg 2 actually brought the exact* — was built first
and **discarded as a provable no-op**. `_wantsTitleRetry` returns 0 the moment leg 1 holds
a folded-exact (`return 0 if _exactFolded($album, $it);`), so reaching this merge at all
proves `@leg1` is exact-free. The only exact that can exist is leg 2's, and the promotion
lifts it from wherever it sits in the merged list. Anti-testing is what caught it:
replacing the conditional with the plain line left every assertion green.

The plain line also sidesteps a real edge in that promotion, which is `if $ex` and not
`if defined $ex`. Leading with leg 2 put its exact at index 0, where `$ex` is `0` and the
unshift is silently skipped — harmless only because the row happened to be first already.
Leading with leg 1 (non-empty by the enclosing guard) means an exact is always at index
≥ 1, so the promotion genuinely runs.

### Tests

`t_releaserank.pl` section **3c**, both directions:

- neither rival folded-exact → leg 1 takes the row, leg 2 still merged in, long TTL
- the Interpol direction: leg 2 brought the exact → it takes the row
- an exact **behind** a loose row in leg 2 still wins (the promotion, not the order)
- an exact leg 1 settles without a second leg at all
- a leg-2 throw still leaves leg 1 holding the row (the 0.9.29 path)
- overlapping legs cache the shared row once, exact still promoted
- leg 1 overflowing `STREAM_MAX_RESULTS` with leg 2's exact arriving last: the exact
  still takes the row, because the promotion runs before the truncation

---

## Finding 2 — FIXED. A signed-out service pinned every real miss to the one-hour TTL

### The defect

`_svcCantAnswer`'s fifth argument marks a **standing** inability — *no API handler
(signed out?)*, set at exactly three call sites, one per adapter. 0.9.30 added it so the
warning fires once per process instead of ~150 times per warm.

The TTL side never got the same treatment. Both standing and transient failures returned
`$collect->(undef)`, which increments `$inconclusive`, which forces
`STREAM_INCONCLUSIVE_TTL`:

```perl
: $inconclusive ? STREAM_INCONCLUSIVE_TTL
:                 STREAM_NOMATCH_TTL;
```

So one installed-but-signed-out service forced **an hour** on every genuinely unmatched
album, where a real miss earns **a day** — the same 24x cadence defect 0.9.30 was cut to
diagnose, arriving through a different door.

**It never self-heals.** `_detectAdapters` gates on `->can()` and nothing else:

```perl
} if Plugins::Qobuz::Plugin->can('getAPIHandler')
  && Plugins::Qobuz::Plugin->can('_albumItem')
  && Plugins::Qobuz::Plugin->can('QobuzGetTracks');
```

It knows nothing about sign-in, so the adapter sits in `@adapters` on every resolve for as
long as the user leaves it signed out. 0.9.30 already recognised this as a state that
*repeats for ever* — that is the entire reason for the once-only warning — which is
exactly what makes it wrong to count as inconclusive.

### Reproduced

Qobuz signed out (priority 1), Deezer genuinely searches both legs and misses:

| | before | after |
|---|---|---|
| ttl | 3600 | 86400 |

### The fix

`$unavailable` is counted **separately** from `$inconclusive`, not merely excluded —
because a service that could not search has not voted, and "nobody searched" is still not
a verdict. It shortens the TTL only when *every* adapter was unavailable:

```perl
: $unavailable == @adapters ? STREAM_INCONCLUSIVE_TTL
:                 STREAM_NOMATCH_TTL;
```

`$resolve` does not reach that line until every adapter has reported (the loop above
returns on the first undef `$result[$i]`), so the comparison really does mean *not one
service was able to search*.

The flag rides `_svcCantAnswer` → `$collect` → `$finish` as a second argument. `$runLeg`'s
watchdog and its eval-failure branch call `$finish` with one argument, so a timeout or a
throw stays transient — which is what they are. The retry gate cannot fire on it either:
`_wantsTitleRetry` returns 0 for anything that is not an ARRAY ref, and a standing failure
always sends `undef`.

### Tests

`t_releaserank.pl` section **3d**:

- one signed out + one that really searched and missed → `STREAM_NOMATCH_TTL`
- every service signed out → nobody searched → `STREAM_INCONCLUSIVE_TTL`
- a transient error → short TTL (unchanged)
- a timeout → short TTL (unchanged)
- a signed-out service does not shorten another service's real match
- a signed-out service is asked exactly once (it does not consume the retry)
- three adapters with the unavailable one in the middle → still a real no-match
- three adapters, all unavailable → no verdict
- a service that signs out between its own two legs still serves leg 1, at
  `STREAM_UNVALIDATED_TTL`, and is not counted unavailable

The scripted-adapter stub gained `SIGNEDOUT` and `ERRORED`, both routed through the
plugin's **own** `_svcCantAnswer` rather than faking its `undef`. The standing/transient
split lives inside that sub, so a test that hand-rolled the undef would pass whatever the
sub did.

---

## Checked and deliberately not reported

- Everything in ledger sections A and B — release-type filter, the Refresh-row closure,
  the `_wantsTitleRetry` widening, `matcher_sync_check.py`, zip/sha state. Finding 1 is
  about the merge **order** after the retry fires, not the retry **gate**, so it does not
  challenge the 0.9.29 entry.
- `_releaseKey`'s `s///e` with `$1` across the `_editionish` call — `$1` is block-scoped
  and restored on sub return.
- `$unvalidated[$win]` provenance, the `$win`-defined-when-non-empty invariant, `@leg1`
  watchdog/throw paths, the `$legs` guard, `_svcCantAnswer`'s `$once` short-circuit,
  adapter `run` signatures — all correct.
- Called-vs-defined sub sweep across both `.pm` files: the only unresolved names are
  foreign-module calls (`_albumItem`, `_renderAlbum`, `_pluginDataFor`,
  `_canonicalize_expiration_time`, `_max`), all pre-existing.

## Matcher sync

**No matcher change.** None of the nine shared subs (`_norm`, `%FOLD`, `_artistMatch`,
`_albumMatches`, `_trackMatches`, `_stripFmt`, `_asciiNorm`, `_punctNorm`,
`_stripArtistPrefix`) is touched — both fixes are `_findPlayable` call-site logic and
`_svcCantAnswer`, none of which the fleet shares. `matcher_sync_check.py` reports
byte-identical results with these changes stashed and applied: `_norm`, `%FOLD` and
`_albumMatches` drift, which is the pre-existing fleet-wide hold recorded in ledger
section B (DSC's provisional alias pass), not anything from this round.

## Downstream audit

This series' repeated failure mode is a fix that quietly makes a branch unreachable or a
discriminator meaningless — 0.9.28 made `$res` always defined and orphaned the inconclusive
branch; 0.9.30 split standing from transient for the log and left the TTL behind. So every
consumer of what these two fixes touch was walked, not reasoned about.

**Fix 1 — who reads the merged list, in order:**

| consumer | order-sensitive? | verdict |
|---|---|---|
| `_dedupeStreamItems` (before the promotion) | which duplicate copy survives | equivalent nodes; now pinned against the cache |
| the `_exactFolded` promotion | no — greps every index | unchanged |
| `STREAM_MAX_RESULTS` cap (after the promotion) | which rows are deleted | **pinned**: promotion-before-cap is what saves leg 2's exact |
| `_releaseAlts` | follows the primary | `%seen` is keyed on the primary's release key, so it can never offer the row back |
| `_findPlayableReview` `$requireAll` drop | no — greps every index | drop decision unchanged; only which node leads a surviving side moves |
| `_findPlayableReview` round-robin | takes `[0]` per side | moves the same way, for the same reason, as an ordinary review |
| `_rebuildStreamItems` | preserves order | unchanged |
| `_matchExactness` in the log line | cosmetic | unchanged |

**Fix 2 — what else could see it:**

- `$inconclusive` has **no consumer beyond the TTL and the log line**, so declining to feed
  it for standing failures cannot reach anything else.
- `$finish` is called from exactly three places (the watchdog, `$runLeg`'s eval-failure
  branch, and `$collect`); the first two pass one argument, so timeouts and throws stay
  transient by construction rather than by intent.
- `_svcCantAnswer` has one `$collect` shape — there is a single `{run}->` invocation site.
- Nothing parses the warn text, which changed from *counted inconclusive* to *counted
  unavailable* on the standing path.
- `_retireOldStreamKeys` compares `$seen == STREAM_KEY_VERSION`, so 23 → 24 wipes the prefix
  as intended.
- **A service that signs out between its own two legs** keeps leg 1's matches at
  `STREAM_UNVALIDATED_TTL` and is not counted unavailable: the merge makes `$res` defined
  before the standing branch is reached. That is correct — there is a match to serve — and
  it is now a test rather than an inference.

## A defect this audit found in the review's own tests

Two of the new assertions were pinning the wrong thing. `_streamResult` runs its **own**
`_dedupeStreamItems` and `STREAM_MAX_RESULTS` cap on the way to the caller, so an assertion
made against the rendered list cannot tell what `$resolve` did from what the renderer did —
deleting `$resolve`'s dedupe outright left the suite green.

The harness's `kvSet` stub now records the **items** alongside the TTL, and the dedupe and
cap assertions moved onto them. What is cached is `$resolve`'s own output and is what a later
open replays, so it is the right surface to pin. Found by anti-testing the new *tests*, not
just the new code — the same discipline that collapsed fix 1 to one line.

## Verification

- 12 suites, **970 assertions, 0 failures** (945 before; +25).
- Anti-tested ten ways. The two mutations that survived are the two findings above: leading
  with leg 1 *unconditionally* changed nothing (collapsing fix 1 from a three-branch
  conditional to one line), and deleting `$resolve`'s dedupe changed nothing (moving two
  assertions onto the cache).
- `STREAM_KEY_VERSION` 23 → 24 (correctness: which release takes the row changed).
  `PARSE_VERSION` stays at 3.

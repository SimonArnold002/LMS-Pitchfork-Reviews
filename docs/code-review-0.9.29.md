# Code review — 0.9.29

Round following 0.9.28. Scope: the three commits `155e3e4` (0.9.27), `46dc305` (field
confirmation), `f8101ac` (0.9.28) against `origin/dev`.

Two findings. **One fixed, one declined** — the declined one is recorded in CLAUDE.md
ledger section B, because its remedy regresses.

---

## Finding 1 — FIXED. A match nobody checked was pinned for a month

### The defect

0.9.28 moved the `@leg1` merge into `$finish` so a slow leg 2 could no longer discard
matches leg 1 was already holding. That is right, and it is what the release exists for.

But the merge also makes `$res` **always defined** once leg 1 held anything. The
`!defined $res` branch — the one that counts the service `inconclusive` — is therefore
unreachable on that path, so a leg-2 **timeout** now falls out of the *found* side of
`$resolve`, where the TTL is `STREAM_FOUND_TTL`: **thirty days**.

Concretely, and it is the release's own field case run one step further. Qobuz's artist
leg returns only the 2-track *This Mirror Weighs a Ton/See Out Loud*. The album-title leg
that exists to find the 12-track album times out. `$res` comes back non-empty from
`@leg1`, `$resolve` picks the single, and the single is cached for a month — on the
strength of a query that never answered.

That is the same silent-wrong-match-pinned-for-a-month shape 0.9.27 set out to remove,
reached by a new route. 0.9.28's TTL paragraph only covers the `@leg1`-**empty** case
(still correctly inconclusive at 3600s); the non-empty case was not considered.

Measured before the fix, via a probe that records what `kvSet` is handed:

```
A. leg2 ANSWERS with the album                  n=2  ttl=2592000
B. leg2 TIMES OUT, leg1 held a loose single     n=1  ttl=2592000   <-- 30 days
C. leg2 THROWS,    leg1 held a loose single     n=1  ttl=2592000   <-- 30 days
D. leg1 TIMES OUT, nothing held                 n=0  ttl=3600
E. leg1 empty, leg2 TIMES OUT                   n=0  ttl=3600
F. both legs answer EMPTY (confirmed miss)      n=0  ttl=86400
G. leg2 ANSWERS empty, leg1 held a single       n=1  ttl=2592000
```

### The fix

Serving the leg-1 match stays — withholding it is precisely the 0.9.28 bug. What changes
is how long it is *kept*.

* `STREAM_UNVALIDATED_TTL` (1 day) — a fourth category, because the existing three cannot
  express "a real answer that was never checked".
* `@unvalidated`, per adapter, set in `$finish` at the merge site: `$unvalidated[$i] = 1
  unless defined $res && ref $res eq 'ARRAY'`.
* `$resolve` reads the **winner's** flag: `@$items ? ($unvalidated[$win] ?
  STREAM_UNVALIDATED_TTL : STREAM_FOUND_TTL) : …`.
* The existing `_dbgv` resolve line gains an `UNVALIDATED` tag, so the state is visible in
  the field instead of being inferred from a TTL.

Five lines of code; the rest of the hunk is the reasoning.

**The discriminator is whether leg 2 ANSWERED, not whether it found anything.** An empty
array is a verdict — it looked and had nothing to add — so leg 1's match stands validated
and keeps the long TTL (case G above, unchanged). A watchdog, a throw inside `$runLeg`'s
`eval`, or an `undef` callback is not a verdict. This is why the test is on `$finish`'s
**argument** and not on `@leg1`.

**Why a day rather than `STREAM_INCONCLUSIVE_TTL`'s hour.** An hour makes every list open
after the first re-resolve the album, and the shape that lands here is a service that
*hung* — so each retry costs a fresh `STREAM_SVC_TIMEOUT` against `BUILD_DEADLINE`, on
every open, for as long as that service stays slow. A day bounds the exposure to the daily
warm, whose pump re-resolves any expired entry and validates it properly the moment the
service answers.

**Why a separate array rather than a flag on the items or another `$inconclusive`.** The
items are what `_cacheStream` freezes and what the ListenLater handshake reads — a
provenance flag has no business in either. `$inconclusive` decides the *empty*-result TTL
and the "no match" log line, neither of which this is.

### Verification

`tools/t_releaserank.pl` gained section 3b (8 assertions). `kvSet` in the harness now
records instead of discarding, so the TTL is assertable; `kvGet` still returns undef, so
nothing is served from cache and the existing assertions stay non-vacuous.

Both directions are pinned. The guard cases matter as much as the positive ones: the flag
is per-adapter, so a service that hung while **losing** the row must not shorten the
winner's fully-checked answer.

Run against the pre-fix behaviour (the live tree with exactly the one `$unvalidated[$i]`
line neutralised):

```
FAIL a leg-2 TIMEOUT -> short TTL                             ->  '2592000'
FAIL a leg-2 THROW -> short TTL                               ->  '2592000'
FAIL a leg-2 undef callback -> short TTL                      ->  '2592000'
FAIL an unvalidated service that DOES win takes the short TTL ->  '2592000'
61 passed, 4 failed
```

The four guard assertions stay green there, so they are not merely mirroring the flag.
Against the fix: 65/65.

Full suite: **939 across twelve suites, 0 failures** (931 before; only `t_releaserank`
moved, 57 → 65).

---

## Finding 2 — DECLINED. The retry gate stays on the folded test

Raised as *plausible*: `_wantsTitleRetry` gates on `_exactFolded` (via `_releaseKey`,
which keeps non-edition bracket content), while the 165-exact/3-loose dry run quoted to
justify the retry's cost was measured with `_matchExactness` (which deletes every
bracket). Suggested remedy: `_exactFolded(...) || _matchExactness(...) eq 'exact'`.

**The mismatch is real.** Every one of these is admitted by `_albumMatches`, counts
*exact* under the measurement, and *loose* under the shipped gate:

```
ALBUM     SERVICE TITLE                                  folded  strict  retry
Foo       Foo (Live)                                     loose   exact   RETRY
Foo       Foo (feat. Bar)                                loose   exact   RETRY
Sinners   Sinners (Original Motion Picture Soundtrack)   loose   exact   RETRY
Foo       Foo (Extended) / (Radio Edit) / (2024 Mix)     loose   exact   RETRY
Foo       Foo (Instrumental) / (Acoustic) / (Demo)       loose   exact   RETRY
Foo       Foo (Deluxe Edition) / (Remastered) / [Explicit]  EXACT exact   -
```

**The remedy is not.** Built and run against the same resolver: a review of *Foo* whose
artist leg returns only *Foo (Live)*, where the title leg would find *Foo*.

```
shipped gate:    items=['Foo', 'Foo (Live)']   queries=2  (Interpol | Foo)
suggested gate:  items=['Foo (Live)']          queries=1  (Interpol)      ttl=2592000
```

The suggestion stops sending the second query, resolves the row to the live album, and
pins it for thirty days — reinstating the exact defect class 0.9.27 removed, in the shape
the retry is *most* valuable against. The two predicates are deliberately separate:
`_matchExactness` is the strict matcher-tier test (0.9.21's unpadded-split rule depends on
its strictness), `_releaseKey` is the ranking/retry **identity**. Mixing them inverts the
fix.

**Residual, accepted and logged in ledger B:** the *cost figure* is understated, not the
gate. Retry frequency under the shipped predicate has never been measured — PFR's debug
category is off on the live server, so the field log carries no `retrying on album` lines
to count. Measuring it needs `plugin.pitchforkreviews` debug enabled and a cold browse.
Until then the fan-out cost is the one already documented in `_findPlayable`'s
`BUILD_DEADLINE` note: a four-`STREAM_SVC_TIMEOUT` worst case, accepted since 0.7.12.

---

## Wider check — what the change reaches

The concern was a fix that pushes the problem one layer down. Each consumer of the resolve
outcome was checked rather than assumed:

| Consumer | Verdict |
|---|---|
| `_cacheStream` items payload | Untouched — the flag is a lexical array, never a key on an item, so nothing new is frozen into the store. |
| ListenLater handshake (`_attachFavUrl`) | Untouched — items are byte-identical; only the TTL differs. |
| `_matchProgress` | Unaffected. It reads `$_->{_album}` first, so a row that matched is never counted *pending*; the `kvGet` peek is only consulted for rows with no match at all. |
| `_findPlayableReview` (combined reviews) | **No outer cache layer** — the sub contains no `kvSet`/`_cacheStream` (verified over its whole range, 2768–2877). It composes per-side `_findPlayable` results, each cached under its own key with its own TTL, so the short TTL is not defeated by an outer hit. This is the layered-cache trap that bit LBF; it does not apply. |
| Warm / `_resolveSection` pump | An expired entry re-resolves on the next pass. That is the intended re-validation, and no new loop: identical to how any expired entry already behaves. |
| `_releaseAlts` / `reviewDetail` | Items unchanged. |
| `STREAM_KEY_VERSION` | Untouched — the key shape did not change, so no migration. |

Also swept:

* **Called-vs-defined subs** (`perl -c` cannot see this — it passes on calls to
  non-existent subs). The unresolved-name set is byte-identical to `HEAD`'s
  (`_albumItem`, `_canonicalize_expiration_time`, `_max`, `_pluginDataFor`,
  `_renderAlbum` — all pre-existing external/qualified calls). Nothing introduced.
* **`matcher_sync_check.py`** — same three DRIFT entries as before the change (`_norm`,
  `%FOLD`, `_albumMatches`), which is the known fleet-wide hold in ledger B. The diff
  touches no matcher sub.
* **`$win` safety** — `$win` is set only where `@{$result[$i]}` is non-empty, so
  `defined $win` and a non-empty `$items` are equivalent and both `$unvalidated[$win]`
  reads are guarded.

## Cache bump — checked, not assumed

**`STREAM_KEY_VERSION` 22 → 23**, and the entries it retires are the ones `:22:` itself
wrote. 0.9.27/0.9.28 stored answers whose checking leg never answered under
`STREAM_FOUND_TTL`; 0.9.29 gives that shape the short TTL, but **only for answers written
from here on**. An entry already in the store carries its 30-day slot and nothing
re-examines it — so without the bump the fix is unobservable against exactly the entries it
exists to correct, and the symptom stays silent (the row plays, it just plays a different
record). This is the same reasoning as the `:22:` bump, one release later.

`PARSE_VERSION` stays at **3** — no article parsing or fetch behaviour changed, so
re-downloading the articles would be cost with no test value.

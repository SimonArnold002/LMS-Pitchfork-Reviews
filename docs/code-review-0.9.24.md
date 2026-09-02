# Code review — 0.7.11 → 0.9.24

Reviewed: full working-tree diff on `dev` (`API.pm`, `Browse.pm`, `Plugin.pm`,
`Settings.pm`, `HomeExtras.pm`, `strings.txt`, the new `DB.pm`) — year-end lists, the
combined-review resolver, the warm rework, the image-proxy handlers, backoff, and the
feed miss markers.

**Cleared, no action needed:** all 11 committed suites pass (784 assertions, 0 failures);
the zip's `Browse.pm` / `API.pm` / `DB.pm` / `Plugin.pm` are byte-identical to the working
tree; `install.xml` 0.9.24 == `repo.xml` 0.9.24 and `<sha>` matches the actual zip; no
missing or orphaned string tokens (only `_DESC`, unreferenced by design); no calls to
undefined subs; all `sprintf` placeholder counts line up.

Traced and held up: the `%RESOLVING` token/adoption release, `$FG_INFLIGHT` accounting and
the warm yield/re-arm (no lost wakeups), the two-phase warm fetch/resolve chain and its
single watchdog, `_splitAlbumTitles`' per-separator padding rule (incl.
`AC/DC / Live at Donington`), the exactness gate and index promotion in
`_findPlayableReview`, the four image-proxy handlers' square + `_onlyDown` guards,
`_parseYear`'s rank/cover state machine, the year Refresh row's `$probed` condition in both
directions, `_viewYear`'s sticky/promote/repair matrix, `_retireOldStreamKeys` (the marker
key is not caught by its own prefix delete), and DB `getList`/`putList` NULL/shape
round-tripping.

Four findings, most severe first. All four are the same underlying pattern the code already
defends against elsewhere (`_cacheStream` and `_markFeedMiss` are eval-guarded precisely for
this): **a failure on a shared publish/store path costs *other* callers their answer.**

---

## 1. A store that fails writes no miss marker → unbounded re-download

**Severity:** medium. **Where:** `PitchforkReviews/API.pm:553`, same shape at `API.pm:391`.

```perl
Plugins::PitchforkReviews::DB::putList($key, $i, PARSE_VERSION);
Plugins::PitchforkReviews::DB::kvDel($missKey);   # a good fetch clears any marker
```

`putList` returns 0 on a failed write (it logs and swallows), but the return value is
discarded and `kvDel($missKey)` runs unconditionally. So a fetch that **parses fine but
fails to store** is treated as a success: no rows land, `stored_at` never advances, and the
miss marker is actively cleared.

Result: the next open sees no stored rows and no marker, re-downloads the ~1–2 MB listing,
fails to store again, and repeats — on every view open and every warm tick, indefinitely.
That is exactly the unbounded-refetch defect `FEED_MISS_TTL` was added to bound, surviving in
the one branch that bypasses it.

**Fix:** gate on the return value — mark a miss (or at minimum, don't clear one) when
`putList` reports failure.

```perl
if (Plugins::PitchforkReviews::DB::putList($key, $i, PARSE_VERSION)) {
    Plugins::PitchforkReviews::DB::kvDel($missKey);
}
else {
    _markFeedMiss($key, $missKey);
}
```

---

## 2. Feed miss gate is consulted with nothing stored → an hour of `[]` on a fresh install

**Severity:** medium. **Where:** `PitchforkReviews/API.pm:522`.

```perl
if (!$opts{force} && Plugins::PitchforkReviews::DB::kvGet($missKey)) {
    ...
    return $cb->($stored || []);
}
```

The header comment argues correctly that gating on `!$stored` would ship the marker inert
for the case it exists for — a server that *has* fetched successfully. It does not cover the
**no-rows** case, which the `$stored || []` fallback silently admits.

On a fresh install (or a new section), one transient fetch failure sets the marker and the
section then answers `[]` for a full `FEED_MISS_TTL` (1 h) with **no retry**. The warm can't
rescue it either: it passes `nostale`, not `force`, so it hits the same gate. Pre-0.9.24 the
next open simply retried.

**Fix:** honour the marker only when there is something to serve —

```perl
if (!$opts{force} && $stored && @$stored
    && Plugins::PitchforkReviews::DB::kvGet($missKey)) { ... }
```

or use a much shorter marker TTL when nothing is stored.

---

## 3. Resolver waiter fan-out is unguarded and runs after `$callback`

**Severity:** medium. **Where:** `PitchforkReviews/Browse.pm:2861`, same shape at
`Browse.pm:2760` (the cache-hit path).

```perl
my $answer = { items => _streamResult($client, $items) };
$callback->($answer);
$_->({ items => _streamResult($client, $items) }) for @waiters;   # unguarded
```

`$callback` chains into the full feed render — a lot of code, any of which can die. Because
the fan-out runs *after* it and is not eval-guarded, one throw strands **every** coalesced
waiter. The `%RESOLVING` slot was already deleted by then, so the `RESOLVE_JOIN_MAX`
adoption path can't rescue them: there is no wedged slot left to adopt.

Each stranded waiter that came from a `view` is a `$FG_INFLIGHT` that never decrements
([Browse.pm:1396](../PitchforkReviews/Browse.pm#L1396) is only reached from the resolver
callback). `$FG_INFLIGHT` is tested for truth, so a single leak pins the warm at
`WARM_CONCURRENCY` and every home shelf at the narrow width for the life of the process —
the 0.9.23 finding-1 leak, reintroduced from the publish side.

**Fix:** serve the waiters first, or guard each one:

```perl
for my $w (@waiters) {
    eval { $w->({ items => _streamResult($client, $items) }); 1 }
        or $log->warn("resolve: waiter for $key threw: $@");
}
$callback->($answer);
```

---

## 4. `_shareFetch`'s `$done` fans out unguarded

**Severity:** low. **Where:** `PitchforkReviews/API.pm:170`.

```perl
my $waiting = delete $PENDING{$key} || [];
$_->($items) for @$waiting;
```

Same pattern, lower blast radius (feed callbacks, not the full render). One throwing waiter
leaves the remaining coalesced callers' browse requests permanently unanswered — Material's
three-dot placeholder, forever — and nothing self-heals them, because the `%PENDING` slot is
already deleted.

**Fix:** wrap each call in `eval`, as `_issueFetch` already does for the issuing path.

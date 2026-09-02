# Code review — 0.7.11 → 0.9.22

Reviewed: full working-tree diff on `dev` (new `DB.pm` SQLite layer, year-end lists in
`API.pm`, combined-review resolver, warm rework, image-proxy handlers).

**Cleared, no action needed:** all 10 committed test suites pass (694 assertions); the
zip matches the working tree; version and `<sha>` consistent across `install.xml` and
`repo.xml`; no missing or orphaned string tokens; no calls to undefined subs; the
`Storable`-through-`sqlite_unicode` round trip in `DB.pm` fuzz-verified clean (400 cases,
0 failures).

Four findings, most severe first.

---

## 1. Wedged-slot recovery drops its waiters and lets the old owner publish

**Severity:** high — silent, permanent, and it kills the warm.
**Where:** `PitchforkReviews/Browse.pm:2622-2630` (the wedged branch), with the
publish path at `PitchforkReviews/Browse.pm:2708-2721`. Sub: `_findPlayable`
(`Browse.pm:2562`).
**Status:** reproduced against the real sub.

### What happens

In-flight coalescing stores `$RESOLVING{$key} = { at => time(), waiters => [] }`. A
second caller for an album already being resolved pushes its callback onto `waiters`
rather than issuing its own search. A slot older than `RESOLVE_JOIN_MAX`
(`Browse.pm:171`, 60s) is treated as wedged and replaced:

```perl
$log->warn("resolve slot for $key looks wedged — starting a fresh search");
delete $RESOLVING{$key};
```

Two defects in that one line.

**a) The queued callbacks go in the bin.** `delete` discards the slot including its
`waiters` array. Every caller already parked on it is never invoked. Those are not
cosmetic drops — in `_resolveSection` (`Browse.pm:1254`) the callback is what
increments `$done` and decrements `$active`, and in view mode it is what decrements
`$FG_INFLIGHT` (`Browse.pm:1250`). A dropped waiter leaks all three permanently.
`$FG_INFLIGHT` never returning to 0 pins the warm at `WARM_CONCURRENCY`
(`Browse.pm:1236`, 2) — see the yield logic at `Browse.pm:1336` — for the remaining
life of the process.

**b) The abandoned owner is orphaned, not cancelled.** Nothing stops the original
resolve. When it eventually completes, `$finish` runs `my $slot = delete
$RESOLVING{$key}` and fires whatever waiters it finds. By then that is the
*replacement* slot: its waiters receive the stale answer the replacement was started to
avoid, and the replacement's own `$finish` later finds no slot and publishes to nobody.

### Fix

Two changes, both local:

1. In the wedged branch, adopt the old slot's waiters into the replacement instead of
   dropping them: capture `@{ $slot->{waiters} || [] }` before the `delete`, and seed
   the new slot's `waiters` with them at the claim site (`Browse.pm:2641`).
2. Give each slot an identity — a token stamped at claim time, or compare with
   `Scalar::Util::refaddr` — and have `$finish` delete and publish **only** if the slot
   currently in `%RESOLVING` is the one it claimed. A late owner then quietly discards
   its own result.

### Verifying

Unit test: claim a slot, backdate `at` past `RESOLVE_JOIN_MAX`, register a waiter,
trigger the replacement, then complete both owners in the wrong order. Assert every
waiter is called exactly once and with the *replacement's* answer, and that
`_fgInflight()` (test seam at `Browse.pm:1252`) returns to 0.

---

## 2. Combined-review alt albums are injected into a playable playlist node

**Severity:** medium — user-visible, one tap away.
**Where:** `PitchforkReviews/Browse.pm:1545-1555`, in `_attachReviewLink`
(`Browse.pm:1509`).

### What happens

`_attachReviewLink` wraps a matched row's `url` coderef and prepends `@intro` to the
service tracklist. The comment block above the sub justifies that on an explicit
invariant: every injected item is non-audio (a `text` capsule, a `link`, a blank
spacer). The 0.9.17 combined-review alts break it — they are genuine service album
nodes, deliberately kept playable in their own right, and on Deezer they carry
`play => deezer://album:<id>` (which is exactly what `_detectAdapters` keys off).

The wrapped node is `type => 'playlist'`, so Material's Play / Add acts on the whole
item list. Play on one combined-review row can queue both sides of the review.

### Fix

Preferred: strip the audio affordances from the copies in the loop — delete
`play` (and `on_select` if set) from `%a`. The alt still drills into its own tracklist
via its `url`, which is what the row is for.

Alternative if the alts should stay directly playable: don't put them in `@intro`;
route them through `reviewDetail`, which already renders every side.

### Verifying

Extend the existing `_attachReviewLink` coverage with a Deezer combined review and
assert no item in the wrapped result carries a `play` key.

---

## 3. Image-proxy handlers are registered by CDN host, so they rewrite other plugins' artwork

**Severity:** medium — cross-plugin side effect, mild but real.
**Where:** `PitchforkReviews/Plugin.pm:130-142`; handlers at `Browse.pm:2209`
(Qobuz), `Browse.pm:2222` (Tidal), `Browse.pm:2236` (Deezer).

### What happens

`Slim::Web::ImageProxy->registerHandler` matches on the URL, not on which plugin
produced the row. Registering `static.qobuz.com`, `resources.tidal.com` and `dzcdn.net`
means every Qobuz / Tidal / Deezer cover on the server — the Qobuz plugin's own
browse, Material's Now Playing, anything — is routed through PFR's rewriters.

That is mostly benign because the rewrite only ever shrinks, but that holds only for
URLs PFR generated at a known starting size. A TIDAL-plugin row that already requested
`/80x80.jpg`, hitting a 300 spec, is rewritten *up* to `/320x320.jpg` (`Browse.pm:2222`
substitutes unconditionally when `getRightSize` returns a width). More bytes than the
row asked for, in a plugin that never opted in.

### Fix

Make each handler a no-op when the URL's existing size is already at or below the
target: parse the current dimension out of the same regex capture, and skip the
substitution unless `$w` is smaller. That preserves "only ever go down" for URLs PFR
did not author, and changes nothing for the ones it did.

### Verifying

Table test per service: a URL already smaller than the spec comes back byte-identical;
a URL larger than the spec is shrunk as today.

---

## 4. `_warmTick` re-arms at 20s forever when the warm can never start

**Severity:** low — wasteful, not incorrect.
**Where:** `PitchforkReviews/Plugin.pm:234-235`, in `_warmTick`
(`Plugin.pm:204`). Constants at `Plugin.pm:54-55`.

### What happens

```perl
Slim::Utils::Timers::setTimer(undef,
    time() + ($started ? WARM_INTERVAL : WARM_PLAYER_RETRY), \&_warmTick);
```

`WARM_PLAYER_RETRY` (20s) is the right answer for "no player has connected *yet*" — it
is what fixed the three-hour hole described at `Browse.pm:891`. But the re-arm is
unconditional and has no ceiling. On a server where `warmCache` returns 0 or throws
indefinitely — headless, no player ever connected, a real LMS configuration — the tick
fires every 20 seconds for the life of the process: ~4,320 wake-ups a day that cannot
succeed, each one also running a `kvSweep` DELETE (`Plugin.pm:217`).

### Fix

Track consecutive non-starts in a file-scoped counter and back off exponentially from
`WARM_PLAYER_RETRY`, capped at `WARM_INTERVAL`. Reset to 0 on the first `$started`.

### Verifying

Drive `_warmTick`'s delay calculation directly with a stubbed `warmCache`: assert the
delay grows on repeated failure, never exceeds `WARM_INTERVAL`, and snaps back to
`WARM_INTERVAL` after a success.

---

## Suggested order

1. **Finding 1** — the only one that breaks behaviour silently and permanently.
2. **Finding 2** — the only one a user would notice directly.
3. **Finding 3** — affects other plugins, so worth clearing before a release.
4. **Finding 4** — housekeeping.

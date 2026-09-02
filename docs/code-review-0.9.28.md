# Code review — 0.9.27 → 0.9.28

Reviewed: the **two commits ahead of `origin/dev`** (`155e3e4` 0.9.27, `46dc305` the field
confirmation). Working tree was clean at review time, so the commit range *is* the scope —
no reconstruction needed, unlike the 0.9.22–0.9.26 series.

Two findings. **One confirmed and fixed; one withdrawn after being tested against the live
server.** The withdrawal is the more useful half of this round, because the reasoning behind
it was plausible enough to be worth pinning down permanently — it is now ledger entry B and
memory note `xmlbrowser-no-session-cache`.

---

## Finding 1 — CONFIRMED and FIXED. A leg-2 timeout discarded leg 1's matches

`Browse.pm`, the two-leg resolver inside `_findPlayable`'s `$startAdapter`.

### The defect

0.9.27 made the album-title retry fire on a **loose-only** leg 1, not just an empty one.
That is the whole Interpol fix — but it also means **leg 1 is now routinely holding real
matches when leg 2 runs**, where before it was holding nothing.

`$collect` handled that correctly: it stashed `@leg1` and merged it back so leg 2 could
never *replace* a good answer with a worse one. The merge was on the wrong side of the
funnel. `$runLeg` arms a fresh watchdog per leg and catches the adapter's throw, and **both
of those paths call `$finish->(undef)` directly** — `$collect` is the adapter's callback and
is never reached when leg 2 times out or blows up.

So an 8-second `STREAM_SVC_TIMEOUT` on the title query threw away matches the artist query
had already found, counted the service `inconclusive`, and answered
`PLUGIN_PITCHFORKREVIEWS_NO_MATCH`.

The existing suite did not catch it because `t_releaserank`'s "leg 1 survives an undef leg 2"
drives the *adapter* calling `$collect->(undef)` — which does go through the merge. The
timeout path had no coverage at all.

### The fix

`@leg1` is declared above `$finish`, and the merge moves into `$finish`, which is the one
funnel every outcome passes through. `$finish` now rewrites its own argument into a lexical
`$res` and merges before the `!defined` inconclusive branch. `$collect` just calls
`$finish->($res)`.

Five lines of code; the rest of the hunk is the note explaining why it must live there.

**Ordering and semantics are unchanged** — leg 2 still leads (that is where the exact
candidate is expected), the promotion in `$resolve` still decides, `_dedupeStreamItems`
still collapses the overlap. The fallback stays gated on `@leg1` being non-empty, so a
timeout **holding nothing** is still `inconclusive` and still takes the 1-hour
`STREAM_INCONCLUSIVE_TTL` rather than being promoted into a 1-day confirmed miss.

### Verification

Reproduced before it was fixed, which is the part that matters. `t_releaserank`'s adapter
stub gained two shapes that never call back — `'HANG'` (the service takes the query and goes
quiet, so only its watchdog can settle the leg) and `'DIE'` (throws inside `$runLeg`'s
`eval`) — plus a `fire_watchdog()` helper that runs the callback the stub `setTimer`
recorded. Seven new assertions, four of them the guard direction.

Run against the **pre-fix** `Browse.pm` via `PFR_BROWSE`:

```
FAIL leg 1 survives a leg-2 TIMEOUT  ->  ''
FAIL leg 1 survives a leg-2 THROW    ->  ''
55 passed, 2 failed
```

Against the fix: 57/57. The tests discriminate rather than passing vacuously.

Full suite: **931 across twelve suites, 0 failures** (924 before; only `t_releaserank`
moved, 50 → 57).

---

## Finding 2 — WITHDRAWN. The Refresh row does refresh

Raised as *plausible*: 0.9.27's unconditional Refresh row is injected into a feed served by
a closure that captured `@intro` and `$inner` at row-build time, so if XMLBrowser satisfied
`nextWindow => 'refresh'` by replaying that level, the page would redraw with the same stale
intro and the same wrong tracklist — the headline "a matched row can finally correct a bad
match" would be reachable but inert.

**It does not happen, and the reason is worth recording** because the trap the finding
describes is real in general — it just cannot fire for a menu shaped like ours.

`Slim/Control/XMLBrowser.pm` (public/9.1) caches a browsed tree as `xmlbrowser_$sid`, and
once a level is fetched it sets `$subFeed->{fetched} = 1` and replays the stored items
instead of re-invoking that level's `url` coderef. Only `$subFeed->{forceRefresh}` clears
that, and only at `$depth == $levels`. But a sid is minted in exactly one place — the top
level, when `item_id` is absent, and only if:

```perl
my $refs = scalar grep { ref $_->{url} } @{ $feed->{items} };
# Don't cache if list has coderefs
if ( !$refs ) { $sid = Slim::Utils::Misc::createUUID(); }
```

PFR's top level is coderef-driven throughout (`_feedTile`, `\&fetchYearFeed`), so **no sid
is ever minted**, and `getSID` needs 8 hex characters at the front of `item_id` while ours
are plain `2`, `2.4`, `2.4.3`. No sid means no cache read on entry and no cache write on
exit: the tree is rebuilt from `topLevel` down on every request, closure included.

Proven on the live server rather than only read off the source, using the plugin's own group
toggle — which uses the identical `nextWindow: refresh`-on-empty mechanism one level up:

```
BEFORE     2 'Grouped by Week (tap to change)'    3 'Week of 24 August 2026'
tap 2.2
AFTER      2 'Grouped by Genre (tap to change)'   3 'Rock'
```

Both the row label and the divider changed, so re-requesting the parent genuinely re-walked
the feed. (Restored afterwards.) A cold standalone request for a deep `item_id:2.4` also
returns the fully assembled page, which is only possible if the whole path is rebuilt.

**No code change. `forceRefresh` is not needed and is used nowhere in the fleet.** Recorded
as ledger entry B and as the memory note `xmlbrowser-no-session-cache`, which explicitly
distinguishes this from the client-side trap in `material-history-stale-labels`: an in-place
refresh re-walks, a page replayed from `view.history` does not.

---

## Also confirmed in the field

0.9.27 itself is behaving correctly on the live server. `Latest Reviews → Interpol` resolves
to `qobuz://album:f06v4yh3txcxt` — the 12-track album — with the 2-track single demoted to
an "Another release with this name" row and the Refresh row beneath it.

## Cache bump — checked, not assumed

**None needed.** The fixed path only ever wrote an `inconclusive` empty result, which carries
`STREAM_INCONCLUSIVE_TTL` (3600s) and self-heals within the hour; nothing stored under the
old behaviour is *wrong*, merely briefly missing. `STREAM_KEY_VERSION` stays at 22 and
`PARSE_VERSION` at 3.

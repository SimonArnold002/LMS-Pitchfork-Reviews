# Pitchfork Reviews — LMS Plugin

## Project Overview
A Lyrion Music Server plugin that browses curated album reviews and plays each
reviewed album from the user's streaming library. **v1 source: Pitchfork** (Best
New Music + Latest Reviews, parsed from the listing pages' embedded Verso state —
see Architecture). Each review resolves to a directly-playable album on Qobuz /
Tidal / Deezer, reusing the album-match engine from the sibling **ListenBrainz
Fresh Releases** plugin. Pure Perl, async, **no extra server software**
(cross-platform). Targets LMS 9.x + Material Skin.

Design decisions live in the auto-memory note `album-reviews-plugin-scope`.

## Review Ledger — READ THIS BEFORE REPORTING ANY FINDING

**Why this exists.** Reviews kept re-reporting things that had already been
decided — deliberate conventions read as defects, and verdicts that lived only in
a chat transcript. Review and fix happen in separate sessions, so nothing carries
a decision forward. Everything below has already been settled.

*This repo is the fleet's reference case, and it disproves the obvious
explanation. The 0.9.22 → 0.9.26 series ran FIVE review rounds against a single
uncommitted tree of 13,227 insertions, baseline frozen for 13 days, and converged
4 → 4 → 4 → 2 → 1 → clean — then committed once. So a big uncommitted diff does
NOT cause findings to repeat. What PFR had was a feature set that stopped moving
while the rounds ran.*

**If you are reviewing:** read sections A and B first, and report an item from
them only if you have genuinely NEW information — a case the recorded reasoning
does not cover. Say which ledger entry you are challenging and what changed.

### A. NOT FINDINGS — deliberate, fleet-wide

- **The zip is not rebuilt and `repo.xml <sha>` is not recomputed in the working
  tree.** Both happen at build time, together with the version bump. `install.xml`
  / `repo.xml` / the zip sitting behind the source is the normal mid-work state
  and was explicitly out of scope for the 0.9.25 and 0.9.26 reviews.
- **`CHANGELOG.md` and `README` are written at the MERGE TO MAIN, not on dev
  builds.** A CHANGELOG behind `install.xml` is CORRECT on `dev`. Dev builds
  update `CLAUDE.md`, `docs/*.md` and the memory notes only.
- **A large uncommitted working tree, where present, is deliberate** — it is the
  review diff. Do not prompt to commit as a fix for anything.

### A2. NOT FINDINGS — Pitchfork Reviews specific

- **PFR's matcher copies follow the fleet rule** and are canonical-or-pinned. See
  `../LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py`.
- **Genre/rank grouping is deliberately NOT run through `_groupedRows`** in the
  contexts noted below — both grouping modes are meaningless there.
- **Tuning values are not defects.** Where a fix note says a threshold was
  "deliberately NOT retuned", that is a tuning call and out of scope.

### B. KNOWN-OPEN AND ACCEPTED — do not re-report as new

- **`matcher_sync_check.py` exits 1 fleet-wide.** A known, deliberate hold while
  DSC's provisional `_albumMatches` alias pass proves in the field. Not a
  regression in this repo.
- **PFR will NOT get LBF's `_candReleaseType` single-drop filter (declined 0.9.27).**
  Proposed while fixing the Interpol wrong-match and rejected on live data. LBF can
  filter because MusicBrainz states the TARGET's release type; PFR has none —
  `_parseState` extracts artist, album, capsule, link, date, cover, score and genre,
  and the only hint that ever exists is the literal " EP" in Pitchfork's title, which
  `_stripFmt` deliberately discards to make the match work at all. Assuming "the target
  is an album" is wrong on the current feed: Pitchfork reviewed *Faith Leazae — Faith
  EP* and Deezer types that same record `album`, 8 tracks. A filter keyed on a type
  nobody agrees about bins correct EP matches. **Release type may still be used to
  decide what to OFFER, never what to DROP** — that door is open (it is the residual
  gap `_releaseAlts` documents), a filter is not.
- **The Refresh row is NOT defeated by a captured closure (withdrawn 0.9.28).** Raised as
  plausible: the row is injected into a feed served by a closure that captured `@intro` and
  `$inner`, so `nextWindow => 'refresh'` looked like it would redraw the same stale rows.
  XMLBrowser does have that trap — `$subFeed->{fetched}` replays a level instead of
  re-invoking its `url` coderef — but it **cannot fire here**: a sid is minted only at the
  top level and only when no top-level item has a coderef `url` (*"Don't cache if list has
  coderefs"*), and PFR's top level is coderef-driven throughout, so no `xmlbrowser_$sid`
  ever exists and the tree is rebuilt from `topLevel` down on every request. Proven live by
  tapping the group toggle (`item_id 2.2`) and re-requesting `2`: both the row label and the
  divider changed. **`forceRefresh` is not needed and is used nowhere in the fleet.** Full
  reasoning in `docs/code-review-0.9.28.md`; memory note `xmlbrowser-no-session-cache`.
- **`_wantsTitleRetry` will NOT be widened with `_matchExactness` (declined 0.9.29).**
  Raised as *plausible*: the retry gate gates on `_exactFolded` (via `_releaseKey`, which
  KEEPS non-edition bracket content), while the 165-exact/3-loose dry run quoted to justify
  the cost was measured with `_matchExactness` (which deletes every bracket). **The mismatch
  is real** — `Foo (Live)`, `Foo (feat. X)`, `Sinners (Original Motion Picture Soundtrack)`,
  `(Extended)`, `(Radio Edit)`, `(Instrumental)`, `(Demo)` are all admitted by
  `_albumMatches`, all count *exact* under the measurement and *loose* under the shipped
  gate. **The proposed remedy is not.** Gating on
  `_exactFolded(...) || _matchExactness(...) eq 'exact'` was built and run: a review of
  *Foo* whose artist leg returns only *Foo (Live)* stops sending the second query, resolves
  the row to the live album and pins it for `STREAM_FOUND_TTL` — reinstating the exact
  defect class 0.9.27 removed, in the shape the retry is most valuable against. The two
  predicates are deliberately separate (`_matchExactness` is the strict matcher-tier test;
  `_releaseKey` is the ranking/retry identity), and mixing them inverts the fix.
  **Residual, accepted:** the *cost figure* is understated, not the gate. Retry frequency
  under the shipped predicate has never been measured — PFR's debug category is off on the
  live server, so the field log carries no `retrying on album` lines to count. Measuring it
  needs `plugin.pitchforkreviews` debug enabled and a cold browse; until then the fan-out
  cost is the one already documented in `_findPlayable`'s BUILD_DEADLINE note (a
  four-`STREAM_SVC_TIMEOUT` worst case, accepted since 0.7.12).
- **The Qobuz search payload's `release_type` availability is UNVERIFIED.**
  `_precacheAlbum` does not delete the field and the plugin reads it elsewhere, but
  nothing confirms `catalog/search` sends it, and the API needs auth so it cannot be
  probed from a dev Mac. Deezer (`record_type`, live-verified) and Tidal (`type`, from
  `API/Async.pm` passing search items through untouched) do carry one. Nothing in the
  plugin depends on this today; it would need a one-off `_dbgv` key dump first.

### C. CLOSED FINDINGS

Fixed findings are recorded per review in `docs/code-review-<version>.md`
(0.9.22 → 0.9.26, 0.9.28, 0.9.29) and in the Status sections below, each with its mechanism and
its test. The whole 0.9.22–0.9.26 series is closed. Do not re-derive it.

### D. ADDING TO THIS LEDGER

When a finding is declined, or accepted-but-deferred, add it here in the same
session — one line, with the reason. A decision that lives only in a chat
transcript will be rediscovered as a finding within days.

## Feature Summary & Release Posts (social media)

**Maintain this section** (same convention as the sibling ListenBrainz / Listen Later plugins). Two living artefacts for announcing the plugin:
1. **Overall feature summary** (below) — the social-media / GitHub Pages "drop page" copy. **Update it whenever a key feature is added, changed or removed** (not for bug fixes). Key-features-only, user-facing, no internals.
2. **Per-release post** — when cutting a release, generate a "What's new" post in the **fleet house template** (Variant B; canonical example = Listen Later). Structure, verbatim: header `🎵 What's new in Pitchfork Reviews — for Lyrion Music Server (LMS)` (no version number in it) → **two prose paragraphs** in a conversational voice, leading with the headline change → a `✨ What's new` header with `•` bullets (short label, em-dash, plain-English description) covering only what changed since the last **main** release; a single "smarter matching" bullet may fold in the notable bug fixes → the requirements + `Free and open source.` line → `👉 Full details & install: https://simonarnold002.github.io/LMS-Pitchfork-Reviews/` (the **bare Pages root**, not `repo.xml`) → a final tag line where only `#LyrionMusicServer` is a hashtag and the rest are plain words: `#LyrionMusicServer lms squeezebox pitchfork qobuz tidal deezer selfhosted`. **No** blockquote, **no** "Fixes & polish" heading, **no** bullet-only intro. (A launch post is the same shape with `🎵 Introducing …` and `✨ Features` covering the whole plugin.)

### Overall feature summary (keep current)

> **Pitchfork Reviews — for Lyrion Music Server.** Browse Pitchfork's album reviews inside LMS and play the reviewed album straight from your streaming library — one tap, no searching.

- **Best New Music** — Pitchfork's curated Best New Music picks as a browsable, playable list.
- **High Scoring Albums** — Pitchfork's curated high-scoring picks as a second browsable, playable list.
- **Latest Reviews** — the most recent album reviews.
- **Best Albums of the Year** — Pitchfork's annual top-50 countdown, ranked and playable. Opens on the newest published list and promotes each new one automatically when it lands each December; every year back to 2016 is a tap away, readable #1-first or as Pitchfork's own 50-to-1 countdown.
- **Grouped your way** — all three lists group under **genre** (default) or **week** dividers, carrying the Pitchfork mark; tap **Grouped by** on the list itself to switch, and all three follow.
- **One-tap playback** — each review is matched to a directly-playable album on **Qobuz / Tidal / Deezer**, shown with the service's own artwork; play it or queue it without searching.
- **Genres on every row** — each review shows its Pitchfork genre(s) on the row and the detail page.
- **Read the full review** — links out to Pitchfork; the plugin keeps only artist, album, date, genre and the short capsule (never reproduces the review).
- **Grid or list** — every row carries artwork, so Material's thumbnail/grid toggle stays available.
- **Choose your services** — set the Qobuz / Tidal / Deezer search order (or turn one off).
- **Material home shelves** — Best New Music, High Scoring Albums and Latest Reviews as scrollable rows on the Material home page.
- **Add to Listen Later** — matched albums carry what the companion *Listen Later* plugin needs to save & replay them.
- **Smart matching** — folds stylised spellings (*WOR$T* = *Worst*, *P!nk* = *Pink*) and a trailing EP/LP so more reviews resolve to a playable album; where an artist has an album and a single sharing a name, the reviewed record wins the row.
- **Not the right album? Change it** — when a service carries another release under the same name, it's offered right there on the album page, alongside a Refresh that re-searches from scratch.

**Requirements:** LMS 9.0.0+ (Material Skin recommended; the classic skin covers browse/play). For playback, at least one of **Qobuz / Tidal / Deezer** installed and signed in. **Pure Perl, cached, no extra server software** — runs the same on a Raspberry Pi or a NAS. Every streaming integration is optional and degrades gracefully.

**Install:** add `https://simonarnold002.github.io/LMS-Pitchfork-Reviews/repo.xml` in LMS → Settings → Plugins.

### Latest per-release post (0.8.0 — covers 0.7.10 → 0.8.0)

🎵 What's new in Pitchfork Reviews — for Lyrion Music Server (LMS)

Every December, Pitchfork counts down the fifty best albums of the year — and it's one of those lists you mean to work through and never quite do, because reading it and playing it are two different jobs. That list is now a section in the plugin. It opens on the newest one published, ranked from fifty up to number one, each entry with its cover, its write-up and a tap to play the album from Qobuz, Tidal or Deezer. Every year back to 2016 is behind the "Choose a year" row, so a decade of year-end lists is sitting there too.

The nicest part is that it looks after itself. The plugin works out which list is the newest rather than having it hardcoded, and checks back while it's waiting — so when this December's list goes live, it just becomes the one you land on. No update to install, nothing to switch over. There's also a fix in here for reviews that showed no review text at all once they'd found a match, which was the wrong way round: the better a review resolved, the less of it you could read.

✨ What's new
• Best Albums of the Year — Pitchfork's annual top-50, ranked and playable, with every year back to 2016
• Read it your way — #1 at the top, or tap to flip into Pitchfork's own 50-to-1 countdown order
• Grouping moved onto the list — switch the review lists between genre and week dividers with a tap, instead of a trip to the settings page
• Promotes itself — the newest list is found automatically and takes over when it publishes each December
• Read the review you matched — a matched album now shows its full write-up above the tracklist, instead of only showing it when nothing was found
• Smarter matching — HTML entities in titles are decoded (an "&" no longer blocks a match), and a release the artist search misses is retried on the album title
• Cleaner Listen Later saves — matched albums hand over the service's own album title and release year, so saves dedupe and mark themselves played

Works on LMS 9.x, best with the Material Skin. For playback you'll need at least one of Qobuz, Tidal or Deezer installed and signed in. Free and open source.

👉 Full details & install: https://simonarnold002.github.io/LMS-Pitchfork-Reviews/

#LyrionMusicServer lms squeezebox pitchfork qobuz tidal deezer selfhosted

_Prior (0.7.9): punctuation-smart matching — a decorative "!" no longer blocks a match (Wham!, Panic! At The Disco), and "&"/"+" read as "and" so one act stops showing up as two._

### Superseded per-release post (0.7.9 — covers 0.7.6 → 0.7.9)

🎵 What's new in Pitchfork Reviews — for Lyrion Music Server (LMS)

Some albums just refused to show up. If an artist styled their name with punctuation — Wham!, Panic! At The Disco, Godspeed You! Black Emperor — the plugin was reading that exclamation mark as a letter, so the review it had found and the album sitting in your streaming library no longer looked like the same record, and the row came back unplayable. That's fixed: a decorative mark is now treated as punctuation, while genuinely stylised spellings like P!nk and WOR$T still fold correctly. Acts that arrive from one service as "X & Y" and another as "X and Y" are now understood as one act too.

The handoff to the companion Listen Later plugin also got tidied. Matched rows are labelled "Artist – Album", and Material passes that whole label through as the album name — so saved albums came back with the artist doubled into the title, which looked wrong and quietly broke Listen Later's played-album detection. Pitchfork Reviews now passes the clean album title alongside the artist, so saves land correctly and mark themselves played.

✨ What's new
• Punctuation-smart matching — a decorative "!" no longer blocks a match, so Wham!, Panic! At The Disco and Godspeed You! Black Emperor resolve to a playable album
• One act, one row — "&" and "+" now read as "and", so the same band arriving from two services stops showing up twice
• Cleaner Listen Later saves — matched albums save under their real title instead of "Artist – Album", and played detection works again
• Visible settings toggle — the "Extra debug logging" checkbox now actually renders in Material, with a clickable label

Works on LMS 9.x, best with the Material Skin. For playback you'll need at least one of Qobuz, Tidal or Deezer installed and signed in. Free and open source.

👉 Full details & install: https://simonarnold002.github.io/LMS-Pitchfork-Reviews/

#LyrionMusicServer lms squeezebox pitchfork qobuz tidal deezer selfhosted

_Prior (0.7.1): genre/week dividers everywhere — Best New Music and High Scoring Albums group under the same Pitchfork-marked genre (or week) headers as Latest Reviews, driven by the one grouping setting._

## Naming
Repo `LMS-Pitchfork-Reviews`; plugin/package/dir `PitchforkReviews`
(`Plugins::PitchforkReviews::*`); prefs `plugin.pitchforkreviews`; command tag
`pitchforkreviews`; cache prefix `pfr:`; zip `PitchforkReviews.zip`; display name
"Pitchfork Reviews" with three feed tiles "Best New Music" + "High Scoring Albums" +
"Latest Reviews". (The
`arv:`/`AlbumReviews` names were the pre-rename identifiers — fully retired.)

## Status: 0.9.29
**A code-review fix on top of 0.9.28's: the match a slow service left unchecked is still
served, but it is no longer kept for a month. Plus one finding declined after its proposed
remedy was built and shown to regress.**

### The defect (review finding 1)

0.9.28 stopped a slow leg 2 from discarding matches leg 1 was holding, by moving the
`@leg1` merge into `$finish`. Correct — and it made `$res` **always defined** once leg 1
held anything, so the `!defined $res` inconclusive branch became unreachable on that path.
A leg-2 **timeout** therefore came out of the *found* side of `$resolve`, where the TTL is
`STREAM_FOUND_TTL`: thirty days.

The release's own field case, one step further. Qobuz's artist leg returns only the 2-track
*This Mirror Weighs a Ton/See Out Loud*; the album-title leg that exists to find the
12-track album times out; the single is pinned for a month on the strength of a query that
never answered. That is the same wrong-match-for-a-month shape 0.9.27 removed, reached by a
new route. 0.9.28's TTL note only covered the `@leg1`-*empty* case.

### The fix

Serving the leg-1 match stays — withholding it is exactly the 0.9.28 bug. What changes is
how long it is kept. A fourth TTL category, `STREAM_UNVALIDATED_TTL` (1 day), because the
existing three cannot express "a real answer nobody checked"; a per-adapter `@unvalidated`
set at the merge site; and `$resolve` reading the **winner's** flag.

**The discriminator is whether leg 2 ANSWERED, not whether it found anything.** An empty
array is a verdict — it looked and had nothing to add — so leg 1's match stands validated
and keeps the long TTL. A watchdog, a throw, or an `undef` callback is not a verdict. Hence
the test is on `$finish`'s argument, not on `@leg1`.

A day rather than the inconclusive hour: the shape that lands here is a service that *hung*,
so an hourly retry spends a fresh `STREAM_SVC_TIMEOUT` against `BUILD_DEADLINE` on every
open for as long as that service stays slow. A day bounds the exposure to the daily warm,
which re-resolves the expired entry and validates it properly.

Five lines of code. **939 assertions across twelve suites, 0 failures** (931 before;
`t_releaserank` 57 → 65). The new assertions were run against the pre-fix behaviour and
four of them fail there, so they discriminate; the four guard assertions — a service that
hung while *losing* the row must not shorten the winner's answer — stay green in both.

### Declined (review finding 2)

`_wantsTitleRetry` stays on the folded test. The mismatch the finding identified is real
(the 165/3 dry run was measured with `_matchExactness`, the gate uses `_exactFolded`), but
the proposed remedy was built and run, and it re-resolves a review of *Foo* to *Foo (Live)*
and pins it for thirty days. Full reasoning in ledger entry B and
`docs/code-review-0.9.29.md`.

### Wider check — what the change reaches

Each consumer of the resolve outcome was checked rather than assumed, because the risk in a
TTL fix is pushing the problem one layer down. `_cacheStream`'s payload and the ListenLater
handshake are untouched (the flag is a lexical array, never a key on an item);
`_matchProgress` reads `_album` first, so a matched row is never counted *pending*
regardless of TTL; and **`_findPlayableReview` has no outer cache layer** — verified over
its whole range, it contains no `kvSet`/`_cacheStream` and composes per-side `_findPlayable`
results, each under its own key, so the short TTL cannot be defeated by an outer hit. That
is the layered-cache trap that bit LBF; it does not apply here. Full table in
`docs/code-review-0.9.29.md`.

Also swept: a called-vs-defined sub pass (`perl -c` cannot see this) whose unresolved-name
set is byte-identical to the previous commit's, and `matcher_sync_check.py`, which reports
the same three pre-existing DRIFT entries — the diff touches no matcher sub.

**`STREAM_KEY_VERSION` 22 → 23, a CORRECTNESS bump**, and the entries it retires are the
ones `:22:` itself wrote. 0.9.27/0.9.28 stored answers whose checking leg never answered
under `STREAM_FOUND_TTL`; 0.9.29 gives that shape the short TTL, but only for answers
written from here on — an entry already in the store keeps its 30-day slot and nothing
re-examines it. Same silent symptom as `:22:` (the row plays, it just plays a different
record). `PARSE_VERSION` stays at **3**; no article parsing or fetch behaviour changed.

**BUILT AND PACKAGED at 0.9.29.** `install.xml` and `repo.xml` both say 0.9.29, the zip is
rebuilt (26 files, 490,060 bytes) and `repo.xml <sha>` recomputed to
`d6b49c467b1f37b5a16aeb7cde441fe4c3cb24b4`. Verified against the zip on disk rather than
assumed: the zip's `Browse.pm` is byte-identical to the tree, carries the fix, and reads
`STREAM_KEY_VERSION => 23`. `README.html`/`index.html` regenerated so the version badge is
not left lying; `README.md` and `CHANGELOG.md` deliberately untouched — those are written at
the merge to main.

## Status: 0.9.28
**A code-review fix: a slow streaming service could throw away a match the plugin had
already found. Plus one finding withdrawn after being tested against the live server.**

### The defect (review finding 1)

0.9.27's headline change — the album-title retry now fires on a **loose-only** leg 1, not
only an empty one — had a consequence its own merge logic anticipated but put in the wrong
place. Because the retry now runs when leg 1 matched *something*, **leg 1 is routinely
holding real matches while leg 2 is in flight**, where before it was holding nothing.

`$collect` stashed those in `@leg1` and merged them back, so leg 2 could never replace a
good answer with a worse one. But `$runLeg` arms a fresh watchdog per leg and catches the
adapter's throw, and **both of those paths call `$finish->(undef)` directly** — `$collect`
is the adapter's callback and is never reached when leg 2 times out or dies. An 8-second
`STREAM_SVC_TIMEOUT` on the title query therefore discarded the matches the artist query had
already found, counted the service `inconclusive`, and answered "No match".

Not an edge case: it needs only one slow search on a review that resolved loosely, which
after 0.9.27 is the ordinary shape of a two-leg resolve.

### The fix

`@leg1` is declared above `$finish` and the merge moves **into** `$finish` — the one funnel
every outcome passes through. `$finish` rewrites its argument into a lexical `$res` and
merges before the `!defined` inconclusive branch; `$collect` simply calls `$finish->($res)`.

Semantics are unchanged: leg 2 still leads, `$resolve`'s promotion still decides,
`_dedupeStreamItems` still collapses the overlap. The fallback stays **gated on `@leg1`
being non-empty**, so a timeout holding nothing is still `inconclusive` on the 1-hour TTL
rather than being promoted into a 1-day confirmed miss.

### The finding that was withdrawn (review finding 2)

The unconditional Refresh row was flagged as possibly inert — it is injected into a feed
served by a closure that captured `@intro` and `$inner`, so a `nextWindow => 'refresh'`
looked like it would redraw the identical stale rows. **It does not.** XMLBrowser mints a
session cache only when no top-level item has a coderef `url`, and PFR's top level is
coderef-driven throughout, so the tree is rebuilt from `topLevel` down on every request.
Proven live, not inferred. See ledger entry B and `docs/code-review-0.9.28.md`.

### Scope

**NO CACHE BUMP, and it is checked rather than assumed.** The fixed path only ever wrote an
`inconclusive` empty result, which carries `STREAM_INCONCLUSIVE_TTL` (3600s) and self-heals
within the hour — nothing stored under the old behaviour is *wrong*, only briefly missing.
`STREAM_KEY_VERSION` stays at **22** and `PARSE_VERSION` at **3**.

**No matcher change.** The fix is entirely inside `_findPlayable`'s per-adapter closures —
PFR call-site logic, outside the shared engine. `matcher_sync_check.py` is unaffected and
still reports the same pre-existing DSC drift.

**BUILT AND PACKAGED at 0.9.28.** `install.xml` and `repo.xml` both say 0.9.28, the zip is
rebuilt (26 files, 485,756 bytes) and `repo.xml <sha>` recomputed to
`8097c4c5f1c17512f90a7cac4fcdbe41a4d6a1e4`. Verified against the zip on disk rather than
assumed: the zip's `Browse.pm` is byte-identical to the tree, carries the fix, and still
reads `STREAM_KEY_VERSION => 22`. `README.html`/`index.html` regenerated so the version
badge (read live from `install.xml`) is not left lying; `README.md` and `CHANGELOG.md` are
deliberately untouched — those are written at the merge to main.

### Tests

**924 → 931 across twelve suites, 0 failures.** Only `t_releaserank` moved (50 → 57).

The new coverage is the timeout path, which had none. `t_releaserank`'s adapter stub gained
two shapes that never call back — `'HANG'` (the service goes quiet, so only its watchdog can
settle the leg) and `'DIE'` (throws inside `$runLeg`'s `eval`) — plus `fire_watchdog()`,
which runs the callback the stub `setTimer` recorded. Three assertions cover the fix and
four the guard direction (a leg-1 timeout, and an empty leg 1 followed by a leg-2 timeout,
must both still report no match).

**The tests were confirmed to discriminate**, which is the point of adding them: run against
the pre-fix `Browse.pm` via `PFR_BROWSE`, exactly the two new fix assertions fail
(`leg 1 survives a leg-2 TIMEOUT`, `leg 1 survives a leg-2 THROW`) and the other five pass.

### Field state

0.9.27 verified correct on the live server during this pass: `Latest Reviews → Interpol`
resolves to `qobuz://album:f06v4yh3txcxt`, the 12-track album, with the 2-track single
demoted to an "Another release with this name" row and Refresh reachable beneath it.

## Status: 0.9.27
**A review stopped resolving to a like-named single, and a matched row can be corrected
by hand for the first time. Found in the field, diagnosed against the live server.**

### The defect

Pitchfork's 28 Aug 2026 review of Interpol's *This Mirror Weighs a Ton* resolved to the
2-track single of the same name. Verified over jsonrpc, not inferred — the row's favurl
carried `&al=This Mirror Weighs a Ton/See Out Loud`, and that Qobuz release is
`Release Type: Single, 2 tracks`. The album is a separate 12-track release, `Album`,
issued the day of the review.

**TWO INDEPENDENT DEFECTS, and either one alone still gets it wrong.**

1. **The album was never a candidate.** PFR searches the ARTIST and filters locally.
   Qobuz's artist search puts the single at position **7** and the album at **68**;
   `QOBUZ_SEARCH_LIMIT` is 50. So `_albumMatches` was never shown the right record.
2. **Nothing preferred it.** The single passes through the prefix tier
   (`index("this mirror weighs a ton see out loud", "this mirror weighs a ton ") == 0`)
   and the row takes `items->[0]` in raw service order. Lift the cap and the single
   still wins.

Tidal (album at 2, single at 7) and Deezer (0 and 4) would both have been right by
ordering alone — but `$resolve` takes the highest-priority service that matched
*anything*, and Qobuz is priority 1.

### THE REVERSE DIRECTION IS WHY THIS IS NOT A TYPE FILTER

The obvious fix — port LBF 0.9.89's `_candReleaseType` single-drop — is wrong here and
is recorded as declined in the ledger. PFR has no release type for the target and cannot
get one. Worse, the shape it would damage is live right now: Djrum's *I Wander EP* sits
on Deezer beside the same-artist singles *I Wander (III)* and *I Wander (IV + V)*, and
**`_norm` deletes bracketed content**, so all three normalise identically and all three
are admitted. Only Deezer's ordering was keeping that row correct.

### `_releaseKey` — the one mechanism both halves needed

`_norm` with bracketed content judged by what it MEANS rather than deleted wholesale: an
EDITION qualifier (a closed list — deluxe/remaster/expanded/…) is dropped, anything else
is unbracketed and KEPT as part of the title.

| | `_norm` | `_releaseKey` |
|---|---|---|
| `Foo` vs `Foo (Deluxe Edition)` | same | same — an edition |
| `I Wander` vs `I Wander (III)` | **same** | differ — a release |
| `…a Ton` vs `…a Ton/See Out Loud` | differ | differ |

**The list is closed and fails toward OFFERING:** an unrecognised bracket is treated as
part of the identity, so it makes two titles distinct. Showing one row too many is
recoverable; silently hiding the release the reader wanted is not.

### What changed

1. **An exact title takes the row** (`_exactFolded` + a promotion in `$resolve`) — what
   0.9.21 already does per side of a combined review, applied to the ordinary path.
   Pure reordering: it does nothing unless an exact candidate sits behind a loose one.
2. **The album-title retry fires on a LOOSE-ONLY result**, not only an empty one. 0.7.12
   added that leg for a recall failure ("Leo" burying "Cicada Burnt"); an empty result is
   just its most obvious shape. A Qobuz title search for `this mirror weighs a ton`
   returns exactly two rows, so the album the cap hid is one query away. **Merged, never
   replacing** — leg 2 has its own recall and can legitimately return less.
3. **`_wantsTitleRetry` demands POSITIVE evidence of looseness.** A candidate stating no
   title is "no evidence", not "not exact" — the distinction `_matchExactness` was
   written to keep. Without it every titleless match costs a `STREAM_SVC_TIMEOUT` to
   learn nothing; the existing suites caught this immediately (26 failures).
4. **The runner-up is OFFERED** (`_releaseAlts`, cap `ALT_RELEASE_MAX` 2), reusing
   0.9.17's `_alt` plumbing with its own label — "Another release with this name", never
   "Also covered by this review", which is a different and false claim. Named from the
   SERVICE's `_svctitle`, because the service's spelling is what distinguishes the two
   rows. Ordinary reviews only; a combined review's alts keep their own meaning.
5. **A matched row can finally reach Refresh.** `reviewDetail` has carried that row since
   0.8.4 and a matched row could never get to it — the drill-in is the service's
   tracklist. So the one surface that can correct a bad match was available only to rows
   with nothing to correct, while `STREAM_FOUND_TTL` pinned the wrong answer for 30 days.

### Scope

**`STREAM_KEY_VERSION` 21 → 22, a CORRECTNESS bump.** Ranking changed, so a stored answer
under `:21:` can name the wrong release — and the symptom is silent (the row plays, it
just plays a different record). `PARSE_VERSION` stays at 3; no article parsing changed.

**No matcher change.** `_releaseKey`/`_exactFolded`/`_wantsTitleRetry`/`_releaseAlts` are
all PFR call-site logic sitting OUTSIDE the shared engine — `_norm`, `%FOLD`,
`_albumMatches`, `_artistMatch` and the fallback helpers are byte-identical — so
`matcher_sync_check.py` is unaffected and still reports the same pre-existing DSC drift.

**BUILT AND PACKAGED at 0.9.27** — unlike 0.9.22–0.9.26, which all sat behind the source.
`install.xml` and `repo.xml` both say 0.9.27, the zip is rebuilt (26 files, 484,833 bytes)
and `repo.xml <sha>` is recomputed to `61d7082d50c814d021cca923a7de90357060cd72`. Verified
against the zip on disk rather than assumed, and the zip's own `Browse.pm` checked to carry
`STREAM_KEY_VERSION => 22`. `README.html`/`index.html` regenerated so the version badge
(read live from `install.xml`) is not left lying; `README.md` and `CHANGELOG.md` are
deliberately untouched — those are written at the merge to main.

**CONFIRMED IN THE FIELD** (2026-08-28, installed on plex): the Interpol review resolves to
the 12-track album, the 2-track single is offered beneath it, and the Refresh row is
reachable from the matched row. So this is a verified fix, not an inferred one — which
matters because the whole defect was silent (the row played, it just played the wrong
record) and nothing in a log would have reported it either way.

### Tests

**851 → 924 across TWELVE suites, 0 failures** (was 851/11). New `tools/t_releaserank.pl`
(50), `t_perf` 398 → 405, `t_reviewintro` 20 → 36.

**Both directions are pinned, because the two properties pull against each other** and a
future simplification will otherwise pick one: the album must beat the like-named single,
AND the EP must beat the same-artist bracketed singles.

**THE WIRING IS ASSERTED SEPARATELY FROM THE HELPER, and that gap was found by the
anti-test rather than by review.** With `_releaseAlts` tested only directly, deleting the
one line that calls it from `_resolveSection` left the whole suite green — the same shape
this file has recorded twice before (0.9.17's alt rows, 0.9.10's shelf width). `t_perf`
section 23 now drives `_resolveSection` and reads `$it->{_alt}`.

**One test premise was deliberately superseded**, not quietly rewritten: `t_reviewintro`'s
"no capsule and no link -> url NOT wrapped" asserted the early return that the
unconditional Refresh row replaces. It now asserts the property that still matters — the
tracklist is untouched and nothing injected is audio.

**Anti-tested TEN ways, every one caught:** the promotion removed fails 6, the retry back
to empty-only fails 4, leg 2 replacing leg 1 fails 3, the no-evidence rule dropped fails
24, the alts not wired in fails 2, the Refresh row removed fails 19, `_releaseKey` degraded
to plain `_norm` fails 6, the edition list emptied fails 8, the two alt labels merged fails
1, and an alt named from the rendered label fails 2.

## Status: 0.9.26
**The two fixes for `docs/code-review-0.9.25.md`, plus the one finding
`docs/code-review-0.9.26.md` raised against the first of them. No feature change.
The review's own suggested patch for that finding is NOT what shipped, and the
difference is recorded below because it is what would be re-proposed.**

### 1. The `year:<Y>` Refresh row's probes stop force-fetching years they already hold

`getLatestYear` forwards its whole `%opts` to every probe, so `force => 1` meant each
candidate was a forced `getYearList` — a real ~1.7MB download of a published, immutable
list, re-parsed and re-stored, purely to answer "is there a newer one?". New **`resweep`**:
skip the negative markers, honour the permanent store. The Refresh row's two jobs are also
**re-ordered** — re-pull `$y` first, probe second — so the probe finds `$y` freshly stored
and cannot duplicate it.

**0.9.24's `$probed` shortcut is GONE and reinstating it is now a defect.** It inferred "the
probe already re-pulled `$y`" from the probe ANSWERING with `$y`, which was true only while
the probe forced; against a probe that answers from the store it reads true on a plain DB
hit, and Refresh on the newest year silently becomes a no-op.

### 2. `_parseYear`'s non-`h2` skip clears the pending cover/rank

Verified empirically rather than by inspection: all ten live years 2016–2025 re-parsed
through the pre-fix and post-fix sub are **byte-identical** (481,766 bytes each), so the
documented trade is not being paid on any current page.

### 3. `resweep` HAD TO BE SOLO IN `_shareFetch` TOO — the review's finding

`force` was carrying a **second** meaning that went with it when fix 1 deleted it.
`_shareFetch` tests `force` to decide whether a fetch may be answered from the stale copy
and whether it joins the coalescing queue; a probe carrying only `resweep` failed both, so
it could be **adopted by an in-flight ordinary fetch**. Against one of the `%PENDING`
strands this file has found and closed four times (0.8.9, 0.9.0, 0.9.23, 0.9.25) nothing
would ever answer it — the tap never completes and Material sits on its three-dot
placeholder. **The manual retry button is the one surface that must keep working when the
automatic paths have wedged, which is why it forced in the first place.**

`resweep` now behaves exactly as `force` does in that sub, making it a strict weaker-force:
it differs from `force` only in honouring the permanent store, which is the whole point of
it.

**THE REVIEW'S OWN PATCH IS INCOMPLETE AND WOULD HAVE SHIPPED A HARDER BREAK THAN THE
DEFECT.** It sketches `$solo` across the two tests and says nothing about `$done`, which is
still `$opts->{force} ? $cb : <fan-out>`. Applied as written, a `resweep` probe claims no
slot but still runs the fan-out: `delete $PENDING{$key}` finds nothing, the loop calls
nobody, and **the probe is never answered on every tap** rather than only against a strand —
and where another caller does own that key, it deletes their slot and fires THEIR waiters
with the probe's items, which is 0.9.23's orphaned-owner defect manufactured by the fix for
the strand. **All three sites or none.**

The stale-serve is given up with the rest, though the review argued for keeping it. Keeping
it while `$done` is the raw `$cb` **double-answers** the caller (stale, then fresh), and
`force` is safe from that only because it skips the stale path. It costs nothing reachable:
the only shape that reaches `_shareFetch` with a stale year is the CURRENT year past
`YEAR_TTL`, and on the path that sets `resweep` the forced re-pull of `$y` has already
stored it.

### Scope

**NO CACHE BUMP.** All three are control flow or render-time; `STREAM_KEY_VERSION` stays at
21 and `PARSE_VERSION` at 3. Fix 3 changes only which callers share a process-memory
`%PENDING` slot. **No matcher change**, so `matcher_sync_check.py` is unaffected and still
reports the same pre-existing DSC drift.

**`resweep` reaches exactly one caller** — `getLatestYear` is called from `_viewYear` and
`yearsAvailable` (no opts) and `_refreshRow` (`force => 1`), so no other call site can
produce a `resweep` probe. The feed path (`_fetchState`) can never carry it at all, which is
what bounds fix 3 to the year path.

### Tests

**851 across the eleven suites, 0 failures** (was 839). `t_perf` gains section 22 (12) beside
21's already-added coverage.

**BOTH DIRECTIONS ARE PINNED, because the two properties pull against each other** and a
future "simplification" will otherwise pick one: a `resweep` probe must not be left
unanswered by someone else's slot, and an ordinary probe must still coalesce.

**The assertion that catches a HALF-APPLIED fix is "exactly one callback"** — it fails on 0
(never answered) and on 2 (stale + fresh) alike, which is precisely the pair the review's
patch produces.

**Anti-tested five ways, every one caught:** the whole fix reverted fails 3, **the review's
patch as written fails 8** (and its output is the defect verbatim — `calls back exactly once
-> '0'`, and the waiters on the unclaimed slot fired), the queue exemption alone fails 2, the
stale exemption alone fails 10, and `resweep` made solo past the STORE as well — the
over-fix, which would undo fix 1 — fails 7.

**A FIXTURE WAS VACUOUS AND THE ASSERTION CAUGHT IT.** `dbStale`'s age is sized for
`FEED_TTL` (3h); a YEAR is stale only past `YEAR_TTL` (30d), so the first version of the
callback-count test answered from the store and never reached `_shareFetch` — it would have
passed against any implementation. The age is now set from the real constant.

### Packaging

**Still at 0.9.24** (`install.xml`/`repo.xml`/the zip) while the source says 0.9.26 —
deliberately out of scope for both reviews, and it needs a version bump + a recomputed
`repo.xml` sha before this ships.

## Status: 0.9.25 (superseded by 0.9.26)
**Hardening from a code review of the 0.7.11 → 0.9.24 working-tree diff
(`docs/code-review-0.9.24.md`). Four findings, all confirmed against the real subs. All
four are ONE pattern — a failure on a shared publish/store path costs OTHER callers their
answer — which is the pattern `_cacheStream` and `_markFeedMiss` were already eval-guarded
for. Two of the four fixes differ from the ones the review proposed, and both differences
are recorded below because they are what would be re-proposed. No feature change.**

### 1. A store that FAILS is not a fetch that succeeded

`putList` logs and returns 0 on a failed write — it does **not** die, so nothing an eval
around it can catch. Both fetch paths discarded that return value and ran
`kvDel($missKey)` unconditionally, so a fetch that **parsed fine but failed to store** read
as a good fetch: no rows landed, `stored_at` never advanced, and the miss marker was
actively cleared. The next open then found no stored rows and no marker, re-downloaded the
listing, failed to store again, and repeated — on every view open and every warm tick,
indefinitely. **That is exactly the unbounded refetch `FEED_MISS_TTL` was added in 0.9.24
to bound, surviving in the one branch that bypassed it.**

Both sites now gate the `kvDel` on the write actually landing and mark a miss when it did
not. The caller is still handed the live parse either way — the parse succeeded, only the
store did not, and losing the store must not also cost the view its answer.

### 2. The feed miss marker gets a SHORT tier when there is nothing to serve

**THE REVIEW'S FIX — gate the READ on `$stored && @$stored` — HANDS THE DEFECT BACK, and
that is the first of the two corrections.** With nothing stored, a feed whose 200 response
parses to nothing (a Pitchfork layout change: a real ~1-2MB download every time) would
re-download on every open with no marker able to stop it, which is 0.9.24 finding 3 again on
a fresh install. The read stays unconditional — the 0.9.24 anti-test pinning that is
untouched and still passes.

What was genuinely wrong is the TTL. On a fresh install (or a new section) one transient
failure set a **1h** marker and the section then answered `[]` for the full hour with no
retry: the warm passes `nostale`, not `force`, so it hits the same gate. Pre-0.9.24 the next
open simply retried. So `FEED_MISS_EMPTY_TTL` (60s) applies when there are no stored rows to
serve. **The storm is still bounded and the install recovers by itself within a minute**,
which is the property that was lost. Both tiers are asserted, in both directions.

### 3. The resolver's waiter fan-out ran after `$callback`, unguarded

`$callback` chains into the full feed render — a lot of code, any of which can die — and the
fan-out ran *after* it with a bare `$_->(...) for @waiters`. One throw stranded **every**
coalesced waiter, and the `%RESOLVING` slot was already deleted by then, so the
`RESOLVE_JOIN_MAX` adoption path could not rescue them: there is no wedged slot left to adopt.

**Each stranded waiter that came from a `view` is a `$FG_INFLIGHT` that never decrements** —
only `_resolveSection`'s resolver callback does that — and `$FG_INFLIGHT` is tested for
TRUTH, not compared against a width, so ONE leak pins the warm at `WARM_CONCURRENCY` and
every home shelf at the narrow width for the life of the process. **That is 0.9.23's
finding-1 leak, reintroduced from the publish side.**

New `_serveWaiters`: the waiters are served **before** `$callback`, one `eval` each. Applied
to the cache-hit path (the adopted waiters) as well as the resolve path — a wedged slot is by
definition `RESOLVE_JOIN_MAX` old, ample time for another resolve of the same album to have
stored the answer, so that early return is a likely exit rather than a corner.

### 4. `_shareFetch`'s `$done` fanned out the same way

Same shape, lower blast radius (feed callbacks, not the full render) and the same
permanence: the `%PENDING` slot is deleted before the loop runs, so a caller skipped there is
never answered by anything — Material's three-dot placeholder, for good. One `eval` per
waiter, as `_issueFetch` already does for the issuing path.

### Also fixed while in the same code

`getYearList`'s own miss write was **not** eval-guarded, although it sits above the `$cb`
that releases the year key's `%PENDING` slot — the exact shape `_markFeedMiss`' header
argues about. Both year writes now go through `_markYearMiss`, which carries the same guard
for the same reason. No empty-store tier there: a year that has never been fetched has no
rows to be starved of, and `YEAR_MISS_TTL` is sized against the 12h/30d promotion cadence,
which is unaffected either way.

### Scope

**NO CACHE BUMP, and it is checked rather than assumed.** Findings 3 and 4 are control flow
only. Finding 1 changes when a kv MARKER is written, not what any list stores — and it can
only fire where nothing was stored in the first place. Finding 2 changes one TTL on that
same marker. `STREAM_KEY_VERSION` stays at 21 and `PARSE_VERSION` at 3; nothing stored
changes shape or meaning, and the new `pfr:feedmiss:*` behaviour is observable against a
warm store.

**No matcher change** — nothing in this pass touches the shared engine, so
`matcher_sync_check.py` is unaffected and still reports the same pre-existing DSC
`_norm`/`%FOLD`/`_albumMatches` drift.

### Tests

**819 across the eleven suites, 0 failures** (was 784). All the growth is `t_perf`
337 → 372: section 16 gains the empty-store tier, plus new sections 19 (a failed store) and
20 (the two fan-outs).

**The failed store is driven through the real `getListing`/`getYearList`**, with a `PUT_FAILS`
knob on the DB stub that reproduces putList's actual contract — logs, writes nothing,
returns 0, **does not die**. That distinction is the whole finding: a die is caught by the
evals already around those sites, a false return is not, so the failure reads as a success
unless the caller checks it. A test of `putList` itself could never see it.

**Finding 3 is pinned at BOTH levels**, the same way 0.9.23's was: unit tests prove the
waiters are called, and a run driven through `_resolveSection` proves what calling them is
FOR, by asserting `_fgInflight()` returns to 0 after the owner throws.

**Anti-tested SEVEN ways, every one caught:** the feed store's return value discarded fails 4,
the year store's fails 3, the two TTL tiers collapsed into one fails 1, **the review's own
`$stored && @$stored` gate fails 3** (pinned so it cannot be "simplified" in), the resolve
fan-out put back after `$callback` fails 3, the cache-hit fan-out fails 1, and the `%PENDING`
fan-out unguarded fails 1.

## Status: 0.9.24 (superseded by 0.9.25)
**Hardening from a code review of the 0.7.11 → 0.9.23 working-tree diff
(`docs/code-review-0.9.23.md`). All four findings confirmed against the real subs, plus a
fifth found while validating the third. THREE OF THE REVIEW'S OWN FIXES WERE WRONG and are
recorded below as such — they are the parts most likely to be re-proposed. No feature change.**

### 1. `tidalImageProxy` squared a NON-SQUARE image, so the URL it wrote 404'd

The handler captured the width out of a two-dimension path segment and substituted a
**square**: a Tidal `480x320.jpg` meeting a 150 spec became `320x320.jpg`, a rendition Tidal
does not serve — no picture at all. `_onlyDown` cannot see it, because 320 < 480 reads as a
perfectly good shrink. **Album covers are square, which is why it survived** — and since the
handlers are registered by CDN HOST, the rows it broke are the TIDAL plugin's own artist and
playlist views, where the non-square sources live.

**THE REVIEW'S PREFERRED FIX — scale the height proportionally — IS BROKEN FOR THE SAME
REASON IT DIAGNOSED.** Tidal serves a FIXED SET of renditions, so a computed `320x213` is no
more real than `320x320` (the actual rung is 320x214). Only its fallback is safe and that is
what shipped: **a non-square URL is returned verbatim.** Every URL PFR authors is a square
album cover, so this costs us nothing and stops touching what was never ours.

Applied to `deezerImageProxy` too (its CDN takes arbitrary sizes, so there the failure is a
distorted picture rather than a 404 — latent, and one rule across the handlers reads better
than two) and to `_fitCover`'s Tidal/Deezer branches, whose square 640 ceiling had the same
shape. Unreachable there — our rows carry album covers — and now asserted so it stays that way.

### 2. `_splitAlbumTitles` classified padding from the WHOLE title but split EVERY slash

`$padded` is a property of the title; the split pattern accepted any slash. **A title carrying
both spellings got the padded treatment applied to unpadded fragments.**
`AC/DC / Live at Donington` contains ` / `, so it was classified padded, then split on the
unpadded slash as well → three sides (`AC`, `DC`, `Live at Donington`), inside
`TITLE_SPLIT_MAX`, so accepted. A padded split trusts a **loose** side (0.9.21), and
`_albumMatches` admits `AC` to a service title of "AC/DC Live" through
`index($t, "ac ") == 0` — **the row plays a record the review is not about, with no error
anywhere.** The artist guard cannot reach it: it compares the WHOLE normalised title, and
`ac dc live at donington` is not `ac dc`.

**Padding is a property of the SEPARATOR, not of the title.** Split only on the spelling that
was detected, so a padded title keeps its unpadded slashes intact (`AC/DC` survives as one
side, judged whole) and the exactness gate still governs genuinely unpadded titles exactly as
0.9.21 designed. All 19 existing split assertions pass unmodified — checked before the change,
because a fix to a split rule that quietly moves an unrelated case is the same defect again.

### 3. The feed path had no negative marker, so a failing feed re-downloaded for ever

A feed's freshness comes from `stored_at`, which moves only when `putList` runs — a parse of
≥1 item. Every other outcome (0 items, a parse/store throw, an HTTP failure) answers from the
stored rows and writes **nothing**, so the moment a feed starts failing its age is past
`FEED_TTL` permanently: every view open and every 3h warm tick re-issues the full ~1-2MB
listing download, indefinitely, invisible in the log after the first warning. Coalescing bounds
the CONCURRENT count, not the rate. The year path has had `YEAR_MISS_TTL` since 0.8.9; the feed
path never got the equivalent.

New `FEED_MISS_TTL` (1h, matching the existing pair) written under a SEPARATE kv key on all
three failure paths, cleared by a good fetch, skipped by `force` so Refresh is always an
immediate live retry.

**"MIRROR THE YEAR PATH EXACTLY" WOULD HAVE SHIPPED IT INERT, which is the review's second
wrong fix.** The year path's read carries `&& !$stored` — and any server that has ever fetched
successfully HAS stored rows, which is precisely the failing case. The feed gate is therefore
`!$opts{force} && kvGet($missKey)` with no `$stored` condition, and the anti-test that pins it
is the year path's own version (fails 5).

**The marker write is eval-guarded**, and not out of habit: two of its three call sites sit
ABOVE `$done`, the only thing that releases the key's `%PENDING` slot, so a die there would
manufacture exactly the strand 0.9.23 finding 1 traced. A marker we fail to write costs one
extra fetch; a die costs the key for the life of the process.

### 4. The `year:<Y>` Refresh downloaded the same article TWICE per tap

`getLatestYear` under `force` walks candidates from `_topYear` down and **each probe IS a
forced `getYearList` fetch**, stopping at the first that answers. So when `$y` is the newest
published year — the year the view opens on — the probe re-downloaded `$y` (~1.7MB) on the way
to answering "has the new list landed?", and the callback force-fetched it again. (The review's
"four large requests" overstates it: the Nov–Dec extra probes are 404s with no payload.)

**THE REVIEW'S "SIMPLEST VERSION" BREAKS REFRESH ON A CLOSED YEAR, and that is its third wrong
fix.** Dropping `force` from the callback unconditionally is wrong because a stored year has no
TTL at all and the probe stops short of any older year — so `getYearList(2019)` without force
just re-reads the permanent store and the button becomes a no-op (pinned since 0.9.11). The
condition is knowable: the probe fetched `$y` **iff `$y` is the answer it came back with**.

### 5. The YEAR path's own miss marker was never consulted where it mattered

Found while validating finding 3, not in the review. `getYearList` WROTE `pfr:yearmiss` on a
failed sweep (0.8.9) but read it only `unless $stored` — and a closed year returns from the
permanent store long before that read. So the only caller that reached it with a stored list
was the **current year gone stale**, which is exactly the case whose sweep costs two ~1.7MB
article fetches and exactly the case the marker was added for. The marker was inert wherever it
mattered. `$stored` condition dropped; the list is still served, only the sweep is suppressed —
which is what `YEAR_MISS_TTL`'s own comment already claimed it did.

### Scope

**NO CACHE BUMP, and finding 2 does NOT need one — the review says it does.** The corrected
split produces DIFFERENT side keys (`AC/DC`, not `AC`), so a wrongly cached fragment answer is
**orphaned rather than served**, and the new sides resolve cold on the next open. The
full-title leg is unchanged. Findings 1 and 4 are proxy-time / control-flow only; findings 3
and 5 add or fix a kv key and change nothing stored. `STREAM_KEY_VERSION` stays at 21.

Verification caveat for finding 1: LMS's own image proxy caches on original URL + spec for 30
days, so a rendition already fetched (or already 404'd) may need the server's image cache
cleared before the change shows on a row already viewed.

**No matcher change** — `_splitAlbumTitles` is PFR call-site logic, outside the shared engine
(recorded at 0.9.17), so `matcher_sync_check.py` is unaffected and still reports the same
pre-existing DSC `_norm`/`%FOLD`/`_albumMatches` drift.

### Tests

**784 across the eleven suites, 0 failures** (was 741). `t_perf` 295 → 337 with three new
sections (16: a failing feed is fetched once; 17: the year marker is consulted; 18: the year
Refresh row), `t_hardening` 72 → 73.

**Finding 4 is driven through `_refreshRow`'s own coderef**, not through the two API subs —
the defect is in how the row composes them, so a test of either one could never see it. Both
directions are asserted, because the fix that satisfies the newest year breaks the closed one.

**ONE TEST PREMISE WAS SUPERSEDED, deliberately.** `t_hardening`'s coalescing-release block
asserted that the very next caller after a throwing store re-fetches. It does not any more —
that throw now writes a miss marker, which is finding 3 working. The property the section is
actually about is unchanged and still pinned, by a stronger test: a STRANDED key is permanent
and nothing can clear it, whereas the marker lapses, so the release is proved by lapsing it.

**Anti-tested EIGHT ways, every one caught:** the Tidal square guard removed fails 2 (and its
output is the defect verbatim — `320x320` for a 480x320 source), the Deezer/`_fitCover` guards
fail 2, the permissive split fails 4 (output `AC|DC|Live at Donington`), the three feed-marker
writes removed fails 8, the marker read removed fails 5, **the feed gate carrying the year
path's `!$stored` fails 5** (the correction, pinned so it cannot be "simplified" back), the
year gate restored to `!$stored` fails 1, always-forcing the year Refresh fails 1, and **never
forcing it — the review's own suggestion — fails 2.**

## Status: 0.9.23 (superseded by 0.9.24)
**Hardening from a code review of the 0.7.11 → 0.9.22 working-tree diff
(`docs/code-review-0.9.22.md`). Four findings, all confirmed against the real subs, two of
them defects the 0.9.12 coalescing work introduced. No feature change.**

### 1. The wedged-slot recovery dropped its waiters and let the old owner publish

`_findPlayable`'s in-flight coalescing replaces a slot older than `RESOLVE_JOIN_MAX`, and
`delete $RESOLVING{$key}` **discarded the slot's `waiters` array with it**. In
`_resolveSection` that callback is the ONLY thing that decrements `$active`/`$done`/
`$FG_INFLIGHT`, so a dropped one strands all three.

**`$FG_INFLIGHT` is tested for TRUTH (`_resolveSection`'s `$widthNow` and its yield), never
compared against a width — so ONE stranded count is enough.** The review said "once that has
happened `WARM_CONCURRENCY` times"; it needs to happen once. And the warm is not *dead*
afterwards, because `WARM_YIELD_MAX` bounds the yield — it cycles: yield 120s, burst two
items, yield again. The worse half is that shelves are pinned at the narrow width **for the
life of the process**, which is precisely the 34/50 → 9/50 carousel regression 0.9.12 was cut
to fix, arrived at from the other side.

Second defect in the same branch: the orphaned owner is **not cancelled, only detached**. Its
release deleted whatever sat at the key by then — the *replacement's* slot — and fired ITS
waiters with the abandoned search's answer, leaving the replacement's own completion to find
nothing.

**Fixes.** The wedge branch ADOPTS the dead slot's waiters; the claim is stamped with a
monotonic `token` and the release only deletes and publishes when the slot still carries it.

**THE ADOPTED WAITERS MUST ALSO BE SERVED ON THE CACHE-HIT RETURN, which the review's fix
missed** — the stored-answer check sits BETWEEN the wedge-delete and the claim, and a wedged
slot is by definition `RESOLVE_JOIN_MAX` old, ample time for another resolve of the same
album to have stored the answer. That early return is a likely exit, not a corner, and
returning through it without them re-drops exactly what adopting them rescued.

**The release also MOVED ABOVE the cache write** (and `_cacheStream` is now eval-guarded),
because everything between the two can die: `DB::kvSet` dies on a character string where it
wants octets, and `_matchExactness` runs eagerly to build the log line. A die below an
unreleased claim left `$resolved` latched at 1 — every later `$finish` returning early — AND
the slot held for ever: **the exact strand `RESOLVE_JOIN_MAX` exists to survive, manufactured
by the release itself, and the most plausible source of the wedges the whole mechanism is
built around.** Not in the review; found while verifying it.

### 2. Combined-review alt albums were injected into a playable container

`_attachReviewLink`'s header states the invariant that every injected item is non-audio, and
that is what makes Play/Add on a review row act on the album the row represents. The 0.9.17
alts are copied in verbatim, and a Deezer album node carries `play => deezer://album:<id>` —
a direct playable URL — so a Play on side A could queue side B's album alongside it.

`delete @a{ qw(play playlist on_select) }` on the copy. `playlist` is beyond the review's
suggestion; deleting a key a service never sets is a no-op, so the invariant now holds
whichever service matched. **`type` is deliberately left as the service set it** — the row
still DRILLS IN to its own tracklist, which is the only thing that makes the second release
reachable from a browse list at all. The review's alternative (route them through
`reviewDetail`) is a straight 0.9.17 regression and was not taken. Cost: no direct Play on
the alt row; you drill in and play from there.

### 3. The image-proxy handlers rewrote other plugins' artwork UPWARD

The handlers are registered by CDN **host** and `Slim::Web::ImageProxy` matches on the URL,
never on which plugin produced the row — so every Qobuz/Tidal/Deezer cover on the server
passes through them, at sizes PFR never chose. **0.8.8's "a handler may only ever go DOWN"
was enforced only by the ladders' top rungs, which can speak for OUR source and nothing
else.** Reproduced: `80x80` → `320x320` (Tidal), `_50` → `_600` (Qobuz), `56x56` → `320x320`
(Deezer), `w_160` → `w_320` (Pitchfork).

New `_onlyDown($cur, $w)` compares against the width **the URL already carries**. Applied to
all four handlers including `pitchforkImageProxy`, which the review scoped out — same defect,
and the rule reads better as one rule. An unreadable current width (Qobuz's unbounded `_max`)
is always shrinkable; equal is a no-op, which also keeps the proxy's cache warm.

### 4. `_warmTick` re-armed at 20s for ever when the warm could never start

`WARM_PLAYER_RETRY` answers "no player has connected YET" and nothing bounded how long "yet"
could last: on a headless server, or through any persistent throw out of `warmCache`, the
tick fired every 20s for the life of the process — ~4,320 wake-ups a day that cannot succeed,
each also running a `kvSweep` DELETE. Now backs off by doubling, reset on the first success.

**`WARM_RETRY_MAX` is 300s, NOT `WARM_INTERVAL` as the review suggested, and that is the
design.** Capping at `WARM_INTERVAL` re-opens the exact hole `WARM_PLAYER_RETRY` was added to
close — a late-connecting player waiting up to three hours for its first warm is the
three-hour no-player hole with extra steps. At 300s the runaway is gone (288 wake-ups a day
worst case) while a player connecting at ANY point is picked up within five minutes. The
suite asserts it as a RELATIONSHIP to `WARM_INTERVAL`, so a future retune cannot quietly land
back there.

### Scope

**NO CACHE BUMP, and it is checked rather than assumed** — the standing dev rule is satisfied
without one. Every piece of state findings 1 and 4 touch (`%RESOLVING`, `$SLOT_SEQ`,
`$FG_INFLIGHT`, `$_warmFails`) is PROCESS MEMORY, cleared by the restart the install
requires. Finding 2 is applied at render (`cachetime => 0`), so it shows on the next open
with no re-resolve — the cached node deliberately keeps its `play`; only the injected copy is
stripped. Finding 3 runs at proxy-fetch time behind LMS's OWN 30-day thumbnail cache, which
a `pfr:` bump cannot reach anyway. Nothing stored changes shape or meaning.

**No matcher change** — `matcher_sync_check.py` reports the same pre-existing DSC drift in
`_norm`/`%FOLD`/`_albumMatches` recorded at 0.8.8 and 0.9.17, still its own fleet-sync
session.

### Tests

**741 across ELEVEN suites, 0 failures** (was 694/10). `t_perf` 260 → 295, plus a new
`t_warmbackoff.pl` (12).

**The new suite exists because `t_perf` cannot load Plugin.pm** — it says so itself, and it
pre-stubs `Plugin::dbg` for Browse.pm's benefit, so loading the real module there would
collide. Plugin.pm also needs `main::WEBUI` defined at compile time or it will not parse. The
backoff arithmetic is exactly the kind that regresses silently (an off-by-one in the doubling,
a cap that does not cap), so it gets a harness that runs the real sub rather than a test that
reads the constants and infers.

**Finding 1 is pinned at BOTH levels, and the second one is the point.** The unit tests prove
the waiters are called; a test driven through `_resolveSection` proves what calling them is
FOR, by asserting `_fgInflight()` returns to 0. The leak lives in the caller's bookkeeping,
not in the resolver, so no test of `_findPlayable` could ever see it.

**Anti-tested NINE ways, one per change, every one caught:** binning the adopted waiters fails
5, releasing without the identity check fails 2 (and its output is the defect verbatim — the
orphan answers the replacement's waiter, and the slot count drops to 0), dropping the
cache-hit fan-out fails 2, dropping the `eval` on the cache write fails 1, putting the release
back below the cache write fails 2, restoring the alt's play affordances fails 2, the
unconditional handler substitution fails 4, capping the backoff at `WARM_INTERVAL` fails 1,
and dropping the backoff entirely fails 4.

**One test premise was wrong before the code was.** The first version of the die-vector test
asserted that a later caller must re-SEARCH; it does not, and should not — the cache write had
already succeeded, so being served from store is correct. The assertion was rewritten to the
property that actually matters: a later caller is *answered* rather than joining a dead claim,
which works because the join check runs BEFORE the stored-answer check.

## Status: 0.9.22
**Two logging tiers, split by VOLUME rather than importance. The milestones are readable
with nothing switched on; the per-item timeline needs `debug_log`.**

### The problem

A warm emitted ~250 per-item lines for 138 albums — one per service search, per resolve,
per cache hit — and a combined review re-evaluated on **every Material view request**: 14
times in 90 seconds in the field, ~0.2ms each from three cache hits. Trivial to run, not
trivial to read past. The handful of lines that describe the shape of a run were buried
between them.

### The split

| | goes where | volume |
|---|---|---|
| `_dbg` | server.log at INFO **always**, + `pfr-debug.log` when `debug_log` is on | ~16 lines/warm |
| `_dbgv` | **nothing at all** unless `debug_log` is on | ~250 lines/warm |

`_dbg` keeps every milestone: the fetch phase, each resolve stage, `warm: done`, each
backfill year and its completion, a promoted year. That set is how this plugin is diagnosed
from a pasted log, so it must not require a setting.

`_dbgv` takes the per-item timeline: `search …`, `resolve …`, `resolve cache hit: …`,
`combined review …`, `year: picked …`.

**WHAT THIS CHANGES ABOUT THE PREF, and it is a real change.** `debug_log` used to mean
"ALSO write a file" — the verbose timeline went to server.log either way, so the setting
could not quiet anything. It now means "emit the verbose timeline at all", which is what
its label already claimed. The diagnostic recipe is unchanged and still complete: turn it
on and every line appears in both server.log and `pfr-debug.log`. Read live, not cached at
load, so it takes effect on the next line — a diagnostic switch is reached for *while*
something is going wrong.

**NOT a performance change, and not sold as one.** Our own work is ~8.6ms per album against
~2500ms upstream, so string building was never the cost. The one site where avoiding the
work is worth it anyway is `_dbgSearch`, which returns before its `sprintf` because it runs
hundreds of times per warm.

### No cache bump, deliberately

The standing dev rule is that every build invalidates caches so the change can be observed.
It is satisfied here without one: nothing cached changes meaning, and the change is visible
against a **warm** store — `resolve cache hit:` was itself one of the noisiest lines. A cold
run would show it too, so bumping would cost a full re-resolve to learn nothing extra.
Stated rather than skipped.

### Tests

**260 in `t_perf.pl`, 694 across the suite, 0 failures.** Driven through `warmCache` and
`_searchQobuz`, because the defect this invites is a call SITE left on the wrong tier — a
test of the two helpers could never see that.

**EVERY MILESTONE IS ASSERTED INDIVIDUALLY, not counted.** The first version of the test
asserted `milestones > 0` and **passed with a milestone demoted to the verbose tier** — the
other `warm:` lines carried it. Anti-tested, four reverts, all caught: `_dbgv` ungated (1),
one resolve-stage milestone demoted (2), the backfill milestone demoted (2), `_verbose`
hardcoded on (3).

**One honest gap, noted in the test itself:** the early `return unless _verbose()` inside
`_dbgSearch` avoids building the string as well as emitting it, and that is not observable
through output — removing it still passes. Recorded so it doesn't read as coverage it isn't.

## Status: 0.9.20 → 0.9.21
**An unpadded combined-review side is now trusted on an EXACT title instead of requiring
every side. 0.9.20 measured it as a dry run first; 0.9.21 acts on the measurement.**

### Why all-or-nothing was wrong, on the case it was built for

0.9.19 shipped and `EP/EP2` still would not play:

```
combined review 'EP/EP2': 'EP' 0, 'EP2' 1 exact
...not every side matched — discarding an unpadded split rather than trusting a fragment
```

**All-or-nothing asked "did every side match?", which conflates two unrelated situations:**
a bogus split, and a genuine pairing where one record simply is not carried. `EP/EP2` is
the second. *EP2* matched **exactly** on Qobuz; *EP* failed at **search recall, not
matching** — `q=EP` returns **raw=0** on Qobuz and kept=0 of 50 on Tidal and Deezer, so no
matcher change could ever find it. The rule therefore threw away a correct match and left
the review unplayable, which was the entire defect.

Confirmed by a forced **Refresh streaming match** in the field (15:58:32): the button
re-searched all four queries live and the rule still discarded the result. The Refresh row
was never at fault.

### Exactness separates them, and the reason is structural

`_albumMatches` can only admit a fragment through a LOOSER tier —
`index($t, "$albumNorm ") == 0` makes `AC` match "ac dc live" — **never as an equal title,
because an album titled exactly *AC* would be a real album.** A genuine half of a pairing
matches outright.

**`_norm` strips parenthesised content**, so `EP2 (Deluxe Edition)` reads as exact. That is
right — a deluxe edition IS the album — and it means the rule does not quietly reject
remasters. Verified rather than assumed, and pinned by a test so a future `_norm` change
cannot silently break it.

**Any item may carry the exact title, not just the first.** A side whose leading hit is
`EP2 Remixes` must not be discarded when the real *EP2* is behind it; the exact node is
promoted to the front, since the row takes the first.

### 0.9.20: measured before it was trusted

A **dry-run build that changed no behaviour** — every existing behavioural test passed
unmodified, which was the proof of that. It added an exactness tag to the existing resolve
line (so no extra log volume) and a SHADOW line stating what exact-per-side *would* decide
beside what all-or-nothing *did*.

**The probe's own semantics were pinned by tests BEFORE its output was used**, because a
reading taken with an unverified instrument is worse than no reading — it looks like
evidence. `exactness=none` is reported distinctly from `loose`: a service that gave us no
title is not evidence either way, and collapsing the two while the point is to count them
would poison the result.

**Full corpus, all 12 stages, 559 matches:**

```
546 exact     13 loose (2.3%)
```

**Every one of the 13 loose matches is a WHOLE title, not a split side** — six are the
trailing-EP format strip (`boygenius EP`, `Harmony of Difference EP`, `Fresia Magdalena
EP`, …), two are non-ASCII folds (`badモード`, `WHAT WE DREW` with its Hangul suffix), the
rest edition/artist-prefix cases. So restricting exactness to unpadded split sides costs
**nothing observable**.

**All three SHADOW verdicts — the switch changes exactly ONE outcome:**

| review | exact-per-side | all-or-nothing |
|---|---|---|
| `EP/EP2` | keeps `EP2` | **DISCARDS** |
| `songs / instrumentals` | keeps both | keeps both |
| `Song of Sage: Post Panic! / Navy's Reprise` | keeps both | keeps both |

### Padded splits are deliberately NOT tightened

Both rules agreed on both padded reviews, so tightening them would be risk with no gain. A
padded split still accepts one **loose** side out of two, because there the separator is a
stated editorial convention rather than an inference.

### Scope

**Resolve key `:20:`→`:21:`, a correctness bump** — every `EP/EP2`-shaped title has a wrong
cached no-match under `:20:`. `PARSE_VERSION` stays at 3; no article parsing or fetching
changed, so re-downloading them would be cost with no test value.

**Tests: 247 in `t_perf.pl`, 682 across the suite, 0 failures.** Anti-tested, four reverts,
all caught: the exactness gate removed so a fragment is trusted (3), all-or-nothing restored
(4), only the first item checked so no promotion happens (2), and exactness applied to padded
splits as well (17).

**A test premise was wrong before the code was** — the first promotion test used
`EP2 (Deluxe Edition)` as the "loose" leading item, which `_norm` folds to exact. The test
was fixed, not the code, and the bracket behaviour is now asserted in its own right.

### Open

**Log noise.** A combined review re-evaluates on every Material view request — observed 14
times in 90 seconds, each ~0.2ms from three cache hits, so the cost is trivial but the log
lines are not. Wants gating alongside the `_dbgSearch` decision.

## Status: 0.9.19
**Pitchfork is not consistent about the spacing. `EP/EP2` is the same defect as
`songs / instrumentals` and the padded-only rule refused it — so unpadded slashes now
split too, on all-or-nothing terms.**

### Found from the field log, not from reasoning

0.9.17 shipped confirmed working — both known combined reviews resolved both sides, no
false splits, no errors. The same log then showed a **third** case the rule could not see:

```
resolve Qobuz: no hit for artist 'Yaeji' — retrying on album 'EP/EP2'
resolve 'yaeji / ep ep2': no match
```

Yaeji's *EP* and *EP2*, both 2017, one review — written **without spaces**. The
space-padding rule that protects `AC/DC` was also refusing a genuine pairing. Two
spellings, same convention.

### Two confidence levels

| spelling | example | rule |
|---|---|---|
| padded | `songs / instrumentals` | unambiguous separator — accept **any** side that matches |
| unpadded | `EP/EP2` | indistinguishable from `AC/DC` — accept only if **every** side matches |

**Corroboration replaces the padding as the safety margin.** On the shapes it must not
break, the second side is what kills the split: `AC/DC Live` → `'AC'` + `'DC Live'`, and
an album genuinely called *AC* does come back, but *DC Live* does not — so the split is
discarded and the title behaves exactly as before. Same for `24/7 Nightmare` →
`'24'` + `'7 Nightmare'`.

**The one-sided result is discarded rather than trusted, and that is the whole point:** a
spurious match is *worse* than no match, because it silently plays the wrong record.

### The guards, in order of how much they carry

1. **The full title is still tried first**, so none of this is reachable unless the title
   as written already failed. A split can only ever ADD a match.
2. A title that IS the artist's name is never split — `AC/DC` by AC/DC, `S/T`. Mirrors
   `_findPlayable` skipping its album leg for a self-titled record, and is the one case
   where both fragments would be searched against the band most likely to match them.
3. Each side must survive trimming with ≥2 characters, so a bare `S/T` and a bare `24/7`
   are refused outright.
4. Padded titles may have up to `TITLE_SPLIT_MAX` (3) sides; **unpadded ones exactly
   two** — three unpadded slashes is far likelier a date or a stylisation.

### Scope

**Resolve key `:18:`→`:19:`, and this one IS a correctness bump** — unlike 0.9.17 and
0.9.18, which were both deliberate invalidations for observability. Every `EP/EP2`-shaped
title has a wrong stored answer under `:18:`: a no-match held for `STREAM_NOMATCH_TTL`,
which would keep the newly-matchable reviews unplayable for a day per open.
`PARSE_VERSION` stays at 3 — nothing about the articles or the fetch phase changed, so
re-downloading them would be cost with no test value.

**Tests: 234 in `t_perf.pl` (+15), 668 across the suite, 0 failures.** Anti-tested, four
reverts, all caught: an unpadded split trusting a partial result (2), the all-or-nothing
rule wrongly applied to padded titles as well (2), the artist-name guard removed (1), and
unpadded allowed three sides (1 — which needed a new `aa/bb/cc` case, since the existing
`1/2/3/4` exceeded the padded cap too and could not see the difference).

## Status: 0.9.18
**The warm fetches all four article pages at once instead of one per resolve stage.
Parallel fetch, serial resolve — and the asymmetry is the design, not an oversight.**

### What was serial that did not need to be

The chain was `fetch → resolve → fetch → resolve → …`. Articles come from pitchfork.com,
matches come from Qobuz/Tidal/Deezer — **completely independent upstreams**, so ~6-8s of
the warm was spent fetching with nothing resolving, and vice versa.

Now: the four fetches go out together, then the four stages resolve one at a time exactly
as before. **The resolve half stays serial deliberately** — four sections of streaming
searches at once is the burst 0.8.10 measured at 48 in flight against a
`BUILD_CONCURRENCY` of 10.

**IT ALSO FRONT-LOADS WHAT A USER SEES FIRST.** Parsed rows — artist, album, capsule,
score, date, cover — are in the DB within a couple of seconds, for **all four sections
rather than the first one only**. Opening a section during the resolve phase now gets a
complete list of rows with matches filling in, instead of an empty view waiting on its
own fetch. That is the view contract, reached from a different direction.

### Why the fetches are NOT simply overlapped with the resolves

The obvious version of this change is wrong, and the measurement that kills it is already
in this file. Fetches share our event loop with Qobuz's `_precacheAlbum`, which runs over
every returned row before our callback sees any of it:

```
article fetch, quiet                    1.5 - 2.4 s
article fetch, while resolves running     23.4 s
```

So overlapping stage N+1's fetch with stage N's resolve turns a 13s stage + 2s fetch into
**max(13s, 23s)** — slower, from the change that looks like it must be faster.
Front-loading keeps every fetch in quiet time, which is the only time they are cheap.

### The flaw the first draft had, and how it was found

**The first version gated the resolve phase on all four fetches. That was wrong, and the
yield test found it rather than any reasoning here.** The year is not a single GET:
`_viewYear` probes for the newest published list (several candidate slugs on a cold
server) and only then asks for the list itself. Gating on it made the three sections a
user opens first wait behind the slowest, least urgent one — **and it is the LAST stage,
so waiting for it up front buys nothing at all.**

So the year is **issued first** (its head start is free — it runs while the feeds are
still being fetched, before any search goes out) and **collected last**, by `$yearStep`.
Only the three feeds gate the phase. If the year is still in flight when the feeds
finish, `$yearStep` rechecks every `WARM_YEAR_RECHECK` rather than dropping the list most
likely to be opened next.

**Fetch order and stage order are no longer the same thing**, so the tests assert them
separately — the old `gets() == 1` proof that "no later stage has begun" no longer means
anything, because a stage no longer owns a fetch.

### Failure handling, which the phase split changes

**A list that does not load costs ONE STAGE, not the warm.** Previously a stage's fetch
and its resolve were the same link, so a dead page took everything after it down with it.
A missing list is now an absent stage. Same for no year at all: it used to
`return _dbg("warm: done (no year-end list found)")` from the innermost callback, which
abandoned the backfill *and* reported a completed warm — survivable only because the three
feeds had already resolved above it. Nothing has resolved at that point now.

`WARM_FETCH_DEADLINE = 45` covers both waits with one timer, **deliberately not killed on
success** (no bookkeeping, and firing into a finished warm is a no-op) and it is what
bounds `$yearStep`'s recheck loop. **Not 60** — that is `YEAR_BACKFILL_DELAY`, and two
unrelated waits on the same number is how a test fires the wrong timer and a log stops
being readable back.

### Scope

**Caches: `PARSE_VERSION` 2→3 AND resolve key `:17:`→`:18:`, which is the pairing 0.9.17
deliberately did not make.** What changed here is the fetch phase, so the article store
must be cold or the warm opens with four DB hits and the change is unobservable. A cold
article store with a warm resolve store is also a shape no real install is ever in, which
would make the timings unreadable. The test is "is the thing that changed exercised", not
"bump on every release".

**Tests: 219 in `t_perf.pl` (+14), 653 across the suite, 0 failures.** Anti-tested, five
reverts, all caught: the year gating the feeds again (1 — and this needed a NEW test, the
existing suite could not see it because the synchronous fixture always answers the year
first), a missing list aborting the chain (3), a late year dropped instead of rechecked
(1), the watchdog armed but never firing (2), the phase starting on the first feed instead
of all three (6).

**A FIXTURE LEAK COST A DEBUGGING SESSION, and it is worth knowing about.** The watchdog
test abandons a fetch on purpose — which strands that key in API.pm's process-wide
coalescing map (the risk its own comments call out), so every later block's `getHsa` was
silently adopted by a dead fetch and never called back. The held request is now answered
as cleanup. Same class as the `%RESOLVING` slots `reset_all()` already clears.

## Status: 0.9.17
**A review can cover TWO releases. `songs / instrumentals` now resolves to both — the
first is the playable row, the second rides into the drill-in.**

### The defect

Pitchfork gives two records issued as a pair **one review**, titled `A / B`. Adrianne
Lenker's `songs / instrumentals` is the canonical case: two separate 2020 albums, one
article. No service carries an album under the joint name, so every leg of every service
misses and the row can never become playable. From the field log:

```
search Qobuz/albums raw=200 kept=0 q=Adrianne Lenker
resolve Qobuz:  no hit for artist 'Adrianne Lenker' — retrying on album 'songs / instrumentals'
resolve Tidal:  ... same          resolve Deezer: ... same
resolve 'adrianne lenker / songs instrumentals': no match
```

Qobuz returned **200** of her albums and `songs` was near-certainly among them. The
matcher was never wrong; the title we asked for does not exist.

**It is silent.** The row looks perfectly resolvable and simply never plays — which is why
it survived every previous pass. Her other two entries (`Bright Future`, `abysskiss`)
matched on Qobuz throughout, so the artist never looked broken.

**Scale: two titles across every list observed** (`songs / instrumentals`,
`Song of Sage: Post Panic! / Navy's Reprise`). Small, bounded, and a guaranteed miss every
time it recurs.

### The fix

`_splitAlbumTitles` + `_findPlayableReview`, wrapping the unchanged `_findPlayable`.

**THE FULL TITLE IS ALWAYS TRIED FIRST, and that ordering is the correctness guarantee.**
Some real albums do carry a space-padded slash; for those the whole point is to match the
title as written. Only once that has returned nothing do we entertain the theory that this
is two records. **An album that resolves today resolves identically after this change** —
the split is reachable only down a path that already ended in "no match", so the extra
cost falls solely on titles that were failing anyway. Asserted by search COUNT, not just by
the answer.

**The separator must be space-padded.** That is the entire safety margin: `AC/DC`, `24/7`,
`S/T` and every date-shaped title keep their slash. Two independent checks enforce it (the
guard regex and the split pattern) — reverting either one alone still passes the suite,
which is the intent, not a redundancy to tidy away.

**Each side resolves under its OWN stream key**, so caching, in-flight coalescing and
Refresh all apply to it unchanged. No second cache layer, nothing new to invalidate.
Steady-state cost of a combined review is three `kvGet`s.

**Sides are INTERLEAVED, not appended.** Side A can legitimately return a dozen editions;
appending B behind them pushes it past `STREAM_MAX_RESULTS` and **silently deletes the very
album the change exists to surface**. Round-robin puts each side's best match before the
cap can bite.

### How two albums live on one row

The list row stays **one row, playable, being the review's FIRST release**. The others ride
in `$it->{_alt}` into the drill-in, above the tracks, labelled *"Also covered by this
review"* and playable in their own right.

**That drill-in is the only route to the second album from a browse list.** A matched row
drills into the matched album's TRACKLIST, not the detail page — `reviewDetail`, which does
show every side, is reachable only from rows that did NOT match.

**Splitting the review into two sibling rows was the alternative and is wrong twice over:**
it would double a ranked year-end list's entries against Pitchfork's own numbering, and
Material keys non-playable rows by parent id + title, so paired rows built from one review
are exactly the collision that already loses a row elsewhere in this file.

**One node per SIDE, never per match.** An ordinary album's extra editions are alternatives
to the *same* record — they must never become "also covered by this review". Asserted with
a two-edition ordinary album that must come back with no `_alt`.

### Scope

**PFR call-site logic, NOT a matcher change.** `A / B` is a Pitchfork editorial convention
and means nothing in the LBF/DSC/LL siblings, so `_albumMatches` and the shared engine are
untouched and `matcher_sync_check` is unaffected. (It reports pre-existing `_norm`/`%FOLD`
drift — the deferred fleet-wide `!`-fold item, not this.)

**Resolve key `:16:`→`:17:`, and this is the case where skipping was tempting.** Nothing
under `:16:` is wrong — the sides were never cached, and the joint title's miss is held for
only `STREAM_NOMATCH_TTL` — so the fix is visible against a warm store anyway. Bumped
regardless, because *visible* is not *tested*: without it the joint-title leg is served
from cache and the path under test starts from its second step. Article/parse caches are
deliberately NOT bumped; the cold start is not what changed here.

**Tests: 204 in `t_perf.pl` (+37), 638 across the suite, 0 failures.** Driven through
`_resolveSection` and `_reviewRow`, never by setting `_album`/`_alt` by hand — a test that
assembled the row itself would pass with the change reverted. Anti-tested, six reverts,
all caught: pump back to `_findPlayable` (7 fail), no alt rows in the drill-in (3),
unpadded slash accepted (2, and only when BOTH guards go), sides appended not interleaved
(1), full title no longer tried first (2), `_alt` taking every extra match rather than one
per side (1).

**Harness:** `%BY_ALBUM` added beside `%SCRIPT` — service → normalised album → matches. A
positional queue only encodes the order legs happened to run in, which cannot express a
resolve that fans out across several albums.

## Status: 0.9.13 → 0.9.16
**One investigation across four builds: why a resolve takes as long as it does, and why
Discography feels faster doing the same job. 0.9.13-0.9.15 are measurement; 0.9.16 is the
single change that came out of it.**

| | |
|---|---|
| 0.9.13 | resolve key `:12:`→`:13:` — a targeted bump so 0.9.12's shelf/coalescing work was observable at all |
| 0.9.14 | `_dbgSearch`: per-call `ms / raw= / kept=` |
| 0.9.15 | adds `at=` — where in the raw list the first match sat |
| 0.9.16 | **caps the Qobuz search at 50** |

### What was verified along the way

**The 0.9.12 home-shelf fix works.** Cold: `26/50` and `38/50` resolved inside the shelf
deadline, against `9/50` under 0.9.11 — and better than the `34/50` that 0.9.9 managed
before 0.9.11 broke it.

**Cold start, init → `warm: done`: 206s (0.9.9) → 92s (0.9.11) → 39s (0.9.15).**

### Why Discography feels faster — it is not the resolver

Same matcher family, opposite content shape. DSC does artist-search + `getArtist(id)` and
matches a **whole discography (~139 albums) from 2 API calls**; PFR does one album search
**per album**. ~70x the calls per row, and inherent: a discography is one artist, a review
list is thirty different ones.

**Batching by artist would not help here** — measured on a cold run: 273 distinct album
resolves across 246 distinct artists, so artist-level batching avoids **27 searches (10%)**.
Not the answer, and worth not building.

### The measurements

```
our own work per album (decode + _albumMatches + _norm + render)   ~8.6 ms
a real cold Qobuz search       n=185   median 2513ms  mean 2643  max 5383
payload                        308 searches -> 33,585 albums pulled, 316 used = 0.94%
                               40% of searches returned the full 200 rows
concurrency (reconstructed)    10 in flight for 94% of busy time = BUILD_CONCURRENCY
```

**There is no hidden ceiling.** The arithmetic reconciles exactly: 50 albums x 2.51s / 10
= 12.6s against the 13.8-16.0s measured on 0.9.11's backfill. Everything behaves as
predicted; a Qobuz album search simply costs 2.5 seconds and we make one per album.

**A HYPOTHESIS WAS RAISED AND RETRACTED, and the retraction is the point.** 0.9.14's run
produced exactly ONE real round trip (214ms) because Qobuz's own cache served the other
307 at ~3ms. From that single sample came a "14x serialisation gap" and a theory about
LMS's HTTP pool. It was wrong. One observation is not a measurement, and the 0.9.15 cold
run killed it.

**The CPU hypothesis died before any code was written for it.** The plan had been to cap
payloads and memoise `_norm` on the theory that decode/match cost was the limiter. At
8.6ms against 2513ms that is 0.3% of the time. Instrumenting first is what stopped a
release being spent optimising it.

### 0.9.16: the one change

Qobuz was the **only** adapter calling out uncapped — Tidal and Deezer have always passed
`limit => 50`. Verified in the plugin's own source rather than inferred (an earlier read
of a signature table was nearly taken on trust):

```perl
sub search { my ($self, $cb, $search, $type, $args) = @_;
    $args->{limit} ||= QOBUZ_DEFAULT_LIMIT;      # = 200
```

**50 is sized from `at=`, not copied from the sibling plugin.** Deepest first-match across
a full cold run was position **40**, median **1**:

```
cap 10 -> 90.3%    cap 25 -> 97.6%    cap 50 -> 100.0%
```

**The saving is not only bandwidth.** The Qobuz plugin runs `_precacheAlbum` over every
returned item before our callback sees any of it — work on **our** event loop, the same one
that starved article fetches (`reviews` took 23.4s while resolves ran, against 1.5-2.4s
quiet). A quarter of the rows is a quarter of that pre-processing.

### Two traps for whoever measures next

**Bumping OUR key does not produce a cold start.** It produces our cold start on top of the
**Qobuz plugin's own cache**, which we do not control — that is what made 0.9.13's
re-resolve of 175 albums run at 8.6ms each.

**Qobuz's search cache keys on `search_${query}_${type}_` and DOES NOT INCLUDE THE LIMIT**,
held for **300s** (`$cache->set($key, $results, 300)`). So a query repeated inside five
minutes returns the cached 200-row payload whatever we asked for, and reads as "the limit
did nothing". It also means **no cache clearing is needed for a cold run — just wait five
minutes.**

### Open

**The A/B is not yet run.** Baseline to beat: **median 2513ms**, raw median 83, 40% at 200
rows. Whether the cap moves it depends on whether Qobuz's 2.5s is computing the search or
serialising the result — unknown, and deliberately not predicted here.

**Tests: 601, 0 failures.** The cap is asserted at the CALL SITE by capturing what
`_searchQobuz` hands the API — the constant alone proves nothing, the gap this file already
documents for `VIEW_DEADLINE` and which caught two of this session's own tests. Anti-tested:
dropping the args hash fails 2, tightening the cap below the observed depth fails 1.

**`_dbgSearch` is unconditional INFO logging** — one line per search, hundreds per warm.
Fine while diagnosing; wants a keep/gate/remove decision before release.

## Status: 0.9.12
**0.9.12 (2026-08-07): fixes the home-shelf regression 0.9.11 introduced, kills the
duplicate searches the field log exposed, and finally sets the view backstop from a
MEASUREMENT.**

**Field results from the 0.9.11 install (10:53:47 restart), which is what this is built
on.** Everything intended worked: `WARM_DELAY` measured **15.1s** (was 152s);
`PARSE_VERSION` 2 forced a genuine cold start (every list re-fetched); the backfill
deferred correctly (*"warm: done — 9 back-catalogue year(s) queued"*, then 2025 at exactly
+60.0s); no errors. **init → warm done was 92.1s against 206s.**

**THE REGRESSION IT ALSO SHOWED, and it was mine.** Pinning shelves to the warm's narrow
width fixed them starving a browse view and broke the shelves themselves:

```
9/50   9/50   14/50   15/29     <- inside the cold window
34/50                           <- what 0.9.9 managed
```

For ~90 seconds after every restart the Material home carousel was mostly unplayable
cards. That trade was implicit in 0.9.11 item 4 and its size was never stated. **Shelves
are now adaptive like the warm** — full width while no view is resolving (the normal case
on the home page), narrow the moment one starts. They still never yield outright, because
unlike the warm they have a carousel to fill.

**IN-FLIGHT COALESCING.** The same log showed Material re-requesting the year shelf **nine
times in six minutes**, each starting its own resolve over the same 50 albums, with the
same album searched twice inside 40ms. The stored-answer check cannot prevent this — a
concurrent resolve has not written yet — so a second caller for an album already in flight
now waits on the first. `$force` never joins and never claims: the Refresh-match row exists
to escape a stale answer, and attaching it would hand it exactly that.

**The slot carries an age (`RESOLVE_JOIN_MAX` 60s), and that is not clutter.** A claimed
slot never released takes that album down for the life of the process. This file has been
bitten by that shape three times — API.pm's `%PENDING`, the backfill guard removed in
0.9.11, the no-player hole. Every service search is watchdogged so the release "should
always" run, and "should always" is the assumption behind most of what has gone wrong here.
Worst case is now a duplicate search, never a permanently unresolvable album.

**VIEW_DEADLINE 5 → 45, a backstop rather than a budget.** Simon's requirement: never hand
the user an incomplete view. 0.9.1's 5s was the right answer to the *wrong world* — every
open was fully cold every time because the store was discarding everything, so waiting for
complete meant waiting for ever. With it retaining, the first open costs one cold pass and
the rest are lookups.

**45 comes from the server, not from arithmetic.** The 0.9.11 backfill years are 50 cold
items at full width with nothing competing:

```
2025:  76.0s − 60s delay = 16.0s / 50 items
2024:  73.8s − 60s delay = 13.8s / 50 items      => ~2.9s per album at width 10
```

**That is NOT the width-2 rate divided by five.** The warm stages resolve at ~1.0–1.3s per
album at width 2, and assuming linear scaling produced an estimate three times too tight —
which is exactly the extrapolation Simon stopped me making. Concurrency does not scale
linearly here. Measure at the width you intend to run.

**Tests: 596 assertions, 0 failures.** All three changes anti-tested: coalescing removed →
4 failures; the age bound removed → 1; shelves pinned narrow again → 2; the backstop back
to 5s → 3. Two harness lessons repeated from earlier in the session — the shelf test had to
be driven through `homeReviews` rather than `_resolveSection`, and the coalescing store is
process-wide so `reset_all` has to clear it or a fixture whose adapters never answer strands
slots the next block joins for ever.

**Still not built:** the "still populating" indicator. With the view now blocking to
completion it is only reachable when the 45s backstop fires, which should be never — so it
wants deciding on evidence that it can happen at all, not building on spec.

## Status: 0.9.11
**0.9.11 (2026-08-07): `Slim::Utils::Cache` is gone from this plugin. Everything is on
the plugin's own SQLite DB, and the install is a genuine cold start.**

**Two corrections from Simon, both of which I had got wrong.**

**1. Not bumping the cache keys was backwards.** 0.9.10 argued for preserving the store so
that "do entries survive a restart?" stayed observable. That optimises one narrow question
at the cost of the thing the release is about: *you cannot test a cold start against a warm
cache*. This is the same call 0.9.0 and 0.9.1 each got wrong in opposite directions, and
the rule that settles it is now written where it will be read — a cold-start fix that
cannot be observed from cold has not been tested at all. `pfr:stream` → `:12:`,
`pfr:year:latest` → `:4`, `PARSE_VERSION` 1 → 2.

**2. "All the cache moved to the DB" was not true, and I said it was.** 0.9.8 moved the
four LISTS and deliberately left three things behind, which an audit found still sitting in
the store that had just been proved to eat data silently:

| key | what it held | |
|---|---|---|
| `pfr:stream:…` | **the streaming resolve — the whole 588-item, five-minute rebuild** | 30d |
| `pfr:year:latest` | which year is the newest published list | 30d / 12h |
| `pfr:yearmiss:*` | "this year has no list" | 1h |

0.9.8's reason for leaving the resolve behind was that a matcher fix shouldn't cost
re-downloading 17.5MB of articles. That is an argument for keeping the two layers SEPARATE
— which two tables do — and never was an argument for leaving one of them in a fragile
store. All three have moved.

**The new `kv` table, and why the old defect cannot be expressed in it.** `expires_at` is
an absolute epoch computed by us, always, with 0 meaning never. There is no
relative-vs-absolute guessing, so there is no boundary and no TTL that silently means
"already expired" — the defect class that cost 0.9.0–0.9.9 is structurally unavailable.
Values go through `Storable` wrapped in a hash, because **0 and undef are both meaningful**:
`getLatestYear` stores 0 for "a completed sweep that found nothing", which must stay
distinguishable from "never stored".

**CLEANUP — and the accident that was hiding the need for it.** Rotation was already
handled: `putList` deletes a list key and reinserts, so a review that drops off Pitchfork's
page takes its row (and its week divider, which is derived from the rows) with it, and
`list_item` is bounded by construction. What was NOT handled is the resolve rows those
reviews leave behind. They expire after 30 days, but the only two things that removed them
were a `kvGet` that happened to read an expired one and the sweep in `_migrate` — and
`_migrate` runs from `dbh()`, which returns early once the handle is cached, so it fired
**once per server start and never again**. The rows needing collection are precisely the
ones nothing will ever read again, so neither mechanism could reach them: the table grew
with **uptime**. Invisible here because a backup restarts this server every morning, which
swept it daily by accident. Same shape as the TTL bug — correct on the machine it was
written on, wrong everywhere else. `DB::kvSweep` now runs on every warm tick.

**A key-version bump also retires its own rows.** The version used to be inlined in the
key string, so bumping it stranded the whole previous family — unreachable, since no code
would ever build those keys again, but occupying the table for a full `STREAM_FOUND_TTL`.
`STREAM_KEY_PREFIX` + `STREAM_KEY_VERSION` are now separate, and `_retireOldStreamKeys`
drops the old family at startup. `kvForgetPrefix` refuses an empty prefix rather than
treating it as "everything" — a guard worth keeping, and one a test now pins.

**REFRESH VERIFIED ON THE NEW SCHEMA (t_perf section 11).** Every view's Refresh row goes
through `force => 1`, and the move off the cache changed what that has to bypass: a stored
list in `list_item`, and a negative marker that is now a kv row. It works — but it was an
untested claim on this schema, inherited from the cache era, and only the *feed* path had
any coverage at all. Now pinned for a closed year (the only way to re-pull one), a feed,
and the streaming-match row — including that `_findPlayable`'s `$force` skips the stored
row's READ but still WRITES the answer, or the match it just corrected would re-resolve on
every open. The opposite direction is asserted too: a refresh that fetches nothing must
answer from the stored list and leave it in place, never blank the view. Anti-tested —
making `getYearList` ignore `force` fails 3, making `_findPlayable` ignore it fails 2.

**A REVIEW THAT LANDS BEFORE THE RELEASE (t_perf section 12).** Pitchfork routinely
reviews an album days or weeks before it reaches Qobuz/Tidal/Deezer, so a row is
legitimately unplayable on first resolve and the plugin's job is to notice when that
changes, on a warm run, unprompted. It already does — but **nothing asserted it**, and the
whole mechanism is one constant: a confirmed no-match is held under `STREAM_NOMATCH_TTL`
(1 day) so it stops being re-searched every tick; when that lapses the next warm searches
again and picks the album up. Record it under `STREAM_FOUND_TTL` by mistake and the
failure is silent and month-long — the review sits permanently unplayable while the album
is on Qobuz. Now pinned end to end: no-match recorded under the short TTL, suppressed
while it stands, re-searched once it lapses, then re-held under the found TTL. Anti-tested
(swap the constant → 1 failure naming `2592000`).

Cadence, for the record: `WARM_INTERVAL` 3h against a 1-day no-match = 8 warm ticks a day,
one of which does the re-search. Deliberate — the other seven cost a kv read each.

**Tests: 577 assertions, 0 failures** (was 501 at 0.9.9). `t_db` grew 32 → 46 against real
SQLite. The kv layer is anti-tested by reintroducing LMS's own
`$ttl <= 2592000 ? time()+$ttl : $ttl` line into `kvSet` — which fails exactly the 90-day
and 365-day round-trips and nothing else, i.e. the test is pointed at the real mechanism
rather than at a proxy for it.

**Test-harness work this forced, worth knowing about.** Six suites had no DB stub at all
(Browse.pm never touched it before); the `dbFresh`/`dbStale`/`dbGet` helpers hardcoded
parse version 1 and broke the moment `PARSE_VERSION` moved — they now read the real
constant so they cannot drift again. `t_searchlegs` deliberately runs a **no-op** store:
it puts one album through the resolver repeatedly to count search legs, so a real cache
makes every case after the first vacuous. That is preserved explicitly rather than
rediscovered later.

## Status: 0.9.10
**0.9.10 (2026-08-07): the cold start. 0.9.9 fixed the TTL; this fixes what the plugin
does with the time it now has. Nothing here changes what a row resolves to.**

**The measurement first, because every wrong turn in 0.9.0–0.9.8 came from reasoning
without one.** Off the 06:31 restart (a genuine cold start — the daily backup stops and
starts the server, and every pre-0.9.9 entry was dead):

| | |
|---|---|
| server init → warm begins | **152s, nothing happens** |
| three feed lists, 88 items | 54s |
| ten year lists, 500 items | **252s (82% of the warm)** |
| startup → the three main sections populated | **206s** |
| startup → warm complete | 458s |

Simon opened Best New Music at **t=24s** — 128 seconds before the warm started — while
three Material home shelves each resolved 50 year-list albums at full view width against
the same Qobuz. His view got 20 of 29 rows.

**1. `WARM_DELAY` 150 → 15, and "no player" is a retry, not a served tick.** The 150 was
never derived: one comment, *"delayed so it doesn't compete with boot"*. Measured, LMS
finishes init **0.2s** after the timer is armed. Scan protection is separate and already
correct (`stillScanning` + retry). What the delay covered by accident is that `warmCache`
needs a connected player and used to return bare — `_warmTick` could not tell that from
success and re-armed at `WARM_INTERVAL`, so on a machine whose player joins late the warm
silently did not run for **three hours** (a full day before `WARM_INTERVAL` came down).
It now returns whether it started, and the caller retries in seconds.

**2. The back catalogue moves off the main chain (`_backfillYears`).** 0.9.0 was right to
warm all ten years — immutable lists, and a cold first open was a measured 12s. Its cost
argument was not: *"138 albums in ELEVEN MILLISECONDS, because a warm item costs a cache
lookup"* describes the **second** run. On a cold start it is 500 live searches, and it sat
in front of nothing for four minutes. Same coverage, sequenced last, spaced by
`YEAR_BACKFILL_DELAY` and yielding like the rest of the warm.

**3. The warm runs wide while the foreground is idle.** 0.9.1 pinned it at
`WARM_CONCURRENCY` to stop it competing with a browsing user — but the yield already does
that *completely*, by holding the queue rather than slowing it. The narrow width only ever
applied when nobody was browsing, which is exactly when it should go flat out.

**4. Home shelves are a third mode, not "whatever isn't the warm".** The old boolean
`$warm` conflated width, the yield and the foreground count, so shelves got a view's full
width **and** a view's claim on `$FG_INFLIGHT`. `_resolveSection` now takes
`view` / `shelf` / `warm`. A shelf is narrow, never yields (it has a carousel to fill) and
is **not** counted — or opening the Material home page would mute the very warm that makes
shelves instant.

**No "already running" guard on the backfill.** One was written and removed the same hour:
the suite caught that a flag set on entry and cleared on completion is off for the life of
the process if any chain fails to call back — the same shape as the `%PENDING` strand and
the no-player hole above. `WARM_INTERVAL` is 3h and a backfill is ~13 min, so two cannot
realistically overlap; if they did, the second finds everything cached.

**NO CACHE BUMP — deliberate, and against the standing fleet rule.** `pfr:stream` stays at
`:11:` and `PARSE_VERSION` at 1. Nothing cached is wrong (this release changes scheduling,
not match decisions or favurl contents), and bumping would erase every entry 0.9.9 wrote —
which is the only evidence that will answer the one question still open: **do the entries
survive a restart now that the expiry is valid?** The measurement is the deliverable here,
so it is not thrown away to satisfy a rule about observability.

**Tests: 117 in t_perf (501 → 508 across the suite), 0 failures.** Every change was
anti-tested by reverting it: warm width → 2 failures; shelf mode at the call sites →
2; back catalogue back on the chain → 3, with main-chain fetches going **4 → 19**;
`warmCache`'s return contract → 1. The shelf test is deliberately driven through
`homeReviews` rather than `_resolveSection` — the first version called the pump directly
and would have passed with the shelves reverted, the same gap this file already flags for
`VIEW_DEADLINE`.

**Not in this build, by sequencing:** the view blocking until fully populated, and the
"still populating" indicator. Setting the view to block *before* fixing the contention
would turn a partial list into a long wait — 0.9.0's failure exactly. The backstop wants a
number, and the number wants an uncontended measurement that does not exist yet.

**A stale comment cost real time this session.** `_resolveSection`'s header asserted "a
cold resolve of one album measured 2.63s" (0.8.8), which sized a proposed 90s backstop
about double. Replaced with figures read off the server's own warm stages — and with an
explicit note that they are **width-2** numbers and must not be divided by a wider
concurrency to predict anything.

## Status: 0.9.5
**0.9.5 (2026-08-06): ROOT CAUSE FOUND AND FIXED. The year lists were too big for the
cache. LMS silently refuses a value above roughly 40KB — `set` returns success, does
not die, and the entry is never retrievable.**

0.9.4's read-back instrumentation produced the answer on its first boot:

```
CACHE WRITE DID NOT STICK: pfr:year:2025:3  50 items  ~60753 bytes  set returned '1'
CACHE WRITE DID NOT STICK: pfr:year:2024:3  50 items  ~62527 bytes  set returned '1'
CACHE WRITE DID NOT STICK: pfr:year:2023:3  50 items  ~57106 bytes  set returned '1'

feed warnings: 0        year warnings: 6
```

The control did its job: the feed writes go through the same sub with the same item
shape and the same TTL, at 29-30 items and about half the size, and stayed silent. The
only variable that mattered was how much was being stored.

**Fix — `_cacheSet` falls back to storing a list in pieces, and only on a FAILED
write.** Not on a size threshold: the exact ceiling is still unknown, and guessing it
is precisely what produced 0.9.3. A whole write is attempted first and pieces are used
only when the read-back proves it did not survive, so everything that works today keeps
working byte-for-byte and the repair fires only where needed. `_cacheGet` reassembles;
a missing piece reads as a MISS, never as a truncated list, or a year would silently
lose albums while looking like a cache hit. Every list reader now goes through it.

**What this cost, and why it took five builds.** The write guard was
`eval { $cache->set(...); 1 } or warn` — the trailing `1` makes the eval true when
`set` returns false without dying, so a refused write was indistinguishable from a good
one and the log said nothing. Three releases of diagnosis went into render deadlines,
concurrency and TTL tiers. **Simon's original report was accurate from the first
message** ("it's having to load each year again"), and every intermediate explanation I
offered for it — the warm, the deadline, the prefetch order, the TTL — was wrong.

**0.9.3's TTL ceiling is retained but its comment is corrected in place.** It explains
nothing; 90 days is merely measured to work. Leaving a confident, wrong mechanism in
the source would have set the next reader up for the same mistake.

**Test:** `t_hardening` section 8 reproduces the server exactly — a stub whose `set`
returns success and silently drops anything over a size limit. It pins round-trip,
completeness, order across piece boundaries, miss-not-truncation on a lost piece, and
that values which fit are still stored whole. Anti-tested three ways: chunking removed
(6 failures), reassembly removed (3), and a lost piece returning a short list (1).

## Status: 0.9.8
**0.9.8 (2026-08-06): every Pitchfork list moves out of `Slim::Utils::Cache` and into a
real SQLite database, `PitchforkReviews/DB.pm`. Simon asked for this early on and was
talked out of it; that was the wrong call and it cost five releases.**

**Why a database, on its own merits.** A published year-end list is immutable — Pitchfork
does not revise "The 50 Best Albums of 2019". A cache is disposable by design (LMS may
purge it, "clear caches" wipes it, DbCache may evict), so no TTL however long can express
"keep this". Simon's original argument — *"they are fixed entities with one new list per
year"* — was the correct criterion all along.

**And because the cache never worked.** From 0.9.0 to 0.9.7 the year lists were not stored
at all: `set` returned success, raised nothing, and the next `get` returned undef. Three
diagnoses were shipped and each disproved by the next measurement:

| release | blamed | disproved by |
|---|---|---|
| 0.9.3 | a 365-day TTL ceiling | 90d failed identically |
| 0.9.5 | a value-size ceiling | `0 of 5 pieces stored` — a ~14KB piece failed, a ~30KB feed succeeded |
| 0.9.6 | the shared `cache.db` | a **15-byte** value failed, as did a fresh namespaced cache |

**The cause is still unidentified**, and two of those experiments shared one design fault
worth remembering: they varied size and location while holding the TTL fixed at the value
under suspicion. The measurements were sound; the inferences were not.

**Design.** One row per album in `list_item`, keyed `reviews` / `bnm` / `hsa` /
`year:<Y>` — a real table, not a blob, so the rows stay queryable for a later
cross-year search. Modelled on `ListenLater/DB.pm`: DBI/DBD::SQLite (both ship with
LMS), WAL, `sqlite_unicode => 1`. An unopenable DB **degrades** — the plugin re-fetches
exactly as before and never dies.

**Invalidation replaces the hand-maintained key suffixes.** `PARSE_VERSION` is one
constant; a stored list recording a different one reads as absent and re-fetches. That is
what makes "no expiry" safe — a permanent store would otherwise keep a parsing mistake
permanently. Rotation is free: `putList` replaces a whole list in one transaction, so
feed entries that dropped off the page are deleted with it. Refresh (`force`) still
overwrites, and now reads the stored copy first so a **failed** refresh leaves the list
in place instead of emptying the view.

**A matcher fix needs none of this** — which streaming album a row resolves to is not in
the DB. That stays in `pfr:stream` and is versioned there, so a matcher change costs
re-resolution only, not 17.5MB of re-downloaded articles. Splitting the two layers is a
real gain over the entangled cache.

**What was deleted:** `_cacheSet`, `_cacheGet`, the chunking, `_diagnoseCacheFailure`,
`TTL_MAX`, `YEAR_CLOSED_TTL`, `YEAR_FB_TTL`, `FEED_FALLBACK_TTL` and the `:fb` duplicate
of every list. The findings from those experiments are preserved as commentary in DB.pm;
the conclusions drawn from them are not.

**Tests:** new `t_db.pl` (32 assertions) against real SQLite in a temp dir — round-trip
of both item shapes, unicode, order, rotation deleting what rotated off, count-mismatch
and stale-`PARSE_VERSION` both reading as *absent* rather than as a short list, and the
degrade path. That last one runs in a **child process**: `$dbh` is a file-lexical, so the
first in-process attempt "passed" against the handle it had already opened and proved
nothing. Anti-tested four ways (2, 1, 3 and 10 named failures).

## Status: 0.9.4
**0.9.4 (2026-08-06): 0.9.3's TTL fix DID NOT WORK, and this build stops guessing.
Verified on plex after the 0.9.3 restart (21:25:43): the warm ran all ten years at
21:28:13-16 and produced 13 fetches, 0 cache hits, 0 set failures. 90 days behaves
exactly as 365 did, so TTL magnitude was never the cause.**

The 0.9.3 hypothesis was wrong. The evidence for it was real — years cached under a
30d key and stopped the moment the TTL went to 365d, while the 90d `pfr:stream` key
hit 87 times in the same log — but a correlation across two key versions is not a
mechanism, and it was shipped as though it were.

**Why four builds missed it.** The write guard was

```perl
eval { $cache->set($key, $items, $ttl); 1 } or $log->warn("cache set failed: $@");
```

The trailing `1` makes the eval true whenever `set` RETURNS false without dying, so a
silently-refused write is indistinguishable from a good one. `set` did not die, did not
warn, and the next `get` returned undef. The log was empty because nothing ever looked.
That single character is why three releases of diagnosis went into render deadlines,
concurrency and TTL tiers.

**`_cacheSet` replaces it, and reads the entry straight back** — the only thing that
proves a write landed. When the round-trip fails it warns with everything needed to
identify the cause without another build: key, item count, approximate serialized
bytes, TTL, and what `set` returned. A failed write is still never fatal.

Applied to the year writes AND to the listing/bnm/hsa writes **deliberately** — the
feed path caches correctly on the live server, so it is the control. If the year writes
warn and the feed writes stay quiet, the difference is in the value, not the cache, and
the size figure in the warning says which.

**This is a diagnostic build; it is not claimed to fix the year cache.** The cause is
still unknown. What it guarantees is that the next boot says what is wrong out loud.

**Test:** `t_hardening` section 6 now asserts the failure is reported and names the key
— anti-tested by making the write silent again and by removing the read-back; both fail
it. Section 6's stale-while-revalidate value also moves 'Stale' → 'Fresh', deliberately:
the two writes used to share one eval, so a die on the main key skipped the fallback
write too — an accident of grouping. They are independent now, so good parsed items
reach the fallback even when the main write fails.

## Status: 0.9.3
**0.9.3 (2026-08-06): the year lists have not been cached AT ALL since 0.9.0. A cache
entry written with a 365-day TTL is never read back on LMS 9.1.2, and `$cache->set`
reports success when it happens — so it failed silently for three builds.**

Measured on plex from the server's own log, not inferred:

| key | TTL | fetched | cache hits |
|---|---|---|---|
| `pfr:year:*:3` (0.9.2) | 365d | 36 | **0** |
| `pfr:year:*:2` (0.9.0/0.9.1) | 365d | 23 | **0** |
| `pfr:year:*:1` (pre-0.9.0) | 30d | — | hits normally |
| `pfr:stream:11` | 90d | — | 87 |
| `pfr:listing/bnm/hsa:5` | 3h | 1 each | 2 each |

Every other view fetches once and hits thereafter — which is exactly what Simon
observed ("nothing had to reload this time, all the other views were instant"). Only
the year view, the only key above 90 days, never hits. `pfr:year:2021:3` was
downloaded **13 times in six minutes**; each one is a ~1.7MB article.

**This was the original complaint all along** — "it's having to load each year again in
Best Of" — and it was never the warm's fault. The warm ran correctly every time; the
articles it fetched were being discarded. Three code reviews and three builds chased
render deadlines, concurrency and prefetch order while the actual fault was a constant
introduced in 0.9.0 by the very fix meant to stop years re-pulling.

**Fix:** `TTL_MAX` (90d, the value proven to round-trip in that same log) is now the
ceiling. `YEAR_CLOSED_TTL` and `YEAR_FB_TTL` — both 365d, both dead — are held at it.
A closed year is now fetched about four times a year instead of continuously.

**The mechanism is still unproven.** The break point is somewhere between 90 and 365
days; 90 is evidenced, not reasoned. The ceiling is therefore documented as
evidence-only and must not be raised without a fresh measurement on a live server.

**Test:** `t_perf.pl` pins `TTL_MAX` and **sweeps every `*TTL*` constant in both
modules**, naming any that exceed it. Pinning the class rather than the one constant
that bit is the point — anti-tested three ways, including a TTL that does not exist
yet. The assertion this replaced was `YEAR_CLOSED_TTL >= 10 * YEAR_TTL`, which pinned
"make it as long as possible" — the instinct that caused the bug — and passed
throughout.

**No cache bump.** The keys were never the problem, and the stale 365d entries are
already unreadable, so the first fetch after install rewrites them at 90d. Bumping
would force a third needless cold start.

## Status: 0.9.2
**0.9.2 (2026-08-06): 0.9.1's fixes, shipped with the cache bump they needed to be
testable. Code identical to 0.9.1 apart from the keys.**

`pfr:listing/bnm/hsa :4 -> :5`, `pfr:year:<Y> :2 -> :3`, `pfr:year:latest :2 -> :3`,
`pfr:stream :10 -> :11`. No parse or shape change in any of them.

0.9.1 shipped with **no** bump, on the argument that re-inflicting a cold start to
observe a cold-start fix is self-defeating, and that 0.9.0's install had left plenty
of years cold anyway. Simon corrected it: 0.9.0's warm **did** run, so the years were
cached, and the cold path is precisely what is under test. Without the bump every year
opens from cache, neither the 5s deadline nor the warm's yield is ever exercised, and
the reported fault cannot be reproduced — the build would have been unfalsifiable.

Note the shape of the mistake, because it is the same one twice in three builds and in
**opposite directions**: 0.9.0 nearly shipped without a bump on "don't disturb a warm
cache"; 0.9.1 did ship without one on "don't re-inflict a cold start". Both were local
arguments that felt sound and both beat the standing fleet rule that every dev build
invalidates every cache. The rule wins; the reasoning to prefer it is already written
at both bump sites.

Every layer is bumped together. A partial bump leaves the articles cached and only
half-reproduces first boot.

## Status: 0.9.1
**0.9.1 (2026-08-06): fixes what 0.9.0 broke in the field. 0.9.0 was slower and
laggier than the build it replaced — "just 3 dots and a very long wait", "very laggy",
"changed a year and got confronted with 3 dots only". Three faults, all introduced by
0.9.0, all compounding.**

1. **The browse deadline went back 25 → 5s** (below `BUILD_DEADLINE`, not above it).
   0.9.0 raised it on the argument that no client imposes a timeout, so the view could
   safely wait for a *complete* list. Every fact in that argument was true and the
   conclusion still did not follow: Material renders nothing at all while the request
   is outstanding, so the whole budget bought a blank screen. Worse, 0.9.0 built the
   "still loading" label *for* the partial render and then set a deadline high enough
   that the partial render mostly stopped happening — it paid the full cost of waiting
   and discarded the feature that made not-waiting acceptable.

2. **The warm now yields to the user.** `BUILD_CONCURRENCY` is per-`_resolveSection`,
   not global, so a browse landing mid-warm ran 10 view searches *on top of* the warm's
   10. That was survivable while the warm was four quick stages; 0.9.0's ten-year
   prefetch turned the overlap from a rarity into the normal case. 0.9.0's note claimed
   prefetching all ten "extends the DURATION of the warm, not its peak load" — true of
   the warm alone, and wrong overall, because duration is exactly what made the peak
   reachable. The warm now runs at `WARM_CONCURRENCY` (2) and dispatches nothing while a
   view is resolving, bounded by `WARM_YIELD_MAX` so yielding can never become *never
   running*.

3. **Both properties had no test at all.** `VIEW_DEADLINE` was reverted by hand to 25
   and all 489 assertions passed — that is how the gap was found. An earlier note in
   this file claimed 0.9.0 "added value + behavioural coverage" for it; that was wrong,
   no such assertion existed. Section 10 of `t_perf.pl` now covers the deadline value,
   the relationship to `BUILD_DEADLINE`, the value `fetchFeed` actually passes, the
   yield, the resume-after-drain, and the release of the in-flight count. All four
   guards were anti-tested by reverting them individually.

**No cache bump.** Deliberate, and the opposite call to 0.9.0's — for the opposite
reason. Nothing cached is wrong, and what 0.9.1 fixes is *the cold start itself*, so
re-inflicting one to observe the fix would be self-defeating. The 0.9.0 install left
plenty of years still cold, which is precisely the condition the yield and the short
deadline are exercised by.

## Status: 0.9.0
**0.9.0 (2026-08-06): the year lists stop going cold. Prefetch every year from first
boot, size artwork on the services' own CDNs, and tell the user when a list is still
resolving instead of presenting a partial one as finished.**

Driven by a field report — *"it has to load each year again in Best of, warm isn't
working"* — and diagnosed from the live log rather than from the code. **Read the log
first next time:** three separate conclusions in that session were reached from
reasoning and then contradicted by `log.txt?lines=3000` (note the parameter — the bare
`log.txt` returns a ~3ms window, which is how "the warm has never run" got asserted from
its absence; the warm runs fine, its lines are just `info` and the category defaults to
`WARN`).

**MEASURED, from the live server:**

| | |
|---|---|
| cold Best-Albums-2019 open | 1.88s article fetch + 9.9s to the deadline, rendering **27 of 50** |
| resolve cache hit rate | 2,152 hits / 54 live resolves (97.6%) |
| a warm tick, 138 albums, 4 stages | **11ms** — a warm item costs a cache lookup, not a search |
| year articles re-fetched in 10.5h | 3 (2019, 2022 immutable; 2025 current) |
| Deezer cover, live CDN probe | 500px = 26,785B, 320 = 17,456B, **160 = 6,217B** |

1. **PREFETCH EVERY YEAR FROM FIRST BOOT** (`warmCache`). Year-end lists are fixed
   entities, so there was nothing for the warm to be incremental about. It now queues
   `YEAR_MIN..latest` — the on-screen year first, then newest-first — on the same
   sequential chain as the three listing stages. **Peak load is unchanged**: concurrency
   never exceeds `BUILD_CONCURRENCY`; prefetching ten years extends the warm's DURATION,
   not what it has in flight. That is the property that keeps it safe on a Pi, and it is
   asserted. (An earlier pass in this session warmed only years already opened plus one
   reach-ahead per tick; `cachedYears`/`nextUncachedYear` are DELETED — that could never
   break the chicken-and-egg, since a year is only warmed once opened.)
2. **TWO TTL TIERS, because the old ones ignored whether the content can change.**
   `YEAR_CLOSED_TTL` (365d) for any year before the current one — a finished list cannot
   be revised, so `YEAR_TTL`'s 30 days bought nothing and cost a re-fetch + re-parse of a
   ~1.7MB article per year, for ever. Only the CURRENT year keeps the short tier.
   `STREAM_FOUND_TTL` **7d → 90d**: the key already carries everything that can
   invalidate a match (parse version + enabled service set), so expiry only ever guarded
   against an album leaving a service — which "Refresh streaming match" already covers.
   The 7 days is what made an immutable 2019 list re-resolve *weekly*.
   - **`pfr:stream:9` → `:10` and `pfr:year:*:1` → `:2`, AND NEITHER IS A CORRECTNESS
     BUMP.** Nothing cached under the old keys is wrong. This build was first cut with no
     bumps at all, reasoning that a TTL applies on WRITE so entries would age onto the new
     schedule by themselves and a bump would force the very cold start the release exists
     to remove. **That was wrong, and Simon caught it:** against a warm cache the two
     headline changes are INVISIBLE — the prefetch logs nothing but cache hits and the new
     TTL never gets written — so the build would have shipped untestable. The bump forces
     the cold start that the prefetch and the "still loading" label were built to absorb,
     which makes it an end-to-end test of the new design rather than a cost. **This is
     what the fleet's [[dev-builds-clear-caches]] rule is for**, and the lesson is that a
     plausible local argument ("don't disturb a warm cache") beat a rule that existed
     precisely to stop that argument.
3. **THE IMAGE-PROXY HANDLER WAS REGISTERED FOR THE WRONG HOST.** 0.8.8 sized
   `media.pitchfork.com` and *deliberately* skipped the services' CDNs ("their plugins to
   manage"). But `_reviewRow` prefers the SERVICE's cover — the Pitchfork one is only the
   fallback for a row that did NOT match — so the handler only ever fired on unmatched
   rows, and every matching improvement shrank its reach. Handlers added for
   `static.qobuz.com`, `resources.tidal.com` and `dzcdn.net`.
   - **Ladders are evidence-backed only** (an unrecognised size is a 404, not a bigger
     file): Qobuz 50/100/150/230/600 from its documented ladder; Tidal 320/640 (both
     measured); Deezer 160/320/500 — its CDN takes arbitrary sizes, **probed live** at 56,
     160, 250, 320, 500, 640, 1000, 1200, 1800, all 200 with genuinely different byte
     counts.
   - **RULE 2, and it is not cosmetic: A HANDLER MAY ONLY EVER GO DOWN.** Each ladder
     stops at the size the row already carries. Deezer serves a 600 spec from its 500
     source today at 26,785B; a ladder containing 640 would satisfy it *properly* at
     50,769B — a 90% regression on the exact surface being optimised. Tidal had the same
     latent fault at 1280. Asserted per service at the spec where each would have bitten.
4. **"STILL LOADING" IS A LABEL, NEVER A ROW** (`_matchProgress`). A row that appears
   while loading and vanishes when done changes the item COUNT between renders, and a
   row's position is an index path Material re-traverses later to play — every row below
   it would shift by one. That is the `hide_unmatched` failure removed from the shelves in
   0.6.1. The status folds into labels that already exist: the year view's content header
   (`2019 - Best Albums (27 of 50 matched - still loading)`) and, for the review feeds
   which have no count-bearing header, the page TITLE. Nothing is added or removed on any
   view, so the same helper is safe everywhere including shelves.
   - **"Still loading" means NOT YET TRIED, never "tried and found nothing"**, and
     counting matches alone got this wrong in two ways that never clear: with no streaming
     service installed nothing can ever resolve ("0 of 50 - still loading" for ever), and
     an album on none of the services never resolves either ("47 of 50" permanently).
     Pending is decided by the RESOLVE CACHE, which holds an entry for anything already
     attempted including a confirmed no-match. Caught by a test failure, not by review.
5. **`VIEW_DEADLINE` (25s) for browse lists; home shelves keep `BUILD_DEADLINE` (10s).**
   10s was set BELOW the work it governs (~2.7 items/sec ⇒ ~18.5s for 50), so a cold list
   was *guaranteed* to render partial. **Nothing on the client required 10s** — checked,
   not assumed: Material browses via `lmsList` → `lmsCommand` → `axios.post('/jsonrpc.js')`
   with no timeout argument against axios' default `timeout: 0`; the 10s `maxNetworkDelay`
   in its bundle is the CometD player-status channel. The deadline is a CAP, not a wait —
   `_resolveSection` returns the instant everything settles — so a longer cap costs a warm
   list nothing and gives a slow machine more resolved rows. Home shelves are excluded
   because their path (HomeExtraBase's CLI request) is NOT what was verified, and 0.6.1
   recorded Material hanging on a slow shelf.
6. **`%PENDING` COULD STILL BE STRANDED, one step earlier than 0.8.9's guard reached.**
   That guard covered everything from the HTTP RESPONSE to `$done`; the slot is claimed
   inside `_shareFetch` and the request is issued by the caller AFTERWARDS, leaving
   `_yearUrls`/`->new`/`->get` bare. **Reproduced** with an injected transport throw: the
   two calls that followed were never answered, and stayed unanswered after the transport
   recovered. One shared `_issueFetch` now wraps both sites — using ONE helper because the
   two paths have drifted before (0.8.9 fixed the year path's negative-cache write and not
   the listing's).
7. **The year parser no longer reverses a list SILENTLY.** With fewer than two printed
   rank markers there is no evidence of direction, and the fallback numbers 1..n in
   document order — against Pitchfork's 50-to-1 house style that inverts the whole list,
   with every rank present and unique so no integrity check catches it. The fallback is
   deliberately UNCHANGED (guessing "countdown" is just a different assumption); it now
   WARNS, naming the page. Verified latent: the live 2025 page has 50 of 50 markers.

- **KNOWN AND DELIBERATELY NOT FIXED:** `_sectionHeader` freezes its children into the
  drill-in page, so a stateful row's label there can go stale. Unreachable on Material
  ≥ 6.4.3 — verified in 6.4.5's own bundle, `"header-basic"==f.type && (…, f.actions =
  void 0)` — and the real fix means making the drill-in re-enter the feed, i.e.
  restructuring live paths to repair a dead one. Constraint documented on the sub.
- **Tests: 481 → 489 assertions across the nine suites** (`t_perf` 65 → 99,
  `t_hardening` 65 → 73, `t_yearlist` 124 → 131). Anti-tested throughout: neutering the
  service handlers fails 7, restoring the enlarging rungs fails 2, reverting the
  closed-year tier fails 2, `STREAM_FOUND_TTL` back to 7d fails 1, removing `_issueFetch`
  fails 6, counting matches instead of consulting the resolve cache fails 1, dropping the
  no-adapter guard fails 1, reverting to a single-year warm fails 4, `VIEW_DEADLINE` back
  to 10 fails 2, and removing the rank-marker warning fails 3.
  **`VIEW_DEADLINE` was initially covered by NOTHING** — found by reverting it and seeing
  every suite still pass. It is now pinned both as a value and as "a browse list passes
  it, a home shelf does not".
- **No matcher change**, so `matcher_sync_check.py` is unaffected — same DSC drift as
  recorded at 0.8.8.

## Status: 0.8.10
**0.8.10 (2026-08-06): hardening the 0.8.9 build — from a code review of the working diff.
Five defects, three of them in code 0.8.8/0.8.9 introduced or widened, and one of those a
fix that never took effect. No feature change bar one deliberate UI consequence (below).
Every one was REPRODUCED against the real subs before it was fixed, then re-run to show the
fix closes it, then anti-tested from the committed suites.**

1. **THE WARM'S STAGES WERE NOT SEQUENTIAL, and the sequencing is the whole point of the
   chain.** `_resolveSection` calls back at `BUILD_DEADLINE` with whatever has resolved and
   deliberately keeps pumping the rest — right for a VIEW, which has a render to get on
   screen, but in `warmCache` that callback is **what starts the next stage**. A cold
   50-item stage takes ~13s (2.63s/album over 10 in flight) against a 10s deadline, so every
   stage began on top of the one before it. **Measured in the repro: 48 searches in flight
   against a `BUILD_CONCURRENCY` of 10** — precisely the burst 0.8.8's "resolve sequentially
   so the warm stays gentle on the streaming APIs" comment exists to prevent, and it got
   worse when 0.8.8 took concurrency 6→10 and the deadline 18→10. `_resolveSection` now
   takes an optional deadline and the warm passes **`WARM_DEADLINE` (300s)** — a backstop
   for a wedged stage, an order of magnitude past any real one, not a budget anything is
   expected to hit. **A hazard part 1 of 0.8.8 CREATED.**
2. **`_warmYearLast` COULD NEVER FIRE.** 0.8.8 added it to warm `year_last` after the newest
   list, then — in the same version — switched the warm from `getLatestYear` to `_viewYear`
   so the warm would also apply the promotion. `_viewYear` RETURNS `year_last` on every
   reachable path, so `$last == $warmed` was true every time and the second pass was dead
   code. **The sub is deleted, not repaired:** nothing renders the newest list while a user
   is pinned to an older one either (every surface reads `_viewYear`), so there is no cold
   list left behind. To make that invariant TOTAL, `_viewYear`'s out-of-range branch now
   **repairs `year_last`** instead of merely overriding it for one render — the one path
   where the pref and the answer could disagree, and the one where the dead sub would have
   woken up to re-run a doomed candidate-slug sweep (two ~1.7MB fetches) every tick.
3. **BOTH ADAPTER MEMOS STILL FROZE A MID-STARTUP ANSWER — 0.8.9 fixed only half of it.**
   It refused to keep an EMPTY detection ("no service plugin has loaded YET"), but a
   **PARTIAL** detection has exactly the same cause and was kept anyway: detection is `->can`
   on three classes, so an early caller sees only what has loaded so far and Qobuz/Tidal are
   then silently unusable for the life of the process, with no error anywhere. Plugin load
   order is **alphabetical**, so this is not even random — Deezer loads before Qobuz and
   TIDAL. The rule is now "nothing is memoised until every plugin has loaded":
   `Plugin::postinitPlugin` calls **`Browse::markStartupComplete`**, which arms both memos
   and drops whatever startup detected. Before it, detect fresh on every ask — three `->can`
   chains, what the code did before the memo existed.
   - **`$_svcOrder` is NOT part of the memo** (caught by the existing suites while fixing
     this): it is the enabled-service list as it appears in a stream cache KEY, so it is
     written on every call. Gating it behind the memo would have keyed resolves on the wrong
     service set.
4. **THE "STREAMING" DIVIDER WAS DRAWN OVER THE VERY PLACEHOLDER IT SUPPRESSES.**
   `reviewDetail` omitted the section `if @$streamItems` — but `_findPlayable` answers
   through `_streamResult`, which **never returns an empty list**: a no-match comes back as a
   one-element "No matching album found" TEXT row. So the omission only ever happened on the
   detail watchdog path (which passes a literal `[]`), and every real no-match page drew the
   header. Now decided by whether a row is a genuine service node (`_svc`), the same field
   `_rebuildStreamItems` keys the cache round-trip on.
   - **THE ONE VISIBLE CHANGE IN THIS RELEASE:** an unmatched review's detail page no longer
     shows the "No matching album found" row — it renders Options + the review, which is
     exactly what the watchdog path has always rendered. That is 0.8.4's recorded decision
     ("an empty Streaming section is omitted entirely — it would say only that the plugin
     tried") finally taking effect. The row's job is still done by "Refresh streaming match"
     sitting above it. If it should come back, keep the placeholder and drop only the header.
5. **THE HOME-SHELF TITLE GUARD WAS KEYED ON THE FORMATTED TITLE.** A home extra's title is
   ONE server-global string, but it is built with `cstring($client, …)` — so on a server whose
   players carry different language overrides, two clients naming the SAME year produce two
   different strings, the guard never holds, and **every home render re-sends the title and
   re-fires Material's home-refresh signal**. Measured in the repro: 4 `setHomeExtraTitle`
   calls for one year across two clients. Keyed on the year now; 0.8.9's "arm the guard only
   on success" property is unchanged and still asserted.

- **No cache-version bumps, no parse change, no favurl change** — and, as at 0.8.9, this is
  checked rather than assumed. Every piece of state touched (`$_adapters`, `$_ordered`,
  `$_orderStamp`, `$_svcOrder`, the title guard) is PROCESS MEMORY, cleared by the restart the
  install requires; `year_last` is a pref, not a cache, and is only ever written to a value
  that was already being rendered. Nothing stored changes shape.
- **The matcher is byte-identical to the 0.8.9 build** (verified by diffing the region against
  the shipped zip, not by inspection). `matcher_sync_check.py` still exits 1 with the SAME
  DSC drift in `_norm`/`%FOLD`/`_albumMatches` recorded at 0.8.8 — still a separate fleet-sync
  session.
- **Tests: +27 assertions, all in the existing suites** — `t_perf` 58 → 65 (new section 7: the
  warm's four stages, with a timer stub that records WHEN each timer is armed so a 10s render
  deadline can elapse without also firing the 300s backstop), `t_hardening` 59 → 65 (section 7
  widened from "never freeze an EMPTY answer" to "never freeze a MID-STARTUP answer"; the
  title-guard section gains the two-language case, which needed the stub `cstring` to become
  client-aware — the defect is invisible in a single-language test), `t_sections` 39 → 46, and
  `t_yearlist` 117 → 124 (the `year_last` == `_viewYear` invariant across all four pref
  states). Others unchanged (38/27/20/25/22).
  **`t_sections`' "an empty Streaming section is omitted" test was VACUOUS** — it passed a
  literal `[]`, a shape the resolver never produces. The new one drives what `_streamResult`
  actually hands back.
  **`t_perf` also had a landmine**: its section 5 replaced `_findPlayable` GLOBALLY rather than
  with `local`, so every later section was silently testing the stub. Restored at the end of
  the block.
  **Anti-tested five ways, one per fix, from the committed suites only:** reverting the warm
  deadline fails 2 in `t_perf`, the `year_last` repair fails 4 in `t_yearlist`, either memo
  gate fails 3 in `t_hardening`, the `_svc` test fails 4 in `t_sections`, and the title guard
  fails 2 in `t_hardening`.

## Status: 0.8.9
**0.8.9 (2026-08-06): hardening the 0.8.8 work itself — from a code review of the 0.8.8
diff. Three real defects, two of them INTRODUCED by 0.8.8's own optimisations, plus a
comment that understated its trade by 2x. No feature change.** Written up as "Part 3"
below, under the 0.8.8 entry it belongs to.

**Why a version bump and not a fold this time.** 0.8.8's two earlier passes went into the
same version because it had been built but never installed. A 0.8.8 zip now EXISTS with the
pre-fix code in it, and a same-version zip won't reinstall — so shipping these under 0.8.8
would silently hand back a build without them. See [[always-redo-sha-on-zip-rebuild]].

**No cache-version bumps, and this one is checked rather than assumed.** Every piece of
state these fixes touch — `%PENDING`, `$_adapters`, `$_ordered`/`$_orderStamp` — is PROCESS
MEMORY, cleared by the restart the install requires. So no fix here is hidden by a warm
cache, which is the thing the fleet's "clear caches on every dev build" rule exists to
prevent. Nothing stored changes shape either: `pfr:year:<y>:1` gaining a short-TTL copy of
`:fb` is compatible with what is already there, and no favurl or parse output changes.

## Status: 0.8.8
**0.8.8 (2026-08-05): TWO passes, folded into one unreleased version — an optimisation pass
on the first open of a view (part 1), and a hardening pass from a code review of the 0.8.7
diff (part 2). Neither changes a feature.** 0.8.8 was built but never installed, so the
second round went into the same version rather than a bump. **Part 3 below shipped as 0.8.9**
— see the entry above for why that one could not be folded in the same way.

### Part 1 — the FIRST open of a view (optimisation pass)
**Nothing about what the plugin shows changes — only how long you wait for it and how much
the server pulls to draw it.**

**Measured before anything was changed** (live server + the real pages, so the work went
where the time actually was):

| path | measured | verdict |
|---|---|---|
| warm feed build (Latest Reviews, 35 rows) | 0.23s | already fine |
| warm year list (2022, 55 rows) | 0.05s | already fine |
| **cold resolve of ONE album** (forced via Refresh streaming match) | **2.63s** | the bottleneck |
| listing page fetch | 0.9–2.0MB, **0.1–4.0s** (BNM was the 4.0s one) + 0.17–0.31s parse | paid by whoever opens first after the TTL |
| 50 thumbnails through the image proxy @300px | 1.2MB delivered, 0.25–1.8s | delivery is fine — the SOURCE fetch was not |

At the old `BUILD_CONCURRENCY 6`, 2.63s × 50 items ÷ 6 ≈ **22s** — past the old 18s
`BUILD_DEADLINE`, so a genuinely cold year list rendered **partial every single time**.

1. **STALE-WHILE-REVALIDATE on every page fetch** (`API::_shareFetch`). An expired feed is
   answered from the last good copy (`:fb`, which already existed for outage survival) and
   the refresh runs behind the caller. `force => 1` (the Refresh row) never serves stale, so
   a deliberate refresh is always live; `nostale => 1` (**the warm**) waits for the real
   page, or the warm would spend its tick resolving the very list it exists to replace.
   An **empty** fallback is not an answer and is never served.
2. **CONCURRENT FETCHES OF THE SAME PAGE ARE COALESCED** (same helper). Material opens a
   browse list while its home shelf is still building; that was two full downloads of one
   ~2MB page. The first caller does the work, the rest queue on it. `force` bypasses the
   queue — a forced refresh must actually refetch, and must not be answered by an
   already-running normal fetch.
3. **THE WARM RUNS EVERY 3h, NOT DAILY** — because that is `API::FEED_TTL`. On a daily tick
   the listing cache was expired for most of the day, so the first person to open a view
   paid the page fetch *and* the resolve of everything published since. Matching the two
   means the warm pays it, before anyone looks. `t_perf.pl` asserts the two constants agree
   (it reads `WARM_INTERVAL` out of the source — Plugin.pm can't be loaded without the LMS
   plugin tree).
4. **THE WARM ALSO WARMS `year_last`** (`_warmYearLast`). `_viewYear`'s pick is sticky, so
   warming only the NEWEST list left the one year certain to be opened next as the only cold
   one. Skipped when it *is* the newest; after the first tick it costs nothing anyway (a
   published list never changes and its matches are cached 7d).
5. **THE TOP-PRIORITY SERVICE IS PROBED ALONE FIRST**, the rest only if it doesn't settle it.
   The old code fired all three at once, which reads as "parallel is faster" but wasn't: the
   answer was **already** only allowed to be the highest-priority match, so a hit on the
   first service discarded two searches that had been sent anyway. Most albums hit the first
   service ⇒ roughly a third of the streaming API traffic for identical answers. **The
   trade, stated plainly:** an album that misses on the first service now costs two rounds,
   not one. That is the minority case, it is the one the deadline + background pump already
   covers, and it is bounded — while the wasted searches were paid on *every* item.
   Inconclusive (no handler / logged out) fans out too, or one logged-out service would
   silently disable the others.
6. **`BUILD_CONCURRENCY` 6 → 10, `BUILD_DEADLINE` 18 → 10.** 5 is what pays for the
   concurrency: what the services see is requests in flight, not items in flight. The
   deadline comes DOWN rather than up — nobody should stare at a building list for 18s, and
   the pump deliberately keeps resolving past it, so whatever missed the cut is already
   cached and the view completes itself on the next open.
7. **ARTWORK: THE COST IS THE SOURCE FETCH, NOT THE THUMBNAIL.** XMLBrowser routes every row
   `image` through `Slim::Web::ImageProxy` and Material asks it for `_150x150_f` (list) /
   `_300x300_f` (grid), doubled on hi-dpi — but to answer, LMS downloads the **original**
   once, resizes, and caches for 30d. Measured per cover: **Tidal 1280×1280 = 563KB**
   (its 320×320 is 41KB), **Pitchfork w_768 = 82KB** (w_320 = 9KB), Qobuz `_600` = 25KB. A
   fresh 50-row list on a Tidal-first setup was pulling **~28MB to draw 50 thumbnails**.
   Two fixes, split by who owns the URL:
   - **`_fitCover`** caps what *we* put on *our* rows at `MAX_COVER_PX` 640 — 600 is the
     largest spec Material ever asks a browse row for, so nothing visible changes. Applied
     in `_reviewRow`, **not** at match time, so every already-cached match gets the smaller
     picture immediately with **no `pfr:stream` bump and no re-resolve**. Anything
     unrecognised is returned verbatim: a cover that fails to shrink costs bandwidth, a
     cover mangled into a 404 costs the picture.
   - **`pitchforkImageProxy`**, a `Slim::Web::ImageProxy` handler for `media.pitchfork.com`
     (our own source — deliberately NOT the services' CDNs, which are their plugins' to
     manage). The width is a path segment, so it names the smallest one that satisfies the
     spec being requested. The proxy's cache is keyed on the ORIGINAL url + spec, so the
     rewrite doesn't fragment it. **Registered unconditionally** — a `match` handler is
     consulted whatever `useLocalImageproxy` says (that pref selects an *external* resizing
     proxy). **LBF gates its coverartarchive handler on that pref, which is the wrong gate —
     a separate fleet fix.**
8. **Cheap cleanups, all free:** adapter **detection is memoised** for the life of the
   process (it can't change without a restart) while the priority ORDER self-invalidates off
   a pref stamp — it was being recomputed **twice per item**, so a 50-row build ran 100
   enumerations and 300 eval'd `_pluginDataFor` lookups; `_svcOrder` caches the cache-key
   fragment alongside; matches are **deduped and capped before being cached**, not only
   before display (a search can match a dozen editions and every one was frozen into the
   cache as a full album node); and **`_resolveSection`'s pump no longer recurses** — a
   cache hit answers synchronously, so the completion re-entered the pump from inside the
   loop iteration that started it and **the stack grew one frame per item** (measured
   3→120 over 40 items; now flat at 3). Returning early is not a lost wakeup: `$active` is
   already decremented, so the loop we return into picks the next item up.
- **No cache-version bumps anywhere.** The favurl is untouched, the parsers' output is
  unchanged, and the row-level cover cap is applied at render.
- **Tests: new `tools/t_perf.pl`, 58 checks**, anti-tested **eight** ways — removing SWR
  fails 3, removing coalescing fails 8, fanning out to all services up front fails 1 (the
  one assertion that can tell the difference), dropping the pump guard fails 1 (depth
  3..120), un-capping the cache fails 2, neutering `_fitCover` fails 5, no-op'ing the proxy
  handler fails 4, and dropping the memoisation fails 2. `t_searchlegs.pl` 24 → 25: its
  section 7 asserted the OLD contract ("the beaten service ran ONE leg") and now asserts the
  new one ("the beaten service was never queried") plus that the winner still runs both of
  its own legs. All seven other suites unchanged (38/27/41/20/39/22/117).
- **`matcher_sync_check.py` still exits 1, and it is still not this change** — no diff hunk
  lands in or after the matcher region (verified mechanically). It remains the DSC drift
  recorded in part 2 below, awaiting its own fleet-sync session.

### Part 2 — hardening (from a code review of the 0.8.7 diff)
**Four self-leaking async drivers, an uncached failure sweep, and three silent-failure
paths. No feature change.**

Every one of these produces plausible output and no error, which is why they survived seven
green test suites. New suite `tools/t_hardening.pl` (41 checks), each fix anti-tested.

1. **SELF-CAPTURING CLOSURES LEAK, and there were four.** `my $x; $x = sub {… $x …}` makes the
   closure the only holder of the only reference to itself; Perl frees by refcount, so it is
   **never** collected, along with everything it captured. Fixed by passing the sub to ITSELF
   (`my $x = sub { my ($self) = @_; … $self->($self) … }; $x->($x)`) — the shape the sibling
   ListenBrainz plugin adopted in LBF 0.9.95.
   - `_findPlayable`'s two-leg search driver — **the worst one**: one per adapter per resolve
     (three services × ~150 items on the daily warm alone), each retaining the matched album
     nodes through `$finish`.
   - `_resolveSection`'s `$pump` (pre-existing, not from the 0.8.x work — same defect, fixed
     with it rather than left as the only remaining copy).
   - `getYearList`'s and `getLatestYear`'s retry drivers.
   - **Testing a leak needs a weak reference, not a behavioural assertion** — the feature works
     perfectly either way. `Scalar::Util::weaken` on the callback the adapter was handed, and
     on the player object for `$pump`. **TRAP, hit on the first run: an anonymous sub that
     closes over NOTHING is built once at compile time and shared, and the optree holds it
     forever — so a `sub { }` probe can never be collected and the test reports a leak whatever
     the code does.** The probe must capture something.
2. **A FAILED YEAR SWEEP WAS NEVER CACHED** (`LATEST_MISS_TTL` / `YEAR_MISS_TTL`, both 1h).
   `getLatestYear` probes `_topYear` down to `YEAR_MIN` and `getYearList` tries every candidate
   slug; with nothing written on the failure path, a slug change or an outage made **every**
   home-shelf render, tile open and daily warm re-run the whole sweep — ~17 fetches of a ~1.7MB
   article, every time. The negative must be distinguishable from a cache miss, hence the **0
   sentinel** and `defined` (a plain truth test reads 0 as "not cached" and sweeps again);
   `cachedLatestYear` collapses it back to undef. **The two negatives are not redundant:**
   `getYearList`'s alone stops the HTTP storm, but only `getLatestYear`'s stops the probe loop
   being re-walked and makes "nothing is published" a stable answer. Short TTL by design — far
   shorter than the 12h December polling interval, so **self-promotion is unaffected** — and
   `force => 1` (the Refresh row) skips both, so a manual retry is always immediate. **A miss
   never overwrites a good `:fb` copy**, or the fallback that exists to survive an outage would
   be destroyed by one.
3. **THE HOME SHELF IS PINNED TO RANK ORDER, reversing part of 0.8.1** (Simon's call). 0.8.1
   ordered it by `year_sort` so it could not disagree with the in-app list, reasoning it was
   safe because the order depends on a durable pref, *"NOT on the request quantity, so the feed
   is still identical at every quantity within a render"*. **That is the wrong invariant.** A
   card's `item_id` is an INDEX PATH and Material re-traverses it in a **separate, later**
   request to play, so the contract spans renders. Verified in Material's source, not inferred:
   `browseGoHome` → `browseFetchHome` → `getHomeExtra` *does* re-fetch, but `browseGoHome`
   repaints the cached `view.topExtra` **synchronously first**, so for one round-trip the old
   order is on screen against the new order on the server and tapping the first card plays #50.
   A shelf is a "here are the picks" surface; countdown is a reading choice belonging to the
   list view, **which keeps its toggle** (asserted, so this stays a hazard removal and not a
   feature removal).
4. **`_parseYear` cleared its pending cover/rank only on the SUCCESS path**, so a heading that
   yielded no album leaked its artwork onto the next entry — visible only when that next entry
   carries no `inline-embed` of its own, and then it is simply the wrong cover. Also fed a rank
   the page never printed into the countdown-direction test.
5. **`_setHomeYearTitle` armed its dedupe guard BEFORE the call it guards**, so one failure
   (Material mid-restart) permanently suppressed every retry for that year until a server
   restart. Guard now arms only on success; the "don't resend an unchanged title" behaviour is
   unchanged and still asserted (every write signals a home refresh).

- **No cache-version bumps.** The favurl carries nothing new (no `pfr:stream` bump — the
  `_findPlayable` change is control flow only) and the parser's output is unchanged: **all ten
  live year pages 2016-2025 were re-fetched and re-parsed, and the result is byte-identical to
  the pre-change parse across all 500 entries** (the fix is defensive — no current real page
  hits the skip path). `pfr:year:latest:1` gaining a 0 and `pfr:year:<y>:1` gaining a `[]` are
  both compatible with what is already stored.
- **Tests: new `tools/t_hardening.pl`, 41 checks**; all seven prior suites unchanged
  (38/27/20/24/39/22/117). **Anti-tested eight ways** — restoring each self-capturing closure
  fails 2/1/1, dropping either negative cache fails 2/1, un-clearing the cover fails 4, arming
  the title guard early fails 5, and putting the shelf back on the pref fails 2.
- **`matcher_sync_check.py` exits 1, and it is NOT this change** — no matcher sub is touched
  (verified line by line). The drift is DSC having moved ahead of the whole fleet in `_norm`
  (apostrophe handling), `%FOLD` (a much larger table) and `_albumMatches` (a whitespace-collapse
  fallback); PFR still agrees with LBF and SH. **That is a separate fleet-sync session.**

### Part 3 (shipped as 0.8.9) — hardening the 0.8.8 work itself
**Three defects, all introduced or widened by part 1's own optimisations, plus one comment
that understated its trade by 2x. Every one was CONFIRMED against the real subs before it
was fixed** (throwaway-harness reproductions, then re-run to show the fix closes them).

1. **COALESCING TURNED A ONE-OFF EXCEPTION INTO A PERMANENT DEAD KEY.** `%PENDING`
   (`API::_shareFetch`) is released by exactly one thing — the fetch reaching its `$done` —
   and both fetch sites did unguarded work on the way there: `_parseState`/`_parseYear`,
   then `$cache->set`. **`$cache->set` is not a theoretical risk: `Browse::_cacheStream`
   already wraps its own in an eval for exactly this reason, and DbCache dies outright on a
   character string.** One escape and that key is stranded for the life of the process, with
   every later non-`force` caller adopted by a fetch that can never answer. **Both symptoms
   are silent, and the one that hits a real server is the worse of the two:**
   - with no `:fb` copy (fresh install) the view simply never answers;
   - **WITH one — i.e. any server that has fetched successfully even once — the feed serves
     the same stale copy for ever and never issues another fetch.** It just quietly stops
     updating, with nothing in the log after the single original error.

   Fixed by guarding the parse + cache write at both sites so `$done`/`$cb` is always
   reached. A failed cache write no longer costs the caller its answer either.
   **This is a hazard part 1 CREATED** — before coalescing, the same exception cost one
   request and nothing more.
2. **THE YEAR-MISS NEGATIVE CACHE WAS SKIPPED IN THE CASE IT MATTERS MOST.** `getYearList`
   wrote `$key` only on the branch where **no** `:fb` copy exists. With one present it
   answered the caller and wrote nothing — so the next open re-ran the whole candidate slug
   sweep (two ~1.7MB article fetches), and the one after that, for ever. That is precisely
   the storm `YEAR_MISS_TTL` was added in part 2 to stop, just moved behind the user where
   it is invisible. The rule is not "write nothing", it is **"write the GOOD COPY, briefly"**:
   the list still renders, `:fb` is still never overwritten by a miss (part 2's rule holds),
   and only the sweep is suppressed, for `YEAR_MISS_TTL`. `t_hardening`'s assertion here was
   over-specified — it checked "the key is absent" rather than the property its own comment
   stated ("a miss must never blank a good copy") — so it has been rewritten to assert the
   property, plus the TTL and the absence of a second sweep.
3. **BOTH ADAPTER MEMOS FAILED CLOSED.** `_streamingAdapters` memoised an EMPTY detection,
   and an empty list is not "no services installed" — it is "no service plugin has loaded
   YET". One early call (anything reaching `_orderedAdapters` before the streaming plugins
   are up) would silently disable **every** match until the next restart, with no error
   anywhere. `_orderedAdapters` needed the same rule for a subtler reason: **its invalidation
   stamp is built from the PREFS, and those do not change when a plugin finishes loading**,
   so an empty list cached there is pinned just as hard. Both now memoise only a positive
   answer; re-running detection while there is genuinely nothing to find is what the code did
   before part 1's memo, and it is cheap next to that failure mode. The memo still works —
   a positive answer is still never re-detected (asserted).
4. **The priority-first comment understated its own trade by 2x.** It claimed "worst case two
   `STREAM_SVC_TIMEOUT`s, not one". The fan-out is triggered by `$finish`, and the 0.7.12
   album-title retry happens **before** `$finish` — so the serial chain on a top-service miss
   is `svc1 artist -> svc1 album -> [fan-out] -> svc2..n artist -> svc2..n album` = **FOUR**
   timeouts, 32s at `STREAM_SVC_TIMEOUT` 8, against a `BUILD_DEADLINE` that part 1 halved
   18 -> 10. Such an item can therefore never make the render; it resolves behind the deadline
   via the pump and appears on the next open, which IS the designed degradation — but it is
   the degradation now, and the comment said otherwise. **Comment corrected; the constants are
   deliberately NOT retuned** (that is a tuning call, not a defect). The note records the fix
   if it ever needs tightening: fan out on the top service's ARTIST leg coming back empty
   rather than on `$finish`, which restores the two-round worst case and keeps most of the
   traffic saving, at one extra search per miss.

- **No cache-version bumps, no parse change, no favurl change.** Every fix is control flow or
  a cache-write that did not happen before; nothing stored changes shape. `pfr:year:<y>:1`
  gaining a short-TTL copy of `:fb` is compatible with what is already there.
- **Tests: `t_hardening.pl` 41 -> 59.** New section 6 (the coalescing slot is released through
  a real thrown exception on both the listing and the year path — a mocked "return false" would
  not reproduce it) and section 7 (neither memo freezes an empty answer, in a genuinely cold
  process — nothing earlier in the file calls the real `_orderedAdapters`), plus the rewritten
  year-miss block. **Anti-tested three ways: reverting the fetch guard fails 2, the year-miss
  write fails 3, the memo guards fail 3.** All eight other suites unchanged
  (38/27/58/20/25/39/22/117).
- **`matcher_sync_check.py` still exits 1, and it is still not this change** — no matcher sub
  is touched. Same DSC drift recorded in part 2, still awaiting its own fleet-sync session.

## Status: 0.8.5 → 0.8.7
**0.8.7 (2026-08-05): the year is named ONLY where it is rendered live. Changing it takes you
straight to that list, and nothing anywhere is left showing the old one.**

Three rounds of field reports, all the same underlying fact:

> **A page keeps the labels it was built with. Material replays a page it already holds in
> history WITHOUT asking the server again — and a plugin cannot refresh a page the user is not
> standing on.** (`needsRefresh` is client-side; Material sets it for podcasts, search and
> playlist drags only. Checked in `browse-functions.js`, not guessed from the minified bundle.)

So any surface that names the chosen year must either be rebuilt when the year changes, or not
name it at all. What went wrong, in order:

1. **The chooser stayed in the back stack** (0.8.4). A picker row opened the chosen year as a
   THIRD level (`url => \&fetchYearFeed`, year pinned in the passthrough), and Material titled
   that chooser page with the row that opened it — "Choose a year (2024)", captured *before*
   the change. Backing out of the 2025 list landed on a page announcing 2024.
2. **The app tile lagged** (0.8.5). Fixed 1 by making a picker row only write `year_last` and
   return an **empty response with `nextWindow => 'parent'`** — Material pops the chooser and
   re-fetches the year view underneath, which rebuilds from the pref. But the app menu ABOVE
   that still held a tile reading `_yearTileName`, unchanged until you left the app.
3. **Rebuilding the app menu costs you your place** (0.8.6). `'grandparent'` pops the chooser
   AND the year view and re-fetches the app menu, so the tile was right immediately — but every
   year change then threw you out of the section. Rejected.

**0.8.7 removes the year from the app tile instead** (Simon's call, given the three-way trade
laid out above). The tile is `PLUGIN_PITCHFORKREVIEWS_YEAR` — "Best Albums of the Year" — again,
and `_yearTileName` is deleted. The year is now named only on surfaces that are rendered live
every time they are shown, or pushed when it changes:

| surface | how it stays right |
|---|---|
| list header (bold, above the albums) | rebuilt on every open of the view |
| page title | same |
| "Choose a year (2023)" row | same |
| Material home shelf | pushed via `setHomeExtraTitle` — from `homeYear`, from the warm, and now **from the picker itself** (a home extra's title is *registered*, not re-rendered, so nothing else would move it) |
| app tile | names no year — nothing to go stale |

`_viewYear`'s sticky-with-promotion behaviour is unchanged: your pick still sticks, a newly
published list still overrides it.

**The nextWindow values, from Material's source.** `browseHandleNextWindow` fires only on a
**zero-item** response, and by then the page you tapped from is already on the history stack:
`'refresh'` → `browseGoBack(view,true)`, i.e. re-fetch the page the row lives on (right for
Refresh / Sorted by / Grouped by, which sit in the view they want redrawn); `'parent'` → one
extra `history.pop()` first (the page below that); `'grandparent'` → two extra pops. The picker
uses `'parent'`; there is no longer any reason to go further.

- The chooser also **names itself** (`title => 'Choose a year'`), so it can never show a stale
  year even if it is on screen, and `_yearPickerRow` no longer forwards `features` (the chooser
  renders no feed that needs it). The pinned-year passthrough path in `fetchYearFeed` still
  works; nothing in the UI uses it now.
- `API::cachedLatestYear` is now unused (it existed only to label the tile without fetching).
  Left in place as a cache accessor.
- **Tests: `t_yearlist.pl` 107 → 117** — the tile carries no year and the app menu never
  fetches to build it; the chooser's own title; no row drilling into `fetchYearFeed`;
  `'parent'` on every row and on the response; the empty item list; the stored pref; the
  home-shelf push; and `_viewYear` re-opening on the picked year. Anti-tested: putting a year
  back on the tile fails 2, restoring the drill-in fails 6. All six other suites unchanged
  (38/27/20/24/39/22).

## Status: 0.8.4
**0.8.4 (2026-08-01): the Options/section headers roll out to the REMAINING views — the three
review feeds and the review detail page. Fleet shape everywhere now.**

0.8.3 gave the year view an Options section; the other views still had their action rows
sitting bare above the first divider, which read as two unexplained rows before the list
began. Now every view leads with an **Options** Material divider and puts its content under
its own heading, matching the sibling ListenBrainz plugin.

- **`fetchFeed` (Best New Music / High Scoring Albums / Latest Reviews)**: Refresh + Grouped
  by move into an Options section; the grouped content keeps its own genre/week dividers
  below. No content header added — unlike the year view, these lists already had dividers.
- **`reviewDetail`: three sections** — Options (Refresh streaming match), Streaming (the
  playable matches), and the prose. An **empty Streaming section is omitted entirely** rather
  than rendered with nothing under it: it would say only that the plugin tried, and the review
  rows below are what the page still has to offer.
- **THE TRAP, and the reason `t_sections.pl` exists: the detail page cannot see `features`.**
  XMLBrowser hands `features` to the TOP feed only, never to a coderef sub-feed, so
  `reviewDetail` has no way to ask whether the client draws headers — it must be TOLD.
  `_reviewRow` now stashes the answer as a **SECOND passthrough element**, and `reviewDetail`
  takes a 5th `$opts` arg. If that regresses, every header on the page silently degrades to
  plain text on Material — the one skin these dividers exist for — and nothing else breaks to
  warn you. Anti-tested: reading `_featuresOf($args)` instead fails 1.
- **`$it` is the CACHED parsed item — the stash must never be written into it.** A stray key
  there is cached for the feed's whole TTL and travels into every other view. Hence a separate
  passthrough element, not `$it->{headers}`. Anti-tested: writing into `$it` fails 5.
- **`$noIcon` (added to `_sectionHeader`) is a real split, not cosmetic.** LIST headers KEEP
  the logo, because an image-less item sets `haveWithoutIcons` and disables Material's
  grid/list toggle for the WHOLE page; DETAIL headers drop it (nothing to drill into, the rows
  sit right below). Same rule the ListenBrainz plugin follows. Anti-tested: keeping the icon on
  detail headers fails 1.
- **A year-end entry's prose section is NOT called "Review"** (`_detailSectionLabel`, the same
  distinction `_linkLabel` already drew): it is Pitchfork's write-up of an album, not a review,
  so it reads **"About this album"**.
- **`$headers` is threaded through every `_reviewRow` call site** — the grouped chain
  (`_divHeader`/`_weeklyRows`/`_genreRows`), the year feed, and all four home shelves (which
  read it from their own `$args`, since HomeExtraBase does pass `features` through its CLI
  request). The shelves themselves stay flat card lists; the threading is only so a card's
  DETAIL page can draw its dividers.
- **No cache or parse change** — no `pfr:stream` bump, no `pfr:year:*`/listing parse-version
  bump. Row assembly and labelling only.
- **Tests: new `tools/t_sections.pl`, 39 checks** (detail sections in order, empty-Streaming
  omission, the year-entry labelling, headers-off parity, the `$noIcon` split both ways, the
  passthrough stash including that `$it` comes back untouched, and the list view's Options
  section). Anti-tested four ways: 1 / 5 / 1 / 3 failures. All six prior suites still pass
  (38/27/20/24/22/107).

## Status: 0.8.3
**0.8.3 (2026-08-01): the Best Albums view NAMES its year, everywhere — and the action rows
move into an Options section.**

Field note: you could not tell which year you were looking at. The tile said "Best Albums of
the Year", the home shelf said the same, and inside, the year appeared only in parentheses on
the "Choose a year" row. **One label, `_yearLabel` — "2025 - Best Albums" — is now shared by
all four surfaces** (tile, home shelf, page title, list header), so they can't disagree.
*(Superseded by 0.8.7: the app TILE no longer names the year — it was the one surface that
could not be rebuilt when the year changed. The other three, plus the chooser row, still share
`_yearLabel`.)*

- **The view REMEMBERS the year, but promotion still wins (`_viewYear`).** The three surfaces
  can only agree if they name the same year, and the tile can't say "2019" unless the choice
  is durable — hence `year_last`. The obvious danger is pinning someone to an old list for
  ever, which would defeat 0.8.0's whole self-updating design, so `year_promoted` records the
  newest list we have already jumped to: when `getLatestYear` reports something newer, that
  new list overrides the remembered year and both prefs move up. Fresh install (prefs 0)
  opens on the newest. An out-of-range remembered year (hand-edited, or a list withdrawn)
  falls back to the newest rather than stranding the view on an empty page.
- **The tile label MUST NOT fetch, and this is the one real constraint.** `topLevel` builds
  its items inline, so blocking the whole app menu on a 1.7MB article fetch just to label one
  tile would be a bad trade — `_yearTileName` reads `year_last`, else the new cache-only
  `API::cachedLatestYear` (no fetch, ever), else falls back to the generic name until the
  first feed open or the daily warm has resolved a year. Anti-tested: making it fetch fails 2.
- **The Material home SHELF title is updated at runtime.** A home extra's title is registered
  ONCE at startup (`registerHomeExtra`), when the newest year is usually not yet known, so it
  is set afterwards through Material's own **`setHomeExtraTitle`** (which also signals the
  home page to refresh) from `homeYear` and from the warm. Guarded on `can` — the call is not
  in older Material — and written only when it actually CHANGES, since every write fires that
  refresh signal.
- **Options section (`_sectionHeader`), the sibling ListenBrainz plugin's shape exactly.**
  Refresh + Choose a year + Sorted by now sit under an "Options" Material divider, and the
  albums under their own `"2025 - Best Albums (50)"` divider — which is what puts the year in
  bold directly above the list. The feed also returns `title => $label` for skins that show a
  page title. `_sectionHeader` takes a **literal** label (unlike `_divHeader`, whose callers
  pass string tokens) because the year headers are built at render time; it keeps the
  header/header-basic split and the drill-to-own-children url for older Material.
- **`features` is now threaded into the year feed** (tile → feed → picker → feed). It never
  was, so the year view had no dividers available to it at all; a non-Material client still
  gets every row, with the headers as plain text.
- **No cache or parse change** — `pfr:year:*` untouched, no `pfr:stream` bump. This is
  labelling and row assembly only.
- **Tests: `tools/t_yearlist.pl` 74 → 107.** New: the shared label, the tile label (including
  that it never fetches), `_viewYear`'s sticky/promote/fallback matrix, `_sectionHeader` in
  both header and plain-text modes, and the assembled view asserted row by row. Anti-tested:
  never promoting fails 5, making the tile fetch fails 2, dropping the section headers fails
  7. All five prior suites still pass (38/27/20/24/22).

## Status: 0.8.2
**0.8.2 (2026-08-01): the review lists' GROUPING moved from the Settings page onto the view,
as a tap-to-change row — the same control as the year list's sort.**
- **`_groupToggle` + `_groupBy` + `_groupLabel`**, mechanically identical to `_yearSortToggle`:
  `"Grouped by %s (tap to change)"`, the shared sort glyph, `nextWindow => 'refresh'` on an
  EMPTY response, and the next mode advanced from the **LIVE** pref so a stale view can't set
  it backwards. Rendered on all three review feeds (BNM / HSA / Latest Reviews) because the
  `group_by` pref is shared by all three.
- **Nothing about the grouping itself changed.** `_weeklyRows`/`_genreRows`/`_divHeader` are
  untouched, so BOTH modes still emit the same branded Material dividers — switching mode
  changes what the headers SAY, never whether there are headers. That is the property the new
  tests exist to protect, since it is the easy thing to lose in a move like this.
- **`_groupedRows` now takes the mode as an argument** (falling back to the pref when absent),
  so the feed reads the pref ONCE per render and passes it to both the toggle row and the
  grouper — the row can't disagree with the list it labels.
- **THE ENUM GUARD MOVED FROM THE SAVE TO THE READ.** `Settings::handler` used to sanitise
  `pref_group_by` on save; with the radio gone that guard would have vanished, so `_groupBy`
  validates against `@GROUP_MODES` and falls back to `'genre'`. A corrupt or unset pref now
  reads as the shipped default instead of rendering an arbitrary grouping. Anti-tested.
- **Removed from the Settings page**: the radio in `settings.html`, `group_by` from
  `Settings::prefs()`, and the enum-coercion block in `Settings::handler`. **The pref itself is
  unchanged**, so an existing user's choice carries over untouched — this moved the control,
  not the setting. Retired the three now-unreferenced strings (`GROUP_BY`, `GROUP_BY_DESC`,
  `GROUP_BY_DATE`); `GROUP_BY_GENRE` is reused by the toggle, and `GROUPED_BY`/`GROUP_WEEK`
  are new. Verified no code or template still references a retired token, and that every
  token the code uses exists in `strings.txt`.
- **No cache bump** — nothing cached changes.
- **Tests: new `tools/t_grouptoggle.pl`, 27 checks.** Fixture is two genres across two calendar
  weeks, so genre and week bucket DIFFERENTLY and an implementation that ignored its mode
  argument cannot pass both. Covers: dividers present in both modes with the branded icon and a
  real `header`/`header-basic` type, every review row surviving, the two modes actually
  producing different output, a header-less client degrading to plain `'text'` dividers,
  the toggle's refresh/glyph/live-pref advance and round trip, and the enum guard.
  **Anti-tested**: ignoring the mode argument fails 3, dropping the enum guard fails 1.

## Status: 0.8.1
**0.8.1 (2026-07-31): the year list can be read in EITHER direction — #1-first (default) or
Pitchfork's own 50-to-1 countdown.**
Asked for directly: people who follow the list each December work through it the way the article
reads. Built as the sibling ListenBrainz plugin's sort toggle, not a settings-page pref, because
it is a per-view reading choice and the fleet keeps those on the view.
- **`year_sort` pref** ('rank' | 'countdown', default 'rank') + **`_yearSortToggle`** — the LBF
  mechanics exactly: `"Sorted by %s (tap to change)"`, the Material sort glyph (`pfr-sort_MTL_icon_sort.png`,
  copied from LBF like the refresh icon), `nextWindow => 'refresh'` on an EMPTY response so the view
  re-walks in place, and the next mode is advanced from the **LIVE** pref rather than the value this
  render captured — so a stale view can't set it backwards.
- **`_yearOrdered` is a RENDER-TIME view of the one cached copy.** `_parseYear` still caches
  rank-ascending; flipping the sort never re-fetches, re-parses or re-resolves. It **copies before
  reversing** — an in-place `reverse` would corrupt the cached arrayref for every later render.
  An unknown/missing mode falls back to best-first rather than rendering an arbitrary order.
- **Applied to the home shelf too**, so it can't disagree with the in-app list. Safe for the
  item_id rule: the order depends on a durable pref, **not on the request quantity**, so the feed
  is still identical at every quantity within a render.
  **REVERSED BY 0.8.8 — and the reasoning above is the wrong invariant.** "Identical within a
  render" is not the item_id contract: a card's item_id is an index path Material re-traverses
  in a SEPARATE, LATER request to play, so the order has to hold ACROSS renders. The shelf is
  now always rank-ordered; the in-app list keeps the toggle. See Status: 0.8.8.
- **No cache bump of any kind** — nothing cached changes shape or content.
- **Tests: +14 in `tools/t_yearlist.pl` (74 total)** — both orders from a deliberately scrambled
  input (proving the order is computed, not inherited from the parse), no entry dropped or
  duplicated, the caller's list left untouched, labels, the toggle's refresh/glyph/live-pref
  advance and its round trip, and a corrupt/unset pref reading as best-first. **Anti-tested**:
  removing the `reverse` fails 1.

## Status: 0.8.0
**0.8.0 (2026-07-31): NEW SECTION — "Best Albums of the Year", Pitchfork's annual top-50,
ranked and playable, back to 2016, promoting each new list automatically.**

**The win is that the item shape is IDENTICAL to a review item.** `_parseYear` emits the same
normalised hash (plus `rank`/`year`), so `_resolveSection`, `_findPlayable`, `_reviewRow`,
`_attachReviewLink` and the whole ListenLater favurl handshake work on it **unchanged** — the
feature is a new parser and a new feed, not a second pipeline. `_streamId` is
`_norm(artist).' '.norm(album)`, so an album that is both a review and a year-list entry
**reuses the cached match for free**.

- **A year-end list is NOT a review listing.** Its entries live in the article BODY prose, not
  in `contentType => 'review'` nodes, so `_walkReviews` cannot see them; `_parseYear` walks
  `transformed.article.body`. One entry is a run of four blocks: a `callout:inset-left`
  inline-embed (the album art), a `heading-h3` div (the rank), an `h2` (artist + album), a `p`
  (the blurb). Title and publication date are **not in the state at all** — they come from the
  page's `og:title` / `article:published_time` meta tags.
- **THREE traps, each hit on real pages, each pinned by a test** (`tools/t_yearlist.pl`):
  1. **Rank comes from DOCUMENT ORDER, never the printed number.** The real 2020 page prints
     "25." twice and never prints 24. The printed digits decide ONE thing — whether the list
     counts down (50→1, the house style) or up — comparing only the first against the last, so
     a single typo cannot flip the direction.
  2. **A heading that is only digits is a RANK MARKER.** The real 2017 page marks one entry's
     rank with an `h2` instead of the `heading-h3` div; without the guard that `h2` is read as
     an entry titled "33." and every following field lands on the wrong record.
  3. **Artist is the text BEFORE the first `<em>`**, and the album runs from that `<em>` to the
     END of the heading. 2024's `["h2","Djrum: ",["em","Meaning's Edge"]," EP"]` has text AFTER
     the album, so "heading minus the album" gives the artist as "Djrum: Meaning's Edge EP".
     Keeping the trailing " EP" on the album is correct — `_stripFmt` already handles it.
- **Slug eras (all verified live).** 2019+ `best-albums-<year>`; 2017–18
  `the-50-best-albums-of-<year>`; 2016 the numeric-prefixed `9980-the-50-best-albums-of-2016`.
  A **future** year is tried under BOTH modern forms before giving up, so a wording change
  doesn't need a plugin update. `YEAR_MIN` is 2016 — older lists use ad-hoc slugs and a
  different body layout.
- **SELF-PROMOTING, and this is the point of `getLatestYear`.** It probes down from the newest
  year that could exist (`_topYear`: from November the current year is worth trying — Pitchfork
  has published Dec 2nd–13th every year since 2016) and remembers the answer via `_latestTtl`.
  **The daily warm re-probes**, so December's list is picked up within hours whether or not
  anyone opens the menu, with no plugin update. The Refresh row forces both the probe and the
  re-parse, so it doubles as a manual "has it landed yet?" button.
- **`_latestTtl` — and the window cap is load-bearing, not a nicety.** Still waiting on the
  current year → hold for `LATEST_WAIT_TTL` (12h). Nothing newer can exist → hold for
  `LATEST_TTL` (30d) **but never past the next publishing window** (`_secsToWindow`, 1 Nov).
  Without that cap the promotion is not deterministic: an answer written in mid-October would
  still be trusted deep into November, so the plugin would not even begin looking until weeks
  after the new list could appear — the exact date depending on nothing but when the cache
  happened to be written. With it, the 12h polling always starts on 1 November, comfortably
  before the earliest observed publication (2 December). Verified over a simulated year:
  Jan–Sep holds 30d, late Oct shrinks to expire exactly at the window edge, 1 Nov switches to
  12h polling, and a 3 Dec publication is picked up and held hard again.
- **`_topYear`/`_secsToWindow`/`_latestTtl` take an injectable `$now`** (defaulting to the real
  clock) purely so the November/December timeline is testable without waiting for December.
- **Deliberately NOT run through `_groupedRows`.** Both grouping modes are meaningless here — a
  year-end list carries **no genre at all** and every entry shares the article's one publication
  date, so week and genre alike collapse to a single divider holding all 50. It renders flat in
  rank order instead, with the rank leading each row label.
- **`_line2` leads with the YEAR, not the date**, on a ranked row: repeating one publication
  date down 50 rows says nothing. The outbound link says **"Read the full list"**
  (`_linkLabel`) — Pitchfork puts **no per-entry review link** in these articles, so promising
  a review the tap won't deliver would be a lie.
- **The rank prefix on the row label is safe for ListenLater.** `&al=` carries the matched
  SERVICE's title (`_svctitle`, set from `$album->{title}` on every matched candidate in all
  three search subs), so LL never falls back to reading Material's label. Reviews (no `rank`)
  are byte-for-byte unchanged.
- **Warm resolves ONLY the latest year.** Older years are immutable and resolve on demand;
  re-matching all ten daily would be 500 albums of pointless streaming traffic. A published
  list never changes, hence `YEAR_TTL` 30d / `YEAR_FB_TTL` 365d against the listing pages' 3h.
- **No `pfr:stream` bump** — purely additive; no existing favurl changes shape.
- **Also: a fourth Material home shelf** (`PFRYear` → `homeYear`), flat whole list per the
  item_id/quantity-stability rule.
- **Verified against LIVE data, not fixtures.** All ten years 2016–2025 fetched and run through
  the REAL `_parseYear`: **500/500 entries clean** — every one with artist, album, cover, blurb
  and a rank, ranks exactly 1..50 with **no duplicate and no hole** in any year, correct #1
  throughout (2020 → Fiona Apple *Fetch the Bolt Cutters*, the year with the printed-rank
  defect), and **zero residual HTML entities**.
- **Tests: `tools/t_yearlist.pl`** — 60 checks against the REAL subs from both API.pm and
  Browse.pm (all three traps, entity decoding, the "Listen/Buy:" affiliate row never being
  mistaken for the blurb, a too-short paragraph skipped, cover selection, ascending lists not
  force-reversed, degenerate input, slug eras, the promotion timeline across a simulated year,
  and the Browse-side rendering that only year rows get). **Anti-tested**: trusting the printed
  rank fails 3, dropping the digits-only heading guard fails 17, taking the album as the `<em>`
  text alone fails 1, removing the entity decode fails 2, removing the window cap fails 1.
  All four prior suites still pass (38/20/24/22).
  **Note the cap anti-test only bit once `_latestTtl` was extracted from `getLatestYear`'s
  closure** — the composed decision was previously unreachable from a test, so it was silently
  uncovered while its two halves both passed.

## Status: 0.7.12
**0.7.12 (2026-07-31): fix — a MATCHED review showed no review text at all.**
Reported in the field: "snippets only show when there's no streaming match", which was
literally true. The capsule lived in exactly one place, `reviewDetail`, and a matched row
**never reaches it** — `_reviewRow` returns the streaming album node instead, whose drill-in
`_attachReviewLink` wrapped with only the "Read the full review" link + a spacer. So the
better a review resolved, the less of it you could read.
- **`_attachReviewLink` now injects the capsule (in full) above the link**: capsule → link →
  spacer → tracks. The row's own `line2` only ever carried a copy truncated to
  `ROW_CAPSULE_MAX` (110).
- **Its guard was also wrong**: `return unless length($link)` meant an item with a capsule but
  no link got nothing attached. Now it attaches if EITHER is present, and each row is pushed
  under its own `length` test.
- **The Pitchfork GENRE is deliberately NOT injected** (`reviewDetail` still shows it). The
  service's tracklist tail already ends in its own `Genre: …` text row, and Material keys
  non-playable plugin rows by parent id + TITLE — two rows both reading "Genre: Pop"
  (Pitchfork's and Qobuz's agreeing, the common case) collide and one silently disappears.
  The genre is on the row's line2 regardless.
- **Verified the "rows above the tracks" worry is NOT the home-shelf item_id trap.** That rule
  is about a SHELF feed's membership varying between renders (the 0.6.1 `hide_unmatched`
  failure); this is a constant prefix inside a CHILD page that already carried two injected
  rows since 0.4.1. Confirmed live over jsonrpc: the Qobuz tracklist already appends its own
  non-audio tail (`Artist` / `Add to favourites` / `Credits` / `Genre` / `Duration` / …) after
  the tracks and playback is unaffected.
- **No `pfr:stream` bump** — the favurl carries nothing new and the wrapper is rebuilt on every
  render (`cachetime => 0`), so the change shows on the next open with no re-resolve.
- **Tests: `tools/t_reviewintro.pl`** — 20 checks against the REAL sub loaded with throwaway
  `Slim::*` stubs (capsule+link, capsule-only, link-only, neither, ARRAY-shaped inner response,
  track order preserved, no injected row is audio, no second `Genre:` row). Anti-tested:
  removing the capsule push fails 14. `perl -c` clean.

**0.7.12 also: HTML entities in Pitchfork's text are now DECODED (`API.pm`).**
Found while checking the above against the live feed: `Sam and Louise Sullivan - Love &amp; Devotion`
was rendering the entity raw. **Not cosmetic** — `_norm` folds `&` to the word "and", so that album
keyed as `love and amp devotion` and could never match the service's `Love & Devotion`; the review
sat permanently unresolved. Surfacing capsules made it worse: `&#8212;` appears in **16 of 133** live
capsules.
- **`_decodeEntities`** — a hand-rolled single-pass decoder (no new dependency; this file already
  hand-rolls its own state scanner). Numeric decimal + hex, plus a table of the named entities
  Pitchfork emits and the common punctuation set. Applied in `_stripTags` (album, capsule) and
  directly to `subHed.name` (artist) and `rubric[].name` (genre) — those are plain fields that skip
  the tag strip, and were clean across 133 live reviews, but one `&` in a band name or `Pop/R&B`
  would poison the matcher identically.
- **Four rules the code depends on, each pinned by a test.** (1) **ONE pass** — `&amp;lt;` must give
  `&lt;`, not `<`; a decode-until-stable loop or a separate `&amp;` substitution double-decodes.
  (2) **Strip tags, THEN decode** — `&lt;em&gt;` is literal text a review meant to show, and
  decoding first turns it into a tag the strip then eats. (3) An **unknown** entity is left VERBATIM
  (never guessed at, never dropped). (4) Controls / surrogates / past-Unicode codepoints are
  **refused** — `chr()` would return something that later breaks the md5 cache key. Also: `&nbsp;`
  decodes to a **plain space**, not U+00A0, because whether `\s` matches U+00A0 depends on the
  string's UTF8 flag, so an edge one would survive the trim on some strings and not others.
- **`pfr:listing|bnm|hsa:3` → `:4`** — those cache the PARSED items, so without the bump the old
  text is served for up to `FEED_TTL` (3h), or `FEED_FALLBACK_TTL` (7d) if a later fetch fails.
  **The `:N` is the parse version — bump it whenever `_parseState` changes what it stores.**
- **No `pfr:stream` bump, deliberately.** `_streamId` is `_norm(artist) . ' ' . _norm(album)`, so a
  decoded title changes its OWN key and re-resolves itself. Measured over all 151 live items:
  **exactly 1 key changes** — the broken one. A blanket bump would re-resolve 150 healthy albums
  for nothing.
- **Verified against live data, not fixtures.** All three listing pages were fetched and parsed
  with the pre-change and post-change `API.pm`, and the two outputs diffed item by item: 151 items,
  identical count / order / `link`, **18 field changes and every one an entity decode**
  (13 capsules, 1 album, 1 title, 3 more capsules), **0 residual entities**, and `cover` / `date` /
  `score` / `genre` / `artist` byte-identical. Live confirmation that the album now resolves needs
  the install (its row's "Refresh streaming match").
- **Tests: `tools/t_entities.pl`** — 38 checks (all four live entity forms, the named table, hex +
  decimal, the one-pass trap, unknown/bare/semicolon-less `&` passthrough, every refused codepoint
  class, `_stripTags` ordering and trimming, and the payoff asserted against the REAL `_norm` from
  Browse.pm). Anti-tested: neutering the decoder fails 23.

**0.7.12 also: a SECOND search leg on the ALBUM TITLE when the artist query finds nothing.**
Field report: "Leo - Cicada Burnt" (Pitchfork, 30 Jul 2026) resolved to nothing. **Measured on the
live server, not guessed:** Qobuz CARRIES it and returns it **first** for the query `cicada burnt`,
while its album search for `leo` returns **200 rows** — Leo Sayer, Léo Ferré, Leo Dan, Leo Kottke,
LiSA's *LEO-NiNE*, even Ludovico Einaudi and Brian Eno — **without it**. `_findPlayable` sends the
raw ARTIST to each service's ALBUM search, so for a common-word artist name the release never enters
the candidate pool and `_albumMatches` is never given the chance to judge it. **A recall gap, not a
matcher gap** — and raising the search limit only moves the cliff (DSC measured that same effect and
recorded it as NOT fixed).
- **`_findPlayable` now runs up to two legs per service.** Leg 1 is the artist, unchanged. If a
  service comes back **DEFINED but EMPTY** — "searched, found nothing" — leg 2 re-queries that same
  service with the **album title**, in that adapter's own encoding (`$qaChars`/`$qaBytes`, the same
  chars-vs-octets split as the artist query). Precision is unaffected: `_albumMatches`' artist gate
  is mandatory, so a generic title like *Home* still has to come back credited to the right act.
- **`undef` is NOT retried.** undef means the service could not be queried at all (no handler /
  timeout / renderer die); a second query would spend another `STREAM_SVC_TIMEOUT` reaching the same
  inconclusive answer. Only a real empty result is a recall answer worth retrying.
- **One retry, ever**, and **each leg arms its own fresh watchdog** (leg 1's is killed first), so
  leg 2 gets a full budget rather than the remains of leg 1's. Worst case per service is therefore
  2 × `STREAM_SVC_TIMEOUT`; the feed's own `BUILD_DEADLINE` (18s) still governs the render, falling
  back to partial + background warm as before.
- **Skipped when it cannot help:** no album title, or the title equal to the artist under `_norm`
  (a self-titled release) — that leg could only repeat the query leg 1 already ran.
- **NO `pfr:stream` bump, and this is a deliberate exception to the "bump on any change" rule.**
  That rule protects FOUND matches, which cache for 7d with the favurl frozen in. What is stale here
  is a **no-match**, TTL 1d — misses retry on their own within a day, and an unmatched row already
  carries "Refresh streaming match" for an instant retry. A found result cannot change, because leg 2
  only runs where a service returned zero matches. Bumping would re-resolve ~150 healthy albums to
  save a 24h wait.
- **Tests: `tools/t_searchlegs.pl`** — 24 checks driving the REAL `_findPlayable` with scripted
  adapters (match settles on one leg; empty retries on the title and that leg's match wins; undef
  never retries; never a third leg; self-titled / empty-title / equal-under-`_norm` skips; per-adapter
  chars-vs-octets on the leg-2 query; priority still decides; a service that matched runs one leg).
  Anti-tested: disabling the leg fails 11. Note the encoding case deliberately uses a title with a
  codepoint above Latin-1 — a string whose codepoints all fit in a byte can sit in Perl without the
  UTF8 flag, and then the chars and octets spellings are identical and would hide an encoding bug.

## Status: 0.7.11
**0.7.11 (2026-07-30): doc-only — three subs' comment blocks had piled up above the wrong sub.**
Found by a code review of the 0.7.10 diff. `_svcYear` + `_stripArtistAffix` were inserted BETWEEN
`_attachFavUrl`'s doc block and `_attachFavUrl` itself, and `_cacheStream`'s block was already
displaced before that — so lines 829–845 were ONE unbroken comment run documenting THREE different
subs, all sitting above `sub _svcYear`, while `_attachFavUrl` (the whole ListenLater favurl
contract) and `_cacheStream` opened with no comment at all. Each block moved back onto its own sub.
- **Code is byte-identical to 0.7.10** — verified by diffing comment-stripped `Browse.pm` against
  the 0.7.10 zip's copy; comment-line count unchanged at 396 (moved, none lost). `perl -c` clean,
  `tools/t_svctitle.pl` 22/22.
- One content edit inside the moved block: the favurl signature line still read
  `[&al=<clean album>]` with no `&y=`, so it now reads `[&al=<service album>][&y=<year>]` to match
  what 0.7.10 actually sends. Leaving it stale directly above the sub is the exact drift 0.7.7 was
  cut to fix in this same file.
- **No `pfr:stream` bump** (stays at `:9:`). The code is byte-identical to 0.7.10, so every cached
  favurl is ALREADY correct — the `_streamKey` rule ("bump on ANY change to what the favurl
  carries") isn't triggered, because it carries exactly what 0.7.10 carried. Flushing would make the
  next open of each list re-resolve every item (`_resolveSection`, concurrency 6, 18s render
  deadline then partial + background warm) for no behavioural gain. Same call as 0.7.4/0.7.9.
- Version bumped rather than folded into 0.7.10 because 0.7.10 was already manually installed and a
  same-version zip won't reinstall — the 0.7.7 precedent exactly.

## Status: 0.7.10
**0.7.10 (2026-07-30): ListenLater handshake — `&al=` now carries the MATCHED SERVICE's album title
(not Pitchfork's), and the favurl gains `&y=` (the release year).**
Ported from the sibling ListenBrainz plugin, which shipped the wrong name **three builds running**
(its 0.9.144–0.9.147) before this was pinned down. Do not re-derive it here — the rule and both traps
are recorded below.

- **THE RULE: once a review is RESOLVED to a service album, the SERVICE's spelling is the only one
  that works.** Two independent consumers are title-keyed: LL's Played auto-detection matches the
  PLAYING track's album title (which the service reports), and LL's `artist|album|year` dedupe key
  must agree with a direct add from that same service. 0.7.6 packed **Pitchfork's** spelling, which
  fixed the "Artist - Album" pollution but left a different mismatch — and Pitchfork's differs often
  enough to matter: it appends `" EP"`/`" LP"` that services drop, which is the entire reason
  `_stripFmt` exists in the matcher. A release stored under a name the service never uses is silently
  unmatchable: it plays perfectly and simply never reaches Played.
- **TRAP 1 — do NOT read the rendered node.** `$it->{name}`/`{line1}` are each streaming plugin's
  DISPLAY LABEL, and they bake the artist in, at opposite ends per service (Qobuz artist-first,
  Bandcamp artist-last). LBF 0.9.145 shipped exactly that. Take the title from the RAW album hash —
  `$album->{title}`, the same field `_albumMatches` already validates against, where the artist is a
  separate argument, so it is the album title alone by construction.
- **TRAP 2 — even the raw title can carry an artist affix**, and the MATCHER never notices, because
  `_albumMatches` accepts a candidate that STARTS WITH our album, so a trailing `" - artist"` sails
  straight through. Hence **`_stripArtistAffix`** (ported byte-identical from LBF 0.9.147 — sha
  `447d1306`; port any change to both). Deliberately conservative: space-padded separator only (so
  `Jay-Z` survives), the discarded side must EQUAL the artist under `_norm` (so `Album - aksfx
  remixes` survives), anything else returned VERBATIM. A missed strip is a wart; a wrong strip
  corrupts the key LL dedupes on.
- **`&y=` (new).** The year is the third segment of LL's dedupe key, so a yearless row keys as
  `artist|album|` and the same album added from a source that supplies a year becomes a second row
  dedupe cannot see. PFR has **never** sent one (there was no year handling in this plugin at all).
  Pitchfork states a REVIEW date, not a release date, so it comes from the matched service's own
  album hash via **`_svcYear`** (ported from LBF; Qobuz `release_date_original`/`released_at` epoch,
  Tidal `releaseDate`, Deezer `release_date`) — which is also the date the service reports at
  playback. `''` when no service states one.
- **Changes:** `_svcYear` + `_stripArtistAffix` added; all three search subs stash
  `_svctitle`/`_year` beside `_albumid`; `_attachFavUrl` takes a 6th `$year` arg and the call site
  passes `$it->{_svctitle}`/`$it->{_year}`. **No fallback at the call site** — with no service title
  we send no `&al=` and LL reads Material's label, which is imperfect but never wrong, whereas the
  wrong string is silently unmatchable. **Bandcamp is not involved** (never ported here).
- **`pfr:stream:8→9`** — the favurl is frozen into the cached item. **Bump on ANY change to what the
  favurl carries, even when the fields keep their shape**; one re-resolve beats a week of silent
  misses aged out of a 7d TTL. (LBF needed four such bumps in one session for want of this rule.)
- **Tests: new `tools/t_svctitle.pl`** — 22 checks against the REAL subs and the REAL `_norm`/`%FOLD`
  chain, split into "must strip" / **"must not strip"** / year extraction. Anti-tested: removing the
  strip fails 7, neutering `_svcYear` fails 3. `perl -c` clean (via throwaway stubs for the `Slim::*`
  tree, which is absent on this Mac — see the note in Server/testing). No matcher change.

## Status: 0.7.9
**0.7.9 (2026-07-29): fix — the settings checkbox was INVISIBLE in Material.**
Fleet-wide (LBF 0.9.122, LL 0.1.73, Album-Booklet 0.1.3, here 0.7.9). Material's settings CSS gives a bare
`<input type="checkbox">` no visible box, so "Extra debug logging" looked like a setting with no control at
all — the pref was there and worked, you just could not see or hit it.
- `settings.html`: the input is wrapped in a `<label>` with a visible "Enabled" caption (new string
  `PLUGIN_PITCHFORKREVIEWS_ENABLED`), which is what Material styles into a real checkbox — and it makes the
  caption itself a click target.
- **Only bug #1 of the pair applies here.** The separate `undef // 1` default trap (an unticked checkbox posts
  NOTHING, so a default-ON pref can never be turned off unless the handler coerces `pref_*` to 0/1) bites
  default-ON toggles; `debug_log` defaults OFF, so this plugin has nothing to coerce.
- No matcher/cache change, so **no `pfr:stream` bump**. Released to `main` as the 0.7.6→0.7.9 rollup.

## Status: 0.7.8
**0.7.8 (2026-07-21): FLEET MATCHER SYNC — a decorative `!` is punctuation, not the letter i; `&`/`+` fold to "and".**
Ported from Discography 0.44.19/0.44.23 where the bug was found in the field. Landed across **DSC / LBF / PFR / SH
in one session**; `matcher_sync_check.py` exits **0**. LL untouched (pinned legacy ASCII `_norm`).
- **`!` folds to a letter only when TOKEN-INTERNAL** (`s/(?<=\w)!(?=\w)/i/g`) — `P!nk` -> `pink` still, while
  `Wham!` / `Panic! At The Disco` / `Godspeed You! Black Emperor` shed the mark. The old unconditional fold made
  a name spelled WITH the mark disagree with the same name WITHOUT it, and since `_albumMatches`' artist gate is
  MANDATORY, every candidate was rejected — on Discography that surfaced as "No releases found" for an artist
  whose MBID had resolved perfectly.
- **`$` and `@` stay UNCONDITIONAL, and THIS FILE'S OWN CASE is why:** scoping them as well broke
  `$uicideboy$` -> `suicideboy`, which no longer matches `Suicideboys` — the example named in `_norm`'s comment
  here. Caught by a cross-repo BEHAVIOURAL harness, not by the sync check, which compares text and would have
  reported four identical copies of the bug.
- **`!!!` still keys `iii`** — a name of nothing but marks keeps the old fold, because `_artistMatch` returns 0
  on an empty side and would reject every candidate.
- **`&` and `+` -> "and"**, same family as `$`->s: one act arriving as "X & Y" and "X and Y" was becoming two rows.
- **`pfr:stream` 7 -> 8**: that cache stores match DECISIONS computed with the old normaliser.

## Status: 0.7.7
**0.7.7 (2026-07-18): doc-only — corrected the `&al=` comment in `_attachFavUrl`.**
The comment claimed `&al=` was packed *"Only when it differs from the artist-prefixed label"*, but the code
adds it unconditionally whenever `$album` is non-empty (same `defined`/`!ref`/`length` guard as `&a=`). No
behaviour change — comment now matches the code. Found by a code review of the 0.7.6 diff. Version bumped
(not folded into 0.7.6) because 0.7.6 was already manually installed, and a same-version zip won't reinstall.

**0.7.6 (2026-07-18): ListenLater interop — pack the CLEAN album title into the favurl as `&al=`.**
Our matched rows label as `"Artist - Album"` (`line1`), and Material forces `$ALBUMNAME`/`$TITLE` to that
whole label for online items — so Listen Later was storing the artist doubled into the album title. That's
NOT cosmetic (the old CLAUDE note was wrong): it broke Listen Later's **Played auto-detection**, which keys on
the album name (the polluted "Will Sheff - Extra Mile" never matches the playing track's clean "Extra Mile"),
and showed doubled in its list. `_attachFavUrl` now packs the clean review album as a private `&al=` param —
the symmetric partner of the `&a=` artist it already packs (both exist because Material sends these rows no
clean `$ALBUMNAME`/`$ARTISTNAME`). Listen Later 0.1.71 reads `&al=` and prefers it over the label, then strips
it (plus a one-off DB migration cleaning rows already saved). No matcher change — `_attachFavUrl` is outside
the shared engine, and the row's own display (line1 = "Artist - Album") is unchanged. `pfr:stream:6→7` so
existing cached matches re-resolve and gain `&al=` (the favurl is frozen into the cached item). `perl -c` clean.

**0.7.5 (2026-07-11): matcher — self-titled-album rule (fleet sync from Discography 0.11.1).**
When an album's title normalises to the ARTIST name ("The Beatles", "Weezer"), `_albumMatches` now
matches on the EXACT normalised title only, skipping the prefix/format/ascii/artist-prefix fallbacks —
so a self-titled release stops swallowing "The Beatles 1962-1966" (Red), "…1967-1970" (Blue),
"…Anthology 1". `_norm` still strips brackets, so "(White Album)"/"(Remastered)" still match; a wrong
artist on an exact title still fails. Applied byte-identical to LBF + DSC + PFR (checker
`_albumMatches` hash `7462b60e053d`) and, adapted, to LL's pinned variant; `matcher_sync_check.py`
exits 0. `pfr:stream:5→6` flushes cached matches. `perl -c` clean; validated by the shared 14-assertion
matcher test (LBF/PFR share identical code). (Sibling bumps: LBF 0.9.90, LL 0.1.70.)

**0.7.4 (2026-07-10): fix — the settings page rendered STALE service priorities after a save.**
`pfr_services` (which carries each service's CURRENT priority into the template) was built in
`handler()` **before** `SUPER::handler` persists the POST, so saving a new priority re-rendered
the page with the old number still in the input — the save HAD applied, but only a reload showed
it. Moved to **`beforeRender`**, the platform's documented post-save hook: `Slim::Web::Settings::handler`
persists each pref, refreshes its own `prefs` template var from the store, and only then calls
`beforeRender($paramRef, $client)` immediately before rendering. **RULE (fleet-wide): any Settings
template variable derived from a pref MUST be built in `beforeRender`, never in `handler` before
`SUPER::handler`;** sanitising the incoming `$params->{pref_*}` still belongs in `handler`. Found
via a code review of the Discography plugin, whose `Settings.pm` was ported from this one — so the
defect came with the port. Fixed in all three the same session (DSC 0.10.4, LBF 0.9.85). No
matcher/cache change, so **no `pfr:stream` bump**.

**0.7.3 (2026-07-10): matcher fallbacks ported from the Discography plugin.**
(1) All-punctuation / single-char titles ("( )", "X"): compare `_punctNorm` (lc,
whitespace stripped, punctuation kept) of the RAW titles when `_norm` erases them —
exact equality only + mandatory artist gate; raw title threaded as trailing `$albumRaw`
through the 3 adapter signatures. (2) Artist-name-prefixed titles (`_stripArtistPrefix`
both sides, >=3-char remainder). Existing EP/LP-strip and ascii fallbacks untouched
(re-verified). `pfr:stream:4->5` flushes cached no-matches.

**0.7.2 (2026-07-10): per-adapter search-query encoding fix** (ported from the
Discography plugin's Sigur Rós diagnosis). `_findPlayable` octet-encoded the outgoing
artist query for every adapter, but Qobuz (`uri_escape_utf8`) and Tidal
(`Text::Unidecode` transliterate) expect CHARACTER strings — octets double-encode
("Sigur Rós" searched as "Sigur RÃ³s" -> junk/empty results); Deezer's
`complex_to_query` wants octets and was unaffected. Adapters now carry
`query_enc => 'chars'|'bytes'` and `_findPlayable` builds both spellings, picking per
adapter. `pfr:stream:3->4` flushes decisions resolved via mangled queries.

Working end to end (page-state parse, streaming resolve to Qobuz/Tidal/Deezer,
genres, week/genre dividers, grid view, ListenLater favurl handshake, branded section
tiles + Settings cog, "Read the full review" reachable on matched rows too,
Material home shelves with a background warm). Settings: `svc_priority_*`
(rendered dynamically from `Browse::serviceStatus` — each service shown
installed/not-installed with its priority input, ported from LBF),
`group_by` (0.5.0: `'genre'` = `_genreRows` groups by
PRIMARY Pitchfork genre, or `'date'` = weekly dividers via `_weeklyRows` —
`_groupedRows` dispatches; genres ordered newest-review-first, newest-first within
each; both modes share `_divHeader`, whose divider icon is the Pitchfork
`HEADER_ICON`. **0.7.1: grouping applies to ALL THREE browse lists** (Best New Music,
High Scoring Albums, Latest Reviews) — the one `group_by` setting drives every one;
BNM/HSA are no longer flat (their home shelves stay flat, see below).
**Genre-split fix (0.5.3):** `_genreKey` splits the display `genre` on the ` / ` JOIN
delimiter only — `m{\s+/\s+}`, spaces REQUIRED — because Pitchfork's own genre NAMES
contain a bare slash (`Pop/R&B`, `Folk/Country`). The old `m{\s*/\s*}` split inside
those names, so "Pop/R&B" bucketed/labelled as "Pop" and "Folk/Country" as "Folk".
**Divider-icon gotcha (0.5.2):** Material renders an icon on a `header`/`header-basic`
divider ONLY when the `image` is the **`_svg.png`** Material-recolour form (or an
`_MTL_*` icon) — a plain `.png` is IGNORED on a header (it's drawn on normal rows but
not headers). 0.5.0/0.5.1 used the plain `PitchforkReviewsIcon.png` on the divider, so
the logo never showed; 0.5.2 uses `HEADER_ICON` = `PitchforkReviewsIcon_svg.png` (theme-
recoloured, `#000`-based SVG), matching LBF whose dividers use its `…Icon_svg.png`.
`LOGO_ICON` (the full-colour raster) stays on the "Read the full review" row (a normal
row, where a plain png renders fine).
Settings uses **radio buttons** not a `<select>` — Material doesn't always render a
dropdown right. **Default is `'genre'`** (confirmed shipping default, user decision
2026-07-08) so a fresh install shows genre grouping; NB `prefs->init` won't overwrite an
existing pref, so an install that already saved `group_by` keeps its value. Grouping is
read live per render (`_groupedRows`) and the feed is `cachetime => 0`, so a settings
change shows on the next re-open of the list — no restart, no cache wait),
`debug_log` (0.4.4: now actually wired — `Plugin::dbg`
mirrors the resolve timeline to server.log at INFO always, and to a size-capped
`pfr-debug.log` when on; `Browse::_dbg` is the alias, ported from LBF). **Icon:** the
Pitchfork round mark, generated to spec — `PitchforkReviewsIcon.svg` (geometric
ring in `#000` so Material recolours it per theme; the arrows are the embedded
Pitchfork-red raster) plus `PitchforkReviewsIcon_svg.png` (install.xml ref /
non-Material fallback) and `PitchforkReviewsIcon.png`, both real transparent PNGs.
Source art is the user-supplied `Pitchfork_Media_(logo).png`; the icon builder is
ad-hoc (measure ring radii + extract the red arrows in Pillow), not committed. On
EVERY zip rebuild: bump the version (install.xml + repo.xml) AND recompute the sha
(`shasum -a 1 PitchforkReviews.zip`).

## File Structure
```
PitchforkReviews/
├── Plugin.pm    # OPMLBased entry point; prefs; log category
├── API.pm       # Async Pitchfork page-state (Verso __PRELOADED_STATE__) fetch + parse + caching
├── Browse.pm    # Browse feeds (top level, per-source feed, review detail) + the album streaming resolver + home-shelf feeds (homeBnm/homeHsa/homeReviews)
├── HomeExtras.pm # Material Skin home-page shelves (0.6.0; PFRHsa added 0.7.0): PFRBnm + PFRHsa + PFRReviews HomeExtraBase subclasses
├── Settings.pm  # Streaming-service priorities + debug-log toggle
├── strings.txt  # EN strings
├── install.xml  # <extension> (singular — manual-install format)
└── HTML/EN/plugins/PitchforkReviews/settings.html
repo.xml         # <extensions> (plural — repo-install manifest)
```

## Architecture
- **Sources** (`API.pm`, page-state parser — reworked 0.2.0): all three sources
  (Latest Reviews, Best New Music, High Scoring Albums) parse
  the listing pages' embedded Verso state `window.__PRELOADED_STATE__`, NOT the RSS
  feed or ld+json. `_parseState`: `_extractState` (string/escape-aware brace scan) →
  `from_json` → `_walkReviews` collects nodes with `contentType=="review"` → per
  item: **artist = `subHed.name`** (clean, no derivation), album = `dangerousHed`
  (strip tags), capsule = `dangerousDek`, date = `pubDate` (ISO), cover =
  `image.sources`, link = `url`, score = `ratingValue.score`, genre = `rubric[].name`
  (a list — deduped + joined " / "; the odd review has none). `getListing()` =
  `/reviews/albums/` (capped 30 ≈ last 2 weeks), `getBnm()` = `/reviews/best/albums/`
  (all items on that page ARE the BNM picks — the `isBestNewMusic` JSON flag is
  unreliable/false even there). `getHsa()` = `/reviews/best/high-scoring-albums/`
  (another curated page whose items ARE the picks, uncapped like BNM). Cached
  `pfr:listing:4` / `pfr:bnm:4` / `pfr:hsa:4` (3h + 7d fallback) — **the `:N` is the PARSE
  version: bump all three whenever `_parseState` changes what it stores, or the old text is
  served for up to 3h (7d if a later fetch fails).** `from_json` yields proper characters (no
  mojibake), and **0.7.12** decodes HTML entities on top (`_decodeEntities`, applied via
  `_stripTags` to album/capsule and directly to artist/genre — `&amp;` in a title was
  silently unmatchable, see Status). Score is available
  but not displayed yet; full review text is never stored (linked out — copyright).
- **Menu** (`Browse.pm`): top = Best New Music + High Scoring Albums + Latest Reviews
  + Plugin Settings.
  The three feed tiles carry **branded section covers** (`menu-best-new-music.png` /
  `menu-high-scoring-albums.png` / `menu-latest-reviews.png` — light card + the red
  Pitchfork mark + bold title + red
  accent bar, generated by `tools/make_covers.py` from the shipped app icon); Plugin
  Settings uses the **cog** font-icon `pfr-cog_MTL_icon_settings.png` (Material
  `_MTL_icon_settings` convention, same as LBF). The list row's `line2` separator is a
  middle dot via a **double-quoted** `"\x{b7}"` — a single-quoted `'\x{b7}'` prints the
  literal escape (the 0.4.0 "odd text before the genre" fix).
  All three browse lists are divided by Material headers — by week (`pubDate`
  grouped) or by **genre** (`group_by` pref → `_genreRows`, primary Pitchfork
  genre; genre is the default). **0.7.1:** the three source tiles share ONE feed —
  `fetchFeed`, dispatched by `$pt->{source}` ('bnm'|'hsa'|'reviews') threaded
  through `_feedTile` (which also threads `features` so headers render) — so BNM
  and High Scoring Albums group exactly like Latest Reviews. (`fetchBnm`/`fetchHsa`
  removed; note BNM's curated ranking order is not preserved once grouped.) Divider
  headers carry the Pitchfork `LOGO_ICON`. Each list open
  resolves every item to streaming **during the build**
  (`_resolveSection`, bounded concurrency 6, 18s render deadline then partial +
  background cache-warm). All dynamic feeds return `cachetime => 0`.
- **Home shelves** (`HomeExtras.pm` + `Browse::homeBnm`/`homeHsa`/`homeReviews`, 0.6.0;
  hardened 0.6.1; third shelf 0.7.0): registered in `Plugin::postinitPlugin` (guarded on MaterialSkin +
  `->can('registerHomeExtra')`, quiet no-op otherwise), three `HomeExtraBase`
  subclasses `PFRBnm`/`PFRHsa`/`PFRReviews`. **Critical rule (ported from LBF's 0.6.11
  lesson):** a home-shelf feed MUST be a FLAT card list — NO Refresh row, NO
  week/genre dividers — and must NOT vary by request quantity. Material uses the
  same feed for the carousel and its "show all" click-in and re-traverses by
  `item_id` at quantity 1 for playback; a header at index 0 (or any change in the
  set of rows) shifts every card's `item_id` and breaks deep streaming playback.
  So the home feeds map `_reviewRow` over the WHOLE flat list — every review,
  matched or not (never `_groupedRows`/`_refreshRow`). **0.6.1 removed the
  `hide_unmatched` filter entirely** (and its `_visibleItems` helper): filtering to
  matched-only made list membership vary as the resolver cache filled, so the
  carousel render and the play re-traversal saw different item_ids — the exact
  0.6.11 failure. **Background warm (0.6.1, `Browse::warmCache`):** the per-item
  resolve is pre-warmed by `Plugin::postinitPlugin`'s warm (`WARM_DELAY` 150s after
  boot — staggered past LBF's 60s — then daily via `_warmTick`, deferred while
  `Slim::Music::Import->stillScanning`), so on a warm cache the home build is all
  cache hits and returns immediately instead of making Material wait out an 18s live
  resolve (which it can time out on → empty/hung shelf, the reason LBF never
  resolves inside its home feeds). `warmCache` resolves getListing, getBnm, then
  getHsa sequentially via `_resolveSection`, using the first connected player for the
  streaming API context (a no-op with no player). Cold cache still resolves during
  the build (degrades to the browse-list behaviour).
- **Rows** (`_reviewRow`): a MATCHED item renders as the streaming album node —
  **playable from the list, with the service's album artwork** — relabelled to the
  review "Artist - Album" + capsule (override `line1`/`line2`/`name`: Material
  prefers `line1` over `name`). Its tracklist drill-in is **wrapped** (`_attachReviewLink`)
  so drilling in shows the **review capsule in full** and a **"Read the full review"**
  weblink above the tracks, while the
  row stays a `type => 'playlist'` node — Play/Add from the list still queue the album,
  and every injected row is non-audio so play traversal skips them. (0.4.1 fix: matched
  rows were pure album nodes, so tapping went straight to the tracklist and the review
  link was unreachable — the one place it lived, `reviewDetail`, is only hit by UNMATCHED
  rows. **0.7.12** finished that job: the capsule was still `reviewDetail`-only, so the
  better a review resolved, the less of it you could read.) The list row's line2 is "date · genre - capsule" and the detail page shows a
  "Genre: …" line. Image priority: native album cover → Pitchfork cover → service logo.
  UNMATCHED items keep the Pitchfork cover and drill to `reviewDetail` (capsule + Read
  review + "Refresh streaming match" which force-re-resolves past the cache). Every row (incl. the Refresh row and week headers) carries an image, or
  Material disables the grid/thumbnail view for the whole page. The Refresh row uses
  the same Material refresh glyph as LBF (`html/images/pfr-refresh_MTL_icon_refresh.png`,
  copied from the sibling plugin).
- **Resolver** (`_findPlayable` + friends): port of the ListenBrainz album engine.
  Search the ARTIST on each enabled service (RAW query — normalisation breaks
  stylised names) and, **since 0.7.12, the ALBUM TITLE as a second leg when a service
  returns an empty result** (a common-word artist name like "Leo" buries the release
  past any search cap — see Status; `undef`/inconclusive is never retried), filter by
  `_albumMatches`, render via the service's own
  `_albumItem`/`_renderAlbum`. Parallel, per-service watchdog, highest-priority match
  wins. Cache `pfr:stream:3:<svc-order>:<id>` (7d found / 1d no-match / 1h
  inconclusive), keyed by the service set so a config change re-matches.
  - **Matching** (`_norm`/`_albumMatches`/`_artistMatch`, ported ~verbatim — keep in
    sync with LBF): `_norm` folds diacritics AND stylised chars (`$`→s, `€`→e, `£`→l,
    `¥`→y, `!`→i, `@`→a) so "WOR$T"=="Worst", "P!nk"=="Pink". `_albumMatches` also has
    an `_asciiNorm` fallback for decorative non-ASCII glyphs that differ between
    sources (Pitchfork "3x6x𐕣" vs Qobuz "3x6x*"): compare with non-ASCII stripped,
    gated to titles that still have ASCII content so genuine CJK/Cyrillic titles keep
    the strict compare and can't false-match. `_stripFmt` gives a third fallback for
    the trailing FORMAT descriptor Pitchfork appends ("… EP"/"… LP") that streaming
    services drop from the title (Pitchfork "Songs From a Valley Girl EP" vs Qobuz
    "Songs From a Valley Girl"): re-compare with a trailing standalone `ep`/`lp` token
    removed from both sides, gated to a ≥3-char base. **Known unfixable miss:** an
    album Pitchfork spells out but the service abbreviates to an initialism (Pitchfork
    "LIVING TYPE DANGEROUS Vol. 1" vs streaming "LTD Vol.1") — an acronym match would
    false-match wildly, so it's left as an accepted miss.

### Services & the streaming cache round-trip (IMPORTANT)
**Qobuz + Tidal + Deezer** (Bandcamp not ported — manual/loop-blocking). Priorities on
the settings page (`svc_priority_qobuz|tidal|deezer`; 0 = never; lower = searched
first). **The subtle bit — album nodes carry a CODEREF `url` that Storable can't
serialise, so it's stripped on cache and reattached per service on read:**
- All three services (Qobuz/Tidal/**Deezer**) are the SAME shape. Their `_albumItem` /
  `_renderAlbum` sets `url => <coderef>` (the browse-into-tracks handler) and keeps the
  native album id in `passthrough` (plain data — survives the cache). `_cacheStream`
  does an unconditional `delete $x{url}`; `_rebuildStreamItems` reattaches the coderef
  by `_svc`: Qobuz→`QobuzGetTracks`, Tidal/**Deezer**→`getAlbum` (the passthrough id
  drives it). An item whose service is no longer enabled is dropped.
- **Deezer is NOT special** — the `deezer://album:<id>` string is its `play`/favourites
  value, NOT the browse `url` (which is `\&getAlbum`, verified against
  michaelherger/lms-deezer). Earlier notes here (and the sibling LBF plugin) wrongly
  treated it as a plain-string url; the real bug was simply that a service with no
  `_rebuildStreamItems` branch falls through to `else { next }` and its cached matches
  **silently vanish on re-read**. LBF had exactly this Deezer gap — fixed there too
  (LBF 0.9.76) by adding the same `getAlbum` reattach branch.
- **Rule for porting more services:** if a service's album node has a coderef `url`, it
  MUST have both a `_rebuildStreamItems` reattach branch AND its browse-coderef method
  (`getAlbum`/equiv) in the adapter-registration `->can` guard, or cached matches drop.
  (0.4.5 fix: the Qobuz adapter guard was missing `QobuzGetTracks` — its reattach method —
  so a Qobuz build lacking that method would register, cache matches, then silently drop
  them on re-read. Now gated on `QobuzGetTracks` alongside `_albumItem`/`getAPIHandler`,
  matching Tidal/Deezer.)

### ListenLater interop — the favorites_url handshake (IMPORTANT)
Adding a matched album to the **Listen Later** plugin (its Material "Add to Listen Later"
custom action) needs the row to carry an explicit **`favorites_url`**. Without one, a Qobuz
match carries no native favurl and XMLBrowser leaks the coderef `url` through as
`presetParams.favorites_url` (= `favorites_url || play || url`) → Listen Later sees a broken
link, can't tell the service, and can't replay. (Tidal/Deezer nodes DO carry a native favurl,
but the form Listen Later replays cleanly is the explicit one below.)
- Fix (0.3.3, ported from LBF `_attachFavUrl`): each search sub stashes `_albumid = $album->{id}`;
  the `_findPlayable` settle loop then sets `favorites_url = <scheme>://album:<id>?cover=<art>&a=<artist>`
  (`scheme` = lc service = Listen Later's `qobuz`/`tidal`/`deezer` source tag). Listen Later reads
  the scheme as the source, `album:<id>` for direct replay, and strips the private `?cover=`/`&a=`
  params (artwork + artist) before saving.
- **Why `&a=` (artist) and `&al=` (clean album):** Material sends these matched rows **no clean
  `$ARTISTNAME`/`$ALBUMNAME`** — the row's `line1` is `"Artist - Album"` and Material forces both
  `$ALBUMNAME` and `$TITLE` to that whole label for online items, and the subtitle (`$ARTISTNAME`) is the
  date/genre/capsule. So the favurl carries the clean pieces: `&a=<artist>` and (0.7.6) `&al=<album>`.
  Listen Later reads `&a=` as the artist fallback and PREFERS `&al=` over the `"Artist - Album"` label,
  then strips both. `?cover=` carries the native album art.
- **0.7.10 SUPERSEDES the `&al=` SOURCE described below.** `&al=` now carries the MATCHED SERVICE's
  album title (raw hash, artist affix stripped), not Pitchfork's, and the favurl also carries `&y=`.
  The 0.7.6 reasoning about WHY the param exists is still correct; only the value changed. See
  "Status: 0.7.10" for the rule and the two traps.
- **Why `&al=` matters (0.7.6):** without it, Listen Later stored the album title WITH the artist prefixed
  ("Will Sheff - Extra Mile"). NOT cosmetic — it broke Listen Later's **Played auto-detection** (it keys on
  the album name, so the polluted title never matched the playing track's clean "Extra Mile") and showed
  doubled in its list. Fixed in `_attachFavUrl` (pack `&al=`) + Listen Later 0.1.71 (read+prefer it, plus a
  one-off migration for already-saved rows). The row's own display (line1 = "Artist - Album") is unchanged.
- Survives the stream cache (`favorites_url`/`_albumid` are plain strings — only the coderef `url`
  is stripped). The favurl is built during the fresh resolve and frozen into the cached item, so a cache HIT
  serves the stored favurl as-is — the stream cache version is bumped **`pfr:stream:6`→`:7`** at 0.7.6 so
  existing cached matches re-resolve and gain `&al=` (rather than serving the old favurl for up to 7d).
  Replay is by `album:<id>`, so playback was always the right album regardless.

## Roadmap
- **v1 (this)** — Pitchfork, feed-only, resolve to Qobuz/Tidal.
- **v2 — AllMusic.** Confirmed reachable in pure Perl (a browser-UA GET returns
  200; no JS challenge). Needs a listing scrape of `/newreleases` + a click-in
  scrape per album for the star rating + capsule. Heaviest source — cache hard,
  low request rate, isolate the HTML selectors in one place. Same UA constant as
  `API.pm`. Reuse the exact same resolver (artist/album → playable).
- Later polish (from the sibling plugin's playbook): ~~Material home shelf~~ (done,
  0.6.0), ~~a background warm to pre-resolve~~ (done, 0.6.1), richer detail page.

## Conventions (shared with the plugin fleet)
- `<extension>` (singular) in install.xml for manual installs; `<extensions>`
  (plural) in repo.xml. A `dev` branch mirrors main, differing only in repo.xml
  `<url>` (main = GitHub Pages, dev = raw). A `v<version>` tag per release.
- Bump version + recompute sha on EVERY zip rebuild.
- Icon: `_svg.png` Material-recolour convention; SVG must use `#000` (3-digit).
- **Settings template vars belong in `beforeRender`, not `handler`.** `Slim::Web::Settings::handler`
  persists the POSTed prefs, refreshes `$params->{prefs}` from the store, and THEN calls
  `beforeRender($params, $client)` before rendering. A pref-derived template var built earlier is
  read PRE-save, so a save shows stale values. Sanitise `$params->{pref_*}` in `handler`; build
  template vars in `beforeRender`. (0.7.4)

## GitHub Pages docs (README.html / index.html)
`README.html` and the `index.html` redirect are **generated** from `README.md` by
`tools/make_readme_html.py` (zero-dependency Markdown→HTML; ported verbatim from the
sibling Listen Later / ListenBrainz plugins). The version badge is read **live from
`PitchforkReviews/install.xml`** — never hardcode it. The intro paragraph becomes the hero
tagline; the first `## ` section onward becomes the body; the **"Features at a glance"**
table renders as cards, other tables as styled tables. **Re-run `python3
tools/make_readme_html.py` after editing `README.md` or bumping the version.** These are
docs only — **NOT in the plugin zip**, so editing them needs no zip rebuild / sha bump.
`install.xml <homepageURL>` (the Manage Plugins "more info" link) points at the Pages
`README.html`. GitHub Pages serves the repo root, so `index.html` → `README.html` and the
`PitchforkReviews.zip`/`repo.xml` links resolve at the Pages URL.

## Server / testing
Test over HTTP against the hostname (works on/off network): `http://plex:9000`
(log.txt, jsonrpc.js). JSON-RPC menu queries need a player MAC. Manual install
mirrors the ListenBrainz plugin (unzip into the Plugins dir, chown
`squeezeboxserver:nogroup`, restart). Do NOT git commit/push without explicit OK.

## Shared Matching Engine — FLEET SYNC RULE (2026-07-10)

The artist/album/track matcher (`_norm`, `%FOLD`, `_artistMatch`, `_albumMatches`,
fallback helpers `_stripFmt`/`_asciiNorm`/`_punctNorm`/`_stripArtistPrefix`; LBF also
`_trackMatches`) is ONE engine with a copy in each of these four repos:

- `LMS-ListenBrainz-New-Releases/ListenBrainzFreshReleases/Browse.pm` (origin, canonical)
- `LMS-Pitchfork-Reviews/PitchforkReviews/Browse.pm`
- `LMS-Discography/Discography/Sources.pm`
- `LMS-Listen-to-Later/ListenLater/Sources.pm` (hash-pinned LENIENT variant — empty-artist
  saved-item replay must still match; do NOT blindly align it)

**THE RULE: a matching fix in ANY of these repos must be applied to ALL repos carrying the
affected sub, in the SAME work session.** Enforcement — this must exit 0 before any matcher
change is called done:

    python3 LMS-ListenBrainz-New-Releases/tools/matcher_sync_check.py

It diffs the comment-stripped CODE of every copy across all four repos. Deliberate variants
are sha1-pinned inside the script with a reason, and FAIL the check if they change without a
conscious re-pin (`--print-hashes` prints current hashes). After aligning: bump every touched
repo's plugin version AND its match/decision cache versions (LBF: `lbf:stream` + `lbf:track` +
`lbf:pl:resolved` — ALL layers; PFR: `pfr:stream`; DSC: `dsc:cand` only if the cached candidate
shape changed — matching runs live there; LL: none — matching is live), rebuild zips + repo.xml
sha. Never leave a matcher fix in one repo "to port later" — that is exactly how the 2026-07
drift happened (LBF missed the P!nk/EP/ascii rules for months).

## Streaming service search & debugging — CANONICAL REFERENCE (don't re-derive)

The Qobuz/Tidal/Deezer search API is the SAME across the four streaming-resolver plugins (PFR, LBF,
Discography, Listen-to-Later). **Full verified signatures live in `LMS-Discography/CLAUDE.md`
("Service Plugin APIs — VERIFIED SIGNATURES") and the `[[service-search-and-debug]]` memory** — the
authoritative table, kept from upstream source. Don't guess these; they break silently. Two gotchas
that cause empty/junk pools:
1. **Envelope: ONLY Qobuz hands back the whole result hash** (`{artists}{items}`/`{albums}{items}`);
   Tidal & Deezer unwrap `{data}` themselves → plain ARRAY.
2. **Query encoding differs** (`query_enc`): Qobuz + Tidal want a CHARACTER string, Deezer wants
   BYTES. Feeding octets to Qobuz/Tidal double-encodes accents → junk/0 results (fixed 2026-07-10).

**HOW TO DEBUG A SEARCH (the canonical method — stop trying variants each session):**
1. `["pref","plugin.pitchforkreviews:debug_log","1"]` (via jsonrpc).
2. Fire the feed once (Material, or a jsonrpc menu query with a player MAC from `["players",0,20]`).
3. **Read the log over HTTP:** `curl -s http://plex:9000/log.txt` and grep the plugin prefix — the
   key line names each service's candidate-pool size + samples. Empty pool = service search returned
   nothing (encoding/availability); healthy pool + no match = a matcher gap.
4. Turn `debug_log` back off. Test the MB mirror directly with a `curl` to `plex:5000/ws/2/…`
   ([[mb-mirror-search-index-gotcha]]); test the library with `["artists",…,"search:NAME"]`.


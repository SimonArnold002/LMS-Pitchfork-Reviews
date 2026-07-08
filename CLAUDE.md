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

## Naming
Repo `LMS-Pitchfork-Reviews`; plugin/package/dir `PitchforkReviews`
(`Plugins::PitchforkReviews::*`); prefs `plugin.pitchforkreviews`; command tag
`pitchforkreviews`; cache prefix `pfr:`; zip `PitchforkReviews.zip`; display name
"Pitchfork Reviews" with two feed tiles "Best New Music" + "Latest Reviews". (The
`arv:`/`AlbumReviews` names were the pre-rename identifiers — fully retired.)

## Status: 0.5.3
Working end to end (page-state parse, streaming resolve to Qobuz/Tidal/Deezer,
genres, week/genre dividers, grid view, ListenLater favurl handshake, branded section
tiles + Settings cog, "Read the full review" reachable on matched rows too,
optional "hide non-playable reviews" filter). Settings: `svc_priority_*`
(rendered dynamically from `Browse::serviceStatus` — each service shown
installed/not-installed with its priority input, ported from LBF),
`hide_unmatched` (default 0 — when on, `_visibleItems` keeps only rows with a
resolved `_album`; a still-resolving item at the render deadline is hidden until
the warm fills the cache), `group_by` (0.5.0: `'genre'` = `_genreRows` groups by
PRIMARY Pitchfork genre, or `'date'` = weekly dividers via `_weeklyRows` —
`_groupedRows` dispatches; genres ordered newest-review-first, newest-first within
each; both modes share `_divHeader`, whose divider icon is the Pitchfork
`HEADER_ICON`; Latest Reviews only — BNM stays flat.
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
├── Browse.pm    # Browse feeds (top level, per-source feed, review detail) + the album streaming resolver
├── Settings.pm  # Streaming-service priorities + debug-log toggle
├── strings.txt  # EN strings
├── install.xml  # <extension> (singular — manual-install format)
└── HTML/EN/plugins/PitchforkReviews/settings.html
repo.xml         # <extensions> (plural — repo-install manifest)
```

## Architecture
- **Sources** (`API.pm`, page-state parser — reworked 0.2.0): both sources parse
  the listing pages' embedded Verso state `window.__PRELOADED_STATE__`, NOT the RSS
  feed or ld+json. `_parseState`: `_extractState` (string/escape-aware brace scan) →
  `from_json` → `_walkReviews` collects nodes with `contentType=="review"` → per
  item: **artist = `subHed.name`** (clean, no derivation), album = `dangerousHed`
  (strip tags), capsule = `dangerousDek`, date = `pubDate` (ISO), cover =
  `image.sources`, link = `url`, score = `ratingValue.score`, genre = `rubric[].name`
  (a list — deduped + joined " / "; the odd review has none). `getListing()` =
  `/reviews/albums/` (capped 30 ≈ last 2 weeks), `getBnm()` = `/reviews/best/albums/`
  (all items on that page ARE the BNM picks — the `isBestNewMusic` JSON flag is
  unreliable/false even there). Cached `pfr:listing:3` / `pfr:bnm:3` (3h + 7d
  fallback). `from_json` yields proper characters (no mojibake). Score is available
  but not displayed yet; full review text is never stored (linked out — copyright).
- **Menu** (`Browse.pm`): top = Best New Music + Latest Reviews + Plugin Settings.
  The two feed tiles carry **branded section covers** (`menu-best-new-music.png` /
  `menu-latest-reviews.png` — light card + the red Pitchfork mark + bold title + red
  accent bar, generated by `tools/make_covers.py` from the shipped app icon); Plugin
  Settings uses the **cog** font-icon `pfr-cog_MTL_icon_settings.png` (Material
  `_MTL_icon_settings` convention, same as LBF). The list row's `line2` separator is a
  middle dot via a **double-quoted** `"\x{b7}"` — a single-quoted `'\x{b7}'` prints the
  literal escape (the 0.4.0 "odd text before the genre" fix).
  Reviews are divided by Material headers — by week (`pubDate` grouped, default) or
  by **genre** (`group_by` pref → `_genreRows`, primary Pitchfork genre); BNM is a flat
  curated list. Divider headers now carry the Pitchfork `LOGO_ICON`. Each list open
  resolves every item to streaming **during the build**
  (`_resolveSection`, bounded concurrency 6, 18s render deadline then partial +
  background cache-warm). All dynamic feeds return `cachetime => 0`.
- **Rows** (`_reviewRow`): a MATCHED item renders as the streaming album node —
  **playable from the list, with the service's album artwork** — relabelled to the
  review "Artist - Album" + capsule (override `line1`/`line2`/`name`: Material
  prefers `line1` over `name`). Its tracklist drill-in is **wrapped** (`_attachReviewLink`)
  so drilling in shows a **"Read the full review"** weblink above the tracks while the
  row stays a `type => 'playlist'` node — Play/Add from the list still queue the album,
  and the injected weblink is non-audio so play traversal skips it. (0.4.1 fix: matched
  rows were pure album nodes, so tapping went straight to the tracklist and the review
  link was unreachable — the one place it lived, `reviewDetail`, is only hit by UNMATCHED
  rows.) The list row's line2 is "date · genre - capsule" and the detail page shows a
  "Genre: …" line. Image priority: native album cover → Pitchfork cover → service logo.
  UNMATCHED items keep the Pitchfork cover and drill to `reviewDetail` (capsule + Read
  review + "Refresh streaming match" which force-re-resolves past the cache). Every row (incl. the Refresh row and week headers) carries an image, or
  Material disables the grid/thumbnail view for the whole page. The Refresh row uses
  the same Material refresh glyph as LBF (`html/images/pfr-refresh_MTL_icon_refresh.png`,
  copied from the sibling plugin).
- **Resolver** (`_findPlayable` + friends): port of the ListenBrainz album engine.
  Search the ARTIST only on each enabled service (RAW query — normalisation breaks
  stylised names), filter by `_albumMatches`, render via the service's own
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
- **Why `&a=` (artist):** Material sends these matched rows **no `$ARTISTNAME`** (their subtitle
  is the date/genre/capsule, not the artist), so the review artist is packed into the favurl; Listen
  Later uses it as the fallback when `$ARTISTNAME` is empty. `?cover=` carries the native album art.
- Survives the stream cache (`favorites_url`/`_albumid` are plain strings — only the coderef `url`
  is stripped). Stream cache key bumped `:2:`→`:3:` so existing cached matches re-resolve and gain
  the favurl. NB: `$ALBUMNAME` is the row's `line1` = "Artist - Album", so Listen Later stores that
  as the album name (cosmetic; replay is by `album:<id>`, so it still plays the right album).

## Roadmap
- **v1 (this)** — Pitchfork, feed-only, resolve to Qobuz/Tidal.
- **v2 — AllMusic.** Confirmed reachable in pure Perl (a browser-UA GET returns
  200; no JS challenge). Needs a listing scrape of `/newreleases` + a click-in
  scrape per album for the star rating + capsule. Heaviest source — cache hard,
  low request rate, isolate the HTML selectors in one place. Same UA constant as
  `API.pm`. Reuse the exact same resolver (artist/album → playable).
- Later polish (from the sibling plugin's playbook): Material home shelf, a
  background warm to pre-resolve, richer detail page.

## Conventions (shared with the plugin fleet)
- `<extension>` (singular) in install.xml for manual installs; `<extensions>`
  (plural) in repo.xml. A `dev` branch mirrors main, differing only in repo.xml
  `<url>` (main = GitHub Pages, dev = raw). A `v<version>` tag per release.
- Bump version + recompute sha on EVERY zip rebuild.
- Icon: `_svg.png` Material-recolour convention; SVG must use `#000` (3-digit).

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

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

## Feature Summary & Release Posts (social media)

**Maintain this section** (same convention as the sibling ListenBrainz / Listen Later plugins). Two living artefacts for announcing the plugin:
1. **Overall feature summary** (below) — the social-media / GitHub Pages "drop page" copy. **Update it whenever a key feature is added, changed or removed** (not for bug fixes). Key-features-only, user-facing, no internals.
2. **Per-release post** — when cutting a release, generate a short social post: lead with new **features**, then a short "Fixes & polish" line for notable bug fixes. Install line is the Pages repo URL. Hashtags: `#LyrionMusicServer #Pitchfork #Squeezebox #SelfHosted`.

### Overall feature summary (keep current)

> **Pitchfork Reviews — for Lyrion Music Server.** Browse Pitchfork's album reviews inside LMS and play the reviewed album straight from your streaming library — one tap, no searching.

- **Best New Music** — Pitchfork's curated Best New Music picks as a browsable, playable list.
- **High Scoring Albums** — Pitchfork's curated high-scoring picks as a second browsable, playable list.
- **Latest Reviews** — the most recent album reviews.
- **Grouped your way** — all three lists group under **genre** (default) or **week** dividers, carrying the Pitchfork mark; one setting controls all three.
- **One-tap playback** — each review is matched to a directly-playable album on **Qobuz / Tidal / Deezer**, shown with the service's own artwork; play it or queue it without searching.
- **Genres on every row** — each review shows its Pitchfork genre(s) on the row and the detail page.
- **Read the full review** — links out to Pitchfork; the plugin keeps only artist, album, date, genre and the short capsule (never reproduces the review).
- **Grid or list** — every row carries artwork, so Material's thumbnail/grid toggle stays available.
- **Choose your services** — set the Qobuz / Tidal / Deezer search order (or turn one off).
- **Material home shelves** — Best New Music, High Scoring Albums and Latest Reviews as scrollable rows on the Material home page.
- **Add to Listen Later** — matched albums carry what the companion *Listen Later* plugin needs to save & replay them.
- **Smart matching** — folds stylised spellings (*WOR$T* = *Worst*, *P!nk* = *Pink*) and a trailing EP/LP so more reviews resolve to a playable album.

**Requirements:** LMS 9.0.0+ (Material Skin recommended; the classic skin covers browse/play). For playback, at least one of **Qobuz / Tidal / Deezer** installed and signed in. **Pure Perl, cached, no extra server software** — runs the same on a Raspberry Pi or a NAS. Every streaming integration is optional and degrades gracefully.

**Install:** add `https://simonarnold002.github.io/LMS-Pitchfork-Reviews/repo.xml` in LMS → Settings → Plugins.

### Latest per-release post (0.7.1)

> **Pitchfork Reviews 0.7.1 — for Lyrion Music Server** 🎵
> **New: genre/week dividers everywhere** — Best New Music and High Scoring Albums now group under the same Pitchfork-marked genre (or week) headers as Latest Reviews, all driven by the one grouping setting.
> Install: `https://simonarnold002.github.io/LMS-Pitchfork-Reviews/repo.xml`
> #LyrionMusicServer #Pitchfork #Squeezebox #SelfHosted

_Prior (0.7.0): New High Scoring Albums source — its own browsable, one-tap-playable list + matching Material home shelf._

## Naming
Repo `LMS-Pitchfork-Reviews`; plugin/package/dir `PitchforkReviews`
(`Plugins::PitchforkReviews::*`); prefs `plugin.pitchforkreviews`; command tag
`pitchforkreviews`; cache prefix `pfr:`; zip `PitchforkReviews.zip`; display name
"Pitchfork Reviews" with three feed tiles "Best New Music" + "High Scoring Albums" +
"Latest Reviews". (The
`arv:`/`AlbumReviews` names were the pre-rename identifiers — fully retired.)

## Status: 0.7.5
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
  `pfr:listing:3` / `pfr:bnm:3` / `pfr:hsa:3` (3h + 7d fallback). `from_json` yields proper characters (no mojibake). Score is available
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


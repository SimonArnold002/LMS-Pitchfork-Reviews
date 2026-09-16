package Plugins::PitchforkReviews::Browse;

# All browse feeds for the Pitchfork Reviews plugin, plus the album-level streaming
# resolver.
#
# Menu shape:
#   Pitchfork Reviews
#     - Best New Music      -> feed of reviews  -> tap a review -> detail page
#     - Latest Reviews      -> feed of reviews  -> tap a review -> detail page
#     - Plugin Settings
#
#   A review detail page resolves the reviewed album against the user's streaming
#   services (Qobuz / Tidal) and shows each match as a directly-playable album
#   node, followed by the review capsule and a "Read review" link out.
#
# The resolver (_findPlayable and friends) is a trimmed port of the album-match
# engine in the ListenBrainz Fresh Releases plugin: search the ARTIST only on each
# service, then filter candidates locally by _albumMatches (title + artist). This
# has far better recall than sending "artist album" as one fuzzy query. The known
# matcher edge cases carry over (accents/punctuation/shorter titles) — see the
# ListenBrainz plugin's match_check tooling if a specific album won't resolve.

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;
use Time::HiRes ();
use Plugins::PitchforkReviews::DB;
use Time::Local;

my $log   = Slim::Utils::Log::logger('plugin.pitchforkreviews');
my $prefs = preferences('plugin.pitchforkreviews');

# TWO LOGGING TIERS (0.9.22), and the split is by VOLUME, not by importance.
#
# _dbg  — MILESTONES. server.log at INFO always, plus pfr-debug.log when the debug_log
#         pref is on. A handful of lines per warm: each stage starting, the fetch phase,
#         done, the backfill, a promoted year. This is the shape of a run, and it has to
#         be readable without turning anything on, because it is how the plugin is
#         diagnosed from a pasted log.
#
# _dbgv — THE PER-ITEM TIMELINE. Nothing at all unless debug_log is on. One line per
#         service search, per resolve, per cache hit, per combined-review evaluation:
#         measured at ~250 lines for a single warm's 138 albums, and a combined review
#         re-evaluates on EVERY Material view request (14 times in 90 seconds in the
#         field, ~0.2ms each from cache — trivial to run, not trivial to read past).
#         That volume buried the milestones it sat between.
#
# WHAT THIS CHANGES ABOUT THE PREF. `debug_log` used to mean "ALSO write a file" — the
# verbose timeline went to server.log either way, so the pref could not quiet anything.
# It now means "emit the verbose timeline at all", which is what its label already claims.
# The diagnostic recipe is unchanged and still complete: turn the pref on and every line
# appears in both server.log and pfr-debug.log.
#
# NOT A PERFORMANCE CHANGE, and it should not be sold as one. Our own work is ~8.6ms per
# album against ~2500ms upstream, so the string building was never the cost. The one place
# it is worth avoiding the work rather than just the output is _dbgSearch, whose sprintf
# runs hundreds of times per warm — it returns early on _verbose() instead.
sub _dbg  { Plugins::PitchforkReviews::Plugin::dbg(@_) }
sub _dbgv { return unless _verbose(); Plugins::PitchforkReviews::Plugin::dbg(@_) }

# Is the verbose timeline wanted? Read live rather than cached at load, so toggling the
# setting takes effect on the next line instead of needing a restart — the whole point of
# a diagnostic switch is that you reach for it while something is going wrong.
sub _verbose { return $prefs->get('debug_log') ? 1 : 0 }

# A FOUND match is stable, and 7 days never reflected that. The key already carries
# everything that can invalidate a match — the parse version and the enabled service
# set (_streamKey) — so expiry was only ever guarding against an album leaving a
# service, which is rare and already has a manual escape hatch ("Refresh streaming
# match", plus `force` on every Refresh row).
#
# What the short TTL actually cost: an IMMUTABLE list re-resolving on a timer. A
# year-end list from 2019 cannot change, but its 50 matches expired every week, so
# every year the user had ever opened went cold again and re-ran 50 searches on the
# next open — behind a BUILD_DEADLINE it cannot meet from cold, so it also rendered
# partial. The resolve cache is keyed per artist+album with no notion of which feed
# asked, so a per-section TTL isn't available without splitting the key; raising the
# floor fixes the year lists and costs the rolling feeds nothing, since a review's
# match is exactly as stable as a year entry's.
# ---------------------------------------------------------------------------
# 2,592,000 SECONDS (30 DAYS) IS A HARD CEILING ON EVERY TTL IN THIS PLUGIN.
#
# Slim/Utils/DbCache.pm, _canonicalize_expiration_time (LMS 9.1) — LMS's own comment:
#
#     # "If value is less than 60*60*24*30 (30 days), time is assumed to be
#     # relative from the present. If larger, it's considered an absolute Unix time."
#     if ( $expiry <= 2592000 && $expiry > -1 ) {
#         $expiry += time();
#     }
#
# A TTL ABOVE the boundary is therefore not a duration — it is read as an absolute
# epoch. `90 * 86400` is stored as expiring on 1970-04-01, and every get() then hits
#
#     if ($expiry && $expiry >= 0 && $expiry < time()) { $data = undef }
#
# and returns nothing, for ever. The row IS written, `set` returns 1, nothing dies and
# nothing warns — which is exactly why this was invisible.
#
# 90 -> 30 (0.9.9). This constant was 7 days and working until 0.9.0 raised it to 90;
# that single change is the whole of the "everything is slow and rows are not playable"
# regression. Measured on the live server immediately before this fix: 1,278 fresh
# streaming searches against 56 cache hits (4%, down from 97.6%), with one album
# resolved EIGHT times inside a single warm pass.
#
# It cost five releases because the right hypothesis was raised first and then discarded
# by a test that never crossed the boundary: 0.9.3 lowered the ceiling 365 -> 90 days,
# saw no change, and concluded TTL was innocent. Everything after — value size, key
# names, namespaces, chunking — held the TTL fixed at 90 days while varying something
# else, so each "disproof" was measuring the same broken write.
#
# 'never' (-1) is also accepted by DbCache and is never purged, but a streaming match
# CAN change when an album leaves a service, so a real expiry is right here. Note also
# that the STRING form ('90 days') converts correctly, because that branch adds time()
# itself — it is only the raw seconds form that has a ceiling.
# t_perf.pl sweeps every TTL constant in both modules against this boundary.
# The resolve key, split into a prefix and a version so a bump can RETIRE ITS OWN OLD
# ROWS. Before this the version was inlined in the key string, which meant a bump left
# the whole previous family sitting in the store until every row aged out — a month of
# dead weight nobody would ever read, and invisible unless you went looking. See
# _retireOldStreamKeys.
use constant STREAM_KEY_PREFIX       => 'pfr:stream:';
# :12: -> :13: (0.9.13). A TARGETED bump, and the reasoning is worth keeping because
# 0.9.12 shipped without one and was unobservable: its whole subject is how shelves and
# views behave while resolving COLD, and against a warm store the entire run was cache
# hits — warm done 11.2s after init with zero live searches.
#
# Only this key moves. PARSE_VERSION stays at 2 because nothing about fetching or
# parsing articles changed, and re-downloading 17.5MB of pages would add noise to the
# exact measurement this bump exists to take. Invalidate the variable under test, not
# everything within reach.
#
# It also exercises _retireOldStreamKeys for the first time on real data — that path has
# never fired, because a version has not moved since it was written.
# :13: -> :14: (0.9.14). Instrumentation that never runs measures nothing: the store is
# warm under :13:, so without this the whole run would be cache hits and the log would
# carry no search lines at all.
#
# KNOWN CONFOUND, stated up front so the numbers are not over-read. Bumping OUR key does
# not produce a cold start — it produces our cold start on top of the QOBUZ PLUGIN'S OWN
# cache, which we do not control. The :12:->:13: bump re-resolved 175 albums at 8.6ms
# each, which is not a network round trip. So expect a BIMODAL latency distribution:
# ~10ms where Qobuz served itself, ~2900ms where it genuinely went out.
#
# That does not spoil the measurement this build is for. `raw=` — the row count that
# decides whether capping the search is worth doing — is the same payload either way,
# and the slow tail gives real latencies. Read the two populations separately.
# :14: -> :15: (0.9.15). Our store went warm under :14:, and Simon has now cleared the
# QOBUZ plugin's cache — which is the other half, and the half that made 0.9.14's latency
# data worthless: 307 of 308 searches came back in 3ms because Qobuz answered itself.
# Both caches cold at once is the only state in which the remaining questions —
# per-request latency, and why 50 albums take 14s when a request takes ~200ms — can be
# measured at all. One restart, one shot.
# :15: -> :16: (0.9.16). The A/B needs our store cold, or nothing re-resolves and the
# limit is never exercised.
#
# ONE THING NOT TO TRIP OVER when reading the next run. Qobuz's own search cache keys on
# `search_${query}_${type}_` and DOES NOT INCLUDE THE LIMIT, holding each entry for 300
# seconds (verified in its API.pm: `$cache->set($key, $results, 300)`). So a query
# repeated inside five minutes returns the CACHED 200-row payload regardless of what we
# asked for, and would read as "the limit did nothing". Compare against the 0.9.15
# baseline — median 2513ms, raw median 83 — using searches at least five minutes apart,
# and that also means no cache clearing is needed to get a cold run: just wait.
#
# :23: -> :24: (0.9.31). A CORRECTNESS BUMP, the same class as 0.9.27's 21 -> 22 and for
# the same reason: which release takes the row changed. Where neither leg had a folded-exact
# candidate, the merge order handed the row to the album-title leg's first loose hit and
# STREAM_FOUND_TTL pinned it for thirty days — so a stored answer under :23: can name the
# wrong release, with a valid-looking entry and no symptom to notice. The second fix makes
# it worse to leave: those wrong answers sit next to no-match entries written at the
# one-hour TTL that should have been a day, so a warm store is a mix of two defects.
# PARSE_VERSION stays at 3 — no article parsing or fetching changed.
#
# :24: -> :25: (0.9.32). AN OBSERVABILITY BUMP, NOT A CORRECTNESS ONE, and the distinction is
# recorded because the two have different rules. Nothing under :24: names the wrong release —
# no ranking or merge behaviour changed — so unlike 0.9.27's and 0.9.31's bumps this one is
# not repairing stored answers. What it does is make the change VISIBLE: the entries 0.9.32
# corrects are no-matches written at STREAM_NOMATCH_TTL by a warm that ran before a service
# authenticated, and against a warm store those simply sit there until they expire, so the fix
# would not be exercised on the first opens after the install. That is the standing dev-build
# rule ([[dev-builds-clear-caches]]) doing its job rather than a defect being cleaned up, and
# it is cheap here: a re-resolve, not a re-download.
#
# :25: -> :26: (0.9.33). A CORRECTNESS BUMP, and a mandatory one. The fleet matcher sync
# changed `_norm` itself — apostrophes now ELIDE instead of becoming a space, so "Jane's
# Addiction" keys 'janes addiction' where :25: keyed 'jane s addiction' — and `%FOLD` grew
# from 10 entries to ~90. EVERY normalised key in the store therefore changes, matched and
# unmatched alike, so serving :25: entries under the new matcher would replay verdicts the
# current code would not reach. `_albumMatches`' new compound-word tier compounds it: rows
# cached as a confirmed no-match at STREAM_NOMATCH_TTL (24h) — the Rolling Stones' "England's
# Newest Hit Makers" among them — now MATCH, and against a warm store they would otherwise
# sit unmatched for a day after the install.
# PARSE_VERSION stays at 3 — still no article parsing or fetching change, so re-pulling
# 17.5MB of articles would be cost with no test value.
#
# :26: -> :27: (0.9.36). A CORRECTNESS BUMP. 0.9.35's first warm, with Spotify at priority 1 on
# Spotty's shared default Client ID, drew hundreds of Spotify 502s and 429s; each read as "not on
# Spotify", so the next service's match was written at STREAM_FOUND_TTL — rows pinned to Qobuz
# for thirty days that Spotify carries. 0.9.36 caps that case at a day (`empty_unverified`), but
# only for entries written from here on, so the ones already in the store must go. The bump sends
# the whole store through a cold warm again; what keeps that from re-pinning rows is the same
# build's `empty_unverified` cap and the 429 back-off, not a slow warm (rejected — see
# PACED_WARM_GAP).
use constant STREAM_KEY_VERSION      => 27;

# How long a coalescing slot may be joined before it is assumed wedged (see
# _findPlayable). Comfortably past the worst honest resolve — four serial
# STREAM_SVC_TIMEOUTs is 32s — so it only ever fires on a genuine strand.
use constant RESOLVE_JOIN_MAX        => 60;

# Album key -> { at => claimed-at, token => claim identity, waiters => [callbacks] }.
# Nothing outside _findPlayable may touch this.
#
# THE TOKEN IS NOT DECORATION. A slot can be REPLACED while its owner is still running
# (see the wedged-slot path in _findPlayable), and the orphaned owner is not cancelled —
# only detached. Without an identity on the claim it releases whatever sits at the key by
# then, which is somebody else's slot. Monotonic and never 0, so it doubles as the "did we
# claim?" flag the release tests.
my %RESOLVING;
my $SLOT_SEQ = 0;

sub _resolvingCount { return scalar keys %RESOLVING }   # test seam
sub _resetResolving { %RESOLVING = (); return }        # test seam

# Test seam: backdate a claim so the wedged-slot path can be exercised without the
# suite sleeping for RESOLVE_JOIN_MAX. Kept beside the store it edits rather than
# reached into from the test, so the invariant stays owned by this file.
sub _ageResolvingSlot {
    my ($key, $secs) = @_;
    $RESOLVING{$key}{at} -= $secs if $RESOLVING{$key};
    return;
}

use constant STREAM_FOUND_TTL        => 30 * 86400;  # 2_592_000 is the ceiling — do not raise
use constant STREAM_NOMATCH_TTL      => 1 * 86400;   # confirmed "not on any service"
use constant STREAM_INCONCLUSIVE_TTL => 3600;        # couldn't query a service -> retry soon
# A REAL ANSWER THAT WAS NEVER VALIDATED (0.9.29) — its own category, deliberately, because
# the three above cannot express it. 0.9.27 fires an album-title leg when the artist leg came
# back LOOSE-ONLY, and 0.9.28 makes $finish merge those leg-1 matches back in so a slow leg 2
# can no longer discard them. Correct — but it also means a leg-2 TIMEOUT now yields a
# non-empty result, which took STREAM_FOUND_TTL: the loose candidate the second search existed
# to check got pinned for THIRTY DAYS on the strength of a query that never answered. That is
# the wrong-match-pinned-for-a-month defect this series exists to remove, reached by a new
# route. So: serve the match (it passed `_albumMatches`; withholding it is the 0.9.28
# regression), but store it for ONE DAY, not thirty.
# Why a day and not STREAM_INCONCLUSIVE_TTL's hour: an hour makes every list open after the
# first re-resolve the album, and the shape that lands here is a service that HUNG — so each
# retry costs a fresh STREAM_SVC_TIMEOUT against BUILD_DEADLINE, on every open, for as long as
# that service stays slow. A day bounds the exposure to the daily warm, which re-resolves any
# expired entry (see the pump in _resolveSection) and validates it properly the moment the
# service answers.
use constant STREAM_UNVALIDATED_TTL  => 1 * 86400;   # matched, but the checking leg never answered

# WHAT A SERVICE LEG DID — ONE CARRIER, NOT FIVE (0.9.32).
#
# This is a refactor with NO behaviour change, and it exists because the same defect kept
# coming back in a new shape for four releases running. The concept "what did this service
# actually do?" had FIVE independent carriers, and every fix added another instead of
# reconciling them:
#
#   `defined $res && ref $res eq 'ARRAY'`  original — asked TWO different questions
#   $inconclusive (counter)                original
#   @unvalidated  (per-adapter array)      0.9.29, to re-derive what the merge had destroyed
#   $standing     (literal at the call site) 0.9.30, for the log
#   $unavailable  (counter)                0.9.31, to wire $standing into the TTL
#
# Each addition desynchronised the others. 0.9.28 moved the merge into `$finish`, which made
# `$res` stop meaning "leg 2 answered", so 0.9.29 had to add carrier 3. 0.9.30 added carriers
# 4 and 5 for the log alone, so 0.9.31 had to wire carrier 4 into the TTL. The review after
# that found carrier 4 asserting a classification `$finish` may never apply, because the merge
# can rewrite `$res` before the branch that counts it is reached.
#
# So: ONE value per adapter, recorded ONCE, in `$finish`, BEFORE the merge touches `$res` —
# the merge is precisely what used to destroy the signal — and every consumer (the TTL, the
# log) reads the record instead of re-deriving it from a proxy.
#
# ADDING A SIXTH BOOLEAN IS THE BUG, NOT THE FIX. If a future change needs to distinguish
# something new about a leg, it belongs in this enum, not beside it.
use constant OUTCOME_ANSWERED    => 'ANSWERED';      # searched and returned a list — `[]` IS a verdict
use constant OUTCOME_ERRORED     => 'ERRORED';       # transient: may well answer on the next open
use constant OUTCOME_UNAVAILABLE => 'UNAVAILABLE';   # STANDING: signed out, measured (see the grace note)

# HOW LONG A MISSING API HANDLER MUST PERSIST BEFORE IT COUNTS AS SIGNED OUT (0.9.32).
#
# 0.9.31 decided this at the CALL SITE, with a literal `1` at the three `no API handler`
# lines — a claim about the FUTURE that the call site cannot possibly make. A missing handler
# has two completely different causes with the same signature:
#
#   the user is signed out / never configured   -> STANDING. Repeats for ever, because
#       `_detectAdapters` gates on `->can()` and knows nothing about sign-in, so the adapter
#       is in @adapters on every resolve. Counting it transient forces an hourly re-resolve
#       on every unmatched album, 24x the traffic, indefinitely. That is 0.9.31's fix.
#   the STARTUP WARM ran before the service authenticated -> TRANSIENT, and it self-heals
#       within seconds. Counting it standing pins real misses at STREAM_NOMATCH_TTL (24h)
#       when nobody actually searched — live at every server restart. The sibling LBF
#       documents exactly this case ("no API handler at resolve time — e.g. the startup warm
#       running before Qobuz/Tidal authenticated").
#
# SO IT IS MEASURED, NOT DECLARED. `%UNAVAIL_SINCE` records when a service was FIRST seen
# without a handler, and is cleared the moment it has one; standing means "still gone after
# the grace window". Inside the window the answer is TRANSIENT, which is the honest reading —
# it may well answer on the next open, which is precisely what OUTCOME_ERRORED means.
#
# IN PROCESS MEMORY DELIBERATELY, not the kv store: the window is meant to be relative to
# THIS process's uptime, because the startup race is a property of this process starting. A
# restart re-opening the window is correct, not a bug — and it costs only that a genuinely
# signed-out service takes the 1h TTL for the first ten minutes after a restart, during which
# it makes no network calls at all (there is no handler to call with).
#
# 600s is sized to cover plugin load + authentication with a wide margin, and is bounded on
# the other side by being far shorter than STREAM_NOMATCH_TTL.
use constant SVC_UNAVAILABLE_GRACE => 600;

use constant STREAM_SVC_TIMEOUT      => 8;           # per-service search watchdog (s)
use constant STREAM_MAX_RESULTS      => 12;

# How long a browse view may block before rendering with whatever has resolved.
# Declared up here because a `use constant` must be compiled before the subs that
# name it, and fetchFeed/fetchYearFeed are above them.
#
# 25 -> 5 (0.9.1), REVERSING 0.9.0. The 0.9.0 reasoning is preserved below because
# it was wrong in an instructive way, and the field result was unambiguous: "just 3
# dots and a very long wait", plus a year change that showed nothing but dots.
#
# What 0.9.0 argued: a cold list resolved only 27 of 50 inside 10s, so 10s
# guaranteed a partial render; the client imposes no timeout of its own (Material
# browses via lmsList -> lmsCommand -> axios.post('/jsonrpc.js', c) with axios'
# default `timeout: 0`; the 10s `maxNetworkDelay` belongs to the CometD player
# channel, not this path); therefore the view could safely wait 25s for a complete
# one. Every one of those statements is still true. The CONCLUSION did not follow.
#
# "Nothing stops us waiting" is not "waiting is what the user wants". Material
# renders nothing at all while the request is outstanding — just its three-dot
# placeholder — so the entire budget is spent on a blank screen. 0.9.0 also built
# the "still loading" label FOR the partial render and then set a deadline high
# enough that the partial render mostly stopped happening: it paid the full cost of
# waiting and threw away the feature that made not-waiting acceptable. A partial
# list you can see, scroll and play from beats a complete one you are still waiting
# for, and the label is what makes the difference legible.
#
# 5 and not 10: with the warm now yielding (see WARM_CONCURRENCY) a cold view gets
# the whole machine, and the pump deliberately keeps resolving past the deadline, so
# what misses the cut is warm for the next open rather than lost.
#
# HOME SHELVES DELIBERATELY KEEP BUILD_DEADLINE. They reach the plugin through
# HomeExtraBase's CLI request, which is NOT the path checked above, and 0.6.1
# recorded Material timing a slow shelf out into an empty/hung carousel.
# 5 -> 45 (0.9.12), AND IT IS NOW A BACKSTOP RATHER THAN A BUDGET.
#
# Simon's requirement, stated plainly: a user should never be handed an incomplete view.
# 0.9.1's 5s was the right answer to the WRONG WORLD — every open was fully cold every
# time, because the resolve cache had been silently discarding everything since 0.9.0
# (see STREAM_FOUND_TTL). Against that, waiting for a complete list meant waiting on
# every open for ever, so rendering partial was the lesser evil. With the store actually
# retaining, the first open of a section costs one cold pass and every open after it is
# a lookup — so waiting is now cheap, and the partial render is just a worse view.
#
# 45 IS FROM A MEASUREMENT, NOT AN EXTRAPOLATION. Read off the live server on the
# 0.9.11 install, from the backfill years, which are 50 genuinely cold items resolving
# at full width with nothing competing:
#
#     2025:  76.0s gap - 60s backfill delay = 16.0s for 50 items
#     2024:  73.8s gap - 60s backfill delay = 13.8s for 50 items
#
# So a cold 50-item list is ~14-16s, about 2.9s per album at width 10. Note that this
# is NOT the width-2 rate divided by five: the earlier warm stages resolve at ~1.0-1.3s
# per album at width 2, and assuming that scales linearly produced an estimate three
# times too tight. Concurrency does not scale linearly here; measure at the width you
# intend to run.
#
# 45 = that ~16s, plus room for the one genuinely slow item. A single album that misses
# the top service chains four serial STREAM_SVC_TIMEOUTs (32s), and that runs alongside
# the rest rather than adding to it — so 45 clears both and is still unmistakably a
# backstop nothing is expected to reach, not a budget being spent.
use constant VIEW_DEADLINE           => 45;          # browse lists only — see above

# Declared here rather than beside BUILD_CONCURRENCY for the same compile-order
# reason as VIEW_DEADLINE above: the home shelves now name it (0.9.10, they pass it
# explicitly instead of relying on _resolveSection's default) and they are defined
# further up this file than the pump is. The reasoning behind the VALUE lives with
# BUILD_CONCURRENCY, where the rest of the resolve tuning is.
use constant BUILD_DEADLINE          => 10;   # home shelves; _resolveSection's default

use constant ROW_CAPSULE_MAX => 110;   # capsule length on a list row
use constant DETAIL_TIMEOUT  => 15;    # detail-page render watchdog (s)
use constant DIVIDER_ICON    => 'html/images/albums.png';   # neutral core LMS icon on week headers (keeps Material's grid toggle enabled)
use constant REFRESH_ICON    => 'plugins/PitchforkReviews/html/images/pfr-refresh_MTL_icon_refresh.png';   # same Material refresh glyph LBF uses
use constant SETTINGS_ICON   => 'plugins/PitchforkReviews/html/images/pfr-cog_MTL_icon_settings.png';     # Material cog font-icon (like LBF)
use constant SORT_ICON       => 'plugins/PitchforkReviews/html/images/pfr-sort_MTL_icon_sort.png';        # Material sort glyph (copied from LBF, same convention as the refresh icon)
use constant BNM_TILE        => 'plugins/PitchforkReviews/html/images/menu-best-new-music.png';           # branded section cover
use constant REVIEWS_TILE    => 'plugins/PitchforkReviews/html/images/menu-latest-reviews.png';           # branded section cover
use constant HSA_TILE        => 'plugins/PitchforkReviews/html/images/menu-high-scoring-albums.png';      # branded section cover
use constant YEAR_TILE       => 'plugins/PitchforkReviews/html/images/menu-best-albums-of-the-year.png';  # branded section cover
use constant LOGO_ICON       => 'plugins/PitchforkReviews/html/images/PitchforkReviewsIcon.png';          # Pitchfork round mark (full-colour raster) — marks the "Read the full review" link
use constant HEADER_ICON     => 'plugins/PitchforkReviews/html/images/PitchforkReviewsIcon_svg.png';      # divider/header icon — MUST be the `_svg.png` Material-recolour form: Material renders an icon on a header-basic divider ONLY for `_svg.png`/`_MTL_*` icons, NOT a plain .png (verified vs LBF, whose dividers use its _svg.png)

# ===========================================================================
# Browse feeds
# ===========================================================================

# Top-level app menu.
sub topLevel {
    my ($client, $cb, $args) = @_;

    # All three source tiles share one grouped feed (fetchFeed, dispatched by
    # `source`): each groups into Material header dividers per the group_by pref.
    # A second provider (AllMusic, v2) drops in here as another _feedTile.
    my $features = _featuresOf($args);   # 'h' => client (Material) supports header dividers

    my @items = (
        _feedTile($client, 'bnm',     'PLUGIN_PITCHFORKREVIEWS_BNM',     BNM_TILE,     $features),
        _feedTile($client, 'hsa',     'PLUGIN_PITCHFORKREVIEWS_HSA',     HSA_TILE,     $features),
        _feedTile($client, 'reviews', 'PLUGIN_PITCHFORKREVIEWS_REVIEWS', REVIEWS_TILE, $features),
        {
            # Opens on the year the view is currently showing (newest published,
            # or the one you last chose — see _viewYear); other years are one row
            # down, inside.
            #
            # DELIBERATELY YEAR-FREE (0.8.7). This tile did name the year, and it
            # was the one place that could then be WRONG: a page keeps whatever
            # labels it was built with, and Material replays a page it already
            # holds in history without asking the server again — so once you
            # changed the year from inside the view, the tile above it went on
            # claiming the old one until you left the app entirely. Nothing in
            # Material lets a plugin refresh a page the user isn't standing on
            # (`needsRefresh` is set client-side, for podcasts and search only),
            # and the alternative — throwing the user back out here so this page
            # is rebuilt — costs a tap on every year change. So the year is named
            # only where it is rendered live: the view's own list header and page
            # title, the "Choose a year (2023)" row, and the Material home shelf
            # (pushed through setHomeExtraTitle whenever it changes).
            name        => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_YEAR'),
            type        => 'link',
            image       => YEAR_TILE,
            url         => \&fetchYearFeed,
            passthrough => [ { features => $features } ],
        },
        {
            name    => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SETTINGS'),
            type    => 'link',
            image   => SETTINGS_ICON,
            weblink => '/plugins/PitchforkReviews/settings.html',
        },
    );

    # cachetime => 0: Material client-caches browse views per player; force a
    # re-fetch each open so a refreshed feed shows without navigating away.
    $cb->({ items => \@items, cachetime => 0 });
}

sub _feedTile {
    my ($client, $source, $nameKey, $image, $features) = @_;
    return {
        name        => cstring($client, $nameKey),
        type        => 'link',
        image       => $image,
        url         => \&fetchFeed,
        # Thread `features` through passthrough: XMLBrowser gives it only to the TOP
        # feed, not a coderef sub-feed, so fetchFeed can't read it from $args.
        passthrough => [ { source => $source, features => $features } ],
    };
}

# A source listing (page state), grouped into Material header dividers by the
# group_by pref (week or genre — same as Latest Reviews). All three sources —
# Latest Reviews, Best New Music, High Scoring Albums — share this feed, keyed by
# $pt->{source}. Resolves each item to streaming during the build so matched rows
# play from the list with the service's artwork; unmatched rows keep the Pitchfork
# cover and drill to the detail page.
sub fetchFeed {
    my ($client, $cb, $args, $pt) = @_;
    my $source  = $pt->{source} // 'reviews';
    my $headers = _wantHeaders($pt->{features} // _featuresOf($args));

    my $fetch = $source eq 'bnm' ? \&Plugins::PitchforkReviews::API::getBnm
              : $source eq 'hsa' ? \&Plugins::PitchforkReviews::API::getHsa
              :                    \&Plugins::PitchforkReviews::API::getListing;

    $fetch->(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            my $mode = _groupBy();

            # Options section (Material header + its rows) on top, then the grouped
            # content under its own genre/week dividers — the same shape as the year
            # view and the sibling ListenBrainz plugin. The action rows used to sit
            # bare above the first divider, which read as two unexplained rows
            # before the list started.
            my @opt  = ( _refreshRow($client, $source), _groupToggle($client, $mode) );
            my @rows = ( _sectionHeader($client, cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SECTION_OPTIONS'), $headers, \@opt),
                         @opt );

            if (@$items) {
                push @rows, @{ _groupedRows($client, $items, $headers, $mode) };
            }
            else {
                push @rows, { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_EMPTY'), type => 'text' };
            }

            # These lists group under genre/week dividers, so unlike the year view they
            # carry no header with a count to fold the progress into. The PAGE TITLE
            # takes it instead — also not a row, so the same "nothing is added or
            # removed" rule holds. Emitted only while incomplete: a finished list keeps
            # the title Material already derives from the tile that opened it, so
            # nothing changes on the normal (warm) path.
            my $progress = @$items ? _matchProgress($client, $items) : '';
            $cb->({ items => \@rows, cachetime => 0,
                    ($progress =~ /^ \(\d+\)$/ ? ()
                     : (title => cstring($client, _sourceTitleToken($source)) . $progress)) });
        }, VIEW_DEADLINE);
    });
}

# ---------------------------------------------------------------------------
# Best Albums of the Year — Pitchfork's annual "The 50 Best Albums of <year>".
#
# Deliberately NOT run through _groupedRows. Both grouping modes are meaningless
# here: a year-end list carries no genre at all, and every entry shares the
# article's one publication date, so week and genre alike collapse to a single
# divider holding all 50. What the list HAS is a rank, so it renders flat in rank
# order with the position on each row.
#
# With no year in the passthrough this opens the newest published list; the year
# picker below re-enters with one pinned.
# ---------------------------------------------------------------------------
sub fetchYearFeed {
    my ($client, $cb, $args, $pt) = @_;
    my $want    = $pt->{year};
    my $headers = _wantHeaders($pt->{features} // _featuresOf($args));

    my $build = sub {
        my $year = shift;
        unless ($year) {
            return $cb->({
                items     => [ { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_EMPTY'), type => 'text' } ],
                cachetime => 0,
            });
        }

        Plugins::PitchforkReviews::API::getYearList($year, sub {
            my $items = shift || [];
            _resolveSection($client, $items, sub {
                my $mode  = _yearSort();
                my $label = _yearLabel($client, $year);

                # Options section (Material header + its rows), then the list under
                # its OWN header — the same shape the sibling ListenBrainz plugin
                # uses. The list header is what names the year in bold directly
                # above the albums; `title` below names it in the page toolbar too,
                # for skins that show one.
                my @opt = ( _refreshRow($client, "year:$year"),
                            _yearPickerRow($client, $year),
                            _yearSortToggle($client, $mode) );

                my @rows = ( _sectionHeader($client, cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SECTION_OPTIONS'), $headers, \@opt),
                             @opt );

                if (@$items) {
                    my $ordered = _yearOrdered($items, $mode);
                    my @albums  = map { _reviewRow($client, $_, $headers) } @$ordered;
                    # The count this header already carried now reports how much
                    # RESOLVED, not just how many rows there are (see _matchProgress).
                    push @rows, _sectionHeader($client, $label . _matchProgress($client, $ordered), $headers, \@albums), @albums;
                }
                else {
                    push @rows, { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_EMPTY'), type => 'text' };
                }

                $cb->({ items => \@rows, title => $label, cachetime => 0 });
            }, VIEW_DEADLINE);
        });
    };

    # An explicit year is a deliberate choice — remember it, so the tile and the
    # home shelf name the year the user actually reads (until a newer list
    # publishes and _viewYear promotes past it).
    if ($want) {
        $prefs->set('year_last', $want);
        return $build->($want);
    }
    _viewYear(sub { $build->(shift) });
}

# Which year the section opens on, resolved async.
#
# STICKY, BUT PROMOTION STILL WINS. The view remembers the year you last looked
# at (`year_last`) so the tile, the home shelf and the view agree on one year
# rather than the tile promising the newest while the view opens on something
# else. But a year-end list is an annual event, and pinning a user to 2019 for
# ever would defeat the whole self-updating design — so whenever getLatestYear
# reports a year newer than the last one we promoted to, that new list wins and
# both prefs move up. A fresh install (prefs 0) simply opens on the newest.
sub _viewYear {
    my ($cb) = @_;
    Plugins::PitchforkReviews::API::getLatestYear(sub {
        my $latest = shift;
        return $cb->(undef) unless $latest;

        my $promoted = $prefs->get('year_promoted') || 0;
        if ($latest > $promoted) {
            _dbg("year: promoting to the newly published $latest (was $promoted)");
            $prefs->set('year_promoted', $latest);
            $prefs->set('year_last',     $latest);
            return $cb->($latest);
        }

        my $last = $prefs->get('year_last') || 0;
        my $min  = Plugins::PitchforkReviews::API::YEAR_MIN();
        return $cb->($last) if $last >= $min && $last <= $latest;

        # Out of range (hand-edited, or a list withdrawn): fall back to the newest
        # AND REPAIR THE PREF, so `year_last` always names the year every surface is
        # actually showing. Leaving it stale kept a value nothing could ever open —
        # which the warm then treated as a year worth pre-resolving, re-running the
        # full candidate-slug sweep (two ~1.7MB article fetches) on every tick.
        $prefs->set('year_last', $latest);
        return $cb->($latest);
    });
}

# "2025 - Best Albums" — the one label the home shelf, the page title and the list
# header all share, so the year is never in doubt. (Not the app tile: see topLevel.)
sub _yearLabel {
    my ($client, $year) = @_;
    return sprintf(cstring($client, 'PLUGIN_PITCHFORKREVIEWS_YEAR_LABEL'), $year);
}

# A Material section divider, taking a LITERAL label (the year headers are built
# at render time, so there is no string token to hand it). Older Material renders
# type => 'header' bold but forces a drill action onto it that can't be
# suppressed, so — as with the week/genre dividers — give it a url returning its
# own children, and tapping the header shows that section instead of an empty
# page. On Material 6.4.3+ _headerType() is 'header-basic', which strips the
# action and harmlessly ignores the url. Non-Material skins get plain text.
#
# $noIcon drops the logo thumbnail, for DETAIL-page section headers — there is
# nothing to browse into there, the rows sit right below, so the icon is clutter.
# List pages keep it, because an image-less item sets haveWithoutIcons and
# disables Material's grid/list toggle for the whole page. (Same split, and the
# same reasoning, as the sibling ListenBrainz plugin.)
# How much of a section actually resolved, as a parenthesised suffix: "(50)" when
# everything matched, "(27 of 50 matched - still loading)" when it did not.
#
# WHY THIS IS A LABEL AND NOT A ROW, which is the whole design constraint. A row that
# appears while loading and vanishes when done CHANGES THE ITEM COUNT between renders,
# and a row's position is an index path Material re-traverses later to play — so every
# row below the message would shift by one the moment resolution completed. That is
# precisely the `hide_unmatched` failure removed from the home shelves in 0.6.1. Folding
# the status into a label that already exists adds and removes nothing, so index paths
# never move and the same helper is safe on every view.
#
# A partial render is not new — BUILD_DEADLINE has always rendered whatever resolved in
# time. What is new is saying so instead of presenting a two-thirds-playable list as if
# it were finished.
# The string token naming a source, so a progress title can say WHICH list is loading.
# Same tokens topLevel gives the three tiles, so the title agrees with the tile that
# opened it rather than inventing a second name for the same feed.
sub _sourceTitleToken {
    my ($source) = @_;
    return $source eq 'bnm' ? 'PLUGIN_PITCHFORKREVIEWS_BNM'
         : $source eq 'hsa' ? 'PLUGIN_PITCHFORKREVIEWS_HSA'
         :                    'PLUGIN_PITCHFORKREVIEWS_REVIEWS';
}

# "STILL LOADING" MEANS *NOT YET TRIED*, NEVER "TRIED AND FOUND NOTHING", and the two
# are easy to conflate because both leave the row without an `_album`. Counting matches
# alone would have been wrong in two ways that never clear:
#   - with NO streaming service installed or enabled nothing can ever resolve, so every
#     list would sit at "0 of 50 - still loading" for ever;
#   - an album genuinely on none of the services never resolves either, so a list with
#     three such entries would read "47 of 50 - still loading" permanently.
# So pending is decided by the RESOLVE CACHE, which holds an entry for anything already
# attempted (a confirmed no-match is cached too, at STREAM_NOMATCH_TTL). Nothing pending
# means the work is done, whatever the match rate, and the label goes back to the plain
# count. Peeking is cheap — a 138-album warm measured 11ms.
sub _matchProgress {
    my ($client, $items) = @_;
    my $total = scalar @$items;

    # Nothing is configured to resolve WITH, so nothing is pending and never will be.
    return " ($total)" unless _orderedAdapters();

    my $matched = grep { $_->{_album} } @$items;
    my $pending = grep {
        !$_->{_album}
            && !Plugins::PitchforkReviews::DB::kvGet(
                    _streamKey(_streamId($_->{artist}, $_->{album})));
    } @$items;
    return " ($total)" unless $pending;

    return ' (' . sprintf(cstring($client, 'PLUGIN_PITCHFORKREVIEWS_LOADING'), $matched, $total) . ')';
}

sub _sectionHeader {
    my ($client, $label, $useH, $children, $noIcon) = @_;
    my $hdr = {
        name  => $label,
        type  => $useH ? _headerType() : 'text',
        ($noIcon ? () : (image => HEADER_ICON)),
    };
    # KNOWN LIMITATION, deliberately left in place. @kids is a SNAPSHOT taken at build
    # time, so the drill-in serves the children as they were when this header was made.
    # For a section whose rows carry live state in their label — "Sorted by Rank (tap to
    # change)", "Grouped by Genre", "Choose a year (2025)" — tapping one inside that
    # drill-in flips the pref but re-renders from the snapshot, so the label does not
    # move. An old closure holds old data by definition, so the only real fix is to make
    # the drill-in RE-ENTER the feed and rebuild, which means restructuring every caller.
    #
    # NOT WORTH IT, because the page is unreachable on any Material that matters:
    # _headerType() returns 'header-basic' from 6.4.3, and Material's own bundle does
    #   "header-basic" == f.type && (f.header=!0, d.numHeaders++, f.actions = void 0)
    # — it strips the actions, so the header has no tap action and this url is never
    # invoked (verified against 6.4.5's material-deferred.min.js, not inferred). Only
    # Material < 6.4.3 can reach it, and there the rows are also rendered LIVE directly
    # below the header, which is the copy everyone actually taps.
    #
    # If this ever needs fixing: pass $children as a CODEREF that rebuilds, not an
    # arrayref, and have the stateful callers supply one.
    if ($useH) {
        my @kids = @$children;
        $hdr->{url}         = sub { $_[1]->({ items => \@kids }) };
        $hdr->{passthrough} = [ {} ];
    }
    return $hdr;
}

# The two orderings a year-end list can be read in. `rank` (#1 first) is the
# browse-list default — a "best albums" list wants its best at the top. `countdown`
# is Pitchfork's OWN order, 50 down to 1, which is how the article reads and how
# people who follow the list each December expect to work through it.
my @YEAR_SORT_MODES = ('rank', 'countdown');

sub _yearSort {
    my $m = $prefs->get('year_sort') || 'rank';
    return (grep { $_ eq $m } @YEAR_SORT_MODES) ? $m : 'rank';
}

# Order a parsed list for display. The items are cached rank-ascending by
# _parseYear, so this is a render-time view of that one cached copy — flipping the
# sort never re-fetches or re-parses, and never touches the streaming resolve.
sub _yearOrdered {
    my ($items, $mode) = @_;
    my @out = sort { $a->{rank} <=> $b->{rank} } @$items;
    @out = reverse @out if ($mode // 'rank') eq 'countdown';
    return \@out;
}

sub _yearSortLabel {
    my ($client, $mode) = @_;
    return cstring($client, ($mode // 'rank') eq 'countdown'
        ? 'PLUGIN_PITCHFORKREVIEWS_SORT_COUNTDOWN'
        : 'PLUGIN_PITCHFORKREVIEWS_SORT_RANK');
}

# "Sorted by <mode> (tap to change)" — the sibling ListenBrainz plugin's toggle
# mechanics exactly: a durable pref, advanced from the LIVE pref value (not from
# what this render captured, so a stale view can't set it backwards), and
# nextWindow => 'refresh' on an EMPTY response so the view re-walks and re-orders
# in place. Deliberately NOT a settings-page pref — it is a per-view reading
# choice, and the fleet keeps those on the view.
sub _yearSortToggle {
    my ($client, $mode) = @_;
    return {
        name       => sprintf(cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SORTED_BY'),
                              _yearSortLabel($client, $mode)),
        type       => 'link',
        image      => SORT_ICON,
        nextWindow => 'refresh',
        url        => sub {
            my ($c, $cb) = @_;
            my $cur  = _yearSort();
            my $next = $YEAR_SORT_MODES[0];
            for my $i (0 .. $#YEAR_SORT_MODES) {
                $next = $YEAR_SORT_MODES[($i + 1) % @YEAR_SORT_MODES], last
                    if $YEAR_SORT_MODES[$i] eq $cur;
            }
            $prefs->set('year_sort', $next);
            $cb->({ items => [] });
        },
    };
}

# "Choose a year (2025)" — the year is repeated here as well as in the list
# header, because this is the row you tap to change it.
sub _yearPickerRow {
    my ($client, $year) = @_;
    return {
        name        => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_PICK_YEAR') . " ($year)",
        type        => 'link',
        image       => YEAR_TILE,
        url         => \&yearPicker,
        passthrough => [ {} ],
    };
}

# Every year we can offer, newest first.
#
# PICKING A YEAR POPS BACK, IT DOES NOT DRILL IN. A row here only stores the
# choice (`year_last`) and returns EMPTY with a nextWindow, so the skin unwinds
# the pages it was showing and RE-FETCHES the one it lands on. Drilling into a
# third level instead used to leave the picker in the back stack still labelled
# with the OLD year ("Choose a year (2024)" is the row that opened it, captured
# before the change) — so backing out of the list landed on a page announcing the
# year you had just moved off.
#
# WHY 'parent'. Verified in Material's own source (browse-functions.js,
# `browseHandleNextWindow`): it fires only on a ZERO-item response, and by then
# the page you tapped from is already on the history stack — so 'refresh' would
# redraw the picker, and 'parent' pops it and re-fetches the page underneath,
# which is the year view. That view rebuilds from `year_last`, so you land
# straight on the list for the year you just chose.
#
# It stops there ON PURPOSE. 'grandparent' would go one further and rebuild the
# app menu too, but that throws you out of the section on every year change.
# Nothing on the app menu names the year any more (see topLevel), so there is
# nothing up there left to correct.
sub yearPicker {
    my ($client, $cb, $args, $pt) = @_;
    Plugins::PitchforkReviews::API::yearsAvailable(sub {
        my $years = shift || [];
        my @rows = map {
            my $y = $_;
            {
                name       => _yearLabel($client, $y),
                type       => 'link',
                image      => YEAR_TILE,
                nextWindow => 'parent',
                url        => sub {
                    my ($c, $ycb) = @_;
                    $prefs->set('year_last', $y);
                    # The home shelf's title is registered, not re-rendered, so it
                    # cannot pick the change up on its own — tell Material now.
                    _setHomeYearTitle($c || $client, $y);
                    _dbgv("year: picked $y");
                    $ycb->({ items => [], nextWindow => 'parent' });
                },
            };
        } @$years;
        push @rows, { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_EMPTY'), type => 'text' } unless @rows;
        # An explicit title: the picker would otherwise inherit the tapped row's
        # label, which carries the year as it was BEFORE the choice.
        $cb->({ items => \@rows, title => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_PICK_YEAR'), cachetime => 0 });
    });
}

# ---------------------------------------------------------------------------
# Material Skin home-page shelves (registered in Plugin::postinitPlugin via
# HomeExtras.pm). Each is a FLAT card list — no Refresh row, no week/genre
# dividers. Material uses the SAME feed for the carousel AND its "show all"
# click-in, and re-traverses by item_id at quantity 1 for playback, so a header
# at index 0 (or any quantity-varying shape) would shift every card's item_id and
# break deep streaming playback. So: always the WHOLE flat list — every review,
# matched or not, at every request quantity — the same rule the ListenBrainz
# plugin's home shelves follow. (We deliberately do NOT filter to matched-only
# here: which items are matched varies as the resolver cache fills, which would
# make the list membership — and thus every item_id — unstable between the
# carousel render and the play re-traversal, breaking deep playback.)
#
# The per-item streaming resolve is pre-warmed by Plugin's background warm
# (warmCache, below), so on a warm cache this build is all cache hits and
# returns immediately — the home carousel never has to wait out an 18s live
# resolve. On a cold cache (fresh install / first tick not yet run) it still
# resolves during the build, degrading to the browse-list behaviour.
# ---------------------------------------------------------------------------
sub homeReviews {
    my ($client, $cb, $args) = @_;
    # Threaded into the rows so a card's DETAIL page can still draw its section
    # dividers (the shelf itself stays a flat card list — see above).
    my $headers = _wantHeaders(_featuresOf($args));
    Plugins::PitchforkReviews::API::getListing(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            $cb->({ items => [ map { _reviewRow($client, $_, $headers) } @$items ], cachetime => 0 });
        }, BUILD_DEADLINE, 'shelf');
    });
}

sub homeBnm {
    my ($client, $cb, $args) = @_;
    # Threaded into the rows so a card's DETAIL page can still draw its section
    # dividers (the shelf itself stays a flat card list — see above).
    my $headers = _wantHeaders(_featuresOf($args));
    Plugins::PitchforkReviews::API::getBnm(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            $cb->({ items => [ map { _reviewRow($client, $_, $headers) } @$items ], cachetime => 0 });
        }, BUILD_DEADLINE, 'shelf');
    });
}

sub homeHsa {
    my ($client, $cb, $args) = @_;
    # Threaded into the rows so a card's DETAIL page can still draw its section
    # dividers (the shelf itself stays a flat card list — see above).
    my $headers = _wantHeaders(_featuresOf($args));
    Plugins::PitchforkReviews::API::getHsa(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            $cb->({ items => [ map { _reviewRow($client, $_, $headers) } @$items ], cachetime => 0 });
        }, BUILD_DEADLINE, 'shelf');
    });
}

# The newest year-end list as a home shelf. Same flat-whole-list rule as the
# others (see homeReviews): no Refresh/picker row, no dividers — those vary the
# membership and would shift every card's item_id.
sub homeYear {
    my ($client, $cb, $args) = @_;
    # Threaded into the rows so a card's DETAIL page can still draw its section
    # dividers (the shelf itself stays a flat card list — see above).
    my $headers = _wantHeaders(_featuresOf($args));
    _viewYear(sub {
        my $year = shift;
        return $cb->({ items => [], cachetime => 0 }) unless $year;
        _setHomeYearTitle($client, $year);
        Plugins::PitchforkReviews::API::getYearList($year, sub {
            my $items = shift || [];
            _resolveSection($client, $items, sub {
                # ALWAYS rank order — deliberately NOT the year_sort pref.
                #
                # 0.8.1 ordered this shelf by the pref so it could not disagree with the
                # in-app list, arguing it was safe because the order depends on a durable
                # pref, "NOT on the request quantity, so the feed is still identical at
                # every quantity within a render". That is the wrong invariant: a card's
                # item_id is an INDEX PATH, and Material re-traverses it in a SEPARATE,
                # LATER request to play — so the contract spans renders, not one render.
                # Flip the sort in the year view and go home and browseGoHome repaints the
                # cached view.topExtra synchronously before its re-fetch lands (verified in
                # browse-page.js/browse-functions.js, not inferred), so for one round-trip
                # the old order is on screen against the new order on the server, and
                # tapping the first card plays #50. A shelf is a "here are the picks"
                # surface; countdown is a reading choice that belongs to the list view.
                my $ordered = _yearOrdered($items, 'rank');
                $cb->({ items => [ map { _reviewRow($client, $_, $headers) } @$ordered ], cachetime => 0 });
            }, BUILD_DEADLINE, 'shelf');
        });
    });
}

# Name the year on the Material home SHELF itself ("Pitchfork: 2025 - Best
# Albums"), not just on its cards.
#
# A home extra's title is registered ONCE at startup, when the newest year is
# usually not yet known — so it is updated here instead, through Material's own
# setHomeExtraTitle (which also signals the home page to refresh). Guarded on
# `can`: the call doesn't exist in older Material, and a shelf title would be an
# absurd reason to break the shelf. Written only when it actually CHANGES, since
# every write fires that refresh signal.
#
# THE GUARD IS KEYED ON THE YEAR, NOT ON THE FORMATTED TITLE (0.8.10). A home
# extra's title is ONE server-global string, but it is built with
# cstring($client, …) — so on a server whose players carry different language
# overrides, two clients naming the SAME year produce two different strings and a
# title-keyed guard never holds: every home render re-sends it and re-fires the
# home-refresh signal, for ever. The year is what the guard is actually about.
my $_homeYearTitled = 0;
sub _setHomeYearTitle {
    my ($client, $year) = @_;
    return unless Plugins::MaterialSkin::Plugin->can('setHomeExtraTitle');
    return if $year && $year == $_homeYearTitled;
    my $title = sprintf(cstring($client, 'PLUGIN_PITCHFORKREVIEWS_HOME_YEAR_LABEL'), $year);
    # The guard is armed only AFTER the call succeeds. Setting it first means one
    # failed call (Material mid-restart, say) permanently suppresses every retry
    # for that year — the shelf would keep the old year's title until the server
    # restarts, and the next attempt is whenever the year changes again.
    if (eval { Plugins::MaterialSkin::Plugin->setHomeExtraTitle('PFRYear', $title); 1 }) {
        $_homeYearTitled = $year;
    }
    else {
        $log->warn("home shelf title update failed: $@");
    }
}

# ---------------------------------------------------------------------------
# Background warm: pre-resolve the Latest Reviews + Best New Music listings to
# streaming so the Material home shelves (and the browse lists) open instantly
# instead of running an up-to-18s resolve live on the home carousel — which
# Material can time out waiting for, leaving the shelf empty/hung (the reason
# the sibling ListenBrainz plugin never resolves inside its home feeds either).
# Scheduled by Plugin::postinitPlugin shortly after startup, then daily, and
# deferred while a library scan runs. Cheap on the daily tick: _findPlayable
# matches are cached (7d found), so real work only happens for reviews that are
# new since the last run. Needs a connected player for the streaming-service API
# context; a quiet no-op (resolution deferred to first open) when none is
# connected.
# ---------------------------------------------------------------------------

# The warm's own resolve deadline (see the note in warmCache). Declared here
# rather than beside BUILD_DEADLINE because a `use constant` has to be compiled
# before the sub that names it.
use constant WARM_DEADLINE => 300;   # backstop for a wedged stage, not a budget

# How long the warm waits for an article fetch (0.9.18). Sized from the fetches
# themselves, which measure 1.5-2.4s quiet and 23.4s starved by resolves — so 45s is a
# wide margin over the worst case ever observed, not a budget. It exists so ONE
# unanswered page costs the warm a deadline rather than the entire run.
#
# NOT 60, which is YEAR_BACKFILL_DELAY. Two unrelated waits landing on the same number
# is the kind of coincidence that makes a test fire the wrong timer and a log impossible
# to read back — and this file is diagnosed almost entirely from its log.
use constant WARM_FETCH_DEADLINE => 45;

# How long $yearStep waits before re-checking whether the year-end list has arrived.
# Only reached when the year fetch outlasts the ENTIRE feed resolve phase, which is
# tens of seconds — so this is a rare path, and short because when it is taken the
# plugin is otherwise idle.
use constant WARM_YEAR_RECHECK => 3;

sub warmCache {
    my ($client) = @_;
    # RETURNS whether the warm actually STARTED (0.9.10), so the caller can retry
    # soon rather than treat "no player yet" as a completed tick. It used to return
    # bare, and _warmTick then re-armed at WARM_INTERVAL — so on any server whose
    # player joins after the warm timer fires, the whole warm silently did not
    # happen for three hours (a full DAY before WARM_INTERVAL came down to 3h).
    # Never seen on Simon's server, where players are always up; a fresh install on
    # a machine that boots faster than its player connects is exactly where it bites.
    $client ||= (Slim::Player::Client::clients())[0];
    unless ($client) {
        _dbg("warm: no connected player yet — will retry");
        return 0;
    }

    # `nostale => 1` on every fetch here (0.8.8). Browsing gets stale-while-
    # revalidate — the last good copy at once, the refresh behind it — but the warm
    # is the thing that DOES the refreshing, and a warm answered from the stale copy
    # would resolve the very list it was supposed to replace and leave the new
    # reviews cold for another cycle.
    my %W = (nostale => 1);

    # TWO PHASES: fetch all four lists AT ONCE, then resolve them one stage at a time
    # (0.9.18). The fetches and the resolves talk to completely independent upstreams —
    # pitchfork.com and Qobuz/Tidal/Deezer — so paying for them in series was ~6-8s of
    # the warm during which nothing resolved and nothing was fetched either.
    #
    # PARALLEL FETCH, SERIAL RESOLVE — and the asymmetry is the whole design, not
    # laziness about the second half. Four HTTP GETs to one CDN-backed site is nothing;
    # four sections of streaming searches at once is the exact burst the sequencing
    # below exists to prevent (0.8.10 measured 48 searches in flight against a
    # BUILD_CONCURRENCY of 10 when stages overlapped).
    #
    # WHY THE FETCHES ARE NOT MERELY OVERLAPPED WITH THE RESOLVES, which was the
    # obvious idea and is the wrong one. They share our event loop with the Qobuz
    # plugin's `_precacheAlbum`, which runs over every returned row before our callback
    # sees any of it: an article fetch that lands while resolves are running was
    # measured at 23.4s against 1.5-2.4s quiet. Overlapping stage N+1's fetch with
    # stage N's resolve therefore turns a 13s stage + 2s fetch into max(13s, 23s) —
    # slower, from the change that looks like it must be faster. Front-loading keeps
    # every fetch in quiet time, which is the only time they are cheap.
    #
    # It also front-loads what a user actually sees first. The parsed rows — artist,
    # album, capsule, score, date, cover — are in the DB within a couple of seconds of
    # the warm starting, for ALL four sections rather than the first one only. Opening
    # a section during the resolve phase then gets a complete list of rows with
    # matches filling in, instead of an empty view waiting on its own fetch.
    #
    # THE SERIAL HALF STILL NEEDS WARM_DEADLINE, or the chaining is decorative
    # (0.8.10). _resolveSection calls back at BUILD_DEADLINE with whatever has resolved
    # by then and deliberately keeps pumping the rest — right for a view, which has a
    # render to get on screen, but here the callback is what STARTS THE NEXT STAGE.
    # A cold 50-item stage takes ~13s at 2.63s/album ÷ 10, so each stage began with the
    # one before it still running. The warm has nothing to render, so it does not want
    # a render deadline — WARM_DEADLINE is a stuck-stage backstop, an order of
    # magnitude past any real stage, not a budget anything is expected to hit.
    # ONLY THE THREE FEEDS GATE THE RESOLVE PHASE — the year does NOT, and that
    # asymmetry was found by the yield test rather than reasoned out in advance. The
    # year is the one fetch that is not a single GET: `_viewYear` probes for the newest
    # published list (several candidate slugs on a cold server) and only then asks for
    # the list itself. Gating on all four made the three sections a user opens first
    # wait behind the slowest, least-urgent one. It is also the LAST stage, so waiting
    # for it up front buys nothing at all.
    #
    # So the year is issued FIRST (its head start is free — it is running while the
    # feeds are still being fetched, i.e. in the quiet window before any search goes
    # out) and collected LAST, by $yearStep.
    my (%got, @back, $year);
    my $feeds     = 3;                     # reviews + bnm + hsa
    my $yearReady = 0;                     # the year fetch has answered, list or not
    my $t0        = Time::HiRes::time();
    my $fired     = 0;
    my $resolveAll;

    # PHASE 2, entered once the three feeds have answered — or once WARM_FETCH_DEADLINE
    # says they never will. A LIST THAT DID NOT ARRIVE IS SIMPLY ABSENT, not a reason to
    # abandon the warm: three good sections beat none because one page 500'd.
    my $begin = sub {
        return if $fired++;
        _dbg(sprintf('warm: %d feed list(s) fetched in %.1fs — resolving',
            scalar(grep { $_ ne 'year' } keys %got), Time::HiRes::time() - $t0));
        $resolveAll->();
    };

    my $arrived = sub {
        my ($stage, $items) = @_;
        $got{$stage} = $items if $items && @$items;
        return $yearReady = 1 if $stage eq 'year';
        $begin->() unless --$feeds;
    };

    # EVERY "should always call back" in this file has eventually not — the %PENDING
    # strand, the backfill guard, the no-player hole. A fetch that never answers must
    # cost the warm one deadline, not the whole run. ONE timer covers both waits and is
    # deliberately NOT killed on success: it then needs no bookkeeping, and firing into
    # a finished warm is a no-op. It is also what bounds $yearStep's recheck loop.
    Slim::Utils::Timers::setTimer(undef, time() + WARM_FETCH_DEADLINE, sub {
        unless ($yearReady) {
            $log->warn('warm: the year-end list did not answer within '
                . WARM_FETCH_DEADLINE . 's — warming without it');
            delete $got{year};
            $yearReady = 1;
        }
        return if $fired;
        $log->warn('warm: ' . $feeds . ' feed fetch(es) did not answer within '
            . WARM_FETCH_DEADLINE . 's — resolving what arrived');
        $begin->();
    });

    # Stage order is fixed and deliberate: the three feeds a user opens first, then the
    # year-end list.
    $resolveAll = sub {
        my @stages = ( [ 'reviews', 'Latest Reviews'      ],
                       [ 'bnm',     'Best New Music'      ],
                       [ 'hsa',     'High Scoring Albums' ] );

        my $finish = sub {
            _dbg('warm: done' . (@back ? ' — ' . scalar(@back)
                 . ' back-catalogue year(s) queued for backfill' : ''));
            _backfillYears($client, \@back);
        };

        # The year, collected after the feeds have resolved. By then it has had the whole
        # feed phase (tens of seconds) to arrive, so the recheck is a rare path rather
        # than the normal one — but it must exist, because the alternative is silently
        # dropping the list most likely to be opened next. Bounded by the watchdog above,
        # which sets $yearReady unconditionally, so this cannot spin for ever.
        my $yearStep = sub {
            my ($self) = @_;
            unless ($yearReady) {
                _dbg('warm: feeds done, waiting on the year-end list');
                return Slim::Utils::Timers::setTimer(undef, time() + WARM_YEAR_RECHECK,
                    sub { $self->($self) });
            }
            my $items = $got{year} or return $finish->();
            _dbg("warm: resolving " . scalar(@$items) . " Best Albums of " . ($year // '?'));
            _resolveSection($client, $items, $finish, WARM_DEADLINE, 'warm');
        };

        # Self-passing sub, not a self-capturing closure — the reference-cycle
        # reasoning documented at _findPlayable's $collect applies here too.
        my $step = sub {
            my ($self) = @_;
            while (my $s = shift @stages) {
                my $items = $got{ $s->[0] } or next;      # never fetched / empty
                _dbg("warm: resolving " . scalar(@$items) . " $s->[1]");
                return _resolveSection($client, $items, sub { $self->($self) },
                    WARM_DEADLINE, 'warm');
            }
            $yearStep->($yearStep);
        };
        $step->($step);
    };

    {
        # ...then the year-end list. This probe is what
        # PROMOTES a newly published list on its own: while the
        # current year is still awaited the "latest year" answer is
        # only held 12h, so the December publication is picked up by
        # the next tick or two without anyone opening the menu and
        # without a plugin update. Warming only the newest list and
        # the one the user actually reads is deliberate — the other
        # eight are immutable and resolve on demand, so re-matching
        # all ten every tick would be 500 albums of pointless
        # streaming traffic.
        # _viewYear (not getLatestYear) so the warm ALSO applies
        # the promotion — a list published overnight moves the
        # prefs on the tick, and the tile and home shelf already
        # name the new year before anyone opens either.
        #
        # ONE list, not two (0.8.10). 0.8.8 warmed this one and
        # then `year_last` as well, on the reasoning that the
        # sticky pick would otherwise be left cold — but that was
        # written when the warm used getLatestYear. Through
        # _viewYear the year warmed here IS `year_last` on every
        # reachable path (promotion sets both; the sticky branch
        # returns the pref; the out-of-range branch now repairs
        # it), so the second pass could never fire, and the sub
        # that did it has gone. Nothing renders the newest list
        # while a user is pinned to an older one either — every
        # surface reads _viewYear — so there is no cold list left
        # behind: the year that is warmed is the year that shows.
        #
        # ...AND THE OTHER NINE ARE WARMED TOO — BUT NOT HERE (0.9.10).
        # 0.9.0 added every year to THIS chain, and the reasoning for
        # warming them was right (immutable lists, so it pays for ever;
        # a cold first open of an old year was a measured 12s wait).
        # Its reasoning about the COST was not. It rested on a field
        # measurement — "138 albums across four stages in ELEVEN
        # MILLISECONDS, because a warm item costs a cache lookup, not a
        # search" — which describes the SECOND run and says nothing
        # about the first. On a genuinely cold start those ten lists are
        # 500 live searches: measured at 252 of the warm's 306 seconds,
        # four minutes of streaming traffic AFTER the plugin already had
        # everything a user opens.
        #
        # So the chain ends at the year on screen, and the back
        # catalogue follows behind it — see _backfillYears, which keeps
        # the newest-first order and the sequential, yielding shape.
        # Same coverage, same eventual benefit, off the critical path.
        #
        # 0.9.0 also called the prefetch gentle because "concurrency
        # never exceeds BUILD_CONCURRENCY — prefetching all ten extends
        # the DURATION of the warm, not its peak load". True of the warm
        # ALONE, and still the wrong conclusion: duration is precisely
        # what made the peak reachable, because the limit is per-section
        # and a browse landing mid-warm ran its own searches on top.
        # Stretching the warm from seconds to a five-minute prefetch
        # turned that overlap from a rarity into the normal case.
        # ISSUED FIRST, COLLECTED LAST. Two chained requests, unlike the other three —
        # identify the year, then ask for its list — so it gets the head start, and it
        # is picked up by $yearStep after the feeds rather than gating them.
        _viewYear(sub {
            $year = shift;
            # NO YEAR IS NOT THE END OF THE WARM ANY MORE (0.9.18). It used to
            # `return _dbg("warm: done (no year-end list found)")` from inside the
            # innermost callback, which abandoned the backfill AND reported a completed
            # warm — survivable only because the three feeds had already resolved above
            # it. Nothing has resolved at this point now, so a missing year has to
            # report itself as a missing year and hand back an empty stage.
            unless ($year) {
                _dbg('warm: no year-end list found — warming the three feeds only');
                return $arrived->('year', []);
            }
            _setHomeYearTitle($client, $year);

            my $latest = Plugins::PitchforkReviews::API::cachedLatestYear() || $year;
            my $min    = Plugins::PitchforkReviews::API::YEAR_MIN();
            @back      = grep { $_ != $year } reverse $min .. $latest;

            # THE WARM ENDS AT THIS YEAR. The nine back-catalogue years are kept, but
            # moved BEHIND it (see _backfillYears).
            Plugins::PitchforkReviews::API::getYearList($year,
                sub { $arrived->('year', shift) }, %W);
        });
    }

    Plugins::PitchforkReviews::API::getListing(sub { $arrived->('reviews', shift) }, %W);
    Plugins::PitchforkReviews::API::getBnm(sub     { $arrived->('bnm',     shift) }, %W);
    Plugins::PitchforkReviews::API::getHsa(sub     { $arrived->('hsa',     shift) }, %W);

    return 1;
}

# ---------------------------------------------------------------------------
# BACK-CATALOGUE BACKFILL (0.9.10) — the other nine year-end lists, warmed one at
# a time, well behind everything a user is likely to touch.
#
# 0.9.0 was right that a cold first open of an old year is a bad experience, and
# right that the lists are immutable so warming them pays for ever. It put them in
# the WRONG PLACE: on the main warm chain, ahead of nothing, where they were 252 of
# the warm's 306 seconds (measured, 06:33-06:38 cold start). For four of those five
# minutes the plugin had already finished everything a user opens and was still
# hammering Qobuz for lists nobody had asked for — and every browse landing in that
# window fought it for the same API.
#
# So: same work, same benefit, sequenced last. The main warm now reports done as
# soon as the three feeds and the on-screen year are resolved, which is the moment
# the plugin actually looks populated; the back catalogue trickles in after, spaced
# by YEAR_BACKFILL_DELAY and yielding to any view like the rest of the warm.
#
# NEWEST-FIRST, because a newer list is likelier to be the next one opened.
#
# A named sub, not the self-passing closure the other drivers use: the recursion is
# across timer callbacks rather than inside one pump, so there is no closure to leak
# and the plain form is clearer.
#
# DELIBERATELY NO "already running" GUARD. One was written and removed the same hour,
# because the test suite immediately caught what it costs: a flag set on entry and
# cleared on completion is OFF FOR THE LIFE OF THE PROCESS if any chain fails to call
# back, and this file has now been bitten by that exact shape twice — the %PENDING
# strand in API.pm and the no-player hole that switched the warm off for three hours.
# What the guard bought was not worth it: WARM_INTERVAL is 3h and a full backfill is
# ~13 minutes, so two cannot realistically overlap, and if they ever did the second
# would find every year cached and cost almost nothing. Less state, no way to wedge.
# ---------------------------------------------------------------------------
use constant YEAR_BACKFILL_DELAY => 60;   # gap between back-catalogue years

sub _backfillYears {
    my ($client, $years) = @_;

    return _dbg('warm: backfill done') unless @{ $years || [] };

    my $y = shift @$years;
    Slim::Utils::Timers::setTimer(undef, time() + YEAR_BACKFILL_DELAY, sub {
        Plugins::PitchforkReviews::API::getYearList($y, sub {
            my $yr = shift || [];
            _dbg("warm: backfilling " . scalar(@$yr) . " Best Albums of $y");
            _resolveSection($client, $yr, sub {
                _backfillYears($client, $years);
            }, WARM_DEADLINE, 'warm');
        }, nostale => 1);
    });
}

# Resolve every item to a streaming album (bounded concurrency), stashing the
# matched album node on $it->{_album}. Renders once all settle OR a deadline hits
# (partial: unresolved items render with the Pitchfork cover + drill, and self-heal
# from cache on the next open). Cheap after the first build — matches are cached.
#
# THE PER-ALBUM COST, RE-MEASURED (0.9.10). This block long carried "a cold resolve
# of one album measured 2.63s", from 0.8.8. That figure sized a proposal wrongly in
# review and has been replaced with numbers taken off the live server's own warm
# stages, which resolve at a known width with nothing else running:
#
#     30 items / 18.85s  |  29 items / 14.08s  |  50 items / 31.50s   at width 2
#     => roughly 1.0-1.3s per cold album
#
# NOTE WHAT THAT DOES *NOT* LICENSE: dividing by a wider concurrency to predict a
# cold section's wall time. The log contains no uncontended width-10 measurement, and
# nothing here establishes that the streaming APIs scale linearly with concurrency.
# If a number is needed for a deadline, measure one cold section at that width with
# nothing else running — do not extrapolate from these.
#
# At the old concurrency of 6 a cold 50-item year list needed
# ~22s — PAST the old 18s deadline, so a genuinely fresh year list rendered
# partial every single time. Both numbers move together (0.8.8): _findPlayable now
# probes the top-priority service ALONE first and only fans out to the rest if it
# misses, which cuts the streaming API calls behind a hit to a third, so a higher
# concurrency costs the services less than 6 did before. The deadline comes DOWN
# rather than up: nobody should stare at a building list for 18s, and the pump
# deliberately keeps resolving past the deadline, so whatever missed the cut is
# already cached and the view completes itself on the next open.
#
# The deadline is overridable per caller, and the WARM is why (0.8.10): its stages
# are chained on this callback, so firing it early doesn't degrade a render there —
# it starts the next stage on top of the running one. See warmCache/WARM_DEADLINE.
use constant BUILD_CONCURRENCY => 10;
# BUILD_DEADLINE is declared up beside VIEW_DEADLINE (compile order — the home
# shelves name it and sit above this point). It is 10s: the shelf budget, and
# _resolveSection's default when a caller passes none.

# The warm's own dispatch width, and the rule that keeps it out of the user's way.
#
# BUILD_CONCURRENCY is PER _resolveSection CALL, not global — which was harmless
# while the warm was four quick stages, and became the plugin's worst lag the moment
# 0.9.0 made it prefetch ten years. A browse that lands mid-warm starts its OWN
# section, so the server ran 10 warm searches plus 10 view searches against the same
# streaming APIs, and the warm now stays busy for the whole cold prefetch rather than
# a few seconds. That is the "very laggy navigation" from the field, and it is
# exactly the slow-machine bite Simon predicted before the build was cut.
#
# Two rules fix it, both here so they cannot drift apart:
#   1. the warm dispatches WARM_CONCURRENCY at a time, not BUILD_CONCURRENCY;
#   2. the warm dispatches NOTHING while a foreground resolve has work in flight.
# The foreground therefore keeps its full width and competes with nobody. A paused
# warm is not a stalled one: it re-checks on a timer and resumes as soon as the view
# it yielded to is done, and it has no deadline it can miss (WARM_DEADLINE is a
# wedged-stage backstop, and the yield timer is not a stall it can trip).
use constant WARM_CONCURRENCY   => 2;
use constant WARM_YIELD_RECHECK => 3;   # seconds between "is the user still browsing?" checks

# ...and a bound on how long the warm will defer, so that yielding can never become
# NOT RUNNING. $FG_INFLIGHT only falls when a _findPlayable answers; every service
# search is watchdogged (STREAM_SVC_TIMEOUT), so it should always drain — but "should
# always" is the assumption behind most of what went wrong here, and the cost of it
# being false is a warm that stays switched off until the server restarts, silently.
# After this long the warm stops trusting the count and proceeds at its own narrow
# width. A genuinely busy foreground still gets two full minutes of priority.
use constant WARM_YIELD_MAX => 120;

# BACKING THE WARM OFF WHILE A SERVICE IS REFUSING US (0.9.36; reactive since 0.9.37).
#
# Measured on the live server, 2026-09-15: once the Spotify adapter re-keyed the store, the
# startup warm drew 184 Spotify `502 Bad Gateway`s inside a minute and the year backfill drew
# `429 Too Many Requests` (retry after 3-7s). Ten Refreshes fired together on a quiet server drew
# none, so ordinary width is fine and the trouble is a sustained burst into a refusing quota.
#
# 0.9.36 paced the WHOLE warm (one album, a 1s gap) whenever Spotify was on Spotty's shared default
# Client ID. REJECTED BY SIMON AS FAR TOO SLOW — a cold pass went from about a minute to twenty or
# more, a big step backwards when no other service makes the warm wait. Do not restore it. The
# warm now runs at full width and backs off ONLY WHILE an adapter says it is being refused
# (`pace_warm`, asked before every dispatch): one album at a time, PACED_WARM_GAP after each live
# resolve, back to full width once the refusals stop. A healthy run pays nothing.
#
# THE WARM ONLY. A view has a person waiting on it and a shelf has a carousel to fill.
#
# THE PUMP, NOT A QUEUE IN FRONT OF THE SEARCH: every service leg carries a STREAM_SVC_TIMEOUT
# watchdog, so a search held in a queue longer than that would be recorded ERRORED without ever
# being sent. A cache hit answers synchronously (from inside the pump — see $pumping) and never
# waits.
#
# BUT SYNCHRONOUS IS NOT CACHED (0.9.39). Spotty refuses in the same call stack, so a refusal also
# answers from inside the pump. The resolver tags it (`_refused`, set in `_svcCantAnswer`, carried
# through `_findPlayable`, `_findPlayableSubtitle` and `_findPlayableReview`) and the pump holds on
# it; before that a Spotify-only warm ran every album through the lockout in one turn. The gap is
# ONE re-armed wakeup plus `$holding`, which stops the launch loop — see the note in the pump. Same
# fix as LBF 1.0.5; the rules are in docs/streaming-adapter-spec.md §6.
#
# WHAT IT CANNOT SEE: a 502 or a timeout carries no signal through Spotty, so those are not backed
# off from. What they cost is bounded by `empty_unverified` (see _streamTtl): a row that loses
# Spotify to one is held a day, not thirty.
use constant PACED_WARM_GAP => 2;   # seconds between live resolves while backing off

sub _pacedWarm {
    for my $a (_orderedAdapters()) {
        my $want = $a->{pace_warm};
        return 1 if ref $want eq 'CODE' && eval { $want->() };
    }
    return 0;
}

# In-flight foreground (non-warm) _findPlayable calls, across every section being
# resolved. The warm reads this and stands down; nothing else may write it.
my $FG_INFLIGHT = 0;

sub _fgInflight { return $FG_INFLIGHT }   # test seam

sub _resolveSection {
    my ($client, $items, $cb, $deadline, $mode) = @_;

    # THREE CALLERS, NOT TWO (0.9.10). The old boolean $warm conflated width, the
    # yield and the foreground count, which is why home shelves ended up with a
    # view's full width AND a view's claim on $FG_INFLIGHT: they were simply
    # "not the warm". Measured cost on the 08:50 cold start — three shelves each
    # resolving 50 year-list albums at BUILD_CONCURRENCY against the same Qobuz the
    # user's Best New Music view was using, which got 20 of 29 rows in its deadline.
    #
    #   view   full width, never yields, counts toward $FG_INFLIGHT (a human waits)
    #   shelf  narrow, never yields (it has a carousel to fill), NOT counted —
    #          a shelf must not make the warm stand down, or opening Material
    #          suppresses the very warm that makes shelves instant
    #   warm   adaptive width, yields to any view, NOT counted
    $mode ||= 'view';
    my $warm = $mode eq 'warm';

    my @queue = @$items;
    my $total = scalar @queue;
    return $cb->() unless $total;

    my $done     = 0;
    my $active   = 0;
    my $finished = 0;

    my $timer = Slim::Utils::Timers::setTimer(undef, time() + ($deadline || BUILD_DEADLINE), sub {
        return if $finished;
        $finished = 1;
        $log->warn("resolve deadline hit ($done/$total matched-or-tried)");
        $cb->();
    });

    my $complete = sub {
        return if $finished;
        $finished = 1;
        Slim::Utils::Timers::killSpecific($timer);
        $cb->();
    };

    # Self-passing sub, not a self-capturing closure (see _findPlayable): the
    # `my $x; $x = sub {... $x ...}` form leaks itself and everything it captured —
    # here the whole section's item list — once per section resolve.
    #
    # $pumping is the RE-ENTRANCY guard, and it is the warm-cache path that needs
    # it: _findPlayable answers a cache hit SYNCHRONOUSLY, so the completion below
    # used to call back into the pump from inside the very while-loop iteration
    # that started it, and the stack grew one frame per item — 50 deep on a year
    # list, ~150 on a full warm, with the whole feed build then running at the
    # bottom of it. Returning early instead is not a lost wakeup: $active has
    # already been decremented, so the loop we return into picks the next item up
    # on its own. An ASYNC completion still finds $pumping false and re-enters
    # normally, which is the only case that ever needed to.
    my $pumping  = 0;
    my $yielding = 0;   # when this warm first stood down (see WARM_YIELD_MAX)
    # THE BACK-OFF GAP (0.9.39): ONE wakeup, re-armed, and a flag that stops the LAUNCH LOOP
    # while it is pending. One timer per completion left a stray wakeup per album in flight when
    # the back-off began, and each stray launched a search straight after the one before it
    # completed — no gap at all. $holding matters because a hold decided from INSIDE the loop (a
    # synchronous refusal) does not stop the loop by arming a timer. See PACED_WARM_GAP.
    my $holding  = 0;
    my $gapTimer;

    # WIDTH IS RE-READ EVERY ITERATION, not fixed at entry (0.9.10). A warm pinned
    # at WARM_CONCURRENCY was the right fix for the wrong problem: 0.9.1 narrowed it
    # so it would stop competing with a browsing user, but the YIELD below already
    # does that — completely, by holding the queue rather than merely slowing it. So
    # the narrow width never protected anybody; it only applied when nobody was
    # browsing, which is precisely when the warm should be going flat out. Measured:
    # the three feed lists take 54s at width 2 on a cold start, and until they finish
    # the plugin looks empty to anyone who opens it.
    #
    # So: wide while the foreground is idle, narrow only in the one case the yield
    # deliberately gives up on — a $FG_INFLIGHT that has not drained inside
    # WARM_YIELD_MAX, where the warm resumes anyway and must stay out of the way.
    # SHELVES ARE ADAPTIVE TOO (0.9.12), not pinned narrow. 0.9.11 fixed the wrong half
    # of the shelf problem: they were starving browse views, so they were pinned at the
    # warm's narrow width — and the field log showed the cost immediately. Home shelves
    # went from 34/50 resolved inside their deadline to **9/50**, so for the first ~90
    # seconds after a restart the Material home carousel was mostly unplayable cards.
    # That is worse than the contention it fixed, and on a surface the user sees first.
    #
    # A shelf sits between the two: it has a carousel to fill, so unlike the warm it can
    # never yield outright, but it is lower priority than a view someone is watching. So
    # it takes the same adaptive rule as the warm — full width while no view is
    # resolving, which on the home page is the normal case, and narrow the moment one
    # starts. That restores the shelf fill without putting back the starvation.
    my $widthNow = sub {
        return BUILD_CONCURRENCY if $mode eq 'view';
        return 1 if $warm && _pacedWarm();   # backing off — see PACED_WARM_GAP
        return $FG_INFLIGHT ? WARM_CONCURRENCY : BUILD_CONCURRENCY;
    };
    my $pump = sub {
        my ($self) = @_;
        return if $pumping;
        $pumping = 1;

        # YIELD. A warm holds its queue while any view is resolving, and re-checks
        # on a timer rather than spinning. Only when it has nothing of its own left
        # in flight, or the wakeup could be lost: an $active completion re-pumps by
        # itself, so arming a second timer there would just duplicate the check.
        # Bounded by WARM_YIELD_MAX so a count that never drains cannot switch the
        # warm off for the life of the process.
        if ($warm && $FG_INFLIGHT && @queue) {
            $yielding ||= time();
            if (time() - $yielding < WARM_YIELD_MAX) {
                $pumping = 0;
                Slim::Utils::Timers::setTimer(undef, time() + WARM_YIELD_RECHECK,
                    sub { $self->($self) }) unless $active;
                return;
            }
            $log->warn("warm: foreground has been busy for " . (time() - $yielding)
                . "s — resuming anyway at " . WARM_CONCURRENCY . " in flight");
        }
        $yielding = 0;

        while (!$holding && $active < $widthNow->() && @queue) {
            my $it = shift @queue;
            $active++;
            my $counted = $mode eq 'view';   # decrement exactly once, whatever the callback does
            $FG_INFLIGHT++ if $counted;
            _findPlayableReview($client, sub {
                my $res = shift;
                my $refusedNow = ref $res eq 'HASH' && $res->{_refused};
                # ONE node per SIDE, in the order the resolver returned them. For an
                # ordinary review that is simply the first match (every node is side 0,
                # and the editions/services behind it are alternatives to the SAME
                # album, not other albums). For a combined "A / B" review it is the
                # best match for each release: the first becomes the playable row,
                # the rest ride along as $it->{_alt} for the drill-in.
                my (%bySide, @order);
                for my $node (_realMatches($res)) {
                    my $side = defined $node->{_side} ? $node->{_side} : 0;
                    next if exists $bySide{$side};
                    $bySide{$side} = $node;
                    push @order, $side;
                }
                if (@order) {
                    $it->{_album} = $bySide{ $order[0] };
                    my @alt = map { $bySide{$_} } @order[1 .. $#order];
                    # ORDINARY REVIEWS ALSO OFFER A GENUINELY DIFFERENT RELEASE (0.9.27).
                    # Only when there is ONE side: a combined review's alts already mean
                    # "the review also covers this", and mixing the two claims on one page
                    # would make neither readable.
                    push @alt, _releaseAlts($it->{_album}, $res) if @order == 1;
                    $it->{_alt} = \@alt if @alt;
                }
                $active--;
                $done++;
                $FG_INFLIGHT-- if $counted;
                $counted = 0;
                $complete->() if $done >= $total;
                # A warm that is BACKING OFF spaces LIVE resolves only. $pumping is still set when
                # this runs synchronously from inside the loop below, which is USUALLY a cache hit,
                # and then the loop simply carries on; an async completion was a real search, so the
                # next one waits.
                #
                # ONE EXCEPTION (0.9.39): a synchronous REFUSAL. Spotty refuses in the same call
                # stack (`getToken` does `return $cb->(-429)`), so "synchronous" does not mean
                # "cached" — a Spotify-only warm ran every album through the lockout in one turn,
                # each stored "couldn't check" for STREAM_INCONCLUSIVE_TTL. The resolver says so
                # (`_refused`), and the pump holds on it.
                if ($warm && @queue && _pacedWarm() && (!$pumping || $refusedNow)) {
                    $holding = 1;
                    Slim::Utils::Timers::killSpecific($gapTimer) if $gapTimer;
                    $gapTimer = Slim::Utils::Timers::setTimer(undef, time() + PACED_WARM_GAP, sub {
                        $gapTimer = undef;
                        $holding  = 0;
                        $self->($self);
                    });
                    return;
                }
                $self->($self);   # keep resolving to warm the cache even past the render deadline
            }, $it->{artist}, $it->{album}, undef, _subtitleMinYear($it));
        }
        $pumping = 0;
    };
    $pump->($pump);
}

# Force-refresh this section and reload the view in place. Material honours
# nextWindow => 'refresh' only on an EMPTY response, so return no items.
sub _refreshRow {
    my ($client, $source) = @_;
    return {
        name        => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_REFRESH'),
        type        => 'link',
        image       => REFRESH_ICON,   # Material refresh glyph (same as LBF); also keeps Material's grid view enabled
        nextWindow  => 'refresh',
        passthrough => [ { source => $source } ],
        url         => sub {
            my ($c, $cb, $args, $pt) = @_;
            my $reload = sub { $cb->({ items => [], nextWindow => 'refresh' }); };
            my $src    = $pt->{source} // '';
            if    ($src eq 'bnm') { Plugins::PitchforkReviews::API::getBnm($reload, force => 1); }
            elsif ($src eq 'hsa') { Plugins::PitchforkReviews::API::getHsa($reload, force => 1); }
            # "year:<Y>" — the row does TWO jobs: re-parse this list, and re-probe for a
            # newer one, so it is also the manual "has the new list landed yet?" button.
            # BOTH ARE DONE EXACTLY ONCE, AND THE ORDER IS WHAT GUARANTEES IT.
            #
            # Re-pull $y FIRST, forced: a stored year has no TTL at all, so force is the
            # only thing that can re-pull one, and a Refresh that reads the store is a
            # no-op (pinned since 0.9.11). Probe SECOND: getLatestYear walks candidates
            # from _topYear down, and its probes no longer force (0.9.26 — they carry
            # `resweep` instead: past the negative markers, never past the store), so
            # every candidate it already holds answers from the DB for nothing. By the
            # time it reaches $y — if it gets that far, which it does only when $y is the
            # newest — the fetch above has just stored it, so the probe cannot download it
            # a second time whether or not $y was stored when the tap arrived.
            #
            # 0.9.24's `$probed` shortcut is GONE, and reinstating it is now a defect:
            # it inferred "the probe already re-pulled $y" from the probe ANSWERING with
            # $y, which was true only while the probe forced. Against a probe that answers
            # from the store it reads true on a plain DB hit, and Refresh on the newest
            # year — the year the view opens on — silently stops re-pulling anything.
            elsif ($src =~ /^year:(\d+)$/) {
                my $y = $1;
                Plugins::PitchforkReviews::API::getYearList($y, sub {
                    Plugins::PitchforkReviews::API::getLatestYear($reload, force => 1);
                }, force => 1);
            }
            else                  { Plugins::PitchforkReviews::API::getListing($reload, force => 1); }
        },
    };
}

# One review row. If it resolved to a streaming album ($it->{_album}), render THAT
# node — playable from the list (Play/Add), with the service's album artwork —
# relabelled with the review artist/album + capsule, AND its tracklist drill-in is
# wrapped so it also carries the review — capsule + "Read the full review" (see
# _attachReviewLink). Otherwise a Pitchfork-cover row that drills to the detail page
# (capsule + Read review + Refresh streaming match).
#
# A COMBINED "A / B" review (see _findPlayableReview) resolves to more than one album.
# The row stays exactly what it is here — ONE row, playable, being the review's FIRST
# release — and the others ride in $it->{_alt} into the drill-in. Splitting the review
# into two sibling rows was the alternative and is wrong twice over: it would double a
# ranked year-end list's entries against Pitchfork's own numbering, and Material keys
# non-playable rows by parent id + title, so paired rows built from one review are
# exactly the collision that already loses a row elsewhere in this file.
sub _reviewRow {
    my ($client, $it, $headers) = @_;

    my $artist = $it->{artist};
    my $album  = $it->{album};
    my $line1  = length $artist ? "$artist - $album" : $album;

    # Year-end list rows lead with their position — it IS the content of a ranked
    # list, and the rows are otherwise indistinguishable in Material's grid view.
    # Safe for the ListenLater handshake: `&al=` carries the matched SERVICE's
    # title (_attachFavUrl), which is always present on a matched row, so LL never
    # falls back to reading this label. Reviews (no rank) are untouched.
    $line1 = "$it->{rank}. $line1" if defined $it->{rank};

    if (my $al = $it->{_album}) {
        my %row = %$al;                                   # playable album node (url coderef, type playlist)
        # The service node carries its own name/line1/line2 (which Material prefers),
        # so relabel ALL of them to the review's "Artist - Album" + capsule.
        $row{name}  = $line1;
        $row{line1} = $line1;
        $row{line2} = _line2($client, $it);
        # Prefer the album cover, then the Pitchfork cover, then the service logo —
        # so a match with no album art still shows real artwork, not just the logo.
        # _fitCover caps an oversized service cover (see MAX_COVER_PX); it is applied
        # HERE rather than at match time on purpose — the row is built fresh on every
        # render, so every already-cached match gets the smaller picture immediately,
        # with no pfr:stream cache-version bump and no re-resolve of anything.
        $row{image} = _fitCover($al->{_cover} || $it->{cover} || $al->{image}) || DIVIDER_ICON;
        # Keep it playable from the list, but make the drill-in also carry the review
        # link (the row was purely the album node before, so tapping went straight to
        # the tracklist and the "Read the full review" link was unreachable).
        _attachReviewLink($client, \%row, $it);
        return \%row;
    }

    return {
        name        => $line1,
        line1       => $line1,
        line2       => _line2($client, $it),
        image       => (_fitCover($it->{cover}) || DIVIDER_ICON),   # always set (keeps Material's grid view enabled)
        type        => 'link',
        url         => \&reviewDetail,
        # $it is the CACHED parsed item — never write into it. The header
        # capability travels as a SEPARATE passthrough element so the detail page
        # can draw its dividers (see reviewDetail).
        passthrough => [ $it, { headers => ($headers ? 1 : 0) } ],
    };
}

# Wrap a matched album node's tracklist coderef so drilling into the album shows the
# review — capsule, then the "Read the full review" link — above the tracks, WITHOUT
# losing playability: the row stays a `type => 'playlist'` node (Play/Add from the list
# still queue the album), and every injected item is non-audio so play traversal skips
# them. The wrapper is built fresh each render (live feed, cachetime => 0) — no caching
# concern.
#
# The CAPSULE is here because `reviewDetail` — the only other place it lives — is
# reachable ONLY by an UNMATCHED row, so the better a review resolved, the less of it
# you could read: a matched album drilled straight into the tracklist. The row's own
# line2 carries a copy, but truncated to ROW_CAPSULE_MAX.
#
# The Pitchfork GENRE is deliberately NOT injected here (`reviewDetail` does show it).
# The service's own tracklist tail already ends in a "Genre: …" text row, and Material
# keys non-playable plugin rows by parent id + TITLE — two rows both reading
# "Genre: Pop" (Pitchfork's and Qobuz's agreeing, which is the common case) collide on
# that key and one of them silently disappears. The genre is on the row's line2 anyway.
sub _attachReviewLink {
    my ($client, $row, $it) = @_;
    return unless ref $row->{url} eq 'CODE';

    my $link    = $it->{link}    // '';
    my $capsule = $it->{capsule} // '';
    # NO EARLY RETURN ANY MORE (0.9.27). It used to be "nothing to add, leave the node
    # alone", widened once already for the alt-album case. The Refresh row is now
    # unconditional and this sub is only ever called on a MATCHED row, so there is always
    # something to add — and a row with no capsule and no link is precisely the one most
    # likely to have matched something odd, i.e. the one that most needs the way out.

    my $inner = $row->{url};                              # service tracklist coderef (QobuzGetTracks / getAlbum)
    my @intro;
    push @intro, {
        name => $capsule,                                 # in full, unlike the row's truncated line2
        type => 'text',
    } if length $capsule;
    push @intro, {
        name    => cstring($client, _linkLabel($it)),
        type    => 'link',
        weblink => $link,
        image   => LOGO_ICON,                             # Pitchfork mark so it stands out from the album art
    } if length $link;

    # THE OTHER RELEASE(S) OF A COMBINED "A / B" REVIEW (0.9.17). The list row is the
    # FIRST side — playable straight from the list, which is what a review row is for —
    # so without this the second album would be unreachable from a browse list
    # entirely: a matched row's drill-in is the matched album's TRACKLIST, not the
    # detail page, so `reviewDetail` (which does show every side) is only ever reached
    # by rows that DIDN'T match. Each alt is a genuine service album node, so it stays
    # playable in its own right and drills into its own tracks.
    #
    # Labelled with PITCHFORK's side title, not the service's: the point of the row is
    # "this review also covers <B>", and the review is the thing being read here. The
    # node's own name/line1/line2 all get it, because Material prefers whichever the
    # service happened to set.
    for my $alt (@{ $it->{_alt} || [] }) {
        my %a  = %$alt;
        # TWO KINDS OF ALT, TWO DIFFERENT CLAIMS, and they must not share a label. A
        # combined-review side IS covered by the review, and is named with PITCHFORK's side
        # title because the review is the thing being read. A `release` alt is the opposite:
        # the review is about ONE record, and this row exists to say the service carries
        # another one under a similar name — so it is named with the SERVICE's own title
        # (`_svctitle`, artist affix already stripped), which is the only honest label for
        # it and the string the reader needs in order to tell the two rows apart.
        my $rel   = ($a{_altkind} // '') eq 'release';
        my $title = ($rel ? $a{_svctitle} : $a{_sidetitle}) // $a{name} // '';
        my $lbl   = length($it->{artist} // '') ? "$it->{artist} - $title" : $title;
        $a{name}  = $lbl;
        $a{line1} = $lbl;
        $a{line2} = cstring($client, $rel ? 'PLUGIN_PITCHFORKREVIEWS_ALSO_RELEASED'
                                          : 'PLUGIN_PITCHFORKREVIEWS_ALSO_REVIEWED');
        $a{image} = _fitCover($a{_cover} || $a{image}) || DIVIDER_ICON;
        # STRIP THE DIRECT-PLAY AFFORDANCES, because this node is being injected into a
        # PLAYABLE container. The invariant stated at the top of this sub — every injected
        # item is non-audio — is what makes Play/Add on the review row act on the album the
        # row represents. An alt arrives as a genuine service album node, and Deezer's
        # carries `play => deezer://album:<id>` (a direct playable URL, not a browse
        # coderef), so a Play on side A's row could queue side B's album alongside it.
        # `type` is deliberately left as the service set it: the row still DRILLS IN to its
        # own tracklist through its `url`, which is what makes the second release reachable
        # at all, and from there it plays normally. Deleting keys that a given service never
        # sets is a no-op, so this holds the invariant whichever service matched.
        delete @a{ qw(play playlist on_select) };
        push @intro, \%a;
    }

    # REFRESH IS REACHABLE FROM A MATCHED ROW AT LAST (0.9.27). `reviewDetail` has carried
    # this row since 0.8.4, and a matched row has never been able to reach it — the drill-in
    # is the service's tracklist, so the one surface that can correct a bad match was
    # available only to rows that had nothing to correct. With STREAM_FOUND_TTL at 30 days
    # that made a wrong match effectively permanent.
    #
    # It sits BELOW the alternatives on purpose: the rows above are the cheap fix (tap the
    # right release), and re-searching is what you do when none of them is right. Non-audio
    # like everything else here, so the container stays playable.
    push @intro, _refreshMatchRow($client, $it);

    push @intro, { name => "\x{a0}", type => 'text' };    # blank row → gap separating the review from the tracks

    $row->{url} = sub {
        my ($c, $cb, $a, $pt) = @_;
        $inner->($c, sub {
            my $res   = shift;
            my @items = ref $res eq 'HASH'  ? @{ $res->{items} || [] }
                      : ref $res eq 'ARRAY' ? @$res : ();
            $cb->({ items => [ @intro, @items ] });        # capsule, link, gap, then the tracks
        }, $a, $pt);
    };
}

# Pitchfork's review score, rendered for DISPLAY ONLY as "8.4/10" (0.9.40).
#
# WHY THIS IS THE SECTION TEST. Asked for on the three review sections (Best New Music,
# High Scoring Albums, Latest Reviews) and NOT on the year-end lists, which have no score
# to show. No section plumbing is needed to draw that line: `_parseYear` sets
# `score => undef` on every year entry it builds (API.pm, "year-end lists carry no score")
# and the DB column is NULLABLE for exactly that reason, so `defined` already separates the
# two shapes. A ranked row can never reach the true branch.
#
# `defined`, NOT truthiness. Pitchfork really does award 0.0 (Jet, *Shine On*), and a
# truth test would silently drop precisely the score most worth reading.
#
# sprintf %.1f because the site's own idiom is one decimal throughout — JSON gives back a
# bare 10 or 8 for a round score, and "10/10" next to "8.4/10" reads as a different scale.
# The pattern guard is what keeps a non-numeric out of sprintf: `ratingValue.score` is
# whatever the page's state happens to hold, and an unexpected string would otherwise
# render as "0.0/10" — a real score that was never awarded.
#
# THE WORD IS TRANSLATED, NOT A LITERAL (0.9.41). "Score 8.1/10" was asked for over the bare
# number; the plugin ships EN and NL, and `_line2`'s other worded part (the detail page's
# "Genre: …") goes through `cstring`, so this does too. That is the whole reason `_line2` and
# this sub take `$client` — both `_reviewRow` call sites already had one to pass.
sub _scoreLabel {
    my ($client, $it) = @_;
    my $s = ($it || {})->{score};
    return '' unless defined $s && !ref $s && $s =~ /^\d+(?:\.\d+)?$/;
    return cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SCORE') . sprintf(' %.1f/10', $s);
}

# Second line: "Score 8.4/10 · date · genre - truncated capsule" (each part dropped if absent).
# On a year-end row the leading meta is the YEAR instead of the date: every entry
# in a list shares one publication date, so repeating it down all 50 rows says
# nothing, while the year is what the row is actually about.
#
# THE SCORE GOES HERE, ON line2, AND MUST NEVER MOVE TO line1/name. A Pitchfork row that
# matched on SPOTIFY carries no `&al=` handshake — `_attachFavUrl` is skipped wholesale for
# a `native_favurl` adapter, and decorating the favurl is settled as wrong (CLAUDE.md A2) —
# so ListenLater stores that row's LABEL as the album title. Measured on plex:9000:
# `favorites_title "The Cure - Mixed Up"`, High Scoring Albums. Anything added to the label
# lands in LL's database; line2 is read by nothing on its add path. line1 is byte-for-byte
# unchanged by this feature, in every section, matched or not.
#
# AND IT IS DISPLAY ONLY in the other direction too: `_line2` is called from the two
# `_reviewRow` returns and nowhere else. It feeds no cache key, no favurl and no search —
# the streaming resolver queries `$it->{artist}` / `$it->{album}`, which this never touches.
# Material's own search-within-list DOES scan the subtitle (search-list.js reads title AND
# subtitle), but that line already carries the date, the genre and the capsule prose, so the
# score adds no surface that was not already there.
sub _line2 {
    my ($client, $it) = @_;
    my $cap = $it->{capsule} // '';
    $cap = substr($cap, 0, ROW_CAPSULE_MAX) . '...' if length($cap) > ROW_CAPSULE_MAX;
    my $lead = defined $it->{rank} ? ($it->{year} // '') : _shortDate($it->{date});
    my $meta = join(" \x{b7} ", grep { length } _scoreLabel($client, $it), $lead, ($it->{genre} // ''));
    return join(' - ', grep { length } $meta, $cap);
}

# Detail page: streaming matches (playable) + capsule + Read review link.
sub reviewDetail {
    my ($client, $cb, $args, $it, $opts) = @_;

    # The row that opened this page passes down whether the client draws headers
    # (_reviewRow stashes it beside $it). XMLBrowser gives `features` only to the
    # TOP feed, never to a coderef sub-feed like this one, so without that stash
    # the detail page could never know — and would silently fall back to plain
    # text on Material, the one skin these dividers exist for.
    my $headers = defined $opts->{headers} ? $opts->{headers}
                :                            _wantHeaders(_featuresOf($args));

    my $done = 0;
    my $finish = sub {
        return if $done;
        $done = 1;
        my $streamItems = shift || [];

        # Three sections, each under its own Material divider — the same shape the
        # list views and the sibling ListenBrainz plugin's detail pages use. Every
        # header here is $noIcon: there is nothing to drill into (the rows sit
        # directly below) and the logo thumbnail on each would just be clutter.
        # Options first, so the action row is labelled rather than sitting bare
        # above the album.
        my @opt = ( _refreshMatchRow($client, $it) );
        my @rows = ( _sectionHeader($client, cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SECTION_OPTIONS'), $headers, \@opt, 1),
                     @opt );

        # Streaming matches (playable). The section is omitted entirely when nothing
        # resolved — it would say only that the plugin tried, and the review rows
        # below are what the page still has to offer.
        #
        # TEST FOR A REAL MATCH, NOT FOR A NON-EMPTY LIST (0.8.10). _findPlayable
        # answers through _streamResult, which never returns an empty list: a
        # no-match comes back as a one-element "No matching album" TEXT row. So
        # `if @$streamItems` was true on every path that goes through the resolver,
        # and the omission above only ever happened on the watchdog path (which
        # passes a literal []) — i.e. the header was drawn over the very placeholder
        # it was written to suppress. `_svc` is the field that marks a genuine
        # service node (_rebuildStreamItems keys the cache round-trip on it).
        my @stream = grep { ref $_ eq 'HASH' && $_->{_svc} } @$streamItems;
        push @rows, _sectionHeader($client, cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SECTION_STREAMING'), $headers, \@stream, 1),
                    @stream
            if @stream;

        my @rev;
        if (length($it->{genre} // '')) {
            push @rev, {
                name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_GENRE') . ': ' . $it->{genre},
                type => 'text',
            };
        }
        if (length($it->{capsule} // '')) {
            push @rev, { name => $it->{capsule}, type => 'text' };
        }
        if (length($it->{link} // '')) {
            push @rev, {
                name    => cstring($client, _linkLabel($it)),
                type    => 'link',
                weblink => $it->{link},
            };
        }
        push @rows, _sectionHeader($client, cstring($client, _detailSectionLabel($it)), $headers, \@rev, 1), @rev
            if @rev;

        $cb->({ items => \@rows, cachetime => 0 });
    };

    # Watchdog: if a streaming search never calls back, still render the capsule
    # + link rather than hanging the page.
    Slim::Utils::Timers::setTimer(undef, time() + DETAIL_TIMEOUT, sub { $finish->([]) });

    _findPlayableReview($client, sub {
        my $res = shift;
        $finish->($res->{items} || []);
    }, $it->{artist}, $it->{album}, undef, _subtitleMinYear($it));
}

# "Refresh streaming match": force-re-resolve THIS album past the cache (which
# rewrites the cached result), then reload the detail page in place so it renders
# the fresh match. Material honours nextWindow => 'refresh' on an empty response.
sub _refreshMatchRow {
    my ($client, $it) = @_;
    return {
        name        => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_REFRESH_MATCH'),
        type        => 'link',
        nextWindow  => 'refresh',
        passthrough => [ $it ],
        url         => sub {
            my ($c, $cb, $args, $pt) = @_;
            # Through the REVIEW resolver, so Refresh on a combined "A / B" review
            # re-resolves the whole title AND both sides — otherwise the one row that
            # most needs a manual retry is the one it can't reach.
            _findPlayableReview($c, sub {
                $cb->({ items => [], nextWindow => 'refresh' });
            }, $pt->{artist}, $pt->{album}, 1, _subtitleMinYear($pt));   # $force = 1 -> skip the cache read
        },
    };
}

# Which string labels the outbound Pitchfork link. A review row links to its own
# review; a year-end row has no per-entry review link to offer (Pitchfork doesn't
# put one in the list), so it links to the list itself and must say so rather than
# promising a review the tap won't deliver.
sub _linkLabel {
    my ($it) = @_;
    return defined $it->{rank}
        ? 'PLUGIN_PITCHFORKREVIEWS_READ_LIST'
        : 'PLUGIN_PITCHFORKREVIEWS_READ_REVIEW';
}

# ...and what to call the section holding that prose. A review page holds a
# review; a year-end entry holds Pitchfork's write-up of the album, which is not
# a review and must not claim to be (the same distinction _linkLabel draws).
sub _detailSectionLabel {
    my ($it) = @_;
    return defined $it->{rank}
        ? 'PLUGIN_PITCHFORKREVIEWS_SECTION_ENTRY'
        : 'PLUGIN_PITCHFORKREVIEWS_SECTION_REVIEW';
}

# "Wed, 02 Jul 2025 05:00:00 GMT" -> "02 Jul 2025" (best-effort; pass through
# anything that doesn't match).
# Short date for a row's line2. Handles ISO ("2026-07-07T...") -> "7 July 2026",
# and passes through an already-short string.
sub _shortDate {
    my $d = shift // '';
    return _fmtDate($1) if $d =~ /^(\d{4}-\d{2}-\d{2})/;
    return $1 if $d =~ /(\d{1,2}\s+\w{3}\s+\d{4})/;
    return $d;
}

# ---------------------------------------------------------------------------
# Week dividers (Material headers) — ports the ListenBrainz plugin's mechanics.
# Group the (newest-first) feed into weeks and insert a divider before each. On a
# header-capable client the divider is a real Material header (bold/accent); other
# skins get plain text. XMLBrowser forces a drill action onto the older 'header'
# type, so the header carries a url returning that week's rows (header-basic, on
# Material 6.4.3+, is non-actionable and ignores it).
# ---------------------------------------------------------------------------

sub _featuresOf {
    my ($args) = @_;
    return (ref $args->{params} eq 'HASH') ? ($args->{params}{features} // '') : '';
}

sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

my $_headerTypeCache;
sub _headerType {
    return $_headerTypeCache if defined $_headerTypeCache;
    my $ver = eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
    my $useBasic;
    if    (!defined $ver)                  { $useBasic = 0; }                                       # can't tell -> safe 'header'
    elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) { $useBasic = (($1 <=> 6) || ($2 <=> 4) || ($3 <=> 3)) >= 0 ? 1 : 0; }  # >= 6.4.3
    else                                   { $useBasic = 1; }                                       # dev/test build -> new type
    return $_headerTypeCache = $useBasic ? 'header-basic' : 'header';
}

# Dispatch a review list to a grouping mode: 'genre' (the default) groups under
# each Pitchfork genre; 'date' keeps the weekly dividers. Either way the feed items
# arrive newest-first (API sorts by date), so date order is preserved within every
# bucket — and BOTH modes emit the same branded Material divider (_divHeader), so
# switching mode changes what the headers say, never whether there are headers.
#
# Flipped in place by _groupToggle on the view (0.8.2), the same mechanics as the
# year-list sort. It was a Settings-page radio until then; the pref is unchanged,
# so an existing choice carries over untouched.
my @GROUP_MODES = ('genre', 'date');

sub _groupBy {
    my $m = $prefs->get('group_by') || 'genre';
    return (grep { $_ eq $m } @GROUP_MODES) ? $m : 'genre';
}

sub _groupedRows {
    my ($client, $items, $headers, $mode) = @_;
    $mode ||= _groupBy();
    return _genreRows($client, $items, $headers) if $mode eq 'genre';
    return _weeklyRows($client, $items, $headers);
}

sub _groupLabel {
    my ($client, $mode) = @_;
    return cstring($client, ($mode // 'genre') eq 'date'
        ? 'PLUGIN_PITCHFORKREVIEWS_GROUP_WEEK'
        : 'PLUGIN_PITCHFORKREVIEWS_GROUP_BY_GENRE');
}

# "Grouped by <mode> (tap to change)" — identical mechanics to _yearSortToggle:
# durable pref, advanced from the LIVE pref (so a stale view can't set it
# backwards), nextWindow => 'refresh' on an EMPTY response to re-walk in place.
# Shared by all three review feeds, because the pref is shared.
sub _groupToggle {
    my ($client, $mode) = @_;
    return {
        name       => sprintf(cstring($client, 'PLUGIN_PITCHFORKREVIEWS_GROUPED_BY'),
                              _groupLabel($client, $mode)),
        type       => 'link',
        image      => SORT_ICON,
        nextWindow => 'refresh',
        url        => sub {
            my ($c, $cb) = @_;
            my $cur  = _groupBy();
            my $next = $GROUP_MODES[0];
            for my $i (0 .. $#GROUP_MODES) {
                $next = $GROUP_MODES[($i + 1) % @GROUP_MODES], last
                    if $GROUP_MODES[$i] eq $cur;
            }
            $prefs->set('group_by', $next);
            $cb->({ items => [] });
        },
    };
}

# Divider header shared by both grouping modes: the Pitchfork logo (not the neutral
# record icon) so headers are branded, and still an image so Material keeps the grid
# toggle enabled. On a header-capable client XMLBrowser forces a drill onto the older
# 'header' type, so carry a url returning that bucket's rows (ignored by header-basic).
sub _divHeader {
    my ($client, $label, $divType, $headers, $rowsFor) = @_;
    my $hdr = { name => $label, type => $divType, image => HEADER_ICON };
    if ($headers) {
        $hdr->{url} = sub {
            my ($c, $cb) = @_;
            $cb->({ items => [ map { _reviewRow($c, $_, $headers) } @$rowsFor ] });
        };
        $hdr->{passthrough} = [ {} ];
    }
    return $hdr;
}

# Group items into weeks, emitting a divider header + that week's review rows.
sub _weeklyRows {
    my ($client, $items, $headers) = @_;
    my $divType = $headers ? _headerType() : 'text';

    my (@order, %bucket);
    for my $it (@$items) {
        my $ws = _weekStartOf($it->{date});
        push @order, $ws unless exists $bucket{$ws};
        push @{ $bucket{$ws} }, $it;
    }

    my @rows;
    for my $ws (@order) {
        my $wk = $bucket{$ws};
        push @rows, _divHeader($client, _weekLabel($client, $ws), $divType, $headers, $wk);
        push @rows, map { _reviewRow($client, $_, $headers) } @$wk;
    }
    return \@rows;
}

# Group items by their PRIMARY Pitchfork genre, emitting a genre divider + that
# genre's rows. Genres appear in the order their newest review does (so the genre
# with the most recent review leads), and rows within a genre stay newest-first —
# the "in date order" the feed already provides.
sub _genreRows {
    my ($client, $items, $headers) = @_;
    my $divType = $headers ? _headerType() : 'text';

    my (@order, %bucket);
    for my $it (@$items) {
        my $g = _genreKey($it);
        push @order, $g unless exists $bucket{$g};
        push @{ $bucket{$g} }, $it;
    }

    my @rows;
    for my $g (@order) {
        my $grp = $bucket{$g};
        push @rows, _divHeader($client, _genreLabel($client, $g), $divType, $headers, $grp);
        push @rows, map { _reviewRow($client, $_, $headers) } @$grp;
    }
    return \@rows;
}

# Bucket key = the primary genre (Pitchfork's first rubric; the row's `genre` is the
# list joined " / "). Split ONLY on that " / " join delimiter (spaces required) — a
# bare "/" is part of a genre NAME (Pitchfork's "Pop/R&B", "Folk/Country") and must
# not be split. Falls to '' when a review carries no genre.
sub _genreKey {
    my ($it) = @_;
    my ($g) = split m{\s+/\s+}, ($it->{genre} // ''), 2;
    $g //= '';
    $g =~ s/^\s+//; $g =~ s/\s+$//;
    return $g;
}

# Divider label for a genre bucket ('' -> "Other").
sub _genreLabel {
    my ($client, $g) = @_;
    return length $g ? $g : cstring($client, 'PLUGIN_PITCHFORKREVIEWS_GENRE_OTHER');
}

# Monday (YYYY-MM-DD, UTC) of the week containing an RFC-822 pubDate
# ("Tue, 07 Jul 2026 04:03:00 +0000"); '' if unparseable.
my %_MON = (
    jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6,
    jul => 7, aug => 8, sep => 9, oct => 10, nov => 11, dec => 12,
);
sub _weekStartOf {
    my ($pub) = @_;
    my ($y, $mon, $d);
    if (($pub // '') =~ /^(\d{4})-(\d{2})-(\d{2})/) {           # ISO 8601 (page state)
        ($y, $mon, $d) = ($1, $2 + 0, $3);
    }
    elsif (($pub // '') =~ /(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})/) {   # RFC-822 (legacy)
        ($d, $mon, $y) = ($1, $_MON{ lc $2 }, $3);
    }
    else {
        return '';
    }
    return '' unless $mon;
    my $epoch = eval { Time::Local::timegm(0, 0, 12, $d, $mon - 1, $y) };
    return '' unless defined $epoch;
    my $wday = (gmtime $epoch)[6];                             # 0 = Sunday
    my @m    = gmtime($epoch - (($wday + 6) % 7) * 86400);     # step back to Monday
    return sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
}

my @_MONTHS = qw(January February March April May June
                 July August September October November December);
sub _fmtDate {
    my ($d) = @_;
    return '' unless ($d // '') =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return sprintf('%d %s %d', $3 + 0, $_MONTHS[$2 - 1], $1);
}

# "Week of 30 June 2026" for a week-start (Monday) date.
sub _weekLabel {
    my ($client, $ws) = @_;
    return cstring($client, 'PLUGIN_PITCHFORKREVIEWS_WEEK') unless $ws =~ /^\d{4}-\d{2}-\d{2}$/;
    return cstring($client, 'PLUGIN_PITCHFORKREVIEWS_WEEK_OF') . ' ' . _fmtDate($ws);
}

# ===========================================================================
# Album streaming resolver (trimmed port of the ListenBrainz plugin's engine).
# ===========================================================================

# Installed, integrable services. v1 ships Qobuz + Tidal — both fully-working
# album search/render in the sibling plugin, and both round-trip through the
# cache (their play node is a coderef url reattached on read by
# _rebuildStreamItems). Bandcamp (manual, loop-blocking) and Deezer can be ported
# from the ListenBrainz plugin later.
# Which services are PRESENT, memoised for the life of the process (0.8.8).
#
# The answer cannot change without a restart — a plugin cannot be installed,
# enabled or removed under a running server — but it was being recomputed twice
# per item (_findPlayable and _streamKey both ask), so a 50-row build ran 100
# enumerations, each doing three ->can chains and three _pluginDataFor icon
# lookups inside an eval. That is 300 eval'd package lookups to answer the same
# question 100 times.
my $_adapters;

# NOTHING IS MEMOISED UNTIL EVERY PLUGIN HAS LOADED (0.8.10). 0.8.9 refused to
# freeze an EMPTY detection, on the grounds that empty means "no service plugin has
# loaded YET" rather than "none is installed" — but a PARTIAL detection has exactly
# the same cause and was frozen anyway. Detection is `->can` on three classes, so
# anything asking during startup (a settings page hit, anything reaching
# _orderedAdapters) sees only the ones loaded so far: Deezer without Qobuz, say, and
# then Qobuz and Tidal are silently unusable for the life of the process, with no
# error anywhere. Which of the two it is depends on plugin load ORDER, which is
# alphabetical, so this is not even random — Deezer always loads before Qobuz and
# TIDAL. postinitPlugin is the point at which the answer becomes knowable: it runs
# after every plugin's initPlugin, so the classes either exist or genuinely are not
# installed. Before it, detect fresh every time (three ->can chains — what the code
# did before the memo existed at all).
my $_startupDone = 0;

sub _streamingAdapters {
    return @$_adapters if $_adapters;
    my @found = _detectAdapters();
    $_adapters = \@found if @found && $_startupDone;
    return @found;
}

# THE ONE LIST OF KNOWN SERVICES: [ pref key, adapter name ]. The priority memo stamp,
# the settings page's service rows and Settings.pm's prefs + sanitise loop all read this,
# so a service added here is added everywhere. It used to be four hand-maintained copies,
# and the memo stamp's copy was the dangerous one: a service missing from it would never
# invalidate the memo when its priority changed (streaming-adapter-spec §8).
our @SERVICES = (
    [ 'qobuz',   'Qobuz'   ],
    [ 'tidal',   'Tidal'   ],
    [ 'deezer',  'Deezer'  ],
    [ 'spotify', 'Spotify' ],
);

# Each adapter carries its own `rebuild` coderef — the browse handler _rebuildStreamItems
# reattaches to a cached match (the renderer's coderef `url` cannot survive Storable).
# It is taken INSIDE the same ->can guard that registers the adapter, so it always names a
# sub that exists. `native_favurl` marks a service whose renderer already ships a working,
# replayable favorites_url that _attachFavUrl must not overwrite. `empty_unverified` marks a
# service whose EMPTY answer cannot be told from an error (read by _streamTtl), and `pace_warm`
# is a coderef answering "slow the background warm down for me" (read by _resolveSection).
sub _detectAdapters {
    my @adapters;

    push @adapters, {
        name => 'Qobuz', icon => _pluginIcon('Plugins::Qobuz::Plugin'),
        run  => \&_searchQobuz, query_enc => 'chars',
        rebuild => \&Plugins::Qobuz::Plugin::QobuzGetTracks,
    } if Plugins::Qobuz::Plugin->can('getAPIHandler')
      && Plugins::Qobuz::Plugin->can('_albumItem')
      && Plugins::Qobuz::Plugin->can('QobuzGetTracks');   # reattach method for cached matches (see _rebuildStreamItems)

    push @adapters, {
        name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'),
        run  => \&_searchTidal, query_enc => 'chars',
        rebuild => \&Plugins::TIDAL::Plugin::getAlbum,
    } if Plugins::TIDAL::Plugin->can('getAPIHandler')
      && Plugins::TIDAL::Plugin->can('getAlbum')
      && Plugins::TIDAL::Plugin->can('_renderAlbum');

    # Deezer (michaelherger/lms-deezer) — same modern plugin family as Qobuz/Tidal.
    # `_renderAlbum` sets `url => \&getAlbum` (a COREF, album id in passthrough) exactly
    # like Tidal, and `play => deezer://album:<id>` (the string is the play/favourites
    # value, NOT the browse url). So it round-trips the cache identically: coderef
    # stripped by _cacheStream, reattached by _rebuildStreamItems. getAlbum is required
    # for that reattach (else a cached match drops on re-read).
    push @adapters, {
        name => 'Deezer', icon => _pluginIcon('Plugins::Deezer::Plugin'),
        run  => \&_searchDeezer, query_enc => 'bytes',
        rebuild => \&Plugins::Deezer::Plugin::getAlbum,
    } if Plugins::Deezer::Plugin->can('getAPIHandler')
      && Plugins::Deezer::Plugin->can('_renderAlbum')
      && Plugins::Deezer::Plugin->can('getAlbum');

    # Spotify — via the Spotty plugin, an OLDER, independent codebase (not the
    # Qobuz/TIDAL/Deezer family): getAPIHandler is a CLASS method, the renderers live in
    # OPML.pm, and search results arrive already normalised. Album nodes are the
    # Tidal/Deezer shape (coderef url => \&OPML::album, spotify:album:<id> uri in
    # passthrough), so they round-trip the cache the same way. Ported from the sibling
    # ListenBrainz plugin (PR #17, honzup); Spotty's API is verified against its source in
    # that repo's docs/spotify-spotty-adapter-pr17.md. Probes only the three methods this
    # adapter calls (there is no track leg here, so no `trackList`).
    push @adapters, {
        name => 'Spotify', icon => _pluginIcon('Plugins::Spotty::Plugin'),
        run  => \&_searchSpotify, query_enc => 'chars',
        rebuild => \&Plugins::Spotty::OPML::album,
        native_favurl => 1,
        # 0.9.36, both measured on the live server — see _streamTtl and PACED_WARM_GAP.
        empty_unverified => 1,                        # Pipeline turns a 502/timeout/429 into `[]`
        pace_warm        => \&_spotifyBackingOff,     # Spotify refused a search moments ago
    } if Plugins::Spotty::Plugin->can('getAPIHandler')
      && Plugins::Spotty::OPML->can('_albumItem')
      && Plugins::Spotty::OPML->can('album');

    return @adapters;
}

# Enabled adapters in search order: ascending svc_priority_<name>, dropping 0.
#
# Memoised against the priorities themselves, so a settings save takes effect on
# the very next resolve with no explicit invalidation to forget — the stamp is
# three pref reads, against a sort plus a rebuilt hash per adapter. `$_svcOrder`
# is the cache-key fragment _streamKey needs, cached alongside rather than
# re-joined per item.
my ($_ordered, $_orderStamp, $_svcOrder);

sub _orderedAdapters {
    my $stamp = join(',', map { $prefs->get("svc_priority_$_->[0]") // '' } @SERVICES);
    return @$_ordered if $_ordered && $_orderStamp eq $stamp;

    my @out;
    for my $a (_streamingAdapters()) {
        my $prio = $prefs->get('svc_priority_' . lc $a->{name});
        $prio = 1 unless defined $prio;
        next unless $prio > 0;
        push @out, { %$a, priority => $prio };
    }
    @out = sort { $a->{priority} <=> $b->{priority} } @out;

    # $_svcOrder is NOT part of the memo — it is this call's answer, written every
    # time. It is the enabled-service list as it appears in a stream cache KEY, so
    # leaving it stale (or blank, when the memo declines) would key a resolve on the
    # wrong service set.
    $_svcOrder = join(',', map { lc $_->{name} } @out);

    # Same rule as _streamingAdapters, for the same reason and one more: the stamp
    # is built from the PREFS, and those do not change when a plugin finishes
    # loading, so a list cached here during startup — empty OR partial — is pinned
    # until a restart or an unrelated settings save. Recomputing is three pref reads
    # and a sort of at most three.
    if (@out && $_startupDone) {
        $_ordered    = \@out;
        $_orderStamp = $stamp;
    }
    else {
        $_ordered = $_orderStamp = undef;
    }
    return @out;
}

# The enabled-service list as it appears in a stream cache key.
sub _svcOrder {
    _orderedAdapters();
    return $_svcOrder;
}

# Called from Plugin::postinitPlugin, i.e. once every plugin's initPlugin has run.
# Until then neither memo above is allowed to keep an answer, because `->can` can
# only report what has loaded SO FAR (see _streamingAdapters). Also drops whatever
# was detected during startup, so the first memoised answer is taken with the whole
# plugin tree up.
sub markStartupComplete {
    $_startupDone = 1;
    $_adapters = $_ordered = $_orderStamp = undef;
    $_svcOrder = '';
    _retireOldStreamKeys();
    return;
}

# Drop every resolve row from a PREVIOUS key version, once, at startup.
#
# On a version change everything under the prefix is stale by definition — that is what
# bumping the version MEANS — so the whole family goes and the new version starts clean.
# Safe to run on every startup: when the version is unchanged this is a single kv read
# and nothing else.
#
# Without it a bump is silently expensive in the other direction: the old rows are
# unreachable (no code will ever build their key again) but still occupy the table for
# their full STREAM_FOUND_TTL. kvForgetPrefix existed for exactly this and was left
# unwired in 0.9.11's first pass.
sub _retireOldStreamKeys {
    my $marker = 'pfr:streamkeyver';
    my $seen   = Plugins::PitchforkReviews::DB::kvGet($marker);
    return if defined $seen && $seen == STREAM_KEY_VERSION;

    my $n = Plugins::PitchforkReviews::DB::kvForgetPrefix(STREAM_KEY_PREFIX);
    Plugins::PitchforkReviews::DB::kvSet($marker, STREAM_KEY_VERSION, 0);   # 0 = never expires
    $log->info("resolve key version " . (defined $seen ? $seen : 'none') . " -> "
             . STREAM_KEY_VERSION . " — retired $n stale row(s)") if $n || defined $seen;
    return $n;
}

# Detection + priority for every known service (installed or not) — drives the
# settings page's service list.
sub serviceStatus {
    my @known = @SERVICES;
    my %installed = map { lc($_->{name}) => 1 } _streamingAdapters();
    return [ map {
        {   key       => $_->[0],
            name      => $_->[1],
            installed => $installed{ $_->[0] } ? 1 : 0,
            priority  => $prefs->get('svc_priority_' . $_->[0]) // 0,
        }
    } @known ];
}

sub _pluginIcon {
    my ($class) = @_;
    return eval { $class->_pluginDataFor('icon') } || undef;
}

# ---------------------------------------------------------------------------
# Cover artwork sizing (0.8.8)
#
# HOW A ROW'S ARTWORK ACTUALLY REACHES THE SCREEN, because the cost is not where
# it looks: XMLBrowser runs every `image` through Slim::Web::ImageProxy, and
# Material then asks that proxy for a SIZE — `_150x150_f` in a list, `_300x300_f`
# in a grid (double on a hi-dpi screen). To answer, LMS downloads the ORIGINAL
# once, resizes it and caches the result for 30 days. So the size of the picture
# we name is paid in full by the server on the first sight of every cover, no
# matter how small the thumbnail it ends up as.
#
# Measured, per cover: Tidal hands out 1280x1280 = 563KB (its 320x320 is 41KB),
# Pitchfork's own w_768 = 82KB (w_320 = 9KB), Qobuz's _600 = 25KB. A fresh
# 50-row list on a Tidal-first setup was pulling ~28MB to draw 50 thumbnails.
#
# Two fixes, split by who owns the URL:
#  - _fitCover, below, caps what WE put on OUR rows. 640 is the ceiling because
#    600 is the largest spec Material ever asks a browse row for, so nothing
#    visible changes at any size.
#  - pitchforkImageProxy handles media.pitchfork.com, where we can do better than
#    a ceiling: the width is a path segment, so the proxy handler picks the
#    smallest one that satisfies the spec actually being requested.
# ---------------------------------------------------------------------------
use constant MAX_COVER_PX => 640;

# Cap a service's own cover URL at MAX_COVER_PX where the service encodes the
# size in the URL. Anything unrecognised is returned VERBATIM — a cover that
# doesn't shrink costs bandwidth, a cover mangled into a 404 costs the picture.
sub _fitCover {
    my ($url) = @_;
    return $url unless defined $url && !ref $url && $url =~ m{^https?://};

    # Only a SQUARE source is capped, in both branches below. The ceiling is square, so
    # applying it to a non-square URL changes the aspect ratio — and on Tidal, whose
    # renditions are a fixed set, invents one that does not exist (a 404, no picture).
    # Defensive here rather than a live fix: an album cover is square, and this only ever
    # runs on covers WE put on OUR rows. The proxy handlers below see other plugins' URLs,
    # where the same mistake was reachable — see tidalImageProxy.

    # Tidal: .../<uuid path>/1280x1280.jpg — the one real offender.
    if ($url =~ m{resources\.tidal\.com/}) {
        $url =~ s{/(\d+)x(\d+)(\.\w+)$}{ $1 == $2 && $1 > MAX_COVER_PX ? '/' . MAX_COVER_PX . 'x' . MAX_COVER_PX . $3 : "/$1x$2$3" }e;
        return $url;
    }
    # Deezer: .../cover/<md5>/500x500-000000-80-0-0.jpg (already under the ceiling
    # at the sizes the plugin asks for, but it doesn't have to stay that way).
    if ($url =~ m{dzcdn\.net/}) {
        $url =~ s{/(\d+)x(\d+)(-[\d-]+\.\w+)$}{ $1 == $2 && $1 > MAX_COVER_PX ? '/' . MAX_COVER_PX . 'x' . MAX_COVER_PX . $3 : "/$1x$2$3" }e;
        return $url;
    }
    # Qobuz: .../<id>_600.jpg — a fixed ladder (50/100/150/230/600/max), so only
    # the unbounded `_max` needs pulling back.
    if ($url =~ m{static\.qobuz\.com/}) {
        $url =~ s{_max(\.\w+)$}{_600$1};
        return $url;
    }
    return $url;
}

# MAY THIS REWRITE HAPPEN? A handler may only ever go DOWN, and that has to be measured
# against the width the URL ALREADY CARRIES — not merely against the top of our own ladder,
# which is all the ladders' top rungs could ever enforce.
#
# The handlers are registered by CDN HOST (Plugin::initPlugin) and Slim::Web::ImageProxy
# matches on the URL, never on which plugin produced the row. So EVERY Qobuz/Tidal/Deezer
# cover on this server passes through them: the service plugins' own browse lists,
# Material's Now Playing, anything at all. Those URLs were authored elsewhere, at whatever
# size that caller wanted, and the ladder cap cannot speak for them — a row already asking
# for 80x80 that meets a 300 spec was being rewritten UP to 320x320, i.e. more bytes than
# the row asked for, in a plugin that never opted in.
#
# An undefined/unreadable current width means the URL states no size we can compare
# (Qobuz's unbounded `_max`), which is always worth shrinking. Equal is a no-op: the URL
# already satisfies the spec, so leaving it verbatim also keeps the proxy's cache warm.
sub _onlyDown {
    my ($cur, $w) = @_;
    return 0 unless $w;
    return 1 unless defined $cur && length $cur;
    return $cur > $w ? 1 : 0;
}

# Slim::Web::ImageProxy handler for Pitchfork's own artwork, registered from
# Plugin::initPlugin. Returning a url answers synchronously (ImageProxy.pm:229).
#
# Pitchfork serves any width from the same photo id — the `w_768` in the path is a
# transform, not a stored file — so instead of one compromise size we hand the
# proxy the smallest width that still satisfies the spec it was asked for. The
# proxy's own cache is keyed on the ORIGINAL url + spec, so rewriting here doesn't
# fragment it, and an unknown/size-less spec falls through unchanged.
sub pitchforkImageProxy {
    my ($url, $spec) = @_;

    my $w = eval {
        Slim::Web::ImageProxy->getRightSize($spec, {
            160 => 160,
            320 => 320,
            480 => 480,
            640 => 640,
        });
    };
    my ($cur) = $url =~ m{/w_(\d+),};
    $url =~ s{/w_\d+,}{/w_$w,} if _onlyDown($cur, $w);
    return $url;
}

# The SERVICES' artwork, same handler shape, registered from Plugin::initPlugin.
#
# 0.8.8 deliberately left these to "their plugins to manage" and sized only
# media.pitchfork.com. That was the wrong call, and its own measurements say so:
# a MATCHED row renders the SERVICE's cover (_reviewRow prefers `_cover`), and the
# Pitchfork cover is only the fallback for a row that DIDN'T match. So the one
# handler that could size a thumbnail was wired to the path the matcher was busy
# emptying — the better matching got, the less of the artwork it touched. On a
# well-resolved list essentially every row bypassed it.
#
# _fitCover still exists and still runs first, but it is a CEILING (640) applied at
# render time with no idea what size is being asked for. Material asks a browse row
# for _150x150_f / _300x300_f, so a 640 fetch to draw a 150 thumbnail was the norm.
# These handlers see the actual spec and name the smallest size that satisfies it.
#
# TWO RULES, and the second is the one 0.8.8 got wrong in the other direction.
#
# (1) LADDERS ARE EVIDENCE-BACKED ONLY. An unrecognised size is not a bigger
#     download, it is a 404 and no picture at all — the rule _fitCover already states.
#       Qobuz  50/100/150/230/600 — the fixed ladder documented on _fitCover above.
#       Tidal  320/640            — both measured (41KB / …, 0.8.8); 640 is also
#                                   what _fitCover has shipped since 0.8.8.
#       Deezer 160/320/500        — its CDN takes ARBITRARY sizes (probed live: 56,
#                                   160, 250, 320, 500, 640, 1000, 1200, 1800 all
#                                   200, all genuinely different byte counts), so
#                                   these are chosen, not discovered.
#
# (2) A HANDLER MAY ONLY EVER GO DOWN, NEVER UP — so each ladder STOPS at the size
#     the row already carries (Qobuz `_600`, Tidal 640 after _fitCover, Deezer 500).
#     Past the top rung getRightSize returns undef and the URL is left verbatim.
#     Without this cap the handler makes hi-dpi grid tiles WORSE: Deezer serves a
#     600 spec from its 500 source today at 26,785 bytes, and a ladder containing
#     640 would "satisfy" that request properly at 50,769 — a 90% regression on the
#     exact surface this is meant to speed up. Same for Tidal at 1280. Every spec is
#     now a strict improvement or a no-op; none is a regression.
sub qobuzImageProxy {
    my ($url, $spec) = @_;

    my $w = eval {
        Slim::Web::ImageProxy->getRightSize($spec, {
            50 => 50, 100 => 100, 150 => 150, 230 => 230, 600 => 600,
        });
    };
    # `_max` is unbounded and is also a valid trailing form, so match either — and it
    # reads as an undefined current width, which _onlyDown treats as always shrinkable.
    my ($cur) = $url =~ m{_(\d+)\.\w+$};
    $url =~ s{_(?:\d+|max)(\.\w+)$}{_$w$1} if _onlyDown($cur, $w);
    return $url;
}

# ONLY A SQUARE SOURCE MAY BE REWRITTEN, and that is the second half of the same rule
# _onlyDown states: these handlers see URLs they did not author. The path carries TWO
# dimensions and the ladder rungs are square, so a `480x320` artist photo meeting a 150
# spec was being rewritten to `320x320` — a rendition Tidal does not serve, i.e. a 404 and
# NO picture at all, on the TIDAL plugin's own artist and playlist views (album covers are
# square, which is why this survived). _onlyDown cannot catch it: it compares widths, and
# 320 < 480 reads as a perfectly good shrink.
#
# SCALING THE HEIGHT PROPORTIONALLY IS NOT THE FIX, for exactly the reason above: Tidal
# serves a FIXED SET of renditions, and a computed `320x213` is no more real than
# `320x320` (the actual rung is 320x214). Anything we cannot name from the ladder must be
# left verbatim — the rule _fitCover has stated since 0.8.8: a cover that fails to shrink
# costs bandwidth, a cover mangled into a 404 costs the picture.
sub tidalImageProxy {
    my ($url, $spec) = @_;

    my ($cw, $ch) = $url =~ m{/(\d+)x(\d+)\.\w+$};
    return $url unless defined $cw && $cw == $ch;

    my $w = eval {
        Slim::Web::ImageProxy->getRightSize($spec, {
            320 => 320, 640 => 640,
        });
    };
    $url =~ s{/\d+x\d+(\.\w+)$}{/${w}x${w}$1} if _onlyDown($cw, $w);
    return $url;
}

# Deezer: .../cover/<md5>/500x500-000000-80-0-0.jpg — the trailing "-000000-80-0-0"
# is background/quality/crop and is preserved untouched; only the dimensions move.
#
# Square-only, the same rule as tidalImageProxy. Deezer's CDN takes ARBITRARY sizes, so
# here the failure is a distorted picture rather than a 404 — the aspect ratio of an
# image some other plugin authored is not ours to change either way, and one rule across
# the handlers reads better than two.
sub deezerImageProxy {
    my ($url, $spec) = @_;

    my ($cw, $ch) = $url =~ m{/(\d+)x(\d+)-[\d-]+\.\w+$};
    return $url unless defined $cw && $cw == $ch;

    my $w = eval {
        Slim::Web::ImageProxy->getRightSize($spec, {
            160 => 160, 320 => 320, 500 => 500,
        });
    };
    $url =~ s{/\d+x\d+(-[\d-]+\.\w+)$}{/${w}x${w}$1} if _onlyDown($cw, $w);
    return $url;
}

# Cache key for an album's matches. Keyed by the current service set (order +
# enabled) so any streaming-config change re-matches on next open instead of
# serving links to a service the user removed/disabled.
sub _streamKey {
    my ($idPart) = @_;
    my $svcOrder = _svcOrder();
    # :7: = favurl gains &al= (album title for ListenLater); :8: = fleet matcher sync (the
    # decorative "!" fix changed match DECISIONS). :9: (0.7.10) = '&al=' now carries the
    # MATCHED SERVICE's title rather than Pitchfork's, and the favurl gains '&y='. The
    # favurl is frozen into the cached item, so without this bump every already-resolved
    # review keeps handing ListenLater the old name for the full 7d TTL — and the symptom
    # (a release that plays fine but never reaches Played) is silent, so it must not be
    # left to age out. **Bump on ANY change to what the favurl carries, even when the
    # fields keep their shape** — one re-resolve beats a week of silent misses.
    #
    # :10: (0.9.0) IS NOT A CORRECTNESS BUMP — nothing cached under :9: is wrong. It is
    # deliberate invalidation so the release's headline feature can be OBSERVED. 0.9.0
    # prefetches every year and raises STREAM_FOUND_TTL 7d -> 90d; against a warm cache
    # both are invisible (the warm logs cache hits and the new TTL only applies on write),
    # so the build would ship untestable. Bumping forces the cold start the prefetch and
    # the "still loading" label were built to absorb, which makes this an end-to-end test
    # of the new design rather than a cost. The fleet rule — every dev build invalidates
    # every cache — exists for exactly this, and an earlier pass at 0.9.0 talked itself
    # out of it on "don't disturb a warm cache" grounds. That was wrong: it optimised the
    # first five minutes at the price of never knowing whether the feature worked.
    #
    # :11: (0.9.1) — SAME REASONING, AND THE SAME MISTAKE ALMOST REPEATED. 0.9.1 fixes a
    # cold-cache regression (a 25s browse block, and a warm that competed with the user),
    # and 0.9.1 first shipped with NO bump on the argument that re-inflicting a cold start
    # to observe a cold-start fix is self-defeating. That inverts the point: the cold path
    # IS the thing under test, 0.9.0's warm had already run and cached the years, and
    # without a bump every year opens from cache — so neither the 5s deadline nor the
    # yield is ever exercised and the fix cannot be confirmed. The listing/bnm/hsa and
    # year keys are bumped alongside this one; a partial bump would leave the articles
    # cached and only half-reproduce first boot.
    # :23: (0.9.29) — a CORRECTNESS bump, and the entries it retires are the ones :22:
    # itself wrote. 0.9.27/0.9.28 stored an answer whose CHECKING LEG NEVER ANSWERED under
    # STREAM_FOUND_TTL, so a leg-2 timeout pinned a loose candidate — the Interpol single
    # again — for thirty days. 0.9.29 gives that shape STREAM_UNVALIDATED_TTL, but only for
    # answers written from here on: an entry already stored under :22: carries the long TTL
    # in the store and nothing re-examines it. Same silent symptom as :22: (the row plays,
    # it just plays a different record) and the same reasoning — the fix is unobservable
    # against exactly the entries it exists to correct. `PARSE_VERSION` stays at 3: no
    # article parsing or fetch behaviour changed.
    #
    # :22: (0.9.27) — a CORRECTNESS bump, and one that must not be skipped. Candidate
    # RANKING changed (an exact title now takes the row) and the retry leg now fires on a
    # loose-only result, so a stored answer under :21: can name the wrong release —
    # Interpol's *This Mirror Weighs a Ton* resolved to the 2-track single of the same
    # name. That answer is cached under STREAM_FOUND_TTL, which is THIRTY DAYS, and the
    # symptom is silent: the row plays, it just plays a different record. Nothing else
    # invalidates it — the favurl even carries the single's title, so Listen Later would
    # keep the wrong name too. `PARSE_VERSION` stays at 3: no article parsing changed, so
    # re-downloading them would be cost with no test value.
    #
    # :19: (0.9.19) — a CORRECTNESS bump, unlike the last two. Unpadded slashes now split
    # (all-or-nothing), so every title of the `EP/EP2` shape has a stored answer under
    # :18: that is wrong — a no-match cached under STREAM_NOMATCH_TTL, which would keep
    # the newly-matchable reviews unplayable for a day per open. PARSE_VERSION is left at
    # 3: nothing about the articles or the fetch phase changed, so re-downloading them
    # would be cost with no test value.
    #
    # :18: (0.9.18) — bumped ALONGSIDE PARSE_VERSION 2->3, which is the pairing 0.9.17
    # deliberately did not make. This release changes the FETCH PHASE, so the article
    # store has to be cold or the warm opens with four DB hits and the change is
    # unobservable; and a cold article store with a warm resolve store is a shape no
    # real install is ever in, which would make the timings unreadable.
    #
    # :17: (0.9.17) — the standing dev rule, applied to a case where it is TEMPTING to
    # skip. Nothing under :16: is wrong: a combined review's sides resolve under their
    # own keys (never cached before), and the joint title's miss is held for only
    # STREAM_NOMATCH_TTL, so the fix would be visible against a warm store anyway. The
    # bump is still right, because "visible" is not "tested": without it the joint-title
    # leg is served from cache and the path under test runs from its second step. Cold
    # is the state the combined-review handling has to be correct in, so cold is what
    # ships. (Numbering follows the release, not a count of correctness bumps.)
    #
    # :12: (0.9.11) — TWO reasons at once. The resolve cache has moved out of
    # Slim::Utils::Cache and into the plugin's own DB (kvGet/kvSet), so nothing under
    # :11: is reachable from here anyway; and this release rewrites the COLD START, which
    # cannot be observed against a warm store. Bumped alongside PARSE_VERSION so the
    # install is a genuine fresh install rather than a half-warm one.
    my $key = STREAM_KEY_PREFIX . STREAM_KEY_VERSION . ':' . $svcOrder . ':' . ($idPart // '');
    utf8::encode($key) if utf8::is_utf8($key);   # octet key — non-Latin can't crash md5
    return $key;
}

# Album-identifying part of the key: the normalised "artist album" string.
sub _streamId {
    my ($artist, $album) = @_;
    return join(' ', grep { length } _norm($artist), _norm($album));
}

# --------------------------------------------------------------------------
# COMBINED REVIEWS: "songs / instrumentals" (0.9.17)
#
# Pitchfork reviews two releases in one article when they were issued as a pair,
# and titles the piece "A / B" — Adrianne Lenker's `songs / instrumentals` (two
# separate 2020 albums) is the canonical case. No streaming service carries an
# album under the joint name, so BOTH legs of BOTH searches fail on all three
# services and the row can never become playable. The log is unambiguous:
#     search Qobuz/albums raw=200 kept=0 q=Adrianne Lenker
#     resolve Qobuz: no hit for artist 'Adrianne Lenker' — retrying on album 'songs / instrumentals'
#     resolve 'adrianne lenker / songs instrumentals': no match
# Qobuz returned 200 of her albums and `songs` was near-certainly among them; the
# title we asked for simply does not exist. It is a silent failure — the review
# looks perfectly resolvable and just never plays.
#
# THIS IS PFR CALL-SITE LOGIC, NOT A MATCHER CHANGE. "A / B" is a Pitchfork
# editorial convention; it means nothing in the ListenBrainz/Discography/Listen
# Later siblings, so `_albumMatches` and the rest of the shared engine are
# untouched and matcher_sync_check stays green. Same class as
# `_stripArtistAffix`'s PFR-only sibling logic above.
#
# Only two such titles exist across every list observed to date
# ('songs / instrumentals', 'Song of Sage: Post Panic! / Navy's Reprise'), so
# this is a small, bounded fix — but it is a guaranteed miss every time it occurs.
# --------------------------------------------------------------------------

# Split a combined review title into its sides. Returns nothing for an ordinary title
# (the caller then takes the untouched single-album path), otherwise the sides and
# whether EVERY side has to resolve for the split to be believed.
#
# TWO CONFIDENCE LEVELS, because Pitchfork is not consistent about the spacing and the
# two spellings are not equally safe to act on (0.9.19).
#
#   'songs / instrumentals'  PADDED — an unambiguous editorial separator. Accept whatever
#                            matches, including one side out of two, at any exactness.
#   'EP/EP2'                 UNPADDED — indistinguishable in shape from `AC/DC`, `24/7`
#                            and `S/T`, so a side is believed only on an EXACT title
#                            match (see the note at the decision itself). Exactness is
#                            the safety margin the padding used to provide.
#
# A TITLE MAY CARRY BOTH SPELLINGS — `AC/DC / Live at Donington` — so the level is a
# property of the SEPARATOR, not of the title. Deciding it per title while splitting on
# every slash is what let a padded title's rule be applied to unpadded fragments; see the
# note at the split itself, which is the defect that shape produced.
#
# Yaeji's `EP/EP2` (two 2017 releases, one review) is the case that forced the second
# level: a padded-only rule refused it and the review stayed unplayable. Note the return
# value only says WHICH RULE APPLIES — the exactness test lives at the call site, where
# the matched service titles are.
#
# Other guards, in order of how much they carry:
#   - THE FULL TITLE IS TRIED FIRST by the caller, so none of this is reachable unless
#     the title as written already failed. A split can only ever ADD a match.
#   - a title that IS the artist's name is never split (`AC/DC` by AC/DC, `S/T`), which
#     also mirrors _findPlayable skipping its album leg in that case.
#   - each side must survive trimming with >= 2 characters, so `S/T` and a bare `24/7`
#     are refused outright and a trailing separator cannot manufacture an empty query.
#   - padded titles may have up to TITLE_SPLIT_MAX sides; unpadded ones EXACTLY TWO,
#     since three unpadded slashes is far more likely a date or a stylisation.
use constant TITLE_SPLIT_MAX => 3;

sub _splitAlbumTitles {
    my ($album, $artist) = @_;
    return () unless defined $album && !ref $album && $album =~ m{/};

    my $albumNorm = _norm($album);
    if (defined $artist && !ref $artist) {
        my $an = _norm($artist);
        return () if length($an) && $albumNorm eq $an;
    }

    # PADDING IS DECIDED PER SEPARATOR, NOT PER TITLE, and a title may genuinely carry
    # both spellings: `AC/DC / Live at Donington`. Splitting that on ANY slash gave three
    # sides — 'AC', 'DC', 'Live at Donington' — inside TITLE_SPLIT_MAX, so it was accepted
    # as a padded split, which trusts a LOOSE side (0.9.21). `_albumMatches` admits 'AC'
    # to a service title of "AC/DC Live" through `index($t, "ac ") == 0`, so the row
    # silently became a record the review is not about. The artist guard above cannot
    # reach it either: it compares the WHOLE title, and 'ac dc live at donington' is not
    # 'ac dc'.
    #
    # So split only on the spelling that was DETECTED. A padded title keeps its unpadded
    # slashes intact (`AC/DC` survives as one side, judged as a whole), and a genuinely
    # unpadded title is still governed by the exactness gate exactly as 0.9.21 designed.
    my $padded = $album =~ m{\s/\s};
    my @parts  = $padded ? split(m{\s+/\s+}, $album) : split(m{/}, $album);
    return () if @parts < 2 || @parts > ($padded ? TITLE_SPLIT_MAX : 2);

    for my $p (@parts) {
        $p =~ s/^\s+|\s+$//g;
        return () unless length($p) >= 2 && length(_norm($p));
    }
    # A side that just repeats the whole title would re-run the identical failing
    # search — drop the split rather than pay for it twice.
    return () if grep { _norm($_) eq $albumNorm } @parts;

    return (\@parts, !$padded);
}

# DRY-RUN INSTRUMENTATION (0.9.20) — MEASURES, CHANGES NOTHING.
#
# Did a winning match equal the service's title EXACTLY, or did it come through one of
# _albumMatches' looser tiers — the space-delimited prefix rule, the trailing ep/lp
# strip, the ascii fold, the artist-prefix strip?
#
# That distinction is the candidate discriminator for unpadded combined-review splits,
# and it comes straight out of the matcher's own shape. A bogus fragment can only ever
# win as a PREFIX: `_norm('AC/DC Live')` is "ac dc live", so side 'AC' wins via
# `index($t, "ac ") == 0` and never as an exact title — an album titled exactly *AC*
# would be a real album. A genuine half of a pairing wins outright: Yaeji's 'EP2' matched
# a service title of exactly "EP2" (field log, 15:41:35).
#
# Read off `_svctitle` — the service's own title with any artist affix removed, i.e. the
# same string the ListenLater handshake sends. A service that gave us no title is
# reported as such rather than guessed at, because "no evidence" and "not exact" must not
# be collapsed while the point of the exercise is to count them.
sub _matchExactness {
    my ($album, $item) = @_;
    return 'exactness=?'    unless ref $item eq 'HASH';
    my $svc = $item->{_svctitle};
    return 'exactness=none' unless defined $svc && !ref $svc && length $svc;
    return _norm($svc) eq _norm($album) ? 'exact' : 'loose';
}

# Bracketed fragments that name an EDITION of a record rather than a different record.
# A CLOSED LIST ON PURPOSE, and it fails toward OFFERING: anything not recognised is
# treated as part of the release's identity, so an unknown bracket makes two titles
# DISTINCT — which at worst shows one row too many, where the opposite error silently
# hides the release the reader was looking for.
my $EDITION_RE = qr/\b(?:deluxe|remaster(?:ed)?|expanded|anniversary|edition|version
                      |explicit|clean|bonus|reissue|special|mono|stereo|hi.?res)\b/xi;

sub _editionish { my ($s) = @_; return defined $s && $s =~ $EDITION_RE ? 1 : 0 }

# The RELEASE IDENTITY of a title — `_norm`, but with bracketed content handled by what it
# MEANS rather than by the fact that it is bracketed.
#
# `_norm` deletes every parenthesised group (`s/[\(\[].*?[\)\]]//g`), and that is right for
# the job it was written for: "Foo (Deluxe Edition)" and "Foo (Remastered)" ARE the album,
# and 0.9.21 pins exactly that. But the same rule collapses things that are NOT the same
# record, and the EP direction is full of them — Djrum's *I Wander* EP sits on Deezer beside
# the one-track singles *I Wander (III)* and *I Wander (IV + V)*, all three admitted by
# `_albumMatches`, all three identical under `_norm`. Rank on `_norm` alone and a 6-track EP
# loses its own row to a single on nothing but service ordering.
#
# So: an edition qualifier is dropped, anything else inside brackets is UNBRACKETED and kept
# as part of the title. "I Wander (III)" -> "i wander iii"; "Foo (Deluxe Edition)" -> "foo".
# The trailing EP/LP fold rides along (see _exactFolded) because Pitchfork writes "<name> EP"
# where every service writes "<name>".
sub _releaseKey {
    my ($t) = @_;
    return '' unless defined $t && !ref $t;
    $t =~ s/[\(\[]([^\)\]]*)[\)\]]/_editionish($1) ? ' ' : " $1 "/ge;
    return _stripFmt(_norm($t));
}

# EXACT WITH THE FORMAT DESCRIPTOR FOLDED — a SEPARATE test from _matchExactness above,
# and the separation is deliberate rather than duplication.
#
# `_matchExactness` is load-bearing for 0.9.21's unpadded-split rule, where STRICTNESS is
# the entire point: a fragment can only ever win through a looser tier, so anything that
# widens "exact" widens what a fragment can pass as. This one is used only to RANK
# candidates that have already been admitted by `_albumMatches`, where the question is a
# different one — "is this the record the review is about, or another release that merely
# starts with the same words?"
#
# WHY THE FOLD IS REQUIRED HERE, from live data. Pitchfork titles an EP "<name> EP" and the
# services drop the suffix, which is the whole reason `_stripFmt` exists in the matcher. So
# a review of an EP can NEVER produce a strict-exact match:
#
#     Djrum - I Wander EP      -> Qobuz/Deezer "I Wander"     strict: loose   folded: EXACT
#     Faith Leazae - Faith EP  -> Deezer "Faith"              strict: loose   folded: EXACT
#     Interpol - This Mirror…  -> "This Mirror…/See Out Loud"  strict+folded: LOOSE
#     Djrum - I Wander EP      -> Deezer "I Wander (III)"      folded: LOOSE  (via _releaseKey)
#
# Rank on the strict test and every EP review is permanently "nothing matched exactly",
# which turns the retry leg in `_findPlayable` into a per-EP-review tax AND invites the
# promotion below to prefer a like-named ALBUM over the correct EP. Folding both sides
# separates the shapes cleanly: the EP cases settle, the two rival shapes do not.
sub _exactFolded {
    my ($album, $item) = @_;
    return 0 unless ref $item eq 'HASH';
    my $svc = $item->{_svctitle};
    return 0 unless defined $svc && !ref $svc && length $svc;
    my $a = _releaseKey($album);
    return 0 unless length $a;
    return _releaseKey($svc) eq $a ? 1 : 0;
}

# Is a second search on the ALBUM TITLE worth spending, given what the artist leg returned?
#
# Two shapes qualify, and only two:
#   * NOTHING came back — the 0.7.12 recall case, unchanged ("Leo" buries "Cicada Burnt").
#   * Something came back, at least one candidate STATES a title, and none of them is
#     folded-exact — the 0.9.27 case (a like-named single standing in for the album).
#
# "NO EVIDENCE" IS NOT "NOT EXACT", and collapsing the two is the mistake `_matchExactness`
# was explicitly written to avoid (it reports `exactness=none` separately from `loose` for
# this reason). A service that matched but told us no title has not said the match is wrong;
# retrying on that would spend a full STREAM_SVC_TIMEOUT to learn nothing, on every album,
# and it is exactly the shape a stubbed or future adapter presents. So the retry needs
# POSITIVE evidence of looseness, not merely the absence of evidence of exactness.
sub _wantsTitleRetry {
    my ($album, $res) = @_;
    return 0 unless defined $res && ref $res eq 'ARRAY';
    return 1 unless @$res;                                    # nothing found at all
    my $stated = 0;
    for my $it (@$res) {
        return 0 if _exactFolded($album, $it);                # one exact is enough to settle
        $stated++ if ref $it eq 'HASH' && defined $it->{_svctitle}
                  && !ref $it->{_svctitle} && length $it->{_svctitle};
    }
    return $stated ? 1 : 0;
}

# Real service matches out of a _findPlayable answer. _streamResult NEVER returns an
# empty list — a miss comes back as a one-element "No streaming match found" TEXT row —
# so emptiness is not the test; `_svc` is (the same distinction reviewDetail draws).
sub _realMatches {
    my ($res) = @_;
    return grep { ref $_ eq 'HASH' && $_->{_svc} } @{ ($res || {})->{items} || [] };
}

# How many "other release" rows an ordinary review may offer. Two, not the full
# STREAM_MAX_RESULTS: these sit above a tracklist, and a page that opens with a stack of
# near-identical rows is a worse answer than the wrong one it is trying to correct.
use constant ALT_RELEASE_MAX => 2;

# OFFER THE RIVAL RATHER THAN ADJUDICATE BETWEEN THEM (0.9.27).
#
# The ranking above decides what the row plays, and it has to — Play/Add act on the list row
# without anyone drilling in. But no ranking is right every time, and until now a MATCHED row
# had no escape at all: it drills into the matched album's tracklist, so `reviewDetail` (with
# its Refresh row, and the full candidate list) is reachable ONLY from a row that did not
# match. A wrong match was silent and pinned for STREAM_FOUND_TTL.
#
# WHY NOT A RELEASE-TYPE FILTER, which is what the sibling plugin does (LBF 0.9.89 drops
# single-typed candidates for a non-single release). LBF can, because MusicBrainz states the
# target's type. PFR HAS NO TYPE FOR THE TARGET AT ALL — `_parseState` extracts artist,
# album, capsule, link, date, cover, score and genre, and the only hint that ever exists is
# the literal " EP" in Pitchfork's title, which `_stripFmt` deliberately discards so the
# match works in the first place. Assuming "the target is an album" is wrong on live data:
# Pitchfork reviewed *Faith Leazae — Faith EP*, and Deezer types that same record `album`
# with 8 tracks. A filter built on a type nobody agrees about bins correct EP matches.
#
# SO THE DISCRIMINATOR IS THE TITLE, via `_releaseKey` — which is `_norm` with bracketed
# content judged by what it MEANS rather than deleted wholesale:
#
#     Foo               vs  Foo (Deluxe Edition)      -> both "foo"        an EDITION, not offered
#     This Mirror…      vs  This Mirror…/See Out Loud -> differ            a RELEASE, offered
#     I Wander          vs  I Wander (III)            -> differ            a RELEASE, offered
#
# Plain `_norm` cannot draw that line — it deletes every bracket, so the third row collapses
# with the first and a 6-track EP becomes indistinguishable from a one-track single. Editions
# of one record still collapse; releases that merely share a name no longer do. Every
# candidate here comes from ONE service (the resolver only ever returns `$win`'s matches), so
# this can never offer "the same album on Tidal" as though it were a different record.
#
# The residual gap is an EP and an album titled identically with no bracket to tell them
# apart, which no title rule can split. That is where a service's own type field would earn
# its keep — as a reason to OFFER a second row, never as a reason to drop one.
sub _releaseAlts {
    my ($primary, $res) = @_;

    # No service title means no evidence, and a guess here would offer the same record twice.
    my $pn = _releaseKey(($primary || {})->{_svctitle} // '');
    return () unless length $pn;

    my %seen = ($pn => 1);
    my @out;
    for my $node (_realMatches($res)) {
        last if @out >= ALT_RELEASE_MAX;
        my $t = $node->{_svctitle};
        next unless defined $t && !ref $t && length $t;
        my $n = _releaseKey($t);
        next unless length $n;
        next if $seen{$n}++;
        # A COPY, never the node the resolver cached and handed other callers — the same
        # rule the combined-review sides follow when they tag `_side`/`_sidetitle`.
        push @out, { %$node, _altkind => 'release' };
    }
    return @out;
}

# --------------------------------------------------------------------------
# SUBTITLED REVIEWS: "Title: Subtitle" (0.9.38)
#
# Pitchfork titles some records with a subtitle the services drop. Field case: Erykah Badu /
# The Alchemist — *Before the World Blows: The Abi and Alan Experiment*, carried by Spotify AND
# Qobuz as *Before The World Blows* (2026). `_albumMatches` tolerates extra words on the
# CANDIDATE only (its prefix tier), so the service's SHORTER title can never match and the row
# stays unplayable. Discography's ledger records the same class as a real, unresolved matcher gap.
#
# PFR CALL-SITE LOGIC, NOT A MATCHER CHANGE — the same class as the "A / B" split above, and
# built the same way: THE FULL TITLE IS TRIED FIRST, so anything that resolves today resolves
# identically, and the retry is reachable only down a path that already ended in "no match".
#
# MEASURED BEFORE IT WAS BUILT (audit 2026-09-15, CLAUDE.md "SCOPED … subtitle retry"): 633 unique
# items across every feed and every year list 2016-2025, SIX with ": ". Two are fixed (Badu, and
# Dawn Richard *Second Line: An Electro Revival*, which the services call *Second Line*); three
# already match on the full title and never reach the retry; one fails on the ARTIST, which no
# title rule can touch.
#
# THE GUARDS, each for a trap the audit found on real catalogue data:
#   - EXACT only, on the pre-colon title (`_matchExactness`). Stops a prefix sibling: Spotify's
#     *NEVER ENOUGH: PORCHES VERSION* would otherwise pass for *NEVER ENOUGH*.
#   - A SERVICE RELEASE YEAR NO EARLIER THAN $minYear, and a match stating no year is refused.
#     Exactness cannot stop the worst trap — the pre-colon text can be a DIFFERENT real record by
#     the same artist. Turnstile's *NEVER ENOUGH: VERSIONS* (2026) shares its pre-colon title with
#     their 2025 album *NEVER ENOUGH*; the year rejects it. `$minYear` comes from the CALLER
#     (_subtitleMinYear): the review's year, or a year-end list's year MINUS ONE, because those
#     lists include late-previous-year releases (*Song of Sage*, 2020, is in the 2021 list). No
#     known year means no retry at all.
#   - NEVER on a title that also carries a slash. That is the combined-review path's shape
#     (*Song of Sage: Post Panic! / Navy's Reprise*), and two splitters working one title is how
#     a fragment ends up trusted.
#   - NEVER when the pre-colon text is the artist's own name, or too short to mean anything.
#   - The artist gate is the matcher's, unchanged: *Homecoming* by America does not pass for
#     Beyoncé's.
#
# THE GUARDS RUN HERE, ON EVERY CALL, never on what is cached. The pre-colon title resolves under
# its OWN stream key, shared with any review whose title simply IS that text; the stored items are
# that search's honest answer, and only this caller knows they are standing in for a longer title.
sub _subtitleBase {
    my ($album, $artist) = @_;
    return undef unless defined $album && !ref $album;
    return undef if $album =~ m{/};
    my ($pre) = $album =~ /^(.*?):\s/ or return undef;
    $pre =~ s/^\s+|\s+$//g;
    my $pn = _norm($pre);
    return undef unless length($pn) >= 2;
    return undef if $pn eq _norm($album);
    if (defined $artist && !ref $artist) {
        my $an = _norm($artist);
        return undef if length($an) && $pn eq $an;
    }
    return $pre;
}

# The earliest service release year a subtitle retry may accept for a row — see above. A
# year-end entry carries `year` (one year of slack); a review carries an ISO `date`.
sub _subtitleMinYear {
    my ($it) = @_;
    return undef unless ref $it eq 'HASH';
    return $it->{year} - 1 if defined $it->{year} && !ref $it->{year} && $it->{year} =~ /^\d{4}$/;
    return $1 if defined $it->{date} && !ref $it->{date} && $it->{date} =~ /^(\d{4})/;
    return undef;
}

sub _findPlayableSubtitle {
    my ($client, $callback, $artist, $album, $force, $minYear) = @_;
    my $base = _subtitleBase($album, $artist);
    return _findPlayable($client, $callback, $artist, $album, $force)
        unless defined $base && defined $minYear && $minYear =~ /^\d{4}$/;

    _findPlayable($client, sub {
        my $res = shift;
        return $callback->($res) if _realMatches($res);   # the full title matched: untouched
        _findPlayable($client, sub {
            my $sub = shift;
            # EITHER search being refused is a refusal of this review (0.9.39) — see PACED_WARM_GAP.
            $res->{_refused} = 1 if ref $sub eq 'HASH' && $sub->{_refused} && ref $res eq 'HASH';
            my @cand = _realMatches($sub);
            my @ok = grep {
                my $y = $_->{_year};
                _matchExactness($base, $_) eq 'exact'
                    && defined $y && !ref $y && $y =~ /^(\d{4})/ && $1 >= $minYear
            } @cand;
            _dbgv("subtitled review '$album': full title missed; '$base' gave " . scalar(@cand)
                . ' match(es), ' . scalar(@ok) . " exact and from $minYear or later");
            # Nothing trustworthy: answer with the FULL title's own miss, exactly as before.
            return $callback->($res) unless @ok;
            $callback->({ items => _streamResult($client, \@ok), ($res->{_refused} ? (_refused => 1) : ()) });
        }, $artist, $base, $force);
    }, $artist, $album, $force);
}

# Resolve a REVIEW to playable nodes: `_findPlayable` for an ordinary title, and for
# a combined "A / B" review the full title first, then each side.
#
# THE FULL TITLE IS ALWAYS TRIED FIRST, and that ordering is the correctness
# guarantee, not politeness. Some real albums do carry a space-padded slash, and for
# those the whole point is to match the title as written; only once that has come
# back with nothing do we entertain the theory that this is two records. So an
# album that resolves today resolves identically after this change — the split is
# reachable only down a path that already ended in "no match". The extra cost is
# paid solely by titles that were failing anyway, and only once: the full title's
# miss caches under STREAM_NOMATCH_TTL, after which the steady-state cost of a
# combined review is three kvGets.
#
# Each side resolves under its OWN stream key, so the cache, the in-flight
# coalescing and Refresh all work on it exactly as they do for any other album —
# there is no second cache layer and nothing new to invalidate.
#
# Sides are marked `_side`/`_sidetitle` and INTERLEAVED so each side's best match
# lands before STREAM_MAX_RESULTS can bite: side A may legitimately return a dozen
# editions, and appending side B behind them would let the cap silently delete the
# second album — the exact failure this sub exists to fix.
sub _findPlayableReview {
    my ($client, $callback, $artist, $album, $force, $minYear) = @_;

    my ($sides, $requireAll) = _splitAlbumTitles($album, $artist);
    # An ordinary title — including a "Title: Subtitle" one, which gets its own guarded retry.
    return _findPlayableSubtitle($client, $callback, $artist, $album, $force, $minYear) unless $sides;
    my @parts = @$sides;

    # ANY search this review made being refused is a refusal of the review (0.9.39) — see
    # PACED_WARM_GAP. Carried on every answer below.
    my $refused = 0;
    my $answer = sub { $callback->({ items => $_[0], ($refused ? (_refused => 1) : ()) }) };

    _findPlayable($client, sub {
        my $fullRes = shift;
        $refused = 1 if ref $fullRes eq 'HASH' && $fullRes->{_refused};
        my @full = _realMatches($fullRes);
        return $answer->(_streamResult($client, \@full)) if @full;

        _dbgv("combined review '$album' didn't match whole — trying " . scalar(@parts)
            . ' side(s)' . ($requireAll ? ', all of which must match' : ''));

        my @perSide;
        my $i = 0;
        # Self-passing sub, not a self-capturing closure — same reference-cycle
        # reasoning as $collect in _findPlayable.
        my $step = sub {
            my ($self) = @_;
            if ($i > $#parts) {
                _dbgv("combined review '$album': "
                    . join(', ', map {
                        my $n = scalar @{ $perSide[$_] || [] };
                        "'$parts[$_]' $n" . ($n ? ' ' . _matchExactness($parts[$_], $perSide[$_][0]) : '');
                      } 0 .. $#parts));

                # AN UNPADDED SIDE IS TRUSTED ONLY ON AN EXACT TITLE (0.9.21), replacing
                # the all-or-nothing rule 0.9.19 shipped. Both rules exist to reject a
                # FRAGMENT — `AC/DC Live` really does put an album called 'AC' in front of
                # the matcher — but they discriminate on different things, and the field
                # measurement settled which is right.
                #
                # All-or-nothing asked "did every side match?", which conflates two
                # completely different situations: a bogus split, and a genuine pairing
                # where one record simply is not carried. `EP/EP2` is the second, and it
                # was the case the feature was built for: Yaeji's *EP2* matched EXACTLY on
                # Qobuz while *EP* failed at SEARCH RECALL, not matching — `q=EP` returns
                # raw=0 on Qobuz and kept=0 of 50 on Tidal and Deezer, so no matcher could
                # ever find it. All-or-nothing therefore threw away a correct match and
                # left the review unplayable, which was the whole defect.
                #
                # Exactness separates the two cleanly, and the reason is structural rather
                # than empirical: `_albumMatches` can only admit a fragment through a
                # LOOSER tier — `index($t, "$albumNorm ") == 0` makes 'AC' match "ac dc
                # live" — never as an equal title, because an album titled exactly *AC*
                # would be a real album.
                #
                # MEASURED BEFORE IT WAS TRUSTED (0.9.20 dry run, 168 matches): 165 exact,
                # 3 loose, and all three loose ones are WHOLE titles — the ep/lp strip, an
                # artist-prefix case, and a Hangul title needing the ascii fold. Not one is
                # a split side, so this costs nothing observable. Padded splits are left
                # alone: on the same run exact-per-side and all-or-nothing agreed on
                # 'songs / instrumentals', so tightening them would be risk without gain.
                #
                # ANY item may carry the exact title, not just the first — a side whose
                # leading hit is a deluxe edition must not be thrown away when the plain
                # edition is right behind it. An exact one is promoted to the front, since
                # the row takes the first node.
                if ($requireAll) {
                    for my $s (0 .. $#parts) {
                        my $items = $perSide[$s] || [];
                        next unless @$items;
                        # grep returns the matching INDEX because the block is a plain
                        # condition; a `? $_ : ()` block would silently mis-handle index 0.
                        my ($ex) = grep { _matchExactness($parts[$s], $items->[$_]) eq 'exact' }
                                   0 .. $#$items;
                        if (defined $ex) {
                            unshift @$items, splice(@$items, $ex, 1) if $ex;
                            next;
                        }
                        _dbgv("combined review '$album': dropping side '$parts[$s]' — "
                            . 'matched only loosely, which is what a fragment looks like');
                        $perSide[$s] = [];
                    }
                    unless (grep { @{ $perSide[$_] || [] } } 0 .. $#parts) {
                        _dbgv("combined review '$album': no side matched exactly — "
                            . 'discarding the unpadded split');
                        return $answer->(_streamResult($client, []));
                    }
                }

                my @out;
                # Round-robin: A[0], B[0], A[1], B[1], ...
                for my $rank (0 .. STREAM_MAX_RESULTS) {
                    for my $s (0 .. $#perSide) {
                        push @out, $perSide[$s][$rank] if $perSide[$s] && $perSide[$s][$rank];
                    }
                }
                return $answer->(_streamResult($client, \@out));
            }
            my $side = $i++;
            _findPlayable($client, sub {
                my $sideRes = shift;
                $refused = 1 if ref $sideRes eq 'HASH' && $sideRes->{_refused};
                my @m = _realMatches($sideRes);
                # Tag a COPY, never the node the resolver cached/handed other callers.
                $perSide[$side] = [ map { { %$_, _side => $side, _sidetitle => $parts[$side] } } @m ];
                $self->($self);
            }, $artist, $parts[$side], $force);
        };
        $step->($step);
    }, $artist, $album, $force);
}

# Fan a resolved answer out to the callers that coalesced onto this key, one eval each.
#
# EACH WAITER GETS ITS OWN _streamResult: the list is capped and deduped per call and a
# caller may mutate what it is handed, so sharing one arrayref across callers would let the
# first edit what the rest receive. And each gets its own eval, because by the time this
# runs the %RESOLVING slot is gone — a waiter that is not called here is never called at
# all, and takes a $FG_INFLIGHT count with it if it came from a view.
sub _serveWaiters {
    my ($client, $items, $key, $waiters, $refused) = @_;
    for my $w (@$waiters) {
        eval { $w->({ items => _streamResult($client, $items), ($refused ? (_refused => 1) : ()) }); 1 }
            or $log->warn("resolve: a waiter for $key threw: $@");
    }
}

# HOW LONG THE RESOLVE IS KEPT — ONE PURE FUNCTION OVER THE RECORDED OUTCOMES (0.9.32).
#
# Extracted from `$resolve`'s inline ladder deliberately, and the reason is the failure mode
# this series keeps hitting: a fix makes a branch UNREACHABLE or a discriminator MEANINGLESS,
# and no example-based test can see it (0.9.28 orphaned the inconclusive branch; 0.9.30 split
# standing from transient for the log and left the TTL behind). A ladder inside a closure can
# only be probed through whichever scenarios someone thought to write. A pure function over a
# CLOSED enum can be enumerated exhaustively — every combination, plus a coverage assertion
# that each enum value still changes some cell — so "this discriminator no longer does
# anything" fails a test instead of shipping. See `t_releaserank.pl` section 3e.
#
# NO BEHAVIOUR CHANGE from the ladder it replaces. Worked cell by cell:
#
#   winner, leg 2 answered                     FOUND         (was: !$unvalidated[$win])
#   winner, leg 2 errored/timed out/undef      UNVALIDATED   (was:  $unvalidated[$win])
#   winner, leg 2 had no API handler           UNVALIDATED   (was:  $unvalidated[$win])
#   winner, an `empty_unverified` service
#     above it did not win (0.9.36)            UNVALIDATED   (new — see the note in the sub)
#   no winner, any transient failure           INCONCLUSIVE  (was:  $inconclusive)
#   no winner, every service unavailable       INCONCLUSIVE  (was:  $unavailable == @adapters)
#   no winner, some unavailable + some missed  NOMATCH
#   no winner, all really missed               NOMATCH
#
# The old `@unvalidated` already collapsed ERRORED and UNAVAILABLE into one flag
# (`unless defined $res && ref $res eq 'ARRAY'`), so naming them separately costs nothing here
# and is what lets the log stop lying about which one happened.
#
# THE WINNER'S OWN OUTCOME DECIDES, not the run's — a service that hung while LOSING the row
# must not shorten a fully validated answer. `$win` is defined whenever `$nitems` is non-zero
# (`$items` is `[]` unless it is), so that lookup is safe.
#
# `$nadapters` is passed rather than taken from `@$outcome` so the "not one service could
# search" test cannot be fooled by a sparse array. With no adapters at all it answers
# INCONCLUSIVE — matching the old `0 == 0`, and the right answer anyway, though
# `_findPlayable` returns before this on that path.
sub _streamTtl {
    my ($outcome, $nadapters, $win, $nitems, $unverified) = @_;

    if ($nitems) {
        # AN UNVERIFIABLE EMPTY ANSWER ABOVE THE WINNER (0.9.36). A service flagged
        # `empty_unverified` cannot tell "not in my catalogue" from "my API refused you": Spotty's
        # Pipeline turns a 502, a timeout and a 429 into the same `[]` as a genuine zero-hit. When
        # such a service OUTRANKS the winner, the row went to the lower service on an answer nobody
        # can check, and FOUND would pin that for thirty days. Measured on the live server with
        # Spotify at priority 1: the startup warm drew 184 Spotify 502s and 17 rows stayed on
        # Qobuz. So the row is held like any other unchecked answer, and re-resolved within a day.
        #
        # ONLY ABOVE THE WINNER, and never a STANDING-unavailable one: a flagged service ranked
        # below the row could not have taken it, and a signed-out one lost no answer. Unflagged
        # services keep the settled rule — the winner's own outcome decides (0.9.29) — and a
        # four-argument call gets exactly the table above it.
        return STREAM_UNVALIDATED_TTL
            if $unverified && $win
            && grep { $unverified->[$_] && ($outcome->[$_] // '') ne OUTCOME_UNAVAILABLE } 0 .. $win - 1;
        return (($outcome->[$win] // '') eq OUTCOME_ANSWERED)
            ? STREAM_FOUND_TTL : STREAM_UNVALIDATED_TTL;
    }
    # A transient failure anywhere means SOMETHING that could have answered did not, so the
    # miss is not confirmed and is retried soon.
    return STREAM_INCONCLUSIVE_TTL
        if grep { ($_ // '') eq OUTCOME_ERRORED } @$outcome;
    # Nobody searched at all. Not a verdict, so there is nothing to pin.
    my $unavail = grep { ($_ // '') eq OUTCOME_UNAVAILABLE } @$outcome;
    return STREAM_INCONCLUSIVE_TTL if $unavail >= $nadapters;
    # At least one service really looked and had nothing. That is a confirmed miss.
    return STREAM_NOMATCH_TTL;
}

# Resolve an album to playable streaming nodes. Calls back { items => [...] }.
# $force skips the cache READ (still writes) so the "Refresh streaming match" row
# can re-resolve past a stale no-match/wrong-match.
sub _findPlayable {
    my ($client, $callback, $artist, $album, $force) = @_;

    my $albumNorm  = _norm($album);
    my $artistNorm = _norm($artist);

    # Send the RAW artist to each service search (normalisation turns punctuation
    # into spaces, which the services' own search can't match); keep the normalised
    # forms for our _albumMatches validation only. Built in BOTH spellings: Qobuz
    # (uri_escape_utf8) and Tidal (Text::Unidecode) expect CHARACTER strings —
    # octets double-encode ("Sigur Rós" searched as "Sigur RÃ³s" -> junk/empty;
    # found + fixed in the Discography plugin 2026-07-10) — while Deezer's
    # complex_to_query wants OCTETS. Each adapter's query_enc picks its spelling.
    my $qChars = $artist;
    utf8::decode($qChars) unless utf8::is_utf8($qChars);   # no-op if not valid UTF-8
    my $qBytes = $artist;
    utf8::encode($qBytes) if utf8::is_utf8($qBytes);

    # SECOND LEG (0.7.12): the same two spellings of the ALBUM TITLE, used only when
    # the artist query comes back with nothing. Searching the artist is right most of
    # the time — it is the stable term, while a title picks up "EP"/"LP"/edition noise —
    # but it fails outright when the artist's name is a COMMON WORD. Measured: Qobuz
    # carries "Leo - Cicada Burnt" and returns it FIRST for the query "cicada burnt",
    # while its album search for "leo" returns 200 rows of Leo Sayer, Léo Ferré, Leo Dan
    # and Leo Kottke without it. Nothing was wrong with the matcher — the release never
    # reached it. Skipped when the title would just repeat the artist query (a self-titled
    # album), which is the one case where the second leg can only return what the first
    # already did.
    my $qaChars = $album;
    utf8::decode($qaChars) unless utf8::is_utf8($qaChars);
    my $qaBytes = $album;
    utf8::encode($qaBytes) if utf8::is_utf8($qaBytes);
    my $wantAlbumLeg = length($albumNorm) && $albumNorm ne $artistNorm;

    my @adapters = _orderedAdapters();
    unless (@adapters) {
        $callback->({ items => _streamResult($client, []) });
        return;
    }

    my $key = _streamKey(_streamId($artist, $album));
    # IN-FLIGHT COALESCING (0.9.12). Measured on the live server: Material re-requested
    # the year-end shelf NINE times in six minutes, and each request started its own
    # _resolveSection over the same 50 albums — the log shows the same album searched
    # twice inside 40ms ('moses sumney / grae'). The stored-answer check below cannot
    # help, because a concurrent resolve has not written yet. So a second caller for an
    # album already being resolved waits on the first instead of issuing its own search.
    #
    # $force NEVER JOINS AND NEVER CLAIMS. The Refresh-match row exists precisely to get
    # a fresh answer, so attaching it to an in-flight resolve would silently give it the
    # stale one it was trying to escape.
    #
    # THE SLOT HAS AN AGE, and that is not defensive clutter. API.pm's %PENDING carries a
    # long comment about a strand taking a key down for the life of the process; the
    # backfill guard removed earlier this session was the same shape; and the no-player
    # hole switched the warm off for three hours. Every service search here is
    # watchdogged so $finish "should always" run — but "should always" is the assumption
    # behind most of what has gone wrong in this file. A slot older than RESOLVE_JOIN_MAX
    # is treated as wedged and simply replaced, so the worst case is a duplicate search,
    # never an album that can never resolve again.
    my $token = 0;
    my @adopted;
    unless ($force) {
        if (my $slot = $RESOLVING{$key}) {
            if (time() - $slot->{at} <= RESOLVE_JOIN_MAX) {
                push @{ $slot->{waiters} }, $callback;
                return;
            }
            # ADOPT THE WAITERS — never bin them with the slot. Anyone queued on a wedged
            # claim holds a callback that nothing else will ever call, and in _resolveSection
            # that callback is the ONLY thing that decrements $active/$done/$FG_INFLIGHT. Drop
            # one from a VIEW and $FG_INFLIGHT never returns to zero for the life of the
            # process — which is not a counter nobody reads: it is tested for TRUTH, so one
            # stranded count leaves the warm yielding WARM_YIELD_MAX between two-item bursts
            # and pins every home shelf at the narrow width permanently. That is the 34/50 ->
            # 9/50 carousel regression 0.9.12 was cut to fix, arrived at from the other side.
            # They were waiting on an answer for THIS key and the fresh search is about to
            # produce one, so they simply move across.
            $log->warn("resolve slot for $key looks wedged — starting a fresh search");
            my $dead = delete $RESOLVING{$key};
            @adopted = @{ $dead->{waiters} || [] };
        }
    }

    if (!$force && (my $c = Plugins::PitchforkReviews::DB::kvGet($key))) {
        _dbgv("resolve cache hit: $key");
        # THE ADOPTED WAITERS HAVE TO BE SERVED HERE TOO, and this is not a corner: a wedged
        # slot is by definition RESOLVE_JOIN_MAX old, which is ample time for another resolve
        # of the same album to have stored the answer. Returning through here without them
        # re-drops exactly what was just rescued. Each caller gets its own list — see the
        # note on the same fan-out below.
        my $items = _rebuildStreamItems($c->{items});
        # ADOPTED WAITERS FIRST, AND EACH ONE GUARDED — see the note on the same fan-out
        # in $resolve below. $callback chains into the full feed render and can die; these
        # callers have no slot left to be rescued through.
        _serveWaiters($client, $items, $key, \@adopted);
        $callback->({ items => _streamResult($client, $items) });
        return;
    }

    # Claim the slot only now — AFTER the stored-answer check, so a cache hit never
    # registers as in-flight and never needs releasing.
    unless ($force) {
        $token = ++$SLOT_SEQ;
        $RESOLVING{$key} = { at => time(), waiters => \@adopted, token => $token };
    }

    # Resolve to the highest-priority service that matched, as soon as that is
    # decided (every higher-priority service has come back). Per-service watchdog
    # so a hung service can't stall the result.
    #
    # THE TOP-PRIORITY SERVICE IS PROBED ALONE FIRST (0.8.8), and the rest are
    # brought in only if it doesn't settle the question. The old code fired all
    # three at once, which read as "parallel is faster" but wasn't: the answer was
    # ALREADY only allowed to be the highest-priority match, so a hit on the first
    # service discarded two searches that had been sent anyway. Most albums hit the
    # first service, so this is roughly a third of the streaming API traffic for the
    # same answers — which is what pays for BUILD_CONCURRENCY going 6 -> 10, since
    # what those APIs actually see is requests in flight, not items in flight.
    # THE TRADE, stated plainly, and it is bigger than "one round becomes two":
    # the fan-out below waits for the top service's BOTH LEGS, because $finish is
    # what triggers it and the album-title retry (0.7.12) happens before $finish.
    # So the serial chain on a top-service miss is
    #     svc1 artist -> svc1 album -> [fan-out] -> svc2..n artist -> svc2..n album
    # = FOUR STREAM_SVC_TIMEOUTs of wall clock worst case (8s each = 32s), against
    # two before. BUILD_DEADLINE is 10s, so an item in that state can never make the
    # render — it resolves behind the deadline via the pump and appears on the next
    # open, which is the designed degradation, but it IS the degradation now.
    # It is still the minority case and it is bounded, whereas the wasted searches
    # were paid on EVERY item including all the ones that matched immediately.
    # If this ever needs tightening, fan out on the top service's ARTIST leg coming
    # back empty rather than on $finish — that restores the two-round worst case and
    # keeps most of the traffic saving, at the cost of one extra search per miss.
    my @result       = map { undef } @adapters;   # undef=pending, []=miss, [..]=match
    my $resolved     = 0;
    # WHAT EACH SERVICE DID — the single carrier (see the OUTCOME_* constants for why there
    # is exactly one). Per-adapter, written once in `$finish` before the merge, read by
    # `_streamTtl` and by the log line below. Held in its own array rather than as a flag on
    # the items: the items are what `_cacheStream` freezes and what the ListenLater handshake
    # reads, and provenance has no business in either.
    #
    # THE THREE VALUES ARE NOT INTERCHANGEABLE, and the distinctions are load-bearing:
    #   ANSWERED    a verdict, even when the list is empty — it looked and had nothing to add
    #   ERRORED     transient; it may well answer on the next open, so retry soon. Covers a
    #               search that errored, a watchdog, a throw — AND a missing API handler that
    #               has not yet outlasted SVC_UNAVAILABLE_GRACE, because during startup that
    #               is exactly what it is: a service that has not authenticated YET.
    #   UNAVAILABLE STANDING: no API handler, measured to have persisted past the grace
    #               window, i.e. nobody is signed in. NOT an inconclusive answer:
    #               `_detectAdapters` gates on `->can()` and knows nothing about sign-in, so
    #               the adapter sits in @adapters on every resolve for as long as the user
    #               leaves it signed out. Counting that as transient forced
    #               STREAM_INCONCLUSIVE_TTL on every genuinely unmatched album — an hour
    #               instead of a day, 24x the resolve traffic, indefinitely (0.9.31). But it
    #               is not simply ignored either, because "nobody could search" is still not a
    #               verdict: it shortens the TTL only when EVERY adapter was unavailable.
    my @outcome;
    # SOME SERVICE REFUSED A SEARCH IN THIS RESOLVE (0.9.39), put on the answer as `_refused`.
    # The warm's pump needs it because a refusal can answer SYNCHRONOUSLY — see PACED_WARM_GAP.
    my $refusedAny = 0;

    my $resolve = sub {
        return if $resolved;
        my $win;
        for my $i (0 .. $#adapters) {
            return if !defined $result[$i];
            if (@{ $result[$i] }) { $win = $i; last; }
        }
        $resolved = 1;

        # RELEASE THE COALESCING SLOT FIRST — before the cache write, before the log line,
        # before anyone is answered. Two reasons, and the second is why it sits up here
        # rather than below the cache write where it used to:
        #   - a callback that re-enters _findPlayable for the same album must find the slot
        #     free rather than join one that is already finishing;
        #   - EVERYTHING BETWEEN HERE AND THE CALLBACKS CAN DIE. _cacheStream reaches
        #     DB::kvSet, which dies on a character string where it wants octets, and
        #     _matchExactness runs eagerly to build the log line. A die below an unreleased
        #     claim left $resolved latched at 1 — so every later $finish returns early — AND
        #     the slot held for ever: the exact strand RESOLVE_JOIN_MAX exists to survive,
        #     manufactured by the release itself.
        # ONLY THE SLOT WE ACTUALLY CLAIMED, compared by token. A $force resolve never
        # claims; and an owner orphaned by the wedged-slot path above must not delete the
        # slot that replaced it, nor fire ITS waiters with this older search's answer and
        # leave the replacement's own completion finding nothing.
        my @waiters;
        if ($token) {
            my $slot = $RESOLVING{$key};
            if ($slot && ($slot->{token} || 0) == $token) {
                delete $RESOLVING{$key};
                @waiters = @{ $slot->{waiters} || [] };
            }
            $token = 0;
        }

        # Dedupe and CAP before caching, not just before display (0.8.8). A search
        # can match a dozen editions of the same album; only the first is ever used
        # by a list row and only STREAM_MAX_RESULTS are ever shown on a detail page,
        # but every one of them was being frozen into the cache as a full album node —
        # paid again in Storable serialisation on every write and every read.
        my $items = defined $win ? _dedupeStreamItems($result[$win]) : [];

        # AN EXACT TITLE WINS THE ROW (0.9.27), which 0.9.21 already does for the sides of a
        # combined review and this path never did. The row takes `$items->[0]` and the
        # services return their own relevance order, so a release that merely STARTS WITH
        # our title can sit in front of the one that IS it.
        #
        # THE FIELD CASE. Pitchfork reviewed Interpol's *This Mirror Weighs a Ton* (12
        # tracks, Qobuz release type Album, released the day of the review). Qobuz also
        # carries the 2-track single *This Mirror Weighs a Ton/See Out Loud*, which
        # `_albumMatches` admits through the prefix tier — `index($t, "this mirror weighs a
        # ton ") == 0` — and which its artist search returns at position 7 against the
        # album's 68. So the row resolved to the single, cached it for STREAM_FOUND_TTL,
        # and the drill-in went straight to two tracks.
        #
        # PURE REORDERING, and that is what makes it safe in the EP direction as well. It
        # only does anything when an exact candidate exists behind a loose one; where every
        # candidate is loose (`I Wander` vs `I Wander (III)` — _norm strips brackets, so
        # both are admitted and neither equals "i wander ep") nothing moves and the
        # behaviour is exactly what it was. Measured by 0.9.20's dry run: 165 exact against
        # 3 loose over 168 matches, and all three loose ones were whole titles with no
        # exact rival to be promoted over them.
        #
        # `grep` returns the matching INDEX because the block is a plain condition; the
        # `if $ex` skips the no-op when the exact one is already first (and when there is
        # none, `$ex` is undef). Same idiom as the split path, deliberately.
        if (@$items > 1) {
            my ($ex) = grep { _exactFolded($album, $items->[$_]) } 0 .. $#$items;
            unshift @$items, splice(@$items, $ex, 1) if $ex;
        }

        $items = [ @{$items}[0 .. STREAM_MAX_RESULTS - 1] ] if @$items > STREAM_MAX_RESULTS;
        # ONE PURE FUNCTION DECIDES, over the recorded outcomes — see `_streamTtl`, which
        # carries the whole truth table and the note on why it is not inline any more.
        # $resolve does not reach here until every adapter has reported (the loop above
        # returns on the first undef `$result[$i]`), so @outcome is complete by construction.
        my $ttl = _streamTtl(\@outcome, scalar(@adapters), $win, scalar(@$items),
                             [ map { $_->{empty_unverified} ? 1 : 0 } @adapters ]);
        # A failed cache write must not take the ANSWER with it. The callers below are
        # waiting on a result we already hold; the worst case of not storing it is that the
        # next open re-resolves. (Same guard, same reason, as API.pm's fetch sites — see the
        # 0.8.9 note there on DbCache dying outright on a character string.)
        eval { _cacheStream($key, $items, $ttl); 1 }
            or $log->warn("resolve: caching $key failed: $@");
        # The exactness tag is 0.9.20 dry-run instrumentation on the EXISTING line, so it
        # costs no extra log volume while giving a corpus-wide count of how load-bearing
        # _albumMatches' looser tiers actually are.
        # Counted off @outcome at the point of USE, so the line can never disagree with the
        # TTL beside it — the two now read the same record rather than two counters kept in
        # step by hand.
        my $nErrored = grep { ($_ // '') eq OUTCOME_ERRORED }     @outcome;
        my $nUnavail = grep { ($_ // '') eq OUTCOME_UNAVAILABLE } @outcome;
        _dbgv("resolve '$artistNorm / $albumNorm': "
            . (defined $win ? "matched on $adapters[$win]{name} (" . scalar(@$items) . ') '
                              . _matchExactness($album, $items->[0])
                              . ((($outcome[$win] // '') ne OUTCOME_ANSWERED)
                                    ? ' UNVALIDATED (leg 2 never answered, '
                                      . STREAM_UNVALIDATED_TTL . 's)'
                                 : ($ttl == STREAM_UNVALIDATED_TTL)
                                    ? ' UNVALIDATED (a higher-priority service\'s empty answer is unverifiable, '
                                      . STREAM_UNVALIDATED_TTL . 's)' : '')
                            : "no match" . ($nErrored ? " ($nErrored inconclusive)" : "")
                                         . ($nUnavail ? " ($nUnavail unavailable)"   : "")
                                         . ($ttl == STREAM_NOMATCH_TTL ? '' : " ttl=$ttl")));

        # THE WAITERS ARE SERVED BEFORE $callback, AND EACH ONE IS GUARDED. $callback
        # chains into the full feed render — a lot of code, any of which can die — and the
        # fan-out used to run after it, unguarded, so one throw stranded EVERY coalesced
        # waiter. The %RESOLVING slot was deleted above by then, so the RESOLVE_JOIN_MAX
        # adoption path cannot rescue them either: there is no wedged slot left to adopt.
        # And a stranded waiter that came from a `view` is a $FG_INFLIGHT that never
        # decrements (only _resolveSection's resolver callback does that) — which is tested
        # for TRUTH, so ONE leak pins the warm at WARM_CONCURRENCY and every home shelf at
        # the narrow width for the life of the process. That is 0.9.23's finding-1 leak,
        # reintroduced from the publish side.
        _serveWaiters($client, $items, $key, \@waiters, $refusedAny);
        $callback->({ items => _streamResult($client, $items), ($refusedAny ? (_refused => 1) : ()) });
    };

    # Self-passing sub, not a self-capturing closure — see the $collect note below.
    # $finish captures $self (an argument), never a variable holding this sub, so
    # the fan-out below recurses without building a reference cycle.
    my $startAdapter = sub {
        my ($self, $i) = @_;
        my $a    = $adapters[$i];
        my $svc  = $a->{name};
        my $icon = $a->{icon};

        # The top-priority service came back without settling it: bring the rest in,
        # in parallel, exactly as the old code did from the start.
        my $fanOut = sub {
            return if $resolved || $i != 0;
            $self->($self, $_) for 1 .. $#adapters;
        };

        my $settled = 0;
        my $svcTimer;
        # Leg 1's matches, held while the album-title leg runs (see $collect). Declared
        # HERE, above $finish, because the fallback that consumes them belongs in $finish:
        # that is the ONE funnel every outcome passes through, including the two $runLeg
        # writes ($collect never sees a watchdog or a throw).
        my @leg1;
        my $finish  = sub {
            return if $settled || $resolved;
            $settled = 1;
            Slim::Utils::Timers::killSpecific($svcTimer) if $svcTimer;
            # $standing: this service has had no API handler for longer than
            # SVC_UNAVAILABLE_GRACE, i.e. it is genuinely signed out rather than mid-startup.
            # MEASURED in `_svcCantAnswer`, never claimed by a call site (0.9.32). $runLeg's
            # watchdog and its eval-failure branch call $finish with one argument, so a
            # timeout or a throw stays transient, which is what they are.
            my ($res, $standing, $refused) = @_;
            # A REFUSED leg is recorded for the answer, not as an outcome of its own: it is
            # ERRORED like any search that was never answered. See $refusedAny.
            $refusedAny = 1 if $refused;

            # RECORD WHAT THIS SERVICE DID — HERE, BEFORE THE MERGE, AND EXACTLY ONCE.
            #
            # The position is the whole fix. The merge below rewrites `$res` into the leg-1
            # list, so every later test of `$res` is asking about the MERGED value while
            # reading like it asks about the argument. That is what orphaned the inconclusive
            # branch in 0.9.28, and what let `_svcCantAnswer` warn "counted unavailable" for a
            # run where neither counter could possibly increment. Recorded up here, the value
            # says what the service did and nothing downstream can quietly redefine it.
            #
            # An ARRAY is a verdict even when it is empty — the service looked and had nothing
            # to add — which is why the test is on the ARGUMENT and never on `@leg1`.
            $outcome[$i] = (defined $res && ref $res eq 'ARRAY') ? OUTCOME_ANSWERED
                         : $standing                             ? OUTCOME_UNAVAILABLE
                         :                                         OUTCOME_ERRORED;
            # MERGE, NEVER REPLACE. Leg 1's matches are real — they passed the same
            # `_albumMatches` gate — and the title query is a different search with its own
            # recall, so it can legitimately return FEWER rows than the artist query did,
            # or none, or nothing at all. Replacing would turn a loose-but-correct match
            # into a no-match whenever leg 2 missed, which is a regression on every title
            # this leg was not built for.
            # LEG 2 LEADS ONLY WHEN IT ACTUALLY BROUGHT THE EXACT (0.9.31). It used to lead
            # unconditionally, on the reasoning that "the promotion in $resolve then decides".
            # That reasoning holds only while an exact candidate EXISTS: the promotion greps
            # for `_exactFolded` and is a no-op when nothing matches it, so with both legs
            # loose the merge ORDER became the decider by accident, and leg 2's arbitrary
            # first loose hit took the row — pinned for STREAM_FOUND_TTL, because leg 2
            # answering is exactly what marks the row validated.
            #
            # THAT IS A 0.9.27 REGRESSION, not a pre-existing wart. Before 0.9.27 the retry
            # gate was `!@$res`, so a loose-only leg 1 never fired leg 2 at all and leg 1's
            # match took the row unopposed. Widening the gate to loose-only is right — it is
            # the Interpol fix — but it routed a whole new class of resolve through a merge
            # order that was only ever justified for the exact case.
            #
            # WHY LEG 1 IS THE BETTER DEFAULT WHEN NEITHER IS EXACT. Leg 1 is the ARTIST
            # query, so every row it returns is already the right artist and the title is
            # what `_albumMatches` judged. Leg 2 is the TITLE query: it exists for recall,
            # reaching releases the artist search buried, and its relevance order is
            # title-first — which is why it is the leg that surfaces a like-named rival in
            # the first place. With no exact to arbitrate, the artist-scoped answer is the
            # conservative one and it is also the one the plugin shipped for four versions.
            #
            # AND LEG 1 CAN LEAD UNCONDITIONALLY, which is why there is no test on leg 2
            # here. `_wantsTitleRetry` returns 0 the moment leg 1 holds a folded-exact, so
            # reaching this merge at all PROVES `@leg1` is exact-free. The only exact that
            # can exist is leg 2's, and the promotion in $resolve lifts it from wherever it
            # sits in the merged list — the order never decided that case, only the case
            # where nothing is exact. A conditional "lead with leg 2 when it brought the
            # exact" was built first and is provably a no-op: it was anti-tested by
            # replacing it with this line, and every assertion still held.
            #
            # It also sidesteps a real edge in that promotion, which is `if $ex` and not
            # `if defined $ex`. Leading with leg 2 puts its exact at index 0, where `$ex`
            # is 0 and the unshift is skipped — harmless only because the row is already
            # first. Leading with leg 1 (non-empty by the guard above) means an exact is
            # always at index >= 1, so the promotion genuinely runs.
            #
            # `_dedupeStreamItems` still collapses the rows both legs returned, and
            # `_releaseAlts` still offers the runner-up, so nothing is LOST by ordering —
            # only which release the row itself opens.
            # THIS MUST LIVE IN $finish, NOT IN $collect. $runLeg's watchdog and its eval
            # failure branch call $finish DIRECTLY — $collect is the adapter's callback and
            # is never reached when leg 2 times out or throws. With the merge in $collect,
            # a leg-2 timeout dropped the matches leg 1 was holding and answered
            # inconclusive; and 0.9.27 fires leg 2 on a LOOSE-ONLY leg 1, so those held
            # matches are the common case, not an edge one.
            if (@leg1) {
                # AND RECORD THAT NOBODY CHECKED IT (0.9.29). Leg 2 not coming back as an
                # ARRAY means it never answered — its watchdog fired, `$runLeg`'s eval caught
                # a throw, or the adapter called back undef. The merge below is still right
                # (leg 1's matches passed `_albumMatches`; dropping them is 0.9.28's bug), but
                # what comes out is an UNCHECKED answer wearing a checked one's clothes, and
                # `$resolve` would otherwise pin it for STREAM_FOUND_TTL — thirty days for the
                # like-named single the second query existed to rule out.
                # A leg 2 that DID answer, even with `[]`, is a real verdict: it looked and had
                # nothing to add, so leg 1's match stands fully validated and keeps the long
                # TTL. That is the discriminator, and it is why this is tested on the ARGUMENT
                # and not on `@leg1`.
                $res = (defined $res && ref $res eq 'ARRAY') ? [ @leg1, @$res ] : [ @leg1 ];
            }
            # undef = couldn't query the service (no handler / timeout / error / broken
            # renderer) -> not a real miss. Which KIND it was is already recorded above; this
            # branch only has to publish the empty result and move the run along.
            if (!defined $res) {
                $result[$i] = [];
                $resolve->();
                $fanOut->();
                return;
            }
            my @matched = (ref $res eq 'ARRAY') ? @$res : ();
            for my $it (@matched) {
                $it->{_cover} = $it->{image} if defined $it->{image};   # native album cover (for list rows)
                $it->{image}  = $icon if $icon;   # service logo as the detail-row thumbnail
                $it->{_svc}   = $svc;             # for the cache rebuild
                # ListenLater interop: give the row a real favorites_url
                # (<scheme>://album:<id>?cover=…&a=…) — without it a Qobuz match carries
                # no favurl and the coderef `url` leaks through as a broken link, so
                # ListenLater can't tell the service or replay the album. Same handshake
                # the sibling plugin uses. (Cover rides ?cover=; artist rides &a= because
                # Material sends these rows no $ARTISTNAME.)
                # The album name and year come from the MATCHED SERVICE (`_svctitle`/`_year`,
                # stashed from the raw album hash at match time), NOT from $album — which is
                # Pitchfork's spelling of the title, and not what the service will report
                # while the album plays. No fallback: with no service title we send no
                # '&al=' and ListenLater reads Material's label, which is imperfect but
                # never wrong, whereas the wrong string is silently unmatchable.
                # A service flagged `native_favurl` (Spotify) already ships a WORKING favurl
                # from its own renderer, and decorating it would break it: Spotty's album()
                # extracts the id with a greedy /album:(.*)/, which would capture the query
                # string into the id and replay nothing.
                _attachFavUrl($it, $svc, $it->{_cover}, $artist, $it->{_svctitle}, $it->{_year})
                    unless $a->{native_favurl};
            }
            $result[$i] = \@matched;
            $resolve->();
            $fanOut->();   # a no-op once $resolve has decided (i.e. whenever this one matched)
        };

        # Fire one search leg and arm a FRESH watchdog for it, so the album-title leg
        # gets its own full budget rather than the remains of the artist leg's.
        my $runLeg = sub {
            my ($qc, $qb, $what, $cb) = @_;
            $svcTimer = Slim::Utils::Timers::setTimer(undef, time() + STREAM_SVC_TIMEOUT, sub {
                return if $settled || $resolved;
                $log->warn("resolve $svc timed out ($what query)");
                $finish->(undef);
            });
            my $queryEnc = ($a->{query_enc} || 'bytes') eq 'chars' ? $qc : $qb;
            eval { $a->{run}->($client, $queryEnc, $artistNorm, $albumNorm, $svc, $cb, $album); 1 } or do {
                $log->warn("resolve $svc failed ($what query): $@");
                $finish->(undef);
            };
        };

        # A DEFINED but EMPTY result is "this service's search didn't surface it",
        # which is a recall answer, not a verdict — retry once on the album title.
        # undef is NOT retried: it means the service couldn't be queried at all
        # (no handler / timeout / error), so a second query would just spend another
        # STREAM_SVC_TIMEOUT to reach the same inconclusive end.
        # SELF-PASSING sub, not a self-capturing closure. `my $x; $x = sub {... $x ...}`
        # makes the sub hold a reference to itself — a cycle Perl's refcounting can
        # never collect, so the closure and everything it captured leak for the life
        # of the process. That matters HERE more than anywhere else in the plugin:
        # one is built per adapter per resolve (three services x ~150 items on the
        # daily warm alone), and each one retains the matched album nodes through
        # $finish. Same defect and same fix as the sibling ListenBrainz plugin
        # (LBF 0.9.95). The thin wrapper handed to $runLeg captures $self but is not
        # captured BY it, so nothing points back at itself.
        my $legs = 0;
        my $collect = sub {
            # $standing rides through to $finish untouched (0.9.31) — see its note there.
            # The retry gate below cannot fire on it: `_wantsTitleRetry` returns 0 for
            # anything that is not an ARRAY ref, and a standing failure always sends undef.
            my ($self, $res, $standing, $refused) = @_;
            return if $settled || $resolved;
            # THE RETRY NOW FIRES ON A LOOSE-ONLY RESULT, not only on an empty one (0.9.27).
            # 0.7.12 added this leg for a RECALL failure — a common-word artist ("Leo")
            # buries the release past any search cap — and an empty result is only the most
            # obvious shape of that. The Interpol case is the same failure with a decoy: the
            # artist search returned a match, so the leg never ran, and the album it should
            # have found sat at position 68 against QOBUZ_SEARCH_LIMIT of 50. A title search
            # for "this mirror weighs a ton" returns exactly two rows and both of them are
            # the right artist, so the release the cap hid is one query away.
            #
            # GATED ON THE FOLDED TEST, WHICH IS NOT A DETAIL. On the strict test an EP
            # review is never exact (see _exactFolded), so every EP-titled review would pay
            # a second search on every cold resolve for a result it already had. Folded,
            # `I Wander EP` -> `I Wander` settles on leg 1 and never gets here.
            #
            # Raising the cap is the other way to reach the same album and is worse: 68
            # needs ~100 rows, Qobuz's own `_precacheAlbum` runs synchronously over every
            # row returned on OUR event loop (the 23.4s article fetch documented above),
            # and it still leaves the single ahead of the album in raw order.
            if ($wantAlbumLeg && !$legs++ && _wantsTitleRetry($album, $res)) {
                @leg1 = @$res;
                Slim::Utils::Timers::killSpecific($svcTimer) if $svcTimer;
                _dbgv("resolve $svc: " . (@leg1 ? scalar(@leg1) . ' loose match(es)' : 'no hit')
                    . " for artist '$artist' — retrying on album '$album'");
                $runLeg->($qaChars, $qaBytes, 'album', sub { $self->($self, @_) });
                return;
            }
            # $finish merges @leg1 back in — every outcome, including a leg-2 watchdog or
            # throw, has to get that fallback and only $finish sees them all.
            $finish->($res, $standing, $refused);
        };

        $runLeg->($qChars, $qBytes, 'artist', sub { $collect->($collect, @_) });
    };

    $startAdapter->($startAdapter, 0);
}

# A release YEAR from a streaming service's RAW album hash, for the '&y=' handshake.
# Qobuz states the date on its album object (release_date_original / the released_at epoch);
# Tidal and Deezer use releaseDate / release_date. Ported verbatim from the ListenBrainz
# sibling — keep the two in step if a service adds a field. '' when nothing states one.
sub _svcYear {
    my (@hashes) = @_;
    for my $h (@hashes) {
        next unless ref $h eq 'HASH';
        for my $k (qw(release_date_original release_date releaseDate date streamStartDate)) {
            my $v = $h->{$k};
            return $1 if defined $v && !ref $v && $v =~ /^(\d{4})/;
        }
        my $e = $h->{released_at};   # Qobuz epoch variant
        if (defined $e && !ref $e && $e =~ /^\d{9,}$/) {
            return (localtime($e))[5] + 1900;
        }
        return $1 if defined $h->{year} && !ref $h->{year} && $h->{year} =~ /^(\d{4})/;
    }
    return '';
}

# Strip an artist affix a service has joined onto its own album title, for '&al='.
# Ported from ListenBrainz Fresh Releases 0.9.147, where a service's "title" field turned
# out not to be the bare title on every service. The MATCHER never notices, because
# _albumMatches accepts a candidate that STARTS WITH our album — so a trailing " - artist"
# sails through matching while being wrong as a title.
#
# Deliberately conservative: the separator must be SPACE-PADDED (so `Jay-Z` is untouched),
# the discarded side must EQUAL the artist under _norm (not merely contain it, so
# "Album - aksfx remixes" is left alone), and anything failing either test is returned
# VERBATIM — a missed strip is a cosmetic wart, a wrong strip corrupts the title Listen
# Later matches and dedupes on. Prefix is tested at the FIRST separator and suffix at the
# LAST, so a title containing its own " - " still resolves.
#
# PFR-ONLY presentation logic, outside the shared matcher — do NOT confuse it with
# `_stripArtistPrefix`, which IS a fleet-synced shared-engine sub. This one does not trip
# matcher_sync_check. Kept byte-identical to LBF's copy; port any change to both.
sub _stripArtistAffix {
    my ($title, $artist) = @_;
    return $title unless defined $title  && !ref $title  && length $title;
    return $title unless defined $artist && !ref $artist && length $artist;

    my $an = _norm($artist);
    return $title unless length $an;

    # Hyphen-minus, the Unicode dash family (figure/en/em/horizontal bar) and minus sign.
    my $dash = qr/\s+[-\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}]\s+/;

    if ($title =~ /^(.*?)$dash(.*)$/s) {          # first separator → "<artist> - <album>"
        my ($lhs, $rhs) = ($1, $2);
        return $rhs if length $rhs && _norm($lhs) eq $an;
    }
    if ($title =~ /^(.*)$dash(.*?)$/s) {          # last separator  → "<album> - <artist>"
        my ($lhs, $rhs) = ($1, $2);
        return $lhs if length $lhs && _norm($rhs) eq $an;
    }
    return $title;
}

# Decorate a matched streaming album with a ListenLater-friendly favorites_url:
#   <scheme>://album:<nativeId>[?cover=<art>][&a=<artist>][&al=<service album>][&y=<year>]
# XMLBrowser copies an explicit $item->{favorites_url} into presetParams.favorites_url
# (which Material exposes as $FAVURL) — without it the coderef `url` leaks as the favurl
# and ListenLater sees a broken link with no service/id. ListenLater reads the scheme as
# the source, album:<id> for direct replay, and the private ?cover=/&a= params (which it
# strips before saving) for artwork + artist. Same handshake as the sibling plugin.
# No native id → no favurl (the row still displays + plays here; it just can't be added
# to ListenLater with full fidelity). Ported from ListenBrainz Fresh Releases.
sub _attachFavUrl {
    my ($it, $svc, $art, $artist, $album, $year) = @_;
    my $id = $it->{_albumid};
    return unless defined $id && length $id;

    my $fav = lc($svc) . '://album:' . $id;   # scheme = ListenLater's qobuz/tidal/deezer source tag
    my @params;

    if (defined $art && !ref $art && length $art) {   # plain URL string only (not a coderef/other ref)
        require URI::Escape;
        push @params, 'cover=' . URI::Escape::uri_escape_utf8($art);
    }
    # Material sends these matched rows no $ARTISTNAME (subtitle is the date/genre/capsule,
    # not the artist), so pack the review artist as a private &a= param; ListenLater reads
    # it as a fallback when $ARTISTNAME is empty, then strips it.
    if (defined $artist && !ref $artist && length $artist) {
        require URI::Escape;
        push @params, 'a=' . URI::Escape::uri_escape_utf8($artist);
    }
    # Our row label is "Artist - Album" (line1), and Material forces $ALBUMNAME/$TITLE to
    # that whole label for online items — so ListenLater would store the artist doubled into
    # the album title (breaking its list display AND its Played auto-detection, which keys on
    # the album name). Pack the album title as &al= (symmetric with &a=); ListenLater
    # prefers it over the label, then strips it. Packed whenever we have a non-empty
    # album string, same idiom (and same defined/ref/length guard) as &a=.
    #
    # SEND THE MATCHED SERVICE'S TITLE, NOT PITCHFORK'S (0.7.10). By the time we build a
    # favurl this review has been RESOLVED to a specific album on Qobuz/Tidal/Deezer, and
    # from that point the SERVICE's spelling is the only one that works downstream: LL's
    # Played auto-detection matches the PLAYING track's album title (which the service
    # reports), and its artist|album|year dedupe key must agree with a direct add from that
    # same service. Pitchfork's spelling and the service's differ often enough to matter —
    # Pitchfork appends " EP"/" LP" that services drop (the `_stripFmt` fallback exists
    # precisely because of it), so sending Pitchfork's name would leave releases unmatched
    # at playback, SILENTLY: the album plays perfectly and just never reaches Played.
    # The sibling ListenBrainz plugin shipped exactly that bug (its 0.9.144-0.9.147);
    # `$album` here is now the service title, stripped of any artist affix — see the
    # `_svctitle` stash in _searchQobuz/_searchTidal/_searchDeezer.
    if (defined $album && !ref $album && length $album) {
        require URI::Escape;
        push @params, 'al=' . URI::Escape::uri_escape_utf8($album);
    }

    # ...and the release YEAR as '&y=' (0.7.10). It is the third segment of ListenLater's
    # artist|album|year dedupe key, so without one a saved row keys as "artist|album|" and
    # the SAME album added from somewhere that supplies a year keys differently — a second
    # row dedupe cannot see. Pitchfork states a review date, not a release date, so the year
    # comes from the MATCHED SERVICE's own album data (_svcYear), which is the release date
    # and is what the service will report while playing. Bare 4-digit, no escaping needed.
    if (defined $year && !ref $year && $year =~ /^(\d{4})$/) {
        push @params, 'y=' . $1;
    }

    $fav .= '?' . join('&', @params) if @params;
    $it->{favorites_url} = $fav;
}

# Cache matched items. Qobuz/Tidal/Deezer album nodes all carry a CODEREF url that
# Storable can't serialise — stripped here, reattached per service on read by
# _rebuildStreamItems (the album id rides `passthrough`, which survives the cache).
# Guarded: Storable dies on unexpected nested refs and that must not stop the page.
sub _cacheStream {
    my ($key, $items, $ttl) = @_;
    my @store = map { my %x = %$_; delete $x{url}; \%x } @$items;
    Plugins::PitchforkReviews::DB::kvSet($key, { items => \@store }, $ttl);
}

# Dedupe by service + display text (services sometimes return the same album
# twice; different editions differ in name and are kept).
sub _dedupeStreamItems {
    my ($items) = @_;
    my (%seen, @out);
    for my $it (@{ $items || [] }) {
        my $k = join('|', $it->{_svc} // '', $it->{name} // '', $it->{line2} // '');
        next if $seen{$k}++;
        push @out, $it;
    }
    return \@out;
}

# Cap + dedupe; a no-match yields a single informational text row.
sub _streamResult {
    my ($client, $items) = @_;
    $items = _dedupeStreamItems($items);
    $items = [ @{$items}[0 .. STREAM_MAX_RESULTS - 1] ] if @$items > STREAM_MAX_RESULTS;
    return @$items
        ? $items
        : [ { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_NO_MATCH'), type => 'text' } ];
}

# Rebuild playable items from cached (url-stripped) data by reattaching each
# service's native play coderef. Items whose service is no longer enabled/present
# are dropped (so disabling a service hides its cached matches immediately).
sub _rebuildStreamItems {
    my ($cached) = @_;

    # Each adapter names its own reattach coderef (`rebuild`, see _detectAdapters), so this
    # needs no per-service branch. Every service's album node has the same shape: the
    # renderer's coderef url is stripped on cache and the native id rides `passthrough`
    # (plain data), which the reattached browse handler resolves the tracklist from. (For
    # Deezer the `deezer://album:<id>` string is the play/favourites value, NOT this url.)
    my %enabled = map { $_->{name} => $_ } _orderedAdapters();

    my @out;
    for my $c (@{ $cached || [] }) {
        my %item = %$c;
        my $svc  = $item{_svc} // '';
        my $rebuild = $enabled{$svc} && $enabled{$svc}{rebuild};
        next unless ref $rebuild eq 'CODE';
        $item{url} = $rebuild;

        push @out, \%item;
    }

    return \@out;
}

# Qobuz: search albums via the plugin's own API, keep title+artist matches, and
# reuse the plugin's _albumItem so each result is a native, playable album node.
# ---------------------------------------------------------------------------
# SEARCH INSTRUMENTATION (0.9.14) — one line per service call, debug-gated.
#
# WHY, and what it is meant to settle. A cold resolve measures ~2900ms per album at
# width 10, while our own work on one — JSON decode, _albumMatches, _norm, item build —
# measures ~8.6ms (taken when Qobuz's own plugin cache served a whole re-resolve at
# 8.6ms/album). So 99.7% of a cold resolve is upstream, and every optimisation aimed at
# our side of it would be optimising the wrong 0.3%.
#
# What is NOT yet known is why throughput scales so badly with concurrency: width 2 gives
# 1.6-2.1 items/s and width 10 gives 3.1-3.6, so 5x the dispatch buys 2x the work. Pure
# network wait would scale linearly. Something has a ceiling — LMS's async HTTP pool, or
# rate limiting inside a service plugin's own handler.
#
# The other open question is payload size. Pitchfork Reviews calls Qobuz as
# `search($cb, $query, 'albums')` and passes NO $args, though the signature is
# ($self,$cb,$query,$type,$args) — so we take Qobuz's default, and the sibling
# Discography plugin caps the same calls at limit 25/50. A common-word artist is
# recorded as returning ~200 albums.
#
# So this logs, per call: elapsed ms, RAW rows returned, and rows surviving the match.
# Raw rows is the number that decides whether a limit is worth adding at all — if Qobuz
# is already returning ~50 the hypothesis is dead and we save building it. Deliberately
# shipped BEFORE any limit change, so the baseline is measured rather than assumed.
# No gate of its own: _dbg already writes to server.log at INFO always and gates only
# the pfr-debug.log append. A second gate here would suppress the INFO line too, which
# is both inconsistent with every other _dbg call in this file and exactly the kind of
# thing that produces a run with no data in it.
# `at=` is the 1-based position of the FIRST kept match in the raw list, and it is the
# field that decides whether capping the search is safe. 0.9.14 logged raw= and kept= and
# proved the waste (33,585 album objects pulled, 316 used — 0.94%) but could not size a
# cap, because "we pulled 200 rows" says nothing about whether the match was at row 3 or
# row 180. Capping below the observed maximum silently loses those matches, which is the
# 'Leo / Cicada Burnt' failure that the second search leg exists to work around.
# WHY A SERVICE WENT QUIET, SAID OUT LOUD (0.9.30).
#
# Every adapter has three ways to answer `undef` — no API handler, the API erroring, and
# the foreign renderer throwing on every candidate — and the first two produced NO log line
# at all. `_dbgSearch` is called AFTER both, so a service that FAILED left exactly the same
# trace as one that was never asked: nothing.
#
# That is how a live Tidal fault stayed invisible. Four Tet's review title makes TIDAL's
# search return 500 on every attempt; PFR correctly records the service OUTCOME_ERRORED, and
# `_streamTtl` takes STREAM_INCONCLUSIVE_TTL instead of STREAM_NOMATCH_TTL — so that row
# re-resolves hourly instead of daily, at 5 searches a cycle, indefinitely. Nothing in PFR's
# own log said why. The only evidence was a MISSING `search Tidal/albums` line beside the
# other two services' present ones, and a `Plugins::TIDAL::API::Async … Error: 500` that
# nobody would think to correlate. Reconstructing that took a per-service line count.
#
# WARN, NOT `_dbgv`, AND THAT IS THE WHOLE POINT. A diagnostic gated behind the debug switch
# is no use for the case it exists to catch: you turn the switch on after NOTICING, and the
# defect here is that there is nothing to notice. One sick album costs a line an hour; a
# service-wide outage — the case actually worth seeing — announces itself instead of showing
# up as quietly fewer matches and a 24x rise in resolve traffic.
#
# `$once` is for the standing-state case rather than the event case. A missing API handler
# usually means the user is signed OUT of that service, which is true for every album in the
# run — warning per resolve would put ~150 identical lines in a single warm and bury the
# thing you wanted to read. Once per service per process says it exactly as often as it is
# worth saying. (Same shape as the signed-out Spotty note in the ListenBrainz sibling.)
my %CANT_ANSWER_WARNED;
my %STANDING_WARNED;

# WHEN EACH SERVICE WAS FIRST SEEN WITHOUT AN API HANDLER, since the last time it had one.
# Keyed by SERVICE ALONE, and that is settled rather than a simplification: the streaming
# account is held by the SERVER, not per player, so `getAPIHandler($client)`'s client
# parameter is a calling convention and carries no per-player account state. See the
# SVC_UNAVAILABLE_GRACE note for why this is measured at all.
my %UNAVAIL_SINCE;

# The service HAS a handler right now, so whatever we were timing is over. Called from the
# three adapters immediately after the `unless ($api)` guard — HAVING A HANDLER IS THE
# AVAILABILITY SIGNAL, which is why this is not hooked to a successful SEARCH instead: a
# search can error for its own reasons while the user is perfectly well signed in.
sub _svcHasHandler {
    my ($svc) = @_;
    # Forget EVERYTHING recorded about an outage, the warn flags included — the service is
    # healthy, so a LATER outage is a new event and deserves to be reported as one. Keeping
    # the flags process-wide (0.9.30's shape) meant a service that failed at startup, signed
    # in, and then dropped out at noon warned exactly nothing, which is the silent-service
    # case the warn exists for. Volume is still bounded: a second warn now costs a successful
    # handler in between.
    delete $UNAVAIL_SINCE{$svc};
    delete $CANT_ANSWER_WARNED{$svc};
    delete $STANDING_WARNED{$svc};
    return 1;
}

# The service has NO handler right now. Records the first sighting and answers whether it has
# been gone long enough to call STANDING rather than a startup race. `$now` is injectable so
# the window is testable without waiting ten minutes — same pattern as `_topYear`/`_latestTtl`.
# MONOTONIC, NOT WALL CLOCK (0.9.33). The grace window is meant to be relative to THIS
# process's uptime — that is the whole reason %UNAVAIL_SINCE lives in process memory rather
# than the kv store (see the SVC_UNAVAILABLE_GRACE note) — and `time()` is not that.
#
# An RTC-less host is the case that matters, which is most of the fleet (Pi/dietpi): the
# clock is restored at boot from the last shutdown stamp (fake-hwclock / timesyncd), then
# NTP STEPS it forward to true time once the network is up. That step is the length of the
# downtime, so a server left off overnight steps by hours — and it lands in precisely the
# window this grace exists to cover, between the plugin's startup warm and the services
# authenticating. Recording $UNAVAIL_SINCE before the step and comparing after it makes the
# delta jump past SVC_UNAVAILABLE_GRACE, so a startup race is classified STANDING. It only
# costs a wrong TTL in the MIXED case (one service authenticated and searching, another not
# yet) because _streamTtl answers INCONCLUSIVE when every adapter is unavailable — but in
# that case it flips INCONCLUSIVE to a 24h STREAM_NOMATCH_TTL pin on a miss nobody confirmed.
#
# CLOCK_MONOTONIC cannot step or run backwards. Falling back to time() where the platform
# has no monotonic clock is no worse than what this replaces.
my $HAVE_MONO = eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 } ? 1 : 0;
sub _monoNow {
    return $HAVE_MONO ? Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) : time();
}

sub _svcNoHandler {
    my ($svc, $now) = @_;
    $now = _monoNow() unless defined $now;
    $UNAVAIL_SINCE{$svc} = $now unless defined $UNAVAIL_SINCE{$svc};
    return (($now - $UNAVAIL_SINCE{$svc}) >= SVC_UNAVAILABLE_GRACE) ? 1 : 0;
}

# Test hook: this state is process-wide and outlives a block, the same hazard `reset_all`
# already clears for %RESOLVING.
sub _resetSvcAvailability {
    %UNAVAIL_SINCE = (); %CANT_ANSWER_WARNED = (); %STANDING_WARNED = (); return 1;
}

sub _svcCantAnswer {
    my ($svc, $why, $query, $collect, $noHandler, $refused) = @_;
    # THE CALL SITE STATES A FACT; THE CLASSIFICATION IS COMPUTED HERE (0.9.32). The fifth
    # argument used to be `$standing` — a hardcoded prediction that a missing handler will
    # still be missing next time. It is now `$noHandler`, which is simply what the adapter
    # observed, and whether that amounts to a STANDING inability is measured against the
    # grace window instead of assumed.
    my $standing = $noHandler ? _svcNoHandler($svc) : 0;

    # THE WARN STATES WHAT HAPPENED. IT NO LONGER PREDICTS HOW IT WILL BE COUNTED (0.9.32).
    #
    # It used to end "— counted unavailable" / "— counted inconclusive", decided HERE, several
    # steps before anything is counted. That claim can be plainly false: if leg 1 is holding
    # matches, the merge in `$finish` makes `$res` defined, the row is stored as a MATCH at
    # STREAM_UNVALIDATED_TTL, and no no-match tally is touched at all. So the line asserted a
    # verdict for a run that reached the opposite one.
    #
    # It is the same root cause as the five-carrier problem this release exists to end — a
    # consumer re-deriving a classification that is made elsewhere — so the cure is the same:
    # say only what is known at this point, and let the ONE place that has the outcomes do the
    # counting. `$resolve`'s `_dbgv` line reads @outcome directly and therefore cannot
    # disagree with the TTL beside it. Per-album counting belongs at debug volume anyway;
    # this line is at WARN because a service going quiet must announce itself (0.9.30).
    $log->warn("resolve $svc: $why (q='" . ($query // '') . "')")
    # SUPPRESSED ON THE FACT, NOT ON THE CLASSIFICATION. Keying the once-per-process guard on
    # `$standing` would put a line in the log for every album for the whole grace window —
    # ~150 per warm, which is exactly the noise 0.9.30's `$once` removed.
        unless $noHandler && $CANT_ANSWER_WARNED{$svc}++;

    # AND SAY SO ONCE MORE WHEN IT STOPS BEING A STARTUP RACE. The line above fires on the
    # FIRST sighting, which for the common case is during boot, when the honest reading is
    # still "not authenticated yet". Without this, a service that never comes back reports
    # itself only as a transient startup blip and the user is never told the difference —
    # which is the whole distinction 0.9.32 introduced. One extra line per outage episode.
    $log->warn("resolve $svc: still unavailable after " . SVC_UNAVAILABLE_GRACE
             . "s — treating it as signed out, not a startup race")
        if $standing && !$STANDING_WARNED{$svc}++;

    # $refused: THIS search was refused by a rate-limiting service and never sent (0.9.39) —
    # passed up so the warm's pump can hold on it even when the answer arrives synchronously.
    # See PACED_WARM_GAP.
    return $collect->(undef, $standing, $refused ? 1 : 0);
}

sub _dbgSearch {
    my ($svc, $leg, $query, $t0, $raw, $kept, $firstAt) = @_;
    # Return before the sprintf, not after: this is the one site called often enough
    # (hundreds per warm) that building a string to throw away is worth skipping.
    return unless _verbose();
    _dbgv(sprintf('search %s/%s %.0fms raw=%s kept=%d at=%s q=%s',
        $svc, $leg, (Time::HiRes::time() - $t0) * 1000,
        (defined $raw ? $raw : '-'), $kept,
        (defined $firstAt ? $firstAt : '-'), ($query // '')));
}

# CAP THE QOBUZ SEARCH (0.9.16). Qobuz was the only adapter calling out uncapped —
# Tidal and Deezer have always passed `limit => 50`. Verified against the plugin's own
# source (LMS-Community/plugin-Qobuz, API.pm) rather than inferred:
#
#     sub search { my ($self, $cb, $search, $type, $args) = @_;
#         $args->{limit} ||= QOBUZ_DEFAULT_LIMIT;    # = 200
#
# MEASURED WASTE, cold, both caches empty: 308 searches pulled 33,585 album objects and
# used 316 of them — 0.94%. 40% of searches returned the full 200 rows.
#
# 50 IS SIZED FROM DATA, NOT COPIED FROM THE SIBLING PLUGIN. The `at=` instrumentation
# added in 0.9.15 logs where in the raw list the first match was found; across a full
# cold run the deepest was position 40 and the median was 1:
#
#     cap 10 -> keeps 90.3%   cap 25 -> 97.6%   cap 50 -> 100.0%
#
# So 50 costs nothing on the evidence, with a 10-row margin over the worst case seen.
# Anything tighter starts trading matches for bytes, which is the 'Leo / Cicada Burnt'
# failure the second search leg exists to work around.
#
# AND THE SAVING IS NOT ONLY BANDWIDTH. The Qobuz plugin runs `_precacheAlbum` over
# EVERY returned item before our callback sees any of it — that is work on OUR server's
# single event loop, the same loop that was starving article fetches (a `reviews` page
# took 23.4s while resolves ran, against 1.5-2.4s when quiet). Asking for a quarter of
# the rows cuts that pre-processing by the same factor.
use constant QOBUZ_SEARCH_LIMIT => 50;

sub _searchQobuz {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;
    my $t0 = Time::HiRes::time();

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) { return _svcCantAnswer($svc, 'no API handler (signed out?)', $query, $collect, 1) }
    _svcHasHandler($svc);   # it is signed in — close any grace window we were timing

    $api->search(sub {
        my $res = shift;
        # errored, not "no results" — the distinction the whole inconclusive path rests on
        return _svcCantAnswer($svc, 'search errored', $query, $collect) unless defined $res;
        my $rows = ($res && $res->{albums} && $res->{albums}{items}) || [];
        my @out;
        my $rendererFailed = 0;
        my ($idx, $firstAt) = (0, undef);
        for my $album (@$rows) {
            $idx++;
            my $candArtist = ref $album->{artist} eq 'HASH' ? $album->{artist}{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title}, $albumRaw);
            next if defined $album->{streamable} && !$album->{streamable};   # drop bogus non-streamable dupes
            # Guard the foreign renderer — a die here is inside this async callback,
            # outside _findPlayable's eval; skip a bad item, don't stall the service.
            my $item = eval { Plugins::Qobuz::Plugin::_albumItem($client, $album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Qobuz _albumItem failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            # The SERVICE's own album title and release year, for the '&al='/'&y=' handshake
            # (see _attachFavUrl). Taken from the RAW album hash — never from the rendered
            # node, whose `name`/`line1` are that plugin's DISPLAY LABEL with the artist
            # baked in (Qobuz renders it artist-first, Bandcamp artist-last), which is what
            # broke the sibling plugin. `title` is the same field _albumMatches validated
            # above, with any artist affix the service joined on removed, compared against
            # the SERVICE's artist spelling ($candArtist) rather than Pitchfork's.
            $item->{_svctitle} = _stripArtistAffix($album->{title}, $candArtist);
            $item->{_year}     = _svcYear($album);
            $firstAt //= $idx;
            push @out, $item;
        }
        _dbgSearch('Qobuz', 'albums', $query, $t0, scalar(@$rows), scalar(@out), $firstAt);
        return _svcCantAnswer($svc, 'every candidate failed to render', $query, $collect)
            if !@out && $rendererFailed;
        $collect->(\@out);
    }, lc($query), 'albums', { limit => QOBUZ_SEARCH_LIMIT });
}

# Tidal: mirror of _searchQobuz using the Tidal plugin's own API + renderer.
sub _searchTidal {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;
    my $t0 = Time::HiRes::time();

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) { return _svcCantAnswer($svc, 'no API handler (signed out?)', $query, $collect, 1) }
    _svcHasHandler($svc);   # it is signed in — close any grace window we were timing

    $api->search(sub {
        my $albums = shift;   # raw album hashes (type => albums)
        return _svcCantAnswer($svc, 'search errored', $query, $collect) unless defined $albums;
        my @out;
        my $rendererFailed = 0;
        my ($idx, $firstAt) = (0, undef);
        for my $album (@{ $albums || [] }) {
            $idx++;
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title}, $albumRaw);
            my $item = eval { Plugins::TIDAL::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Tidal _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            # The SERVICE's own album title and release year, for the '&al='/'&y=' handshake
            # (see _attachFavUrl). Taken from the RAW album hash — never from the rendered
            # node, whose `name`/`line1` are that plugin's DISPLAY LABEL with the artist
            # baked in (Qobuz renders it artist-first, Bandcamp artist-last), which is what
            # broke the sibling plugin. `title` is the same field _albumMatches validated
            # above, with any artist affix the service joined on removed, compared against
            # the SERVICE's artist spelling ($candArtist) rather than Pitchfork's.
            $item->{_svctitle} = _stripArtistAffix($album->{title}, $candArtist);
            $item->{_year}     = _svcYear($album);
            $firstAt //= $idx;
            push @out, $item;
        }
        _dbgSearch('Tidal', 'albums', $query, $t0, (ref $albums eq 'ARRAY' ? scalar(@{$albums}) : undef), scalar(@out), $firstAt);
        return _svcCantAnswer($svc, 'every candidate failed to render', $query, $collect)
            if !@out && $rendererFailed;
        $collect->(\@out);
    }, { type => 'albums', search => $query, limit => 50 });
}

# Deezer: mirror of _searchTidal (ported from the ListenBrainz plugin). getAPIHandler
# returns a Plugins::Deezer::API::Async; ->search calls back with a bare arrayref of
# raw album hashes; `_renderAlbum` returns a native album node (`url => \&getAlbum`
# coderef, id in passthrough) that round-trips the cache exactly like Tidal's.
sub _searchDeezer {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;
    my $t0 = Time::HiRes::time();

    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    unless ($api) { return _svcCantAnswer($svc, 'no API handler (signed out?)', $query, $collect, 1) }
    _svcHasHandler($svc);   # it is signed in — close any grace window we were timing

    $api->search(sub {
        my $albums = shift;
        return _svcCantAnswer($svc, 'search errored', $query, $collect) unless defined $albums;
        # Tolerate a hash-wrapped list so a shape mismatch degrades to a clean miss
        # rather than dying in this async callback (outside _findPlayable's eval).
        $albums = $albums->{data} || $albums->{albums} || [] if ref $albums eq 'HASH';
        return $collect->([]) unless ref $albums eq 'ARRAY';
        my @out;
        my $rendererFailed = 0;
        my ($idx, $firstAt) = (0, undef);
        for my $album (@$albums) {
            $idx++;
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title}, $albumRaw);
            my $item = eval { Plugins::Deezer::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Deezer _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            # The SERVICE's own album title and release year, for the '&al='/'&y=' handshake
            # (see _attachFavUrl). Taken from the RAW album hash — never from the rendered
            # node, whose `name`/`line1` are that plugin's DISPLAY LABEL with the artist
            # baked in (Qobuz renders it artist-first, Bandcamp artist-last), which is what
            # broke the sibling plugin. `title` is the same field _albumMatches validated
            # above, with any artist affix the service joined on removed, compared against
            # the SERVICE's artist spelling ($candArtist) rather than Pitchfork's.
            $item->{_svctitle} = _stripArtistAffix($album->{title}, $candArtist);
            $item->{_year}     = _svcYear($album);
            $firstAt //= $idx;
            push @out, $item;
        }
        _dbgSearch('Deezer', 'albums', $query, $t0, (ref $albums eq 'ARRAY' ? scalar(@{$albums}) : undef), scalar(@out), $firstAt);
        return _svcCantAnswer($svc, 'every candidate failed to render', $query, $collect)
            if !@out && $rendererFailed;
        $collect->(\@out);
    }, { search => $query, type => 'album', strict => 'off', limit => 50 });
}

# When _searchSpotify last saw a search REFUSED (0.9.37) — the warm backs off for
# SPOTIFY_BACKOFF_WINDOW after it (see _spotifyBackingOff, PACED_WARM_GAP). Our own clock,
# deliberately not Spotty's flag: that clears only on a SUCCESSFUL Spotify response, and with
# Spotify ranked low it can be many albums before one is sent — the warm would crawl the whole
# time. Declared HERE, above its first use: `our` is lexically scoped. `our` so a suite can place
# the stamp.
use constant SPOTIFY_BACKOFF_WINDOW => 30;   # seconds; Spotify's observed Retry-After was 3-7s
our $SPOTIFY_REFUSED_AT = 0;

# Spotify: via the Spotty plugin (ported from the ListenBrainz sibling's _searchSpotify, PR
# #17 by honzup; Spotty's API verified in that repo's docs/spotify-spotty-adapter-pr17.md).
# ->search(cb, {query, type, limit}) — key `query`, SINGULAR type — runs through Spotty's
# Pipeline and calls back with a bare arrayref of ALREADY-NORMALISED album hashes
# ({name, artist, artists, id, uri, release_date, …}); the album title is `name`, not
# `title`.
#
# TWO DELIBERATE DIFFERENCES FROM THE SIBLING, both because this plugin already owns the
# problem the sibling's code solves:
#   - No `hasCredentials` -> [] branch for a missing handler. Signed-out Spotty is
#     PERMANENT, but that is exactly what _svcCantAnswer's grace window measures here: once
#     standing it is OUTCOME_UNAVAILABLE, which cannot shorten another service's no-match
#     (_streamTtl), and a no-handler call sends no request. One carrier, no Spotify branch.
#   - No zero-raw-results-is-an-error rule. Spotty's Pipeline swallows API errors into an
#     empty arrayref, so an outage reads as a real miss. Accepted for the NO-MATCH case:
#     without a bounded retry schedule the rule would re-search a genuinely absent album
#     hourly for ever. The two places that trade was NOT acceptable are handled narrowly
#     (0.9.36, measured on the live server with Spotify at priority 1):
#       * empty WHILE SPOTTY IS RATE-LIMITING is an error, not a verdict — below;
#       * an empty answer ABOVE the row's winner caps that row at a day (`empty_unverified`,
#         see _streamTtl), so a lower service's match is not pinned for thirty days on it.
sub _searchSpotify {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;
    my $t0 = Time::HiRes::time();

    my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
    unless ($api) { return _svcCantAnswer($svc, 'no API handler (signed out?)', $query, $collect, 1) }
    _svcHasHandler($svc);   # it is signed in — close any grace window we were timing

    $api->search(sub {
        my $albums = shift;
        # Defensive only: this Pipeline always sends an arrayref, even on error.
        return _svcCantAnswer($svc, 'search errored', $query, $collect)
            unless defined $albums && ref $albums eq 'ARRAY';
        # EMPTY WHILE SPOTTY IS RATE-LIMITING IS NOT A VERDICT (0.9.36). After a 429 Spotty
        # refuses every call for Retry-After without sending a request or logging a line, and
        # each refusal reaches us as the same `[]` as a genuine zero-hit. `hasError429` is the one
        # signal its API exposes: set by the 429, cleared by the next SUCCESSFUL response — and a
        # real empty answer is a successful response, which clears it before this callback runs.
        # Only an EMPTY list is doubted; a list with albums in it is an answer whatever the flag.
        if (!@$albums && _spottyRateLimited()) {
            $SPOTIFY_REFUSED_AT = time();   # and the warm backs off — see PACED_WARM_GAP
            return _svcCantAnswer($svc, 'empty answer while Spotify is rate-limiting (429)', $query, $collect, 0, 1);
        }
        my @out;
        my $rendererFailed = 0;
        my ($idx, $firstAt) = (0, undef);
        for my $album (@$albums) {
            $idx++;
            next unless ref $album eq 'HASH';
            my $candArtist = (defined $album->{artist} && !ref $album->{artist})
                ? $album->{artist}
                : (ref $album->{artists} eq 'ARRAY' && ref $album->{artists}[0] eq 'HASH')
                    ? $album->{artists}[0]{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{name}, $albumRaw);
            my $item = eval { Plugins::Spotty::OPML::_albumItem($client, $album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Spotify _albumItem failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            # Native id, for parity with the other adapters — the bare id field, else parsed
            # from the spotify:album:<id> uri. NOT turned into a decorated favurl: the adapter
            # is `native_favurl`, so Spotty's own favorites_url is kept (see the settle loop).
            my $sid = $album->{id};
            ($sid) = ($album->{uri} // '') =~ /album:([A-Za-z0-9]+)$/ unless defined $sid && length $sid;
            $item->{_albumid}  = $sid;
            # The SERVICE's own title (`name` on Spotify) and release year — see _searchQobuz.
            $item->{_svctitle} = _stripArtistAffix($album->{name}, $candArtist);
            $item->{_year}     = _svcYear($album);
            $firstAt //= $idx;
            push @out, $item;
        }
        _dbgSearch('Spotify', 'albums', $query, $t0, scalar(@$albums), scalar(@out), $firstAt);
        return _svcCantAnswer($svc, 'every candidate failed to render', $query, $collect)
            if !@out && $rendererFailed;
        $collect->(\@out);
    }, { query => $query, type => 'album', limit => 50 });
}

# Spotty probe, guarded on `can` and eval so an older or reshaped Spotty reads as "no signal"
# rather than taking a resolve down. `hasError429`: the last Spotify response was a 429 and
# nothing has succeeded since.
sub _spottyRateLimited {
    my $f = Plugins::Spotty::API->can('hasError429') or return 0;
    return eval { $f->('Plugins::Spotty::API') } ? 1 : 0;
}

# The Spotify adapter's `pace_warm`: true for SPOTIFY_BACKOFF_WINDOW after _searchSpotify last
# saw a search REFUSED (the stamp and the window are declared above _searchSpotify, which
# writes it).
sub _spotifyBackingOff {
    return (time() - ($SPOTIFY_REFUSED_AT || 0)) < SPOTIFY_BACKOFF_WINDOW ? 1 : 0;
}

# ===========================================================================
# Matching (verbatim from the ListenBrainz plugin — keep in sync if that changes)
# ===========================================================================

# A candidate album matches when its title equals or begins with our album title
# (word boundary) AND the artist matches. With no artist to disambiguate, only an
# exact title match counts.
sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle, $albumRaw) = @_;

    # All-punctuation / single-char titles ("( )", "X") normalise to (near)
    # nothing, so the standard path can't see them. Compare a punctuation-
    # PRESERVING form instead - lowercase, whitespace stripped: "( )" == "()"
    # but != "( ) (live)". Exact equality ONLY (a prefix rule would let "x"
    # swallow "xx") and the artist gate is mandatory. (Ported from the
    # Discography plugin 0.10.3, 2026-07-10.)
    if (length $albumNorm < 2) {
        my $ap = _punctNorm($albumRaw);
        return 0 unless length $ap;
        return 0 unless _punctNorm($candTitle) eq $ap;
        return 0 if $artistNorm eq '';
        return _artistMatch($artistNorm, _norm($candArtist));
    }

    my $t = _norm($candTitle);
    return 0 if $t eq '';

    # SELF-TITLED releases ("The Beatles", "Weezer") match on the EXACT title only:
    # every fallback below reads "<album> <extra>" as an edition of the same album,
    # which is catastrophic when the album title IS the artist name — it swallows
    # "The Beatles 1962-1966" (Red), "…1967-1970" (Blue), "…Anthology 1". _norm
    # already strips brackets, so "The Beatles (White Album)"/"(Remastered)" still
    # match. (Ported from the Discography plugin 0.11.1 — fleet matcher sync.)
    if (length($artistNorm) && $albumNorm eq $artistNorm) {
        return 0 unless $t eq $albumNorm;
        return _artistMatch($artistNorm, _norm($candArtist));
    }

    my $ok = ($t eq $albumNorm || index($t, "$albumNorm ") == 0);

    # Fallback for the trailing FORMAT descriptor Pitchfork appends ("… EP", "… LP")
    # that streaming services usually omit from the album title — e.g. Pitchfork
    # "Songs From a Valley Girl EP" vs Qobuz "Songs From a Valley Girl". Compare again
    # with a trailing standalone "ep"/"lp" token stripped from BOTH sides, gated so a
    # 1-2 char base can't false-match.
    if (!$ok) {
        my $ab = _stripFmt($albumNorm);
        my $tb = _stripFmt($t);
        $ok = 1 if length($ab) >= 3 && length($tb) >= 3
                && ($tb eq $ab || index($tb, "$ab ") == 0);
    }

    # Fallback for DECORATIVE non-ASCII glyphs that differ between sources — e.g.
    # Pitchfork "3x6x𐕣 =666…" (Teller Bank$) vs Qobuz "3x6x* =666…", where the
    # syllabics glyph is a Unicode "letter" _norm keeps but the service spells it
    # "*". Compare again with all non-ASCII stripped, but ONLY when both titles
    # still carry ASCII content: a genuine CJK/Cyrillic title strips to empty and
    # keeps the strict comparison above, so it can't false-match a different album.
    if (!$ok) {
        my $aa = _asciiNorm($albumNorm);
        my $ta = _asciiNorm($t);
        $ok = 1 if length($aa) >= 2 && length($ta) >= 2
                && ($ta eq $aa || index($ta, "$aa ") == 0);
    }

    # COMPOUND-WORD / WORD-BOUNDARY variant: the two titles are identical once
    # every space is removed -- e.g. MB "England's Newest Hit Makers" (the
    # Rolling Stones' 1964 debut) vs the streaming spelling "England's Newest
    # Hitmakers" ('hit makers' <-> 'hitmakers'). The services and MusicBrainz
    # routinely disagree on whether a compound is one word or two, and no fold
    # above sees a space as optional. EXACT space-collapsed equality ONLY -- no
    # prefix rule here, because collapsing the spaces also destroys the word
    # boundary that makes the prefix tiers safe (a prefix match on
    # "hitmakers..." could then swallow an unrelated title). Length-gated so a
    # short collapsed key can't collide by accident. Field: 2026-07-24.
    # (Fleet matcher sync from the Discography plugin 0.50.6.)
    if (!$ok) {
        (my $as = $albumNorm) =~ s/\s+//g;
        (my $ts = $t)         =~ s/\s+//g;
        $ok = 1 if length($as) >= 6 && $ts eq $as;
    }

    # Titles carrying the ARTIST NAME as a prefix on ONE side only - e.g. the
    # release "Belle and Sebastian Write About Love" vs the source title
    # "Write About Love". Strip a leading "<artist> " from both sides and
    # re-compare, gated on a >=3 char remainder; the artist check below still
    # applies. (Ported from the Discography plugin 0.9.1.)
    if (!$ok && length $artistNorm) {
        my $ab = _stripArtistPrefix($albumNorm, $artistNorm);
        my $tb = _stripArtistPrefix($t, $artistNorm);
        if (($ab ne $albumNorm || $tb ne $t) && length($ab) >= 3 && length($tb) >= 3) {
            $ok = 1 if $tb eq $ab || index($tb, "$ab ") == 0;
        }
    }
    return 0 unless $ok;

    # With no artist to disambiguate, require an exact FULL-norm title (the ascii
    # fallback is only trusted alongside an artist match).
    return ($t eq $albumNorm) ? 1 : 0 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
}

# Strip a trailing standalone format descriptor ("ep"/"lp") that Pitchfork appends
# to a title but streaming services usually leave off. Only the LAST token.
sub _stripFmt {
    my $s = shift // '';
    $s =~ s/\s+(?:ep|lp)$//;
    return $s;
}

# Lowercased, whitespace-stripped, punctuation KEPT - only for titles _norm
# erases (see the short-title branch in _albumMatches).
sub _punctNorm {
    my $s = shift // '';
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);
    }
    $s = lc($s);
    $s =~ s/\s+//g;
    return $s;
}

sub _stripArtistPrefix {
    my ($t, $a) = @_;
    return substr($t, length($a) + 1) if index($t, "$a ") == 0;
    return $t;
}

# _norm with all non-ASCII stripped — used only as an album-title fallback (see
# _albumMatches) to bridge decorative-glyph spelling differences between sources.
sub _asciiNorm {
    my $s = shift // '';
    $s =~ s/[^\x00-\x7f]+/ /g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

# Token-subset artist match: every word of the shorter credit must appear in the
# longer (tolerates word order, & vs , and partial credits).
sub _artistMatch {
    my ($a, $b) = @_;
    return 0 if $a eq '' || $b eq '';

    my %at = map { ($_ => 1) } split ' ', $a;
    my %bt = map { ($_ => 1) } split ' ', $b;
    my ($small, $big) = (scalar keys %at <= scalar keys %bt) ? (\%at, \%bt) : (\%bt, \%at);

    for my $tok (keys %$small) {
        return 0 unless $big->{$tok};
    }
    return 1;
}

# Diacritic folding for _norm (see the ListenBrainz plugin for the full rationale).
my $HAVE_NFD = eval { require Unicode::Normalize; 1 } ? 1 : 0;
my %FOLD = (
    # ligatures and digraphs
    "\x{e6}"  => 'ae', "\x{153}" => 'oe', "\x{df}"  => 'ss', "\x{fe}" => 'th',
    "\x{133}" => 'ij', "\x{1c6}" => 'dz', "\x{1f3}" => 'dz', "\x{1c9}" => 'lj',
    "\x{1cc}" => 'nj', "\x{223}" => 'ou', "\x{195}" => 'hv', "\x{1a3}" => 'oi',
    # stroked / barred letters
    "\x{f8}"  => 'o', "\x{111}" => 'd', "\x{142}" => 'l', "\x{127}" => 'h',
    "\x{167}" => 't', "\x{180}" => 'b', "\x{19a}" => 'l', "\x{1e5}" => 'g',
    "\x{23c}" => 'c', "\x{23f}" => 's', "\x{240}" => 'z', "\x{247}" => 'e',
    "\x{249}" => 'j', "\x{24b}" => 'q', "\x{24d}" => 'r', "\x{24f}" => 'y',
    "\x{1b6}" => 'z', "\x{2c65}" => 'a', "\x{2c66}" => 't', "\x{289}" => 'u',
    "\x{268}" => 'i', "\x{275}" => 'o',
    # hooked letters
    "\x{253}" => 'b', "\x{188}" => 'c', "\x{256}" => 'd', "\x{257}" => 'd',
    "\x{192}" => 'f', "\x{260}" => 'g', "\x{199}" => 'k', "\x{1ad}" => 't',
    "\x{1a5}" => 'p', "\x{272}" => 'n', "\x{19e}" => 'n', "\x{288}" => 't',
    "\x{28b}" => 'v', "\x{1b4}" => 'y', "\x{271}" => 'm',
    # dotless, long-s, turned and archaic forms
    "\x{131}" => 'i', "\x{17f}" => 's', "\x{140}" => 'l', "\x{138}" => 'k',
    "\x{149}" => 'n', "\x{14b}" => 'n', "\x{1dd}" => 'e', "\x{259}" => 'e',
    "\x{254}" => 'o', "\x{25b}" => 'e', "\x{25c}" => 'e', "\x{292}" => 'z',
    "\x{250}" => 'a', "\x{26f}" => 'm', "\x{28a}" => 'u', "\x{26a}" => 'i',
    "\x{283}" => 'sh', "\x{263}" => 'g', "\x{28c}" => 'v', "\x{280}" => 'r',
    "\x{21d}" => 'g', "\x{1bf}" => 'w', "\x{1a8}" => 's', "\x{225}" => 'z',
    "\x{221}" => 'd', "\x{234}" => 'l', "\x{235}" => 'n', "\x{236}" => 't',
    "\x{237}" => 'j', "\x{f0}"  => 'd',
);

# Normalise a title/artist for fuzzy matching: decode octets, lowercase, fold
# Latin diacritics, drop bracketed qualifiers + punctuation, collapse whitespace.
# Keeps alphanumerics from any script so non-Latin names survive.
sub _norm {
    my $s = shift // '';
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);   # only adopt if valid UTF-8
    }
    $s = lc($s);
    if ($HAVE_NFD && utf8::is_utf8($s)) {
        $s = Unicode::Normalize::NFC(
             Unicode::Normalize::NFD($s) =~ s/[\x{0300}-\x{036F}]+//gr );
        $s =~ s/([^\x00-\x7f])/exists $FOLD{$1} ? $FOLD{$1} : $1/ge;
    }
    # Fold common STYLISED letter substitutions so a Pitchfork spelling matches the
    # service's (and vice-versa): "WOR$T" == "Worst", "$uicideboy$" == "Suicideboys",
    # "P!nk" == "Pink". These map to a letter BEFORE the punctuation pass below turns
    # them into spaces. (The currency signs also cover €/£/¥ stylisations.)
    # LEETSPEAK SUBSTITUTIONS - a punctuation mark standing in for a LETTER.
    #
    # Applied ONLY when a word character FOLLOWS the mark. That is precisely
    # what separates a letter from decoration: "P!nk" -> pink and "Ke$ha" ->
    # kesha (the mark sits INSIDE the word), while a trailing or free-standing
    # mark is punctuation and falls through to the [^\p{Alnum}] rule below.
    #
    # WHY, and it is not cosmetic (field via DSC, 2026-07-21): the old
    # unconditional fold made a name spelled WITH the mark disagree with the
    # same name spelled WITHOUT it - "Layo & Bushwacka!" -> 'layo bushwackai'
    # against 'layo bushwacka'. `_albumMatches`' artist gate is MANDATORY, so
    # EVERY streaming candidate was rejected and the page read "No releases
    # found" for an artist with a correctly resolved MBID. The same fold also
    # made "Panic At The Disco" unsearchable without typing the "!".
    #
    # A name made ENTIRELY of these marks ("!!!", a real band) keeps the old
    # unconditional fold: stripping would leave '', and `_artistMatch` rejects
    # an empty side outright - i.e. this very bug in a new costume.
    # "$" and "@" are UNCONDITIONAL: in a stylised name they are effectively
    # always a letter, including at the END - "$uicideboy$" is Suicideboy(s),
    # so the trailing "$" is an s, not decoration. Scoping the boundary rule
    # below to them broke exactly that (caught by the cross-repo behaviour
    # harness, which PFR documents as a supported case).
    $s =~ s/\$/s/g;
    $s =~ s/\@/a/g;
    # "!" IS different, and it is the one that motivated this: it has a real
    # decorative use that the others do not - "Wham!", "Panic! At The Disco",
    # "Godspeed You! Black Emperor", "Layo & Bushwacka!" - where the mark is
    # punctuation and the name is spelled both ways in the wild. So "!" folds
    # to a letter ONLY when a word character FOLLOWS it (inside a word, as in
    # "P!nk"); otherwise it falls through to the [^\p{Alnum}] pass below.
    #
    # A name of nothing BUT marks ("!!!", a real band) keeps the unconditional
    # fold: stripping would leave '', and `_artistMatch` rejects an empty side
    # outright - this very bug in a new costume.
    if ($s =~ /[\p{Alnum}]/) { $s =~ s/(?<=\w)!(?=\w)/i/g }
    else                      { $s =~ s/!/i/g }
    $s =~ s/\x{20ac}/e/g;   # €
    $s =~ s/\x{a3}/l/g;     # £
    $s =~ s/\x{a5}/y/g;     # ¥

    # "&" and "+" are SPOKEN "and", and this is the same rule as every
    # substitution above it - a symbol folded to the word it stands for, like
    # $ -> s and ! -> i. Without it the two spellings key differently ("simon
    # garfunkel" vs "simon and garfunkel", because & alone becomes a space
    # below), so the SAME act arriving from two services became two search rows
    # and only merged if MusicBrainz happened to record the variant as an
    # alias. Field 2026-07-21: Deezer says "Layo and bushwacka!" where Tidal
    # says "Layo & Bushwacka" - one act, two rows.
    #
    # "+" is included because services use it the same way; MB's own alias list
    # for that duo literally carries "Layo + Bushwacka!".
    $s =~ s/[&+]/ and /g;
    $s =~ s/[\(\[].*?[\)\]]//g;

    # APOSTROPHES ELIDE - they do NOT become a space. Every other mark handled
    # by the [^\p{Alnum}] rule below SEPARATES words; an apostrophe sits INSIDE
    # one, marking a contraction or a possessive, and both spellings of the same
    # name are common in the wild.
    #
    # WHY (field via DSC, 2026-07-21): spacing it keyed "Jane's Addiction" as
    # 'jane s addiction' against 'janes addiction'. `_artistMatch` is an
    # exact-token SUBSET test, so the token 'janes' matched nothing on the other
    # side and the act failed to match against EVERY source. Same for
    # O'Connor/OConnor, D'Angelo/DAngelo, The B-52's/B-52s. This is the "!"
    # fold's mandatory-artist-gate failure in another costume.
    #
    # LMS's own index agrees with eliding: it TOKENISES on the apostrophe
    # (verified live - `artists search:Connor` returns "Sinead O'Connor"), so
    # folding the mark away is the one choice that puts both spellings on a
    # single key.
    #
    # GUARD - "'n'" contracting "and" is the exception, because there the mark
    # joins two WORDS rather than sitting inside one. All three spellings agree
    # TODAY ("Rock'n'Roll", "Rock 'n' Roll" and "Rock N Roll" all key
    # 'rock n roll'); eliding blindly would key the first as 'rocknroll' and
    # break a set that currently works. Space that one form first and the
    # three-way agreement survives untouched.
    # (Fleet matcher sync from the Discography plugin 0.44.26.)
    my $apos = qr/['\x{2019}\x{2018}\x{02bc}\x{00b4}\x{2032}`]/;
    $s =~ s/(?<=\w)${apos}n${apos}(?=\w)/ n /g;
    $s =~ s/$apos//g;

    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

1;

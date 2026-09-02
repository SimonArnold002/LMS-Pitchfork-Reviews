package Plugins::PitchforkReviews::API;

# Fetches Pitchfork's album-reviews and Best New Music LISTING PAGES and parses
# the embedded Verso state (window.__PRELOADED_STATE__) into clean, structured
# review items. This is far better than the RSS feed: the state gives, per review,
#   artist  = subHed.name          album  = dangerousHed (HTML-stripped)
#   capsule = dangerousDek         date   = pubDate (ISO)
#   cover   = image.sources        link   = url        score = ratingValue.score
#   genre   = rubric[].name (deduped, joined " / ")
# directly — no filename/slug derivation, and from_json yields proper characters
# (so no mojibake). Only metadata + the short capsule is stored; the full review
# is linked out, never reproduced.
#
# Three sources, same parser:
#   getListing() -> the album-reviews page (all recent reviews, capped)
#   getBnm()     -> the Best New Music page (its items ARE the BNM picks)
#   getHsa()     -> the High Scoring Albums page (its items ARE the picks)
#
# A FOURTH source with its OWN parser: the annual year-end list
# ("The 50 Best Albums of <year>").
#   getYearList($y) -> that year's ranked list      getLatestYear() -> newest published
# Same embedded state, but a DIFFERENT shape: a year-end list is an ARTICLE whose
# entries live in the body prose, NOT `contentType => 'review'` nodes — so
# _walkReviews cannot see them and _parseYear walks transformed.article.body
# instead. It emits the SAME normalised item hash (plus `rank`/`year`), which is
# the whole point: Browse.pm's resolver, row builder and ListenLater handshake all
# work on it unchanged.

use strict;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Plugins::PitchforkReviews::DB;
use Time::Local;                  # core — the year-end publishing-window cap
use JSON::XS::VersionOneAndTwo;   # from_json — bundled in LMS

my $log   = Slim::Utils::Log::logger('plugin.pitchforkreviews');

# Listing pages update through the day. The stored rows double as the last good copy,
# so a transient fetch/parse failure keeps the menu populated with no second copy kept.
use constant FEED_TTL          => 3 * 3600;        # 3h

# BUMP THIS WHENEVER _parseState OR _parseYear CHANGES WHAT IT EXTRACTS.
#
# The lists now live in a real database with no expiry on the immutable ones, which
# means a permanent store would keep a PARSING MISTAKE permanently too. Every stored
# list records the version that produced it; a mismatch reads as "not held" and the list
# is re-fetched with the corrected parser (see DB::getList).
#
# This replaces the hand-maintained `pfr:year:3` / `pfr:listing:5` key suffixes, which
# had to be edited across two modules and three test files in lockstep and were got
# wrong in both directions inside a single day.
#
# NB a MATCHER fix does NOT belong here. Which streaming album a row resolves to is not
# stored in the DB at all — it lives in pfr:stream and is versioned there. Bumping this
# for a matcher change would re-download every article for nothing.
# 1 -> 2 (0.9.11). NOT a parsing change — a deliberate full invalidation, so the build
# that rewrites the cold start is actually tested against one. Every stored list reads as
# absent and re-fetches, which together with the pfr:stream key bump makes the install a
# genuine fresh install. This is the call 0.9.0 and 0.9.1 both got wrong in opposite
# directions; the rule that settles it is that a cold-start fix which cannot be observed
# from cold has not been tested at all.
# 2 -> 3 (0.9.18). Also not a parsing change, and bumped for a reason 0.9.17 explicitly
# did NOT have: what changed is the FETCH PHASE — the four article fetches now go out
# together instead of one per resolve stage — and every stored list reads as a DB hit
# that never fetches at all. 0.9.17 left this alone because it touched only the resolver.
# The test is "is the thing that changed exercised", not "bump on every release".
use constant PARSE_VERSION     => 3;
use constant HTTP_TIMEOUT      => 20;
use constant REVIEWS_MAX       => 30;              # cap the reviews list (~ RSS window / last ~2 weeks)

use constant UA => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                 . 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

use constant SITE        => 'https://pitchfork.com';
use constant REVIEWS_URL => 'https://pitchfork.com/reviews/albums/';
use constant BNM_URL     => 'https://pitchfork.com/reviews/best/albums/';
use constant HSA_URL     => 'https://pitchfork.com/reviews/best/high-scoring-albums/';

# --- year-end lists --------------------------------------------------------
# A PUBLISHED year-end list never changes again, so it is stored PERMANENTLY (DB.pm)
# and has no TTL at all. YEAR_TTL applies to one list only: the current year, which can
# still be corrected in the days after it lands.
use constant LIST_BASE       => 'https://pitchfork.com/features/lists-and-guides/';
use constant YEAR_MIN        => 2016;              # verified parseable back to here; older lists use ad-hoc slugs
use constant YEAR_TTL        => 30 * 86400;

use constant CAPSULE_MIN     => 80;                # a body <p> shorter than this isn't an entry blurb
# How long "the newest published year is N" is trusted. When N is the newest year
# that COULD exist, nothing newer can appear, so cache it hard. When we're still
# waiting on the current year's list, re-probe twice a day so a newly published
# list is picked up within hours — with no plugin update.
use constant LATEST_TTL      => 30 * 86400;
use constant LATEST_WAIT_TTL => 12 * 3600;
use constant PUBLISH_MONTH   => 10;                # 0-based: from November, this year's list may exist
# How long a FAILED answer is held. Without these every home-shelf render, tile
# open and daily warm re-runs the whole sweep — getLatestYear probes _topYear
# down to YEAR_MIN, and each probe is a getYearList fetch of a ~1.7MB article, so
# a slug change or an outage costs ~10-21 large HTTP requests EVERY time. Kept
# deliberately short: long enough to stop the storm, far shorter than the 12h
# December polling interval, so self-promotion is unaffected. `force => 1` (the
# Refresh row) skips these, so a manual retry is always immediate.
use constant LATEST_MISS_TTL => 3600;              # 1h — "no list found at all"
use constant YEAR_MISS_TTL   => 3600;              # 1h — "this year has no list"
# The SAME rule on the feed path, which never had one. A feed's freshness is measured
# from `stored_at`, and that moves only when putList runs — i.e. only on a successful
# parse of >= 1 item. So the moment a feed starts failing, its age is past FEED_TTL for
# ever: every view open and every warm tick re-issues the full ~1-2MB listing download,
# indefinitely, with nothing in the log after the first warning. Coalescing bounds the
# CONCURRENT count, not the rate. 1h against FEED_TTL's 3h means an upstream fault costs
# at most one fetch an hour instead of one per open, and `force => 1` skips it, so
# Refresh is always an immediate live retry.
use constant FEED_MISS_TTL   => 3600;              # 1h — "this feed just failed"
# ...but only where there are stored rows to answer from. With nothing stored the same
# marker means an hour of `[]` on a fresh install after ONE transient failure, so it is
# held just long enough to stop a re-download loop. See _markFeedMiss.
use constant FEED_MISS_EMPTY_TTL => 60;            # 1m — "...and there is nothing to serve"

# ---------------------------------------------------------------------------
# Two fetch-side speed-ups shared by every source (0.8.8). Both are about the
# FIRST open of a view, which is the only one that was ever slow.
#
# STALE-WHILE-REVALIDATE. A listing page is 0.9-2.0MB and takes 0.1-4.0s to
# fetch (measured; Best New Music was the 4.0s one), plus the parse. With a 3h
# working TTL, that whole cost used to land on whoever opened the view first
# after it expired. Now an expired list is answered IMMEDIATELY from the rows already
# stored (which are by definition the last good copy) and the refresh
# runs behind the caller, so the next open — or the 3h warm, whichever comes
# first — has the new one. `force => 1` (the Refresh row) never serves stale, so
# a deliberate refresh is always live, and `nostale => 1` (the warm) waits for
# the real fetch, or the warm would resolve the copy it was supposed to replace.
#
# COALESCING. Concurrent callers for the SAME page share one HTTP request: the
# first does the work, the rest queue on it. Material opens a browse list while
# its home shelf is still building, and a cold start fires both at once — that
# used to be two full downloads of the same page. `force` bypasses the queue
# (a forced refresh must actually refetch, and must not be answered by an
# already-running normal fetch).
#
# `resweep` IS SOLO HERE TOO, AND THAT IS THE HALF 0.9.26 NEARLY DROPPED. It was
# introduced (see getLatestYear) so the Refresh row's probes stop force-fetching a
# year they already hold — but `force` was carrying a SECOND meaning that went with
# it, and this sub is where that meaning lives. A probe carrying only `resweep`
# would fail both tests below, so it could be adopted by an in-flight ordinary
# fetch — and if that slot is one of the strands this file has found and closed four
# times (0.8.9, 0.9.0, 0.9.23, 0.9.25), nothing would ever answer the probe: the tap
# never completes and Material sits on its three-dot placeholder. The manual retry
# button is the one surface that must keep working when the automatic paths have
# wedged, which is why it forced in the first place.
#
# So `resweep` behaves EXACTLY as `force` does in this sub — stale, queue and $done
# alike — which makes it a strict weaker-force: it differs from `force` only in
# honouring the permanent store, which is the whole point of it. The cost is the
# trade `force` has always made: a probe that neither joins nor claims issues its
# OWN request when the year is genuinely uncached and something else is already
# fetching it. Bounded to a cold candidate — a stored year answers from the DB long
# before it reaches here — so it is a duplicate on a cold probe, never a per-tap cost.
#
# ALL THREE SITES OR NONE, and $done is the one that bites hardest. Exempting the
# two tests while leaving $done on the fan-out path is worse than not fixing this at
# all, in two ways at once: the probe claims no slot, so `delete $PENDING{$key}`
# finds NOTHING and the loop calls nobody — the probe is never answered, on every
# tap rather than only against a strand — and where another caller DOES own that key
# it deletes their slot and fires THEIR waiters with the probe's items, which is
# 0.9.23's orphaned-owner defect manufactured by the fix for the strand. Pinned as
# "exactly one callback" (t_perf section 22), which catches 0 and 2 alike.
# ---------------------------------------------------------------------------
my %PENDING;   # cache key -> [ callbacks waiting on the in-flight fetch ]

# Returns (answered, done) for a fetch about to start: `answered` is true when
# the caller has already had the stale copy, `done` is what the fetch calls with
# its result. Returns nothing at all when an in-flight fetch has adopted $cb —
# the caller must then return without fetching.
sub _shareFetch {
    # $stale is the DB's stored copy, passed in by the caller that already read it.
    # It used to be a `:fb` cache key read here — a second copy of every list, written
    # on every fetch purely so an expired entry had something to serve. The stored rows
    # ARE the last good copy now, so the duplicate and its TTL are gone.
    my ($key, $stale, $cb, $opts) = @_;

    # A SOLO fetch neither joins the queue nor claims a slot, and is never answered
    # from the stale copy. `force` and `resweep` are both solo — see the header.
    my $solo = $opts->{force} || $opts->{resweep};

    my $answered = 0;
    if (!$solo && !$opts->{nostale}) {
        if ($stale && @$stale) {
            $log->info("$key expired — serving the last good copy ("
                . scalar(@$stale) . " items) and refreshing in the background");
            $answered = 1;
            $cb->($stale);
        }
    }

    if (!$solo) {
        if ($PENDING{$key}) {
            push @{ $PENDING{$key} }, $cb unless $answered;
            return;                                  # adopted — do not fetch
        }
        $PENDING{$key} = $answered ? [] : [ $cb ];
    }

    # EACH WAITER IS GUARDED SEPARATELY, the same rule _issueFetch already applies to the
    # issuing path. These are coalesced callers: one that throws must not take the rest of
    # the queue down with it, because the %PENDING slot has already been deleted by the
    # time they run — so nothing will ever answer them, and nothing self-heals them either.
    # The symptom is Material's three-dot placeholder on a browse request that is simply
    # never completed.
    my $done = $solo ? $cb : sub {
        my ($items) = @_;
        my $waiting = delete $PENDING{$key} || [];
        for my $w (@$waiting) {
            eval { $w->($items); 1 }
                or $log->error("$key: a coalesced caller threw: $@");
        }
    };

    return ($answered, $done);
}

# Issue a fetch that has ALREADY claimed a %PENDING slot, releasing the slot if the
# issuing itself throws.
#
# 0.8.9 guarded everything from the HTTP RESPONSE to $done, because $done is the only
# thing that takes the slot down. But the slot is claimed inside _shareFetch, and the
# request is issued by the caller AFTERWARDS — so the few lines in between were still
# bare, and a throw there strands the key exactly as before, just earlier. Reproduced
# with an injected transport failure: the two calls that follow are never answered,
# and they stay unanswered after the transport recovers, because nothing ever deletes
# the slot again.
#
# The symptom is the same silent pair 0.8.9 documented: with nothing stored the view
# never fills in; WITH stored rows, the feed serves them for ever and stops fetching.
# (SOLO callers — `force` and `resweep` — hold no slot, so their $done is the raw
# callback and the release is harmless there; answering them on a throw is still the
# right thing, and for a `resweep` probe it is what stops a dead transport hanging the
# Refresh tap rather than merely failing it.)
sub _issueFetch {
    my ($done, $stale, $what, $issue) = @_;
    return if eval { $issue->(); 1 };
    $log->error("$what could not be issued: $@");
    # Answer from the last good copy rather than leaving callers hanging, and — the
    # point of the guard — let $done delete the slot so the NEXT open fetches again.
    $done->( $stale || [] );
    return;
}

# getListing($cb, force => 0|1) / getBnm($cb, force => 0|1)
# Each calls back with an arrayref of normalised items (newest-first):
#   { artist, album, title, capsule, link, date, cover, score, genre, is_bnm }
# The key is now a plain list name — it identifies a row set in the DB and the
# coalescing slot, nothing more. The `:N` parse suffix it used to carry has moved to
# PARSE_VERSION, which is one constant instead of a string repeated across two modules
# and three test files.
sub getListing { my ($cb, %o) = @_; _fetchState(REVIEWS_URL, 'reviews', REVIEWS_MAX, $cb, %o); }
sub getBnm     { my ($cb, %o) = @_; _fetchState(BNM_URL,     'bnm',     0,           $cb, %o); }
sub getHsa     { my ($cb, %o) = @_; _fetchState(HSA_URL,     'hsa',     0,           $cb, %o); }

# ---------------------------------------------------------------------------
# Year-end lists
# ---------------------------------------------------------------------------

# The slug moved twice, so it is derived per era rather than assumed. Verified
# live for every year 2016-2025 (500/500 entries parsed clean):
#   2019+      best-albums-<year>            <- also the guess for a FUTURE year
#   2017-2018  the-50-best-albums-of-<year>
#   2016       <id>-the-50-best-albums-of-2016   (the old numeric-prefixed form)
# A future year is tried under BOTH modern forms before giving up, so a slug
# change back to the older wording doesn't need a plugin update.
my %YEAR_SLUG = (
    2016 => '9980-the-50-best-albums-of-2016',
    2017 => 'the-50-best-albums-of-2017',
    2018 => 'the-50-best-albums-of-2018',
);

sub _min { $_[0] < $_[1] ? $_[0] : $_[1] }

# How long to trust "the newest published list is $probe".
#
# $probe < $top means the current year's list is still awaited, so re-probe twice
# a day and December's publication is picked up within hours. $probe == $top means
# nothing newer CAN exist — hold it, but never past the next publishing window, or
# an answer cached in October would still be trusted deep into November and the
# plugin would not start looking until weeks after the new list could appear.
sub _latestTtl {
    my ($probe, $top, $now) = @_;
    return LATEST_WAIT_TTL if $probe < $top;
    return _min(LATEST_TTL, _secsToWindow($now));
}

sub _yearUrls {
    my ($y) = @_;
    return (LIST_BASE . $YEAR_SLUG{$y} . '/') if $YEAR_SLUG{$y};
    return (LIST_BASE . "best-albums-$y/", LIST_BASE . "the-50-best-albums-of-$y/");
}

# The newest year that COULD have a list published. Pitchfork has published in
# the first half of December every year since 2016 (2nd-13th), so from November
# the current year is worth probing; before that the newest possible is last year.
# $now is injectable so the November/December promotion timeline can be tested
# without waiting for December; it defaults to the real clock everywhere in use.
# The current calendar year. Injectable `$now` like _topYear/_secsToWindow below,
# for the same reason: the closed-year TTL tier is otherwise untestable without
# waiting for a year to end.
sub _nowYear {
    my $now = shift // time;
    return (localtime($now))[5] + 1900;
}

sub _topYear {
    my $now = shift // time;
    my @t = localtime($now);
    my ($year, $mon) = ($t[5] + 1900, $t[4]);
    return $mon >= PUBLISH_MONTH ? $year : $year - 1;
}

# Seconds until the next publishing window opens (1 November). Used to CAP how
# long a "nothing newer can exist" answer is held.
#
# Without this cap the promotion is not deterministic: outside the window the
# answer is cached for LATEST_TTL (30d), so a copy set in mid-October would still
# be trusted well into November — the plugin would not even start looking for the
# new list until weeks after it could appear, purely because of when the cache
# happened to be written. Capping at the window edge means the 12h polling always
# begins on 1 November, comfortably before Pitchfork's earliest publication (2
# December across 2016-2025).
sub _secsToWindow {
    my $now = shift // time;
    my @t   = localtime($now);
    my ($year, $mon) = ($t[5] + 1900, $t[4]);
    # Already inside this year's window -> the next one is next November.
    my $target = $mon >= PUBLISH_MONTH ? $year + 1 : $year;
    my $start  = eval { Time::Local::timelocal(0, 0, 0, 1, PUBLISH_MONTH, $target - 1900) };
    return LATEST_TTL unless $start;          # never let a date failure shorten the TTL to nothing
    my $secs = $start - $now;
    return $secs > 0 ? $secs : LATEST_TTL;
}

# getYearList($year, $cb, force => 0|1, resweep => 0|1) -> arrayref of items, BEST
# FIRST (rank 1 at the top). Empty arrayref when that year has no list
# published/parseable. `force` re-pulls the article past everything; `resweep` is the
# weaker form — past the negative marker AND past the coalescing queue, never past the
# stored list (see the marker read below, _shareFetch's header, and getLatestYear, its
# only caller). "Weaker" is ONLY about the store: everywhere else it is as solo as
# `force`, or the Refresh row's probe could be adopted by a fetch that never answers.
# STORED IN THE DB, NOT THE CACHE (0.9.8). The `pfr:year:N` key suffix this comment
# used to document is gone: invalidation is PARSE_VERSION now, and a published list has
# no expiry at all. The history of those bumps is kept in DB.pm, along with what was
# measured while trying to make the cache hold this and why none of it worked.
sub getYearList {
    my ($year, $cb, %opts) = @_;
    $year = int($year || 0);
    return $cb->([]) unless $year >= YEAR_MIN;

    my $key    = "year:$year";
    my $missKey = "pfr:yearmiss:$year";   # short-lived NEGATIVE marker — a kv row, not a list

    # THE POINT OF THE DATABASE. A published year-end list is immutable, so once it is
    # stored it is never fetched again — no TTL, no expiry, no "held for N days". Only
    # the CURRENT year can still be corrected after publication, so it alone re-checks
    # on YEAR_TTL. Refresh (`force`) is the sole way to re-pull a closed year.
    # Read even under `force`, for the same reason as _fetchState: a forced refresh that
    # fails must leave the stored list in place, not empty the view.
    my $stored = Plugins::PitchforkReviews::DB::getList($key, PARSE_VERSION);
    if ($stored && !$opts{force}) {
        my $stale = $year >= _nowYear()
                 && (Plugins::PitchforkReviews::DB::listAge($key) // 0) >= YEAR_TTL;
        unless ($stale) {
            $log->info("$key DB hit (" . scalar(@$stored) . " items)");
            return $cb->($stored);
        }
    }

    # A completed-but-empty sweep is still cached, not stored: it is a NEGATIVE result
    # with a one-hour life, which is exactly what a cache is for and what a permanent
    # table is not.
    #
    # NOT gated on `!$stored`, which is where this read used to be inert. A closed year
    # returns above and never reaches here, so the only caller that gets this far WITH a
    # stored list is the CURRENT year gone stale — precisely the one whose sweep costs two
    # ~1.7MB fetches, and precisely the one the marker was added to suppress. The list is
    # still served; only the sweep is skipped, which is what YEAR_MISS_TTL's own note
    # above already claims.
    #
    # `resweep` skips the marker WITHOUT skipping the store above it, and it exists for
    # exactly one caller: getLatestYear's probes under `force` (see there). Dropping the
    # marker read is what keeps the Refresh row an immediate live retry; NOT dropping the
    # store read is what stops the probe re-downloading a year it already holds. Every
    # other caller still obeys the marker, so the sweep storm it bounds stays bounded.
    if (!$opts{force} && !$opts{resweep} && Plugins::PitchforkReviews::DB::kvGet($missKey)) {
        return $cb->($stored || []);
    }

    # Stale-while-revalidate + coalescing (see _shareFetch). Worth more here than
    # anywhere else: a PUBLISHED year-end list never changes again, so the copy
    # served while the refresh runs is not merely acceptable, it is the same list —
    # and the fetch it replaces is a ~1.7MB article, tried against up to two
    # candidate slugs. getLatestYear probes through this sub, so its sweep gets the
    # same benefit. An empty return means an in-flight fetch adopted this caller.
    my ($answered, $cbDone) = _shareFetch($key, $stored, $cb, \%opts);
    return unless $cbDone;
    $cb = $cbDone;

    # Inside the guard from here: _yearUrls and the request-issue both run before any
    # response can arrive, so a throw in either would strand the slot claimed just
    # above (see _issueFetch).
    _issueFetch($cb, $stored, $key, sub {
    my @urls = _yearUrls($year);
    # SELF-PASSING sub, not a self-capturing closure. `my $x; $x = sub {... $x ...}`
    # makes the sub hold a reference to itself, which Perl's refcounting can never
    # free — the closure and everything it captured (here the whole parsed list)
    # leak for the life of the process, once per call. Taking itself as an argument
    # keeps the recursion without the cycle.
    my $try = sub {
        my ($self) = @_;
        my $url = shift @urls;
        unless ($url) {
            # Every candidate slug failed. Fall back to the last good parse so a
            # transient outage doesn't empty a list the user was just browsing.
            $log->warn("no year-end list found for $year");
            # Cache the MISS briefly, or every render re-runs the full candidate sweep —
            # two ~1.7MB article fetches (see YEAR_MISS_TTL). This is a SEPARATE key, not
            # the stored list: a failed sweep must never overwrite a good stored year,
            # which is what the old design risked by writing the answer to the working
            # key. The user keeps seeing the list; only the sweep is suppressed.
            _markYearMiss($key, $missKey);
            return $cb->($stored || []);
        }

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $http = shift;
                # Guarded for the same reason as _fetchState above: $cb is what
                # releases this key's coalescing slot, so a die on the way to it
                # strands the key in %PENDING for the life of the process. A parse
                # fault is treated as "this slug didn't work" and falls through to
                # the next candidate, which always ends at a $cb.
                my $items = eval { _parseYear($http->content, $year, $url) };
                if ($@) {
                    $log->error("$key parse failed ($url): $@");
                    return $self->($self);
                }
                unless ($items && @$items) {
                    $log->warn("$key parsed 0 items from " . length($http->content) . " bytes ($url)");
                    return $self->($self);
                }
                # A store that fails must not cost the caller its answer — putList logs
                # and returns 0, and the caller is still handed the live parse below.
                # But "re-fetched next time" is the trap, not the mitigation: a ~1.7MB
                # article re-downloaded on every open for as long as the write keeps
                # failing. So the marker is written rather than cleared, exactly as on
                # the feed path, and only a store that LANDED clears it.
                if (Plugins::PitchforkReviews::DB::putList($key, $items, PARSE_VERSION)) {
                    Plugins::PitchforkReviews::DB::kvDel($missKey);   # a good fetch clears any miss marker
                    $log->info("$key fetched (" . scalar(@$items) . " items from $url)");
                }
                else {
                    $log->warn("$key fetched " . scalar(@$items)
                        . " items but the store failed — marking so it is not re-pulled every open");
                    _markYearMiss($key, $missKey);
                }
                $cb->($items);
            },
            sub {
                my ($http, $error) = @_;
                # A 404 is the EXPECTED answer for a year not published yet (and for
                # the wrong slug of an era), so this is info, not a warning.
                $log->info("year fetch miss ($url): $error");
                $self->($self);
            },
            { timeout => HTTP_TIMEOUT },
        )->get($url, 'User-Agent' => UA);
    };
    $try->($try);
    });
}

# getLatestYear($cb, force => 0|1) -> the newest year with a published list.
#
# THIS is what makes the feature self-updating: it probes down from the newest
# year that could exist and remembers the answer. While the current year's list
# is still awaited the answer is held for only LATEST_WAIT_TTL, so the December
# publication is picked up within hours — the daily warm re-probes on its own, so
# it promotes even if nobody opens the menu. Once the newest possible year IS
# published there is nothing newer to find, so the answer is cached hard.
sub getLatestYear {
    my ($cb, %opts) = @_;

    my $key = 'pfr:year:latest:4';
    if (!$opts{force}) {
        # 0 is the NEGATIVE sentinel — a COMPLETED sweep that found nothing. It has
        # to be distinguishable from a cache miss (a plain truth test would read it
        # as "not cached" and sweep again), hence `defined`.
        my $c = Plugins::PitchforkReviews::DB::kvGet($key);
        return $cb->($c || undef) if defined $c;
    }

    my $top = _topYear();
    my $y   = $top;
    # Self-passing sub, not a self-capturing closure — see getYearList above.
    my $try = sub {
        my ($self) = @_;
        if ($y < YEAR_MIN) {
            $log->warn("no year-end list found at all (probed $top down to " . YEAR_MIN . ")");
            Plugins::PitchforkReviews::DB::kvSet($key, 0, LATEST_MISS_TTL);
            return $cb->(undef);
        }
        my $probe = $y;
        # FORCE THE PROBE DECISION, NOT THE PROBE'S FETCHES. %opts is forwarded to every
        # probe, so `force => 1` used to mean each candidate was a forced getYearList —
        # a real ~1.7MB download of a published, immutable list, re-parsed and re-stored,
        # purely to answer "is there a newer one?". `force` on THIS sub means "re-walk the
        # sweep": it still skips the latest-year kv read above, and `resweep` still skips
        # each candidate's year-miss marker (or a marker from a failed sweep would make
        # the Refresh row unable to discover a newly published list for YEAR_MISS_TTL —
        # the row's second job, and the only reason it forces at all), and it is still solo
        # in _shareFetch — see there, it is the half of `force`'s meaning that has nothing
        # to do with fetching. What it stops doing is bypassing the permanent store: a
        # candidate we already hold answers from the DB.
        my %probeOpts = %opts;
        $probeOpts{resweep} = 1 if delete $probeOpts{force};
        getYearList($probe, sub {
            my $items = shift || [];
            if (@$items) {
                my $ttl = _latestTtl($probe, $top);
                Plugins::PitchforkReviews::DB::kvSet($key, $probe, $ttl);
                $log->info("latest year-end list = $probe (held ${ttl}s)");
                return $cb->($probe);
            }
            $y--;
            $self->($self);
        }, %probeOpts);
    };
    $try->($try);
}

# Every year we can offer, newest first. YEAR_MIN is the floor: 2016 is the
# oldest list that parses cleanly under this shape (older ones use ad-hoc slugs
# and a different body layout).
# The newest year IF it is already known, without ever fetching. For callers that
# must answer synchronously — the top-level menu builds its tiles inline, and
# blocking the whole app menu on a 1.7MB article fetch to label one tile would be
# a bad trade. Returns undef until something (a feed open, or the daily warm) has
# resolved it; the caller falls back to the generic label.
# `|| undef` collapses the 0 negative sentinel (see getLatestYear) back to "not
# known", which is what a caller falling back to a generic label expects.
sub cachedLatestYear { return Plugins::PitchforkReviews::DB::kvGet('pfr:year:latest:4') || undef; }

# (cachedYears / nextUncachedYear lived here. They served an incremental warm — the
# years already opened, plus one reach-ahead per tick — which the boot-time prefetch of
# ALL years replaces outright. Deleted rather than left unused: a year-end list is a
# fixed entity, so there was never anything for the warm to be incremental about.)

sub yearsAvailable {
    my ($cb) = @_;
    getLatestYear(sub {
        my $latest = shift;
        return $cb->([]) unless $latest;
        $cb->([ reverse(YEAR_MIN .. $latest) ]);
    });
}

# Record "this feed just failed". EVAL-GUARDED, and that is not defensive habit: most of
# the call sites sit ABOVE `$done`, which is the only thing that releases the key's
# %PENDING slot — so a die here would manufacture exactly the strand the guards around it
# exist to prevent (0.9.23 finding 1, where a kvSet above an unreleased claim was the most
# plausible source of the wedges). A marker we fail to write costs one extra fetch; a die
# costs the key for the life of the process.
#
# TWO TTLS, CHOSEN BY WHETHER THERE IS ANYTHING TO SERVE, and the short one is a fix not a
# tuning knob. The gate that reads this marker is deliberately not conditioned on `$stored`
# (see _fetchState) — but with NOTHING stored, holding it for the full hour means one
# transient failure on a fresh install answers that section `[]` for an hour with no retry
# at all: the warm passes `nostale`, not `force`, so it hits the same gate. Pre-0.9.24 the
# next open simply retried. Conditioning the READ on `$stored` instead would hand the
# unbounded-refetch defect straight back to the fresh install (a layout change is a real
# ~1-2MB download that parses to nothing, on every open), so the marker still stands — for
# a minute rather than an hour. That bounds the storm and still recovers promptly.
sub _markFeedMiss {
    my ($key, $missKey, $stored) = @_;
    my $ttl = ($stored && @$stored) ? FEED_MISS_TTL : FEED_MISS_EMPTY_TTL;
    eval { Plugins::PitchforkReviews::DB::kvSet($missKey, 1, $ttl); 1 }
        or $log->error("$key: could not record the fetch failure: $@");
}

# The year path's equivalent. Same eval guard for the same reason — every one of its call
# sites sits above the $cb that releases the year key's %PENDING slot. There is no
# empty-store tier here: a year that has never been fetched has no rows to be starved of,
# and the 12h/30d promotion cadence YEAR_MISS_TTL is sized against is unaffected either way.
sub _markYearMiss {
    my ($key, $missKey) = @_;
    eval { Plugins::PitchforkReviews::DB::kvSet($missKey, 1, YEAR_MISS_TTL); 1 }
        or $log->error("$key: could not record the sweep failure: $@");
}

sub _fetchState {
    my ($url, $key, $cap, $cb, %opts) = @_;

    # The stored copy serves two roles at once: a hit while it is fresh, and the
    # last-good-copy while it is not. Read once, used for both.
    #
    # READ IT EVEN UNDER `force`. Only the HIT below is suppressed for a forced refresh
    # — the fallback is not. Skipping the read entirely would mean a Refresh that then
    # failed (a 404, an outage) emptied the view instead of leaving what was already
    # there, which is the opposite of what a refresh button should risk.
    my $stored  = Plugins::PitchforkReviews::DB::getList($key, PARSE_VERSION);
    my $age     = $stored ? Plugins::PitchforkReviews::DB::listAge($key) : undef;
    # A SEPARATE key, never the stored list — the rule the year path states at its own
    # miss write: a failure must never overwrite the good copy the view is reading.
    my $missKey = "pfr:feedmiss:$key";

    if (!$opts{force} && $stored && defined $age && $age < FEED_TTL) {
        $log->info("$key DB hit (" . scalar(@$stored) . " items)");
        return $cb->($stored);
    }

    # A recent fetch failed or parsed nothing (see FEED_MISS_TTL). Keep answering from the
    # stored rows — which is what stops a failed refresh blanking the view — but do not
    # re-download while the marker stands.
    #
    # DELIBERATELY NOT GATED ON `!$stored`. Any server that has ever fetched successfully
    # HAS stored rows, and that is precisely the case this exists for, so that condition
    # would ship the marker inert on every real install.
    if (!$opts{force} && Plugins::PitchforkReviews::DB::kvGet($missKey)) {
        $log->info("$key fetch suppressed — a recent one failed (marker held "
            . FEED_MISS_TTL . "s); serving "
            . ($stored ? scalar(@$stored) . ' stored item(s)' : 'nothing'));
        return $cb->($stored || []);
    }

    # Stale-while-revalidate + coalescing (see _shareFetch). An empty return
    # means an in-flight fetch has taken this caller's callback.
    my ($answered, $done) = _shareFetch($key, $stored, $cb, \%opts);
    return unless $done;

    _issueFetch($done, $stored, $key, sub {
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            # EVERYTHING before $done runs inside an eval, because $done is what
            # releases this key's coalescing slot (see _shareFetch). A die here —
            # a parse fault, or the DB write throwing — strands the key in
            # %PENDING for the life of the process, and every later caller is then
            # adopted by a fetch that can never answer. The symptom is silent
            # either way: with nothing stored the view hangs, and WITH stored rows
            # (i.e. on any server that has fetched successfully once) the feed serves
            # the same copy for ever and never issues another fetch.
            my $items = eval {
                my $i = _parseState($http->content);
                $i = [ @{$i}[0 .. $cap - 1] ] if $cap && @$i > $cap;
                if (@$i) {
                    # One write, replacing the whole list. For the rolling feeds that IS
                    # the rotation: entries that dropped off the page are deleted in the
                    # same transaction, so nothing accumulates.
                    #
                    # GATED ON THE RETURN VALUE, and that is the whole point: putList logs
                    # and returns 0 on a failed write rather than dying, so a fetch that
                    # PARSES FINE BUT FAILS TO STORE used to read as a success — no rows
                    # landed, `stored_at` never moved, and the marker was actively cleared.
                    # The next open then found no stored rows and no marker, re-downloaded
                    # the ~1-2MB listing, failed to store again, and repeated for ever:
                    # exactly the unbounded refetch FEED_MISS_TTL exists to bound, surviving
                    # in the one branch that bypassed it. The caller still gets $i — the
                    # parse succeeded, only the store did not.
                    if (Plugins::PitchforkReviews::DB::putList($key, $i, PARSE_VERSION)) {
                        Plugins::PitchforkReviews::DB::kvDel($missKey);   # a good fetch clears any marker
                        $log->info("$key fetched (" . scalar(@$i) . " items)");
                    }
                    else {
                        $log->warn("$key fetched " . scalar(@$i) . " items but the store failed — "
                            . "marking, so this does not become a download loop");
                        _markFeedMiss($key, $missKey, $stored);
                    }
                }
                else {
                    $log->warn("$key parsed 0 items from " . length($http->content) . " bytes ($url)");
                    _markFeedMiss($key, $missKey, $stored);
                    $i = $stored || [];
                }
                $i;
            };
            if ($@ || !$items) {
                $log->error("$key parse/store failed ($url): $@");
                _markFeedMiss($key, $missKey, $stored);
                $items = $stored || [];
            }
            $done->($items);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("fetch failed ($url): $error");
            _markFeedMiss($key, $missKey, $stored);
            $done->($stored || []);
        },
        { timeout => HTTP_TIMEOUT },
    )->get($url, 'User-Agent' => UA);
    });
}

# ---------------------------------------------------------------------------
# Parse window.__PRELOADED_STATE__ -> normalised review items.
# ---------------------------------------------------------------------------
sub _parseState {
    my ($content) = @_;

    my $json = _extractState($content);
    return [] unless length $json;

    my $state = eval { from_json($json) };
    if ($@ || !ref $state) {
        $log->warn("state JSON parse error: $@");
        return [];
    }

    my @raw;
    _walkReviews($state, \@raw);

    my (%seen, @items);
    for my $r (@raw) {
        my $link = $r->{url} // '';
        next unless length $link;
        $link = SITE . $link if $link =~ m{^/};
        next if $seen{$link}++;

        my $album = _stripTags($r->{dangerousHed} // '');
        $album =~ s/^\*+//; $album =~ s/\*+$//;          # *markdown emphasis*
        $album =~ s/^\s+//; $album =~ s/\s+$//;
        next unless length $album;

        # subHed/rubric are plain name fields, not "dangerous" HTML, so they get the
        # entity decode without the tag strip. Observed clean across 133 live reviews,
        # but an "&amp;" in a band or genre name ("Pop/R&B") is one review away and
        # would poison the matcher exactly as it did the album title.
        my $artist  = _decodeEntities((ref $r->{subHed} eq 'HASH' ? $r->{subHed}{name} : '') // '');
        my $capsule = _stripTags($r->{dangerousDek} // '');
        my $rv      = ref $r->{ratingValue} eq 'HASH' ? $r->{ratingValue} : {};

        # Genre(s) from the "rubric" list (can repeat / hold several) — dedupe,
        # keep order, join for display. Missing on the odd review.
        my (@g, %gs);
        for my $x (@{ ref $r->{rubric} eq 'ARRAY' ? $r->{rubric} : [] }) {
            my $n = ref $x eq 'HASH' ? _decodeEntities($x->{name}) : undef;
            next unless defined $n && length $n;
            push @g, $n unless $gs{$n}++;
        }

        push @items, {
            artist  => $artist,
            album   => $album,
            title   => (length $artist ? "$artist: $album" : $album),
            capsule => $capsule,
            link    => $link,
            date    => ($r->{pubDate} // ''),          # ISO 8601 (sorts + week-groups)
            cover   => _coverUrl($r->{image}),
            score   => $rv->{score},
            genre   => join(' / ', @g),
            is_bnm  => ($rv->{isBestNewMusic} ? 1 : 0),
        };
    }

    # Newest-first (ISO pubDate sorts lexicographically = chronologically).
    @items = sort { ($b->{date} // '') cmp ($a->{date} // '') } @items;
    return \@items;
}

# ---------------------------------------------------------------------------
# Parse a year-end list article -> normalised items (same shape as a review,
# plus rank/year), BEST FIRST.
#
# The body is Verso's array-of-nodes prose: ["tag", {attrs}?, child, child...].
# One entry is a run of four consecutive blocks:
#   ["inline-embed", {type=>"callout:inset-left"}, [... photo ...]]   the album art
#   ["div", {class=>"heading-h3"}, "50."]                             the rank
#   ["h2", "Sharp Pins: ", ["em", "Radio DDR"]]                       artist + album
#   ["p", "Whether by age or by disposition..."]                      the blurb
#
# THREE traps, each hit on real pages and each guarded here:
#
#  1. RANK COMES FROM DOCUMENT ORDER, never the printed number. Pitchfork's own
#     2020 page prints "25." twice and never prints 24, so trusting the digits
#     yields a duplicate and a hole. Position is always right. The printed
#     numbers are used for ONE thing only — deciding whether the list counts down
#     (50->1, the house style) or up — which survives a single typo because it
#     only compares the first against the last.
#  2. A HEADING THAT IS ONLY DIGITS IS A RANK. The 2017 page marks one entry's
#     rank with an <h2> instead of the heading-h3 div; without this guard that
#     <h2> is read as an entry titled "33." and shunts every following field onto
#     the wrong record.
#  3. ARTIST IS THE TEXT BEFORE THE FIRST <em>, not "the heading minus the album".
#     2024's ["h2","Djrum: ",["em","Meaning's Edge"]," EP"] has text AFTER the
#     album, so the subtract-the-suffix reading gives the artist as
#     "Djrum: Meaning's Edge EP".
# ---------------------------------------------------------------------------
sub _parseYear {
    my ($content, $year, $url) = @_;

    my $json = _extractState($content);
    return [] unless length $json;

    my $state = eval { from_json($json) };
    if ($@ || !ref $state) {
        $log->warn("year state JSON parse error: $@");
        return [];
    }

    my $body = eval { $state->{transformed}{article}{body} };
    return [] unless ref $body eq 'ARRAY';

    # Title + publication date live in the page's meta tags, not the state.
    my ($hed) = $content =~ m{<meta property="og:title" content="([^"]*)"};
    my ($pub) = $content =~ m{<meta property="article:published_time" content="([^"]*)"};
    $hed = _decodeEntities($hed // '');
    $pub //= '';

    my (@items, $cover, $printed);
    for my $blk (@$body) {
        next unless ref $blk eq 'ARRAY' && @$blk;
        my $tag   = $blk->[0] // '';
        my $attrs = ref $blk->[1] eq 'HASH' ? $blk->[1] : {};

        if ($tag eq 'inline-embed' && ($attrs->{type} // '') eq 'callout:inset-left') {
            my $photo = _findPhoto($blk);
            $cover = _coverUrl($photo) if $photo;
            next;
        }

        if ( ($tag eq 'div' && ($attrs->{class} // '') eq 'heading-h3')
          || $tag eq 'h2' || $tag eq 'h3' ) {
            my $t = _nodeText($blk);
            $t =~ s/^\s+//; $t =~ s/\s+$//;

            if ($t =~ /^(\d+)\.?$/) {           # trap 2: a bare number is a rank marker
                $printed = $1 + 0;
                next;
            }
            # A sub-heading that is not an entry. Clears the pending cover/rank for the
            # same reason as the branch below, and the two together are what make the
            # contract TOTAL: $cover and $printed are set by the inline-embed above and
            # belong to the next ENTRY, so every exit from this branch that is not an
            # entry must clear them. Leaving this one — an h3, or a heading-h3 div whose
            # text is not a bare number — carried an embed's artwork past it, and the
            # following entry, if it has no embed of its own, rendered the WRONG album's
            # cover under a rank the page never printed for it (which then feeds the
            # countdown-direction test). Silent both ways: plausible output, no error.
            #
            # The trade, since the two skips are not the same shape: an entry that
            # legitimately sits BELOW a decorative sub-heading, with its embed ABOVE it,
            # now renders coverless. That is the safe failure — the row still resolves and
            # plays, only the artwork falls back — against silently-wrong artwork plus a
            # phantom rank. Neither shape occurs today: across all ten live years
            # 2016-2025 this skip never fires at all (500/500 entries, verified against
            # the live pages), which is also why the sibling branch below sat unreachable
            # from 0.8.8 until now.
            unless ($tag eq 'h2') {
                $cover = $printed = undef;
                next;
            }

            my ($artist, $album) = _headingParts($blk);
            unless (length $album) {
                # A heading that yielded no album is NOT an entry either — same clear,
                # for the same reason (0.8.8).
                $cover = $printed = undef;
                next;
            }

            push @items, {
                artist  => $artist,
                album   => $album,
                title   => (length $artist ? "$artist: $album" : $album),
                capsule => '',
                link    => $url,                # no per-entry review link exists; link the list
                date    => $pub,
                cover   => ($cover // ''),
                score   => undef,               # year-end lists carry no score
                genre   => '',                  # ...and no genre
                is_bnm  => 0,
                year    => $year,
                list_title => $hed,
                _printed   => $printed,
            };
            $cover = $printed = undef;
            next;
        }

        # The first substantial paragraph after a heading is that entry's blurb.
        # "Listen/Buy: Amazon | Apple Music | ..." is an affiliate row, not prose.
        if ($tag eq 'p' && @items && !length $items[-1]{capsule}) {
            my $t = _stripTags(_nodeText($blk));
            next if $t =~ m{^Listen/Buy};
            $items[-1]{capsule} = $t if length($t) > CAPSULE_MIN;
        }
    }

    my $n = scalar @items or return [];

    # Trap 1: rank by position. Direction is taken from the printed numbers (a
    # countdown is the house style, but don't assume it), comparing only the
    # first against the last so one mistyped number in the middle can't flip it.
    my @printed = grep { defined } map { $_->{_printed} } @items;

    # LOSING THE MARKERS ENTIRELY IS NOT THE SAME AS READING THEM AS ASCENDING, and
    # until now it was treated as such. With fewer than two printed ranks there is no
    # evidence of direction at all, and the fallback below numbers the list 1..n in
    # document order — so against Pitchfork's actual house style (a 50-to-1 countdown)
    # the whole list comes out REVERSED, with the article's #50 sitting at the top
    # labelled "1.". No error, no log line, and every rank present and unique, so all
    # the existing integrity checks still pass.
    #
    # The fallback is deliberately UNCHANGED — ascending is what the tests pin and
    # guessing "countdown" from house style would just be a different assumption. What
    # changes is that it stops being silent, so a markup change is diagnosable from the
    # log instead of being reported as "the list is upside down". Verified against the
    # live 2025 page: 50 of 50 markers present, so this is insurance, not a live fix.
    if ($n && @printed < 2) {
        $log->warn("$url: $n entries but only " . scalar(@printed)
            . " printed rank marker(s) — cannot tell the list's direction, "
            . "numbering 1..$n in document order (the order may be reversed)");
    }

    my $countdown = (@printed >= 2 && $printed[0] > $printed[-1]) ? 1 : 0;
    for my $i (0 .. $n - 1) {
        $items[$i]{rank} = $countdown ? ($n - $i) : ($i + 1);
        delete $items[$i]{_printed};
    }

    # Best first — the countdown reads well as an article, but a browse list
    # wants #1 at the top.
    @items = sort { $a->{rank} <=> $b->{rank} } @items;
    return \@items;
}

# Flatten a Verso body node to plain text. Element 0 is the tag name and any HASH
# child is an attributes bag, so both are skipped.
sub _nodeText {
    my ($n) = @_;
    return defined $n ? $n : '' unless ref $n;
    return '' unless ref $n eq 'ARRAY';
    my $out = '';
    for my $i (1 .. $#$n) {
        next if ref $n->[$i] eq 'HASH';
        $out .= _nodeText($n->[$i]);
    }
    return $out;
}

# Split an entry heading into (artist, album). See trap 3 above: the album starts
# at the first <em> and runs to the END of the heading (so a trailing " EP" stays
# on the album, where _stripFmt in the matcher already knows how to handle it).
# A heading with no <em> at all falls back to the "Artist: Album" colon split.
sub _headingParts {
    my ($n) = @_;
    my @kids = grep { ref $_ ne 'HASH' } @{$n}[1 .. $#$n];

    my $emAt;
    for my $i (0 .. $#kids) {
        if (ref $kids[$i] eq 'ARRAY' && ($kids[$i][0] // '') eq 'em') { $emAt = $i; last; }
    }

    my ($artist, $album);
    if (defined $emAt) {
        $artist = join('', map { _nodeText($_) } @kids[ 0 .. $emAt - 1 ]);
        $album  = join('', map { _nodeText($_) } @kids[ $emAt .. $#kids ]);
    }
    else {
        my $full = join('', map { _nodeText($_) } @kids);
        ($artist, $album) = $full =~ /^([^:]+):\s*(\S.*)$/ ? ($1, $2) : ('', $full);
    }

    # Same tidy-up the review path gives dangerousHed: strip tags, decode
    # entities (an "&amp;" here would poison the matcher exactly as it did for
    # reviews in 0.7.12), trim, and drop *markdown emphasis*.
    for ($artist, $album) {
        $_ = _stripTags($_ // '');
        s/^\*+//; s/\*+$//;
        s/^\s+//; s/\s+$//;
    }
    $artist =~ s/\s*[:\x{2013}\x{2014}-]\s*$//;   # the separator before the album
    $artist =~ s/\s+$//;

    return ($artist, $album);
}

# First photo node anywhere inside a block (the entry's album art).
sub _findPhoto {
    my ($n) = @_;
    if (ref $n eq 'HASH') {
        return $n if ($n->{contentType} // '') eq 'photo' && ref $n->{sources} eq 'HASH';
        for my $v (values %$n) { my $f = _findPhoto($v); return $f if $f; }
    }
    elsif (ref $n eq 'ARRAY') {
        for my $v (@$n) { my $f = _findPhoto($v); return $f if $f; }
    }
    return undef;
}

# Recursively collect Verso "review" content nodes.
sub _walkReviews {
    my ($node, $out) = @_;
    if (ref $node eq 'HASH') {
        if (($node->{contentType} // '') eq 'review'
            && ($node->{url} // '') =~ m{/reviews/album}) {
            push @$out, $node;
        }
        _walkReviews($_, $out) for values %$node;
    }
    elsif (ref $node eq 'ARRAY') {
        _walkReviews($_, $out) for @$node;
    }
}

# Extract the JSON object assigned to window.__PRELOADED_STATE__ by scanning for
# the matching close brace (string/escape aware). Fast: the [^{}"\\]* run lets the
# regex engine skip long spans between significant characters.
sub _extractState {
    my ($content) = @_;
    my $i = index($content, 'window.__PRELOADED_STATE__');
    return '' if $i < 0;
    my $eq = index($content, '=', $i);
    return '' if $eq < 0;
    my $start = index($content, '{', $eq);
    return '' if $start < 0;

    pos($content) = $start;
    my $depth = 0;
    my $instr = 0;
    while ($content =~ /\G[^{}"\\]*([{}"\\])/gc) {
        my $ch = $1;
        if ($instr) {
            if    ($ch eq '\\') { pos($content) += 1; }   # skip the escaped char
            elsif ($ch eq '"')  { $instr = 0; }
            # braces inside a string are ignored
        }
        else {
            if    ($ch eq '"') { $instr = 1; }
            elsif ($ch eq '{') { $depth++; }
            elsif ($ch eq '}') {
                $depth--;
                return substr($content, $start, pos($content) - $start) if $depth == 0;
            }
        }
    }
    return '';
}

# Pick a reasonable cover URL from a Verso image node: the smallest source >= 640px
# wide (a good thumbnail; LMS's proxy can resize down), else the largest available,
# else a constructed master URL from the id.
sub _coverUrl {
    my ($image) = @_;
    return '' unless ref $image eq 'HASH';

    my $src = $image->{sources};
    if (ref $src eq 'HASH') {
        my @cands = grep { ref $_ eq 'HASH' && $_->{url} } values %$src;
        if (@cands) {
            my @sorted = sort { ($a->{width} || 0) <=> ($b->{width} || 0) } @cands;
            for my $c (@sorted) { return $c->{url} if ($c->{width} || 0) >= 640; }
            return $sorted[-1]{url};
        }
    }
    return 'https://media.pitchfork.com/photos/' . $image->{id} . '/1:1/w_800,c_limit/a.jpg'
        if $image->{id};
    return '';
}

sub _stripTags {
    my $s = shift // '';
    $s =~ s/<[^>]+>//g;
    # Decode AFTER stripping, never before: "&lt;em&gt;" is literal text a review
    # meant to show, and decoding first would turn it into a tag the strip then ate.
    $s = _decodeEntities($s);
    $s =~ s/^\s+//; $s =~ s/\s+$//;   # after decoding — an edge "&nbsp;" is whitespace too
    return $s;
}

# Named entities Pitchfork actually emits, plus the rest of the common punctuation
# set. Everything non-ASCII it produces arrives NUMERIC (&#8212; is by far the most
# common), so this table does not try to cover accented letters — an unknown named
# entity is left VERBATIM rather than guessed at or dropped. Case-sensitive on
# purpose: "&Eacute;" and "&eacute;" are different characters, so a lc() lookup
# would be a silent corruption waiting for the first accented entity.
my %ENTITY = (
    amp    => '&',        lt     => '<',        gt     => '>',
    quot   => '"',        apos   => "'",        nbsp   => ' ',
    ndash  => "\x{2013}", mdash  => "\x{2014}", minus  => "\x{2212}",
    hellip => "\x{2026}", lsquo  => "\x{2018}", rsquo  => "\x{2019}",
    ldquo  => "\x{201c}", rdquo  => "\x{201d}", sbquo  => "\x{201a}",
    bdquo  => "\x{201e}", laquo  => "\x{ab}",   raquo  => "\x{bb}",
    deg    => "\x{b0}",   times  => "\x{d7}",   middot => "\x{b7}",
    bull   => "\x{2022}", dagger => "\x{2020}", prime  => "\x{2032}",
    Prime  => "\x{2033}", trade  => "\x{2122}", reg    => "\x{ae}",
    copy   => "\x{a9}",   eacute => "\x{e9}",   #  ^ the one accented name worth having
);
# `&nbsp;` decodes to a PLAIN space, not U+00A0. This is display text that also feeds
# the matcher, and whether \s matches U+00A0 depends on the string's UTF8 flag — a
# trailing one would survive the trim above on one string and not another. A plain
# space is what the review means and behaves the same everywhere.

# Decode HTML entities in ONE pass. One pass is the whole point: "&amp;lt;" must
# become "&lt;" (what the review wrote), not "<" — a decode-until-stable loop, or
# handling &amp; in a separate substitution, would double-decode it.
sub _decodeEntities {
    my $s = shift // '';
    return $s if index($s, '&') < 0;          # the overwhelmingly common case

    $s =~ s{&(\#(?:[0-9]{1,7}|[xX][0-9a-fA-F]{1,6})|[a-zA-Z][a-zA-Z0-9]{1,9});}{
        my $e = $1;
        my $r =   $e =~ /^\#[xX]([0-9a-fA-F]+)$/ ? _entChr(hex $1)
                : $e =~ /^\#([0-9]+)$/           ? _entChr(0 + $1)
                :                                  $ENTITY{$e};
        defined $r ? $r : "&$e;";             # unknown / out of range: leave it alone
    }ge;

    return $s;
}

# A codepoint we are willing to substitute in. Rejects control characters, the
# surrogate range and anything past Unicode — chr() would happily hand back a
# character that later blows up the cache's md5 key or the log.
sub _entChr {
    my ($n) = @_;
    return undef if !defined $n;
    return undef if $n < 32 && $n != 9 && $n != 10;
    return undef if $n == 127;
    return undef if $n >= 0xD800 && $n <= 0xDFFF;
    return undef if $n > 0x10FFFF;
    return chr($n);
}

1;

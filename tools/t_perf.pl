#!/usr/bin/env perl
# 0.8.8 — the first open of a view. Everything here is about the COLD path; none of
# it changes what the plugin shows, which is exactly why it needs tests: every one
# of these can regress silently into "correct, just slow again".
#
# WHAT WAS MEASURED FIRST (against the live server + the real pages, 2026-08-05):
#   - a warm feed build is already instant: 0.23s for 35 rows, 0.05s for 55.
#   - a COLD resolve of ONE album is 2.63s. At the old concurrency of 6 that made a
#     cold 50-item year list ~22s — past the old 18s deadline, so a fresh year list
#     rendered partial EVERY time.
#   - a listing page is 0.9-2.0MB and takes 0.1-4.0s to fetch, and with a 3h TTL
#     against a DAILY warm, whoever opened a view first after expiry paid it.
#   - artwork: Tidal hands out 1280x1280 = 563KB per cover, Pitchfork w_768 = 82KB.
#     LMS downloads the original once per cover to resize it, so a fresh 50-row list
#     on a Tidal-first setup pulled ~28MB to draw 50 thumbnails.
#
# WHAT IS PINNED HERE:
#   1. STALE-WHILE-REVALIDATE. An expired feed answers from the last good copy at
#      once and refreshes behind the caller. `force` (the Refresh row) and `nostale`
#      (the warm) must BOTH opt out, for different reasons — a manual refresh has to
#      be live, and a warm answered from the stale copy would resolve the very list
#      it exists to replace.
#   2. COALESCING. Concurrent callers for the same page share ONE fetch. A browse
#      list opening while its home shelf builds used to download the page twice.
#   3. PRIORITY-FIRST PROBING. Only the top-priority service is asked first; the rest
#      follow only if it fails to settle it. Same answer, a third of the traffic.
#   4. THE PUMP DOES NOT RECURSE. _findPlayable answers a cache hit synchronously, so
#      the completion re-entered the pump from inside the loop that started it and the
#      stack grew one frame per item — 50 deep on a year list, ~150 on a full warm.
#   5. COVER SIZING, both halves: the ceiling we put on our own rows, and the
#      spec-aware width the Pitchfork image-proxy handler asks for.
#   6. Matches are deduped and CAPPED before they are cached, not only before display.
#   7. Adapter detection is memoised once startup is over, but the priority ORDER still
#      self-invalidates. (0.8.10: nothing is memoised BEFORE startup is over — see
#      t_hardening section 7 for why a mid-startup answer must not be kept.)
#
# Run from the repo root:  perl tools/t_perf.pl
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

# --- throwaway Slim::* tree (absent on a dev Mac) ---------------------------
BEGIN {
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = $INC{'Slim/Utils/Cache.pm'}
        = $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'}
        = $INC{'Slim/Utils/Strings.pm'} = $INC{'Slim/Utils/Timers.pm'}
        = $INC{'Slim/Web/ImageProxy.pm'} = $INC{'JSON/XS/VersionOneAndTwo.pm'} = $INC{'Plugins/PitchforkReviews/DB.pm'} = __FILE__;
}

{
    # In-memory stand-in for the list DATABASE (0.9.8). The suites here test feed and
    # year LOGIC, not storage — DB.pm has its own suite against real SQLite (t_db.pl).
    # Keeping it in memory also makes what was stored directly assertable.
    package Plugins::PitchforkReviews::DB;
    our (%LISTS, %VER, %AGE);
    sub getList {
        my ($k, $v) = @_;
        return undef unless $LISTS{$k};
        return undef if defined $v && defined $VER{$k} && $VER{$k} != $v;
        return $LISTS{$k};
    }
    # $PUT_FAILS reproduces the real putList's FAILED-WRITE contract: it logs, swallows,
    # writes nothing and returns 0 — it does NOT die. That distinction is the whole of
    # section 19: a die is caught by the evals around these sites, a false return is not,
    # so the failure reads as a success unless the caller checks it.
    our $PUT_FAILS = 0;
    sub putList {
        my ($k, $i, $v) = @_;
        return 0 unless ref $i eq 'ARRAY' && @$i;
        return 0 if $PUT_FAILS;
        $LISTS{$k} = $i; $VER{$k} = $v; $AGE{$k} = 0;
        return 1;
    }
    sub listAge    { exists $LISTS{$_[0]} ? ($AGE{$_[0]} // 0) : undef }
    sub forget     { delete $LISTS{$_[0]}; delete $AGE{$_[0]}; delete $VER{$_[0]}; 1 }
    sub forgetAll  { %LISTS = (); %AGE = (); %VER = (); 1 }
    sub storedKeys { sort keys %LISTS }
    sub reset_db   { %LISTS = (); %AGE = (); %VER = ();  kvReset(); }
    # KV SIDE (0.9.11) — the resolve cache, the newest-year answer and the negative
    # markers all live here now, not in Slim::Utils::Cache. A REAL in-memory store:
    # these are caching tests, so a no-op would make every one of them vacuous.
    # @KVSETS records the TTL each write asked for, which is what the boundary and
    # expiry assertions read. There is no clock — an "expired" key is simply absent,
    # which is what the code sees anyway.
    our (%KV, @KVSETS);
    sub kvGet { my ($k) = @_; exists $KV{$k} ? $KV{$k} : undef }
    sub kvSet { my ($k, $v, $ttl) = @_; $KV{$k} = $v; push @KVSETS, { key => $k, ttl => $ttl }; 1 }
    sub kvDel { my ($k) = @_; delete $KV{$k}; 1 }
    sub kvForgetPrefix { my ($p) = @_; my $n = 0; for (keys %KV) { $n++, delete $KV{$_} if index($_, $p) == 0 } $n }
    sub kvCount { scalar keys %KV }
    sub kvReset { %KV = (); @KVSETS = (); }
}
{
    # A real in-memory store: these are caching tests, so a no-op cache would make
    # every one of them vacuous. There is no TTL clock — an "expired" key is simply
    # one that isn't there, which is what the code sees anyway.
    package Slim::Utils::Cache;
    our (%STORE, @SETS);
    sub new   { bless {}, shift }
    sub get   { my (undef, $k) = @_; exists $STORE{$k} ? $STORE{$k} : undef }
    sub set   { my (undef, $k, $v, $ttl) = @_; $STORE{$k} = $v; push @SETS, { key => $k, ttl => $ttl }; 1 }
    sub reset { %STORE = (); @SETS = (); }

    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; our %P;
                                  sub AUTOLOAD {} sub init {}
                                  sub get { $P{$_[1]} } sub set { $P{$_[1]} = $_[2] }
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  sub cstring { $_[1] } sub string { $_[0] }
    package Slim::Utils::Timers;  our $armed = 0; our @T;
                                  # Records what was armed and WHEN, so section 7 can let a
                                  # 10s render deadline elapse without also firing a 300s
                                  # warm backstop — the whole difference under test there.
                                  sub setTimer { my (undef, $when, $cb) = @_;
                                                 push @T, { id => ++$armed, when => $when, cb => $cb };
                                                 return $armed }
                                  sub killSpecific { my ($i) = @_; @T = grep { $_->{id} != $i } @T; 1 }
                                  sub killTimers {}
                                  sub reset { @T = () }
                                  # Fire only the timers due in [now+$lo, now+$hi].
                                  sub fireWindow {
                                      my ($lo, $hi) = @_;
                                      my ($t0, $t1) = (time() + $lo, time() + $hi);
                                      my (@due, @keep);
                                      for (@T) { push @{ ($_->{when} >= $t0 && $_->{when} <= $t1) ? \@due : \@keep }, $_ }
                                      @T = @keep;
                                      $_->{cb}->() for @due;
                                      return scalar @due;
                                  }

    package Plugins::PitchforkReviews::Plugin; sub dbg {}

    # The real getRightSize, ported from Slim/Web/ImageProxy.pm: return the value of
    # the SMALLEST key that is >= the larger dimension of the spec, or undef when the
    # spec names no size at all. Reimplemented rather than mocked because the whole
    # point of the handler test is which bucket a given spec lands in.
    package Slim::Web::ImageProxy;
    sub registerHandler {1}
    sub getRightSize {
        my (undef, $spec, $sizes) = @_;
        my ($w, $h) = $spec =~ /_(\d+)x(\d+)_/ ? ($1, $2) : (0, 0);
        my $min = $w > $h ? $w : $h;
        return undef unless $min;
        for (sort { $a <=> $b } keys %$sizes) { return $sizes->{$_} if $_ >= $min }
        return undef;
    }

    # Scripted HTTP with an OPTIONAL deferred mode. Synchronous replies are enough for
    # the stale/force tests, but coalescing only exists between the moment a fetch
    # starts and the moment it answers — with an instant reply there is no window to
    # test, and the test would pass against code that never coalesced at all.
    package Slim::Networking::SimpleAsyncHTTP;
    our (%ROUTES, @GETS, $DEFER, @PENDING);
    sub new { my ($c, $ok, $err) = @_; bless { ok => $ok, err => $err }, $c }
    sub get {
        my ($self, $url) = @_;
        push @GETS, $url;
        return push(@PENDING, { self => $self, url => $url }) if $DEFER;
        _answer($self, $url);
    }
    sub _answer {
        my ($self, $url) = @_;
        return $self->{ok}->(bless { c => $ROUTES{$url} }, 'T::Resp') if defined $ROUTES{$url};
        $self->{err}->($self, '404 Not Found');
    }
    sub flush { my @q = @PENDING; @PENDING = (); _answer($_->{self}, $_->{url}) for @q; }
    package T::Resp; sub content { $_[0]{c} }

    package JSON::XS::VersionOneAndTwo; use Exporter 'import'; our @EXPORT = qw(from_json to_json);
                                  use JSON::PP ();
                                  sub from_json { JSON::PP::decode_json($_[0]) }
                                  sub to_json   { JSON::PP::encode_json($_[0]) }
}

my $API = $ENV{PFR_API} || 'PitchforkReviews/API.pm';
$INC{'Plugins/PitchforkReviews/API.pm'} = $API;
do($API =~ m{^/} ? $API : "./$API") or die "can't load $API: " . ($@ || $!);

my $BROWSE = $ENV{PFR_BROWSE} || 'PitchforkReviews/Browse.pm';
$INC{'Plugins/PitchforkReviews/Browse.pm'} = $BROWSE;
do($BROWSE =~ m{^/} ? $BROWSE : "./$BROWSE") or die "can't load $BROWSE: " . ($@ || $!);

my ($p, $f) = (0, 0);

# The TTL a kv write ASKED FOR, read off the DB stub's @KVSETS.
sub kvTtlFor {
    my ($k) = @_;
    my $t;
    for (@Plugins::PitchforkReviews::DB::KVSETS) { $t = $_->{ttl} if $_->{key} eq $k }
    return $t;
}

sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

sub reset_all {
    # In-flight coalescing slots are process-wide, so a fixture whose adapters never
    # answer would otherwise leave claimed slots that the NEXT block's identical album
    # keys join and wait on for ever. (In production RESOLVE_JOIN_MAX bounds that; here
    # the clock never moves.)
    Plugins::PitchforkReviews::Browse::_resetResolving()
        if Plugins::PitchforkReviews::Browse->can('_resetResolving');
    Plugins::PitchforkReviews::DB::reset_db();
    $Plugins::PitchforkReviews::DB::PUT_FAILS = 0;
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
    Slim::Utils::Timers::reset();
    %Slim::Networking::SimpleAsyncHTTP::ROUTES = ();
    @Slim::Networking::SimpleAsyncHTTP::GETS   = ();
    @Slim::Networking::SimpleAsyncHTTP::PENDING = ();
    $Slim::Networking::SimpleAsyncHTTP::DEFER  = 0;
}
sub gets { scalar @Slim::Networking::SimpleAsyncHTTP::GETS }

# The smallest page that _parseState will read one review out of.
sub listingPage {
    my ($album) = @_;
    my $state = JSON::PP::encode_json({
        items => [ {
            contentType  => 'review',
            url          => "/reviews/albums/$album/",
            dangerousHed => $album,
            subHed       => { name => 'An Artist' },
            dangerousDek => 'A capsule.',
            pubDate      => '2026-08-01T05:00:00.000Z',
            image        => { sources => { lg => { url => 'https://media.pitchfork.com/photos/x/1:1/w_768,c_limit/a.jpg', width => 768 } } },
            ratingValue  => { score => 8.0 },
            rubric       => [ { name => 'Rock' } ],
        } ],
    });
    return "<html><script>window.__PRELOADED_STATE__ = $state;</script></html>";
}

# The smallest year-end article _parseYear will read entries out of. One entry per rank,
# each labelled "<artist> N", so a test can tell one parse from another.
sub yearFixture {
    my ($year, $artist) = @_;
    my @body;
    for my $i (1 .. 3) {
        push @body,
          [ 'div', { class => 'heading-h3' }, "$i." ],
          [ 'h2', "$artist $i: ", [ 'em', "Album $i" ] ],
          [ 'p', 'x' x 200 ];
    }
    return qq{<meta property="og:title" content="The 50 Best Albums of $year">}
         . qq{<meta property="article:published_time" content="$year-12-02T14:00:00.000Z">}
         . '<script>window.__PRELOADED_STATE__ = '
         . JSON::PP::encode_json({ transformed => { article => { body => \@body } } })
         . ';</script>';
}

my $REVIEWS = 'https://pitchfork.com/reviews/albums/';
my $KEY     = 'reviews';       # 0.9.8: a DB list key, not a cache key

# Seed the list DATABASE. $age is what decides fresh-vs-stale, so these two helpers say
# which is meant instead of leaving it to a magic number at each call site.
sub dbFresh { Plugins::PitchforkReviews::DB::putList($_[0], $_[1], Plugins::PitchforkReviews::API::PARSE_VERSION());
              $Plugins::PitchforkReviews::DB::AGE{$_[0]} = 0 }
sub dbStale { Plugins::PitchforkReviews::DB::putList($_[0], $_[1], Plugins::PitchforkReviews::API::PARSE_VERSION());
              $Plugins::PitchforkReviews::DB::AGE{$_[0]} = 99_999 }
sub dbGet   { Plugins::PitchforkReviews::DB::getList($_[0], Plugins::PitchforkReviews::API::PARSE_VERSION()) }

# ===========================================================================
# 1. Stale-while-revalidate
# ===========================================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');
    dbStale($KEY, [ { album => 'Stale', artist => 'A' } ]);

    my @order;
    Plugins::PitchforkReviews::API::getListing(sub { push @order, $_[0][0]{album} });

    is('expired feed answers from the last good copy', $order[0], 'Stale');
    is('...exactly once — the background refresh does not call back again', scalar(@order), 1);
    is('...and the refresh really was issued', gets(), 1);
    is('...and it landed in the DB for the next open',
        dbGet($KEY)->[0]{album}, 'Fresh');

    # The second open now has a live copy and must not touch the network at all.
    my $second;
    Plugins::PitchforkReviews::API::getListing(sub { $second = $_[0][0]{album} });
    is('the next open is served fresh from the DB', $second, 'Fresh');
    is('...with no further fetch',                 gets(),  1);
}

# force => 1 is the Refresh row: never stale, always live.
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');
    dbFresh($KEY, [ { album => 'Cached', artist => 'A' } ]);

    my @got;
    Plugins::PitchforkReviews::API::getListing(sub { push @got, $_[0][0]{album} }, force => 1);
    is('force skips both the live copy and the stale one', $got[0], 'Fresh');
    is('...answering once',                                scalar(@got), 1);
}

# nostale => 1 is the warm: it waits for the real page, or it would spend the tick
# resolving the copy it was supposed to replace.
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');
    dbStale($KEY, [ { album => 'Stale', artist => 'A' } ]);

    my @got;
    Plugins::PitchforkReviews::API::getListing(sub { push @got, $_[0][0]{album} }, nostale => 1);
    is('nostale waits for the live page', $got[0], 'Fresh');
    is('...answering once',               scalar(@got), 1);
}

# A stale answer must not be given when the fallback is empty — an empty list is not
# an answer, it is the absence of one, and serving it would render an empty view.
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');
    # An empty stored list is refused by putList, so the DB simply holds nothing —
    # which is the same condition the old empty `:fb` array represented.
    Plugins::PitchforkReviews::DB::reset_db();

    my @got;
    Plugins::PitchforkReviews::API::getListing(sub { push @got, scalar @{$_[0]} });
    is('an EMPTY fallback is not served as stale', scalar(@got), 1);
    is('...the caller waits for the real page',    $got[0],      1);
}

# ===========================================================================
# 2. Coalescing
# ===========================================================================
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');

    my @got;
    Plugins::PitchforkReviews::API::getListing(sub { push @got, 'a:' . $_[0][0]{album} });
    Plugins::PitchforkReviews::API::getListing(sub { push @got, 'b:' . $_[0][0]{album} });
    Plugins::PitchforkReviews::API::getListing(sub { push @got, 'c:' . $_[0][0]{album} });

    is('three cold callers, ONE fetch', gets(), 1);
    is('...nobody has answered yet',    scalar(@got), 0);

    Slim::Networking::SimpleAsyncHTTP::flush();
    is('...and all three are answered by it', join(',', @got), 'a:Fresh,b:Fresh,c:Fresh');

    # The queue must be released, or the next cold open would wait on a fetch that
    # has already finished and never be answered at all.
    @got = ();
    Plugins::PitchforkReviews::DB::forget($KEY);
    Plugins::PitchforkReviews::API::getListing(sub { push @got, $_[0][0]{album} });
    is('a later cold open starts its own fetch', gets(), 2);
    Slim::Networking::SimpleAsyncHTTP::flush();
    is('...and is answered',                     $got[0], 'Fresh');
}

# Stale + concurrent: everyone is answered from the copy immediately, and the single
# background refresh behind them is still only one fetch.
{
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');
    dbStale($KEY, [ { album => 'Stale', artist => 'A' } ]);

    my @got;
    Plugins::PitchforkReviews::API::getListing(sub { push @got, $_[0][0]{album} }) for 1 .. 3;
    is('three stale opens all answered at once', scalar(@got), 3);
    is('...from the stored copy',                join(',', @got), 'Stale,Stale,Stale');
    is('...behind ONE background refresh',       gets(), 1);

    Slim::Networking::SimpleAsyncHTTP::flush();
    is('...which answers nobody a second time', scalar(@got), 3);
}

# ===========================================================================
# 3. Cover sizing
# ===========================================================================
{
    my $fit = \&Plugins::PitchforkReviews::Browse::_fitCover;

    is('Tidal 1280 is capped at 640',
        $fit->('https://resources.tidal.com/images/aa/bb/1280x1280.jpg'),
        'https://resources.tidal.com/images/aa/bb/640x640.jpg');
    is('a Tidal cover already under the ceiling is untouched',
        $fit->('https://resources.tidal.com/images/aa/bb/320x320.jpg'),
        'https://resources.tidal.com/images/aa/bb/320x320.jpg');
    is('Qobuz _max is pulled back to _600',
        $fit->('https://static.qobuz.com/images/covers/aa/bb/x_max.jpg'),
        'https://static.qobuz.com/images/covers/aa/bb/x_600.jpg');
    is('the ordinary Qobuz _600 is left alone',
        $fit->('https://static.qobuz.com/images/covers/aa/bb/x_600.jpg'),
        'https://static.qobuz.com/images/covers/aa/bb/x_600.jpg');
    is('an oversized Deezer cover is capped, keeping its parameter tail',
        $fit->('https://e-cdns-images.dzcdn.net/images/cover/abc/1000x1000-000000-80-0-0.jpg'),
        'https://e-cdns-images.dzcdn.net/images/cover/abc/640x640-000000-80-0-0.jpg');
    is('Deezer at 500 is already smaller than the ceiling',
        $fit->('https://e-cdns-images.dzcdn.net/images/cover/abc/500x500-000000-80-0-0.jpg'),
        'https://e-cdns-images.dzcdn.net/images/cover/abc/500x500-000000-80-0-0.jpg');
    # Anything we don't recognise is returned VERBATIM: a cover that fails to shrink
    # costs bandwidth, a cover mangled into a 404 costs the picture.
    is('an unknown host passes through',
        $fit->('https://example.com/art/9999x9999.jpg'),
        'https://example.com/art/9999x9999.jpg');
    is('a plugin-relative icon is not a URL and is untouched',
        $fit->('plugins/PitchforkReviews/html/images/x.png'),
        'plugins/PitchforkReviews/html/images/x.png');
    ok('undef survives (an unmatched row with no cover)', !defined $fit->(undef));
}

# The image-proxy handler: the width follows the spec actually being asked for.
{
    my $px  = \&Plugins::PitchforkReviews::Browse::pitchforkImageProxy;
    my $url = 'https://media.pitchfork.com/photos/abc/1:1/w_768,c_limit/a.jpg';

    is('a list thumbnail asks for 160',   ($px->($url, '_150x150_f') =~ m{/w_(\d+),})[0], '160');
    is('a grid tile asks for 320',        ($px->($url, '_300x300_f') =~ m{/w_(\d+),})[0], '320');
    is('a hi-dpi grid tile asks for 640', ($px->($url, '_600x600_f') =~ m{/w_(\d+),})[0], '640');
    is('a request larger than any bucket keeps the original width',
        ($px->($url, '_1200x1200_f') =~ m{/w_(\d+),})[0], '768');
    is('a spec naming no size is left alone', $px->($url, '.jpg'), $url);
    is('the rest of the URL is preserved',
        $px->($url, '_150x150_f'),
        'https://media.pitchfork.com/photos/abc/1:1/w_160,c_limit/a.jpg');
}

# ...and the row builder actually applies the cap.
{
    local $T::Prefs::P{group_by} = 'genre';
    my $row = Plugins::PitchforkReviews::Browse::_reviewRow(undef, {
        artist => 'A', album => 'B', date => '2026-08-01T00:00:00Z',
        cover  => 'https://media.pitchfork.com/photos/abc/1:1/w_768,c_limit/a.jpg',
        _album => {
            _svc   => 'Tidal',
            type   => 'playlist',
            _cover => 'https://resources.tidal.com/images/aa/bb/1280x1280.jpg',
        },
    }, 0);
    is('a matched row carries the capped service cover',
        $row->{image}, 'https://resources.tidal.com/images/aa/bb/640x640.jpg');

    my $un = Plugins::PitchforkReviews::Browse::_reviewRow(undef, {
        artist => 'A', album => 'B', date => '2026-08-01T00:00:00Z',
        cover  => 'https://resources.tidal.com/images/aa/bb/1280x1280.jpg',
    }, 0);
    is('an UNMATCHED row is capped too',
        $un->{image}, 'https://resources.tidal.com/images/aa/bb/640x640.jpg');
}

# ===========================================================================
# 4. Priority-first probing, the cache cap, and adapter memoisation
# ===========================================================================
# Scripted services, installed through _detectAdapters so the REAL _orderedAdapters
# (and therefore the real memoisation) is what runs. %SCRIPT is consulted per call,
# so the reply can change while the adapter list stays memoised — which is the point.
# %SCRIPT is a per-service QUEUE consumed call by call, which is right when the point
# is the ORDER of the legs. %BY_ALBUM is the other axis, added for section 15: keyed
# service -> normalised album -> matches, it answers on WHICH ALBUM is being resolved
# and so survives a resolve that fans out into several albums (a combined "A / B"
# review), where a positional queue would only encode the order they happened to run
# in. A missing key is a MISS, not an error — that is the whole shape of the
# combined-review problem. Both legs of one album get the same answer, so the
# album-title retry still runs and is still counted.
our (%SCRIPT, %BY_ALBUM, @QUERIES, $DETECTS);
{
    no warnings 'redefine';
    *Plugins::PitchforkReviews::Browse::_detectAdapters = sub {
        $DETECTS++;
        return map {
            my $name = $_;
            {   name      => $name,
                icon      => "icon-$name",
                query_enc => 'chars',
                run       => sub {
                    my (undef, $query, undef, $albumNorm, $svc, $collect) = @_;
                    push @QUERIES, { svc => $svc, query => $query, album => $albumNorm };
                    if (%BY_ALBUM) {
                        return $collect->($BY_ALBUM{$svc}{$albumNorm} || []);
                    }
                    my $plan = $SCRIPT{$svc} ||= [];
                    $collect->(shift @$plan);
                },
            };
        } qw(Qobuz Tidal Deezer);
    };
}

# These sections model a RUNNING server, where detection is trustworthy and therefore
# memoised. Plugin::postinitPlugin makes that call for real, after every plugin's
# initPlugin; before it, Browse deliberately re-detects on every ask (0.8.10).
Plugins::PitchforkReviews::Browse::markStartupComplete();

sub resolve {
    my (%o) = @_;
    @QUERIES = ();
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
    %SCRIPT = %{ $o{script} || {} };
    %BY_ALBUM = ();
    my $got;
    Plugins::PitchforkReviews::Browse::_findPlayable(undef, sub { $got = $_[0] }, $o{artist} // 'An Artist', $o{album} // 'An Album');
    return $got;
}
sub queriedSvcs { my %s; $s{$_->{svc}}++ for @QUERIES; return join(',', sort keys %s) }

$T::Prefs::P{svc_priority_qobuz}  = 1;
$T::Prefs::P{svc_priority_tidal}  = 2;
$T::Prefs::P{svc_priority_deezer} = 3;

{
    my $HIT = [ { name => 'match', image => 'c.jpg', _albumid => 1 } ];
    my $r = resolve(script => { Qobuz => [ $HIT ] });
    is('the top-priority service matched: nobody else is asked', queriedSvcs(), 'Qobuz');
    is('...and its match is the answer', $r->{items}[0]{name}, 'match');

    # A MISS on the top service brings the others in — in parallel, as before.
    resolve(script => { Qobuz => [ [], [] ], Tidal => [ [] ], Deezer => [ [] ] });
    is('a miss on the top service fans out to the rest', queriedSvcs(), 'Deezer,Qobuz,Tidal');

    # An INCONCLUSIVE top service (no handler / error) must fan out too, or a logged-out
    # first service would silently disable every other one.
    resolve(script => { Qobuz => [ undef ], Tidal => [ [] ], Deezer => [ [] ] });
    is('an inconclusive top service also fans out', queriedSvcs(), 'Deezer,Qobuz,Tidal');

    # ...and priority still decides among the services that DID run.
    my $r2 = resolve(script => {
        Qobuz  => [ [], [] ],
        Tidal  => [ [ { name => 'from tidal',  image => 'c.jpg' } ] ],
        Deezer => [ [ { name => 'from deezer', image => 'c.jpg' } ] ],
    });
    is('the higher-priority of the fanned-out services wins', $r2->{items}[0]{name}, 'from tidal');
}

# Matches are deduped and capped BEFORE they are cached, not only before display.
{
    my @many = map { { name => "edition $_", line2 => "$_", image => 'c.jpg', _albumid => $_ } } 1 .. 20;
    resolve(script => { Qobuz => [ \@many ] });
    my ($cached) = grep { /^pfr:stream:/ } keys %Plugins::PitchforkReviews::DB::KV;
    is('20 matches cache as STREAM_MAX_RESULTS',
        scalar @{ $Plugins::PitchforkReviews::DB::KV{$cached}{items} },
        Plugins::PitchforkReviews::Browse::STREAM_MAX_RESULTS());

    # Duplicates collapse first, so the cap is 12 distinct editions, not 12 rows.
    my @dupes = map { { name => 'same', line2 => 'x', image => 'c.jpg', _albumid => 1 } } 1 .. 20;
    resolve(script => { Qobuz => [ \@dupes ] });
    my ($k2) = grep { /^pfr:stream:/ } keys %Plugins::PitchforkReviews::DB::KV;
    is('twenty identical matches cache as one',
        scalar @{ $Plugins::PitchforkReviews::DB::KV{$k2}{items} }, 1);
}

# Adapter DETECTION is memoised for the life of the process (it cannot change without
# a restart), but the priority ORDER is not — a settings save must take effect on the
# next resolve, with no invalidation call to forget.
{
    my $before = $DETECTS;
    Plugins::PitchforkReviews::Browse::_orderedAdapters() for 1 .. 5;
    is('five lookups, no re-detection', $DETECTS, $before);

    $T::Prefs::P{svc_priority_tidal} = 0;                     # "never search Tidal"
    my @a = Plugins::PitchforkReviews::Browse::_orderedAdapters();
    is('disabling a service takes effect immediately',
        join(',', map { $_->{name} } @a), 'Qobuz,Deezer');
    is('...and the cache-key fragment follows it',
        Plugins::PitchforkReviews::Browse::_svcOrder(), 'qobuz,deezer');

    $T::Prefs::P{svc_priority_tidal} = 2;
    is('...and putting it back restores the order',
        Plugins::PitchforkReviews::Browse::_svcOrder(), 'qobuz,tidal,deezer');
    is('none of which re-detected anything', $DETECTS, $before);
}

# ===========================================================================
# 5. The pump does not recurse on a warm cache
# ===========================================================================
# _findPlayable answers a cache HIT synchronously, so the completion used to call the
# pump from inside the loop iteration that started it: one stack frame per item, with
# the whole feed build then running at the bottom of a 50-deep stack.
#
# Depth is the only observable — the feature works identically either way — so this
# measures it directly. The guard makes every item settle at the same depth; without
# it the depth climbs monotonically with the queue.
{
    my @depths;
    # Swapped out globally (the pump has to run against it across the whole block) and
    # put BACK at the end, or every later section silently tests this stub instead of
    # the real resolver.
    my $realFindPlayable = \&Plugins::PitchforkReviews::Browse::_findPlayable;
    {
        no warnings 'redefine';
        *Plugins::PitchforkReviews::Browse::_findPlayable = sub {
            my ($client, $cb) = @_;
            my $d = 0; $d++ while caller($d);
            push @depths, $d;
            $cb->({ items => [ { _svc => 'Qobuz', name => 'x' } ] });   # synchronous, like a cache hit
        };
    }

    my @items = map { { artist => "A$_", album => "B$_" } } 1 .. 40;
    my $built = 0;
    Plugins::PitchforkReviews::Browse::_resolveSection(undef, \@items, sub { $built = 1 });

    is('every item still resolved', scalar(@depths), 40);
    ok('...and every one got its album', !grep { !$_->{_album} } @items);
    is('the section still completes',    $built, 1);
    { no warnings 'redefine'; *Plugins::PitchforkReviews::Browse::_findPlayable = $realFindPlayable; }

    my ($min, $max) = ($depths[0], $depths[0]);
    for (@depths) { $min = $_ if $_ < $min; $max = $_ if $_ > $max }
    ok("the stack does not grow with the queue (depth $min..$max over 40 items)",
        ($max - $min) <= 1);
}

# ===========================================================================
# 6. The tuned constants, and the one cross-file invariant
# ===========================================================================
{
    is('BUILD_CONCURRENCY', Plugins::PitchforkReviews::Browse::BUILD_CONCURRENCY(), 10);
    is('BUILD_DEADLINE',    Plugins::PitchforkReviews::Browse::BUILD_DEADLINE(),    10);
    ok('the deadline is under Material\'s patience and over a single cold resolve (2.63s measured)',
        Plugins::PitchforkReviews::Browse::BUILD_DEADLINE() >= 8
     && Plugins::PitchforkReviews::Browse::BUILD_DEADLINE() <= 15);

    # Plugin.pm cannot be loaded here (it needs the whole LMS plugin tree), but the
    # warm cadence is only correct RELATIVE to the feed TTL: a warm slower than the
    # TTL leaves the cache expired for the rest of the interval, which is the exact
    # state 0.8.8 exists to remove. Read it out of the source and compare.
    open my $fh, '<', ($ENV{PFR_PLUGIN} || 'PitchforkReviews/Plugin.pm') or die $!;
    my $src = do { local $/; <$fh> };
    my ($warm) = $src =~ /WARM_INTERVAL\s*=>\s*([\d\s*]+?);/;
    my $secs = eval $warm;
    is('the warm interval matches API::FEED_TTL',
        $secs, Plugins::PitchforkReviews::API::FEED_TTL());
}

# ===========================================================================
# 7. The warm fetches in parallel and resolves one stage at a time
# ===========================================================================
# The warm chains its RESOLVE stages on _resolveSection's callback — but that callback
# fires at BUILD_DEADLINE with whatever has resolved by then, and the pump deliberately
# keeps going past it. Right for a VIEW, which has a render to get on screen; wrong
# here, where the callback is what STARTS THE NEXT STAGE. A cold 50-item stage takes
# ~13s (2.63s/album over 10 in flight), so every stage began on top of the one before
# it: measured 40 searches in flight against a BUILD_CONCURRENCY of 10, which is exactly
# the burst the sequencing exists to prevent. Hence WARM_DEADLINE — a backstop for a
# wedged stage, an order of magnitude past any real one, not a budget.
#
# THE FETCHES DO NOT SHARE THAT CONSTRAINT (0.9.18). Four HTTP GETs to one site are
# nothing next to four sections of streaming searches, and they hit a different upstream
# entirely, so they all go out at once ahead of the resolve phase. Both halves are
# asserted here: parallel fetch, serial resolve.
{
    my $LIST = 'https://pitchfork.com/reviews/albums/';
    my $BNM  = 'https://pitchfork.com/reviews/best/albums/';
    my $HSA  = 'https://pitchfork.com/reviews/best/high-scoring-albums/';
    my $YEAR = 'https://pitchfork.com/features/lists-and-guides/best-albums-2025/';

    # A listing with enough reviews on it for ONE stage to overflow BUILD_CONCURRENCY
    # by itself — the shared listingPage() carries a single review.
    my $listingPageN = sub {
        my ($n, $tag) = @_;
        my $state = JSON::PP::encode_json({ items => [ map { {
            contentType  => 'review',
            url          => "/reviews/albums/$tag-$_/",
            dangerousHed => "$tag Album $_",
            subHed       => { name => "$tag Artist $_" },
            dangerousDek => 'A capsule.',
            pubDate      => '2026-08-01T05:00:00.000Z',
            image        => { sources => { lg => { url => 'https://img/a.jpg', width => 768 } } },
            ratingValue  => { score => 8.0 },
            rubric       => [ { name => 'Rock' } ],
        } } 1 .. $n ] });
        return "<html><script>window.__PRELOADED_STATE__ = $state;</script></html>";
    };

    my $arm = sub {
        reset_all();
        $Slim::Networking::SimpleAsyncHTTP::ROUTES{$_->[0]} = $listingPageN->(12, $_->[1])
            for [$LIST,'Rev'], [$BNM,'Bnm'], [$HSA,'Hsa'];
        # A year page the real _parseYear reads 12 entries out of, so a single stage
        # can overflow BUILD_CONCURRENCY on its own.
        my @body;
        for my $i (1 .. 12) {
            push @body,
              [ 'inline-embed', { type => 'callout:inset-left' },
                { contentType => 'photo', sources => { hi => { url => "https://img/$i.jpg", width => 800 } } } ],
              [ 'div', { class => 'heading-h3' }, "$i." ],
              [ 'h2', "Artist $i: ", [ 'em', "Album $i" ] ],
              [ 'p', 'x' x 200 ];
        }
        $Slim::Networking::SimpleAsyncHTTP::ROUTES{$YEAR} =
            qq{<meta property="og:title" content="The 50 Best Albums of 2025">}
          . qq{<meta property="article:published_time" content="2025-12-02T14:00:00.000Z">}
          . '<script>window.__PRELOADED_STATE__ = '
          . JSON::PP::encode_json({ transformed => { article => { body => \@body } } })
          . ';</script>';
        $T::Prefs::P{year_promoted} = 2025;
        $T::Prefs::P{year_last}     = 2025;
        Plugins::PitchforkReviews::DB::kvSet('pfr:year:latest:4', 2025);
    };

    # Every search stays in flight, so "started" IS "still outstanding".
    $arm->();
    my $started = 0;
    my $getsAtFirstSearch;
    my @NEVER = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                   run => sub { $getsAtFirstSearch //= gets(); $started++ } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @NEVER };
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');
        # 0.9.10 — WIDE WHILE THE FOREGROUND IS IDLE, reversing 0.9.1's fixed narrow
        # width. 0.9.1 pinned the warm at WARM_CONCURRENCY so it would stop competing
        # with a browsing user, but the yield (section 10) already does that
        # COMPLETELY: it holds the queue rather than merely slowing it. So the narrow
        # width never protected anyone — it applied only when nobody was browsing,
        # which is precisely when the warm should be going flat out. Measured on a cold
        # start: 54s for the three feed lists at width 2, during all of which the
        # plugin looks empty to anyone who opens it.
        is('an idle-foreground warm runs at BUILD_CONCURRENCY, not the narrow width',
            $started, Plugins::PitchforkReviews::Browse::BUILD_CONCURRENCY());

        # Fire DEADLINE timers only: the window sits above the 8s per-service watchdogs
        # and below the 300s warm backstop, i.e. "the old 10s deadline elapsed while the
        # stage was still running".
        my $rounds = 0;
        while (Slim::Utils::Timers::fireWindow(9, 60) && $rounds++ < 40) { }
        is('...and nothing further was started on top of it',
            $started, Plugins::PitchforkReviews::Browse::BUILD_CONCURRENCY());
        # THE FETCHES ARE FRONT-LOADED (0.9.18), and this is where that is pinned.
        # It used to read `gets() == 1`: under the serial chain, stage 2's fetch WAS
        # stage 2, so one GET proved no later stage had begun. Fetch and resolve are
        # now separate phases, so the property is asserted directly instead — by
        # capturing the GET count at the moment the FIRST search goes out. All four
        # lists must already be in by then. `$started` above is what now carries the
        # "stages do not overlap" half.
        is('every list is fetched before the first search is issued',
            $getsAtFirstSearch, 4);
        is('...and no fetch is triggered by a stage starting', gets(), 4);
    }

    # ...and the chain still completes, in order, once searches answer.
    $arm->();
    my ($open, $peak) = (0, 0);
    my @qs;
    my @ANSWER = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                    run => sub { my (undef, $q, undef, undef, undef, $cb) = @_;
                                 push @qs, $q;
                                 $open++; $peak = $open if $open > $peak;
                                 $open--; $cb->([]); } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ANSWER };
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');

        # FETCH ORDER AND STAGE ORDER ARE NO LONGER THE SAME THING (0.9.18), so they are
        # asserted separately. The year is issued FIRST — it is two chained requests
        # (identify the year, then ask for its list) and it gates the LAST stage, so it
        # gets the head start and must never be the reason the three feeds wait.
        my @g = @Slim::Networking::SimpleAsyncHTTP::GETS;
        is('the year probe is issued first, while nothing else is running', $g[0], $YEAR);
        is('...then the three feeds, which are what gate the resolve phase',
            join('|', @g[1 .. 3]), join('|', $LIST, $BNM, $HSA));

        # ...and RESOLVING still goes feeds-first, year last. That ordering is the
        # user-facing half — the three sections a user opens are populated before the
        # year-end list — and it is now the only place it is visible, since the fetches
        # no longer run in stage order.
        my (%seenq, @stageOrder);
        for (@qs) {
            my ($tag) = /^(Rev|Bnm|Hsa)\b/ ? $1 : /^Artist \d/ ? 'year' : ();
            push @stageOrder, $tag if $tag && !$seenq{$tag}++;
        }
        is('the feeds resolve in stage order, and the year-end list last',
            join('|', @stageOrder), 'Rev|Bnm|Hsa|year');

        # THE WARM ENDS THERE (0.9.10). This is the headline property of the release
        # and it is asserted as an EXACT COUNT, not "and the rest are years": the
        # defect being pinned is extra work, so a test that tolerates trailing
        # fetches cannot see it. 0.9.0 put all ten year-end lists on this chain,
        # where they were 252 of the warm's 306 measured seconds — four minutes of
        # Qobuz traffic AFTER the plugin already had everything a user opens, and
        # every browse landing in that window fought it for the same API.
        is('the main warm chain stops once the plugin looks populated — nothing else',
            scalar(@g), 4);
        ok("...and concurrency stayed inside BUILD_CONCURRENCY ($peak)",
           $peak <= Plugins::PitchforkReviews::Browse::BUILD_CONCURRENCY());
    }

    is('WARM_DEADLINE is a backstop, well past any real stage',
        (Plugins::PitchforkReviews::Browse::WARM_DEADLINE()
            >= 10 * Plugins::PitchforkReviews::Browse::BUILD_DEADLINE()) ? 1 : 0, 1);

    # --- A LIST THAT DOES NOT LOAD COSTS ONE STAGE, NOT THE WARM (0.9.18).
    #
    # Under the serial chain a stage's fetch and its resolve were the SAME LINK, so a
    # dead page took every stage after it down with it. Separating the phases only helps
    # if a missing list is then treated as an ABSENT STAGE rather than as a reason to
    # stop — the failure mode this file has hit repeatedly in other guises (the %PENDING
    # strand, the no-player hole, the backfill guard).
    #
    # Each fixture list carries a distinguishable artist prefix, so which stages ran is
    # read back off the searches rather than inferred from a count.
    my $answerer = sub {
        my ($seen) = @_;
        return ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                  run  => sub { push @$seen, $_[1]; $_[5]->([]) } });
    };
    {
        $arm->();
        delete $Slim::Networking::SimpleAsyncHTTP::ROUTES{$BNM};   # -> 404
        my @seen;
        my @ANS = $answerer->(\@seen);
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ANS };
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');

        ok('a list that 404s does not stop Latest Reviews', scalar(grep { /^Rev Artist/ } @seen));
        ok('...nor High Scoring Albums, which came AFTER it',
           scalar(grep { /^Hsa Artist/ } @seen));
        ok('...nor the year-end list at the end of the chain',
           scalar(grep { /^Artist \d/ } @seen));
        ok('...and the dead stage resolves nothing, rather than resolving junk',
           !grep { /^Bnm Artist/ } @seen);
    }

    # --- THE YEAR-END LIST MUST NOT GATE THE THREE FEEDS (0.9.18).
    #
    # Kept as a test in its own right because it is the flaw the FIRST draft of the
    # fetch phase had, and it was caught by an unrelated section rather than reasoned
    # out: gating the resolve phase on all four fetches made the three sections a user
    # opens first wait behind the slowest and least urgent one. The year is two chained
    # requests — identify the newest published list, then ask for it, several candidate
    # slugs deep on a cold server — and it is the LAST stage, so waiting for it up front
    # buys nothing whatsoever.
    #
    # Needs the year to be genuinely outstanding while the feeds are in, which the
    # synchronous fixture cannot express on its own — hence DEFER and a held request.
    {
        $arm->();
        local $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;
        my @seen;
        my @ANS = $answerer->(\@seen);
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ANS };
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');

        my @held;
        for (1 .. 5) {
            my @q = @Slim::Networking::SimpleAsyncHTTP::PENDING;
            @Slim::Networking::SimpleAsyncHTTP::PENDING = ();
            last unless @q;
            push @held, grep { $_->{url} eq $YEAR } @q;
            Slim::Networking::SimpleAsyncHTTP::_answer($_->{self}, $_->{url})
                for grep { $_->{url} ne $YEAR } @q;
        }
        ok('the year-end list is genuinely still in flight', scalar(@held));
        ok('...and all three feeds resolved anyway',
           scalar(grep { /^Rev Artist/ } @seen) && scalar(grep { /^Bnm Artist/ } @seen)
           && scalar(grep { /^Hsa Artist/ } @seen));
        ok('...while the year itself has not', !grep { /^Artist \d/ } @seen);

        # ...and it is not DROPPED for being late: the feeds finished, so the chain is
        # sitting on a recheck timer waiting for exactly this.
        Slim::Networking::SimpleAsyncHTTP::_answer($_->{self}, $_->{url}) for @held;
        Slim::Utils::Timers::fireWindow(1,
            Plugins::PitchforkReviews::Browse::WARM_YEAR_RECHECK() + 1);
        ok('...the recheck picks it up once it lands',
           scalar(grep { /^Artist \d/ } @seen));
    }

    # --- ONE UNANSWERED FETCH MUST NOT HOLD THE WARM FOR EVER (0.9.18).
    #
    # The resolve phase waits on all four fetches, which is a new way for the warm to
    # stall that the serial chain did not have in this shape. WARM_FETCH_DEADLINE is the
    # answer, and a constant that nothing fires is not a safeguard — so this drives the
    # timer and checks the phase actually starts.
    {
        $arm->();
        local $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;
        my @seen;
        my @ANS = $answerer->(\@seen);
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ANS };
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');

        is('nothing resolves while the lists are still in flight', scalar(@seen), 0);

        # Answer everything EXCEPT High Scoring Albums, re-draining because the year is
        # two chained requests and only queues its list once the probe has answered.
        my @held;
        for (1 .. 5) {
            my @q = @Slim::Networking::SimpleAsyncHTTP::PENDING;
            @Slim::Networking::SimpleAsyncHTTP::PENDING = ();
            last unless @q;
            push @held, grep { $_->{url} eq $HSA } @q;
            Slim::Networking::SimpleAsyncHTTP::_answer($_->{self}, $_->{url})
                for grep { $_->{url} ne $HSA } @q;
        }
        is('one list still outstanding holds the whole resolve phase', scalar(@seen), 0);

        my $d = Plugins::PitchforkReviews::Browse::WARM_FETCH_DEADLINE();
        is('the deadline is armed, and is the only timer in its window',
            Slim::Utils::Timers::fireWindow($d - 5, $d + 5), 1);
        ok('...and firing it resolves the three lists that did arrive',
           scalar(grep { /^Rev Artist/ } @seen) && scalar(grep { /^Bnm Artist/ } @seen)
           && scalar(grep { /^Artist \d/ } @seen));
        ok('...without the one that never answered',
           !grep { /^Hsa Artist/ } @seen);

        # ANSWER THE ABANDONED FETCH BEFORE LEAVING, and this is not tidiness — it cost
        # a debugging session. API.pm's coalescing map is process-wide and a request that
        # never answers strands its key there for good (the risk its own comments call
        # out), so every LATER block's getHsa was silently adopted by this dead fetch and
        # never called back. Same class of fixture leak as the %RESOLVING slots
        # reset_all() clears, and the same reason: state that outlives the block.
        Slim::Networking::SimpleAsyncHTTP::_answer($_->{self}, $_->{url}) for @held;
    }

    # --- LOG TIERS (0.9.22) ---------------------------------------------------
    # Split by VOLUME, not importance. The milestones are how this plugin gets diagnosed
    # from a pasted log, so they must be readable with nothing switched on; the per-item
    # timeline is ~250 lines for one warm and buried them.
    #
    # Driven through warmCache and _searchQobuz, not by calling _dbg/_dbgv — the defect
    # this guards against is a call SITE left on the wrong tier, which a test of the two
    # helpers could never see.
    {
        my $capture = sub {
            my ($on) = @_;
            $arm->();
            my @lines;
            my @seen;
            my @A = $answerer->(\@seen);
            no warnings 'redefine';
            local *Plugins::PitchforkReviews::Plugin::dbg = sub { push @lines, $_[0] };
            local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @A };
            local $T::Prefs::P{debug_log} = $on;
            Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');
            my $delay  = Plugins::PitchforkReviews::Browse::YEAR_BACKFILL_DELAY();
            my $rounds = 0;
            while (Slim::Utils::Timers::fireWindow($delay - 5, $delay + 5) && $rounds++ < 40) { }
            return {
                milestones => scalar(grep { /^warm: /                                 } @lines),
                peritem    => scalar(grep { /^(resolve |search |combined review |year: picked)/ } @lines),
                fetched    => scalar(grep { /^warm: \d+ feed list\(s\) fetched/        } @lines),
                stages     => scalar(grep { /^warm: resolving \d+ /                    } @lines),
                done       => scalar(grep { /^warm: done/                              } @lines),
                backfill   => scalar(grep { /^warm: backfill(ing)? /                   } @lines),
                bfdone     => scalar(grep { /^warm: backfill done/                     } @lines),
            };
        };

        my $off = $capture->(0);
        my $on  = $capture->(1);

        # EVERY milestone is named individually, not counted. A bare "> 0" passes while a
        # single milestone quietly slips to the verbose tier — which is exactly the mistake
        # this tiering invites, and the first version of this test could not see it.
        is('with debug OFF the fetch phase still reports',       $off->{fetched},  1);
        is('...every resolve stage still reports (3 feeds + year)', $off->{stages}, 4);
        is('...the warm still reports done',                     $off->{done},     1);
        is('...the backfill still reports each year + its end',   $off->{backfill}, 10);
        is('...including its own completion',                    $off->{bfdone},   1);
        is('...and NOT one line of the per-item timeline',        $off->{peritem},  0);

        is('with debug ON the milestones are unchanged',
            join(',', @{$on}{qw(fetched stages done backfill bfdone)}),
            join(',', @{$off}{qw(fetched stages done backfill bfdone)}));
        ok("...and now the per-item timeline appears too ($on->{peritem} line(s))",
           $on->{peritem} > 0);

        # _dbgSearch is asserted at its real call site. NOTE what this does and does not
        # cover: it pins that nothing is EMITTED with the pref off. The early `return unless
        # _verbose()` inside _dbgSearch avoids building the string as well, and that is
        # deliberately NOT observable through output — removing it would still pass here.
        # Said plainly rather than left to look like coverage it isn't.
        for my $on (0, 1) {
            my @lines;
            no warnings 'redefine', 'once';
            local *Plugins::PitchforkReviews::Plugin::dbg = sub { push @lines, $_[0] };
            local *Plugins::Qobuz::Plugin::getAPIHandler = sub { bless {}, 'T::QobuzAPI2' };
            local *T::QobuzAPI2::search = sub { $_[1]->({ albums => { items => [] } }) };
            local $T::Prefs::P{debug_log} = $on;
            Plugins::PitchforkReviews::Browse->can('_searchQobuz')
                ->(undef, 'An Artist', 'an artist', 'an album', 'Qobuz', sub {}, 'An Album');
            is(($on ? 'a search logs its timing line with debug ON'
                    : 'a search logs NOTHING with debug OFF'),
                scalar(grep { /^search Qobuz/ } @lines), $on ? 1 : 0);
        }

        # Read live, not cached at load: a diagnostic switch is reached for WHILE something
        # is going wrong, so it must not need a restart.
        my $verbose = Plugins::PitchforkReviews::Browse->can('_verbose');
        local $T::Prefs::P{debug_log} = 0; is('_verbose tracks the pref (off)', $verbose->(), 0);
        local $T::Prefs::P{debug_log} = 1; is('...and flips without a reload', $verbose->(), 1);
    }

    # --- THE BACK CATALOGUE IS STILL WARMED — BEHIND THE USER-FACING WORK (0.9.10).
    #
    # 0.9.0's reasoning for prefetching every year was sound and is kept: the lists are
    # immutable, so warming them pays for ever, and a cold first open of an old year was
    # a measured 12s wait. What was wrong was the PLACEMENT — on the main chain, ahead
    # of nothing, consuming 252 of the warm's 306 seconds.
    #
    # So this block asserts the same coverage as before, but reached through
    # _backfillYears' timers instead of inline: every year back to YEAR_MIN, newest
    # first, on-screen year already done. If the backfill were dropped rather than
    # deferred, every assertion here fails — which is the point of keeping them.
    $arm->();

    # Every year 2016..2025 is prefetched. Each cached article carries a distinguishable
    # artist so the resolve order can be read back; the on-screen year (2025) is left
    # UNcached so it is the one article the warm legitimately fetches.
    dbFresh("year:$_", [ { artist => "Y$_", album => "A$_" } ])
        for 2016 .. 2024;

    my @seen;
    my ($yopen, $ypeak) = (0, 0);
    my @REC = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                 run => sub { push @seen, $_[1];
                              $yopen++; $ypeak = $yopen if $yopen > $ypeak; $yopen--;
                              $_[5]->([]); } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @REC };
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');

        # The main chain is done here; the back catalogue is behind one
        # YEAR_BACKFILL_DELAY timer per year, each armed by the previous one's
        # completion. Checked BEFORE draining, so "deferred" is a property under test
        # rather than something the drain hides.
        ok('the back catalogue has NOT run on the main chain',
           !grep { /^Y\d{4}$/ } @seen);

        my $delay  = Plugins::PitchforkReviews::Browse::YEAR_BACKFILL_DELAY();
        my $rounds = 0;
        while (Slim::Utils::Timers::fireWindow($delay - 5, $delay + 5) && $rounds++ < 40) { }
        ok("...and it drained once its timers fired ($rounds round(s))", $rounds >= 9);
    }

    my $idx = sub { my $w = shift; for my $i (0 .. $#seen) { return $i if $seen[$i] eq $w } return -1 };

    ok('EVERY year back to YEAR_MIN is backfilled, not just the opened ones',
       $idx->('Y2016') >= 0 && $idx->('Y2019') >= 0 && $idx->('Y2024') >= 0);
    ok('the on-screen year goes FIRST, before the back catalogue',
       $idx->('Artist 1') >= 0 && $idx->('Artist 1') < $idx->('Y2024'));
    ok('...and the rest follow NEWEST-first', $idx->('Y2024') < $idx->('Y2016'));

    # PEAK LOAD — prefetching ten years extends the warm's DURATION, not how much it
    # has in flight. That is what makes it safe on slow hardware, and it is the property
    # that dies first if the year stages are ever fired in parallel.
    #
    # Asserted against WARM_CONCURRENCY, not BUILD_CONCURRENCY (0.9.1). Against the
    # wider cap this could not fail for the reason it exists: a warm that ignored the
    # yield rule and ran at full view width would still have passed.
    ok("the chain stayed sequential ($ypeak in flight, cap "
       . Plugins::PitchforkReviews::Browse::WARM_CONCURRENCY() . ")",
       $ypeak <= Plugins::PitchforkReviews::Browse::WARM_CONCURRENCY());

    # Only the ONE uncached article is fetched; the nine cached years cost nothing.
    is('a cached year costs no page fetch (3 listings + the one uncached year)', gets(), 4);

    # --- THE "STILL LOADING" LABEL. Three states, and the last two are the ones that
    # would otherwise never clear: with no streaming service nothing can EVER resolve,
    # and an album on none of the services never resolves either. Counting matches alone
    # would leave both stuck reading "still loading" for ever, so pending is decided by
    # the RESOLVE CACHE (which holds an entry for anything already attempted, including
    # a confirmed no-match) rather than by whether a row ended up playable.
    {
        my $prog  = \&Plugins::PitchforkReviews::Browse::_matchProgress;
        my @items = map { { artist => "A$_", album => "B$_" } } 1 .. 3;
        my $keyof = sub {
            Plugins::PitchforkReviews::Browse::_streamKey(
                Plugins::PitchforkReviews::Browse::_streamId($_[0]{artist}, $_[0]{album}));
        };

        no warnings 'redefine';
        # Make the numbers assertable — the shared cstring stub returns the bare token.
        local *Plugins::PitchforkReviews::Browse::cstring = sub { '%s of %s matched - still loading' };

        {
            local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { () };
            is('with NO streaming service it never claims to be loading',
                $prog->(undef, \@items), ' (3)');
        }

        local *Plugins::PitchforkReviews::Browse::_orderedAdapters =
            sub { ({ name => 'Qobuz', priority => 1 }) };

        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        is('nothing attempted yet reads as still loading',
            $prog->(undef, \@items), ' (0 of 3 matched - still loading)');

        # One resolved and playable, two not yet tried.
        $items[0]{_album} = { _svc => 'Qobuz' };
        Plugins::PitchforkReviews::DB::kvSet($keyof->($items[0]), { items => [ {} ] });
        is('a partly-resolved list counts the matches',
            $prog->(undef, \@items), ' (1 of 3 matched - still loading)');

        # THE ONE THAT MUST CLEAR: the other two were tried and matched NOTHING. The
        # work is finished, so the label goes back to a plain count even though only
        # one row is playable.
        Plugins::PitchforkReviews::DB::kvSet($keyof->($items[$_]), { items => [] }) for 1, 2;
        is('once everything has been TRIED it stops saying loading, however few matched',
            $prog->(undef, \@items), ' (3)');
    }
}

# ---------------------------------------------------------------------------
# 8. Artwork sizing on the SERVICES' CDNs, and the closed-year TTL tier.
#
# Both exist because 0.8.8's optimisations were aimed one step to the side of the
# cost. The proxy handler sized media.pitchfork.com — but _reviewRow prefers the
# SERVICE's cover, so the handler only ever fired on rows that FAILED to match, and
# improving the matcher shrank its reach. And YEAR_TTL treated a finished year-end
# list as perishable, so an immutable article was re-fetched every 30 days.
# ---------------------------------------------------------------------------
{
    my $qz = \&Plugins::PitchforkReviews::Browse::qobuzImageProxy;
    my $td = \&Plugins::PitchforkReviews::Browse::tidalImageProxy;

    my $qurl = 'https://static.qobuz.com/images/covers/aa/bb/abc123_600.jpg';
    is('Qobuz: a list thumbnail drops to the 150 rung',
        $qz->($qurl, '_150x150_f'), 'https://static.qobuz.com/images/covers/aa/bb/abc123_150.jpg');
    is('Qobuz: a grid tile takes the next rung up that satisfies it',
        ($qz->($qurl, '_300x300_f') =~ m{_(\d+)\.jpg$})[0], '600');
    is('Qobuz: _max is a valid trailing form and is pulled back too',
        $qz->('https://static.qobuz.com/images/covers/aa/bb/abc123_max.jpg', '_150x150_f'),
        'https://static.qobuz.com/images/covers/aa/bb/abc123_150.jpg');
    is('Qobuz: a request past the top rung is left VERBATIM, never invented',
        $qz->($qurl, '_1200x1200_f'), $qurl);
    is('Qobuz: a spec naming no size is left alone', $qz->($qurl, '.jpg'), $qurl);

    my $turl = 'https://resources.tidal.com/images/aa/bb/1280x1280.jpg';
    is('Tidal: a list thumbnail drops to 320 (41KB, vs 563KB at 1280)',
        $td->($turl, '_150x150_f'), 'https://resources.tidal.com/images/aa/bb/320x320.jpg');
    is('Tidal: a grid tile still fits in 320',
        ($td->($turl, '_300x300_f') =~ m{/(\d+)x}) [0], '320');
    is('Tidal: a hi-dpi grid tile takes 640',
        ($td->($turl, '_600x600_f') =~ m{/(\d+)x}) [0], '640');
    is('Tidal: a request past the top rung is left VERBATIM',
        $td->($turl, '_2000x2000_f'), $turl);

    my $dz   = \&Plugins::PitchforkReviews::Browse::deezerImageProxy;
    my $durl = 'https://cdn-images.dzcdn.net/images/cover/abc123/500x500-000000-80-0-0.jpg';
    is('Deezer: a list thumbnail drops to 160 (6.2KB, vs 26.8KB at 500)',
        $dz->($durl, '_150x150_f'),
        'https://cdn-images.dzcdn.net/images/cover/abc123/160x160-000000-80-0-0.jpg');
    is('Deezer: a grid tile takes 320 (17.5KB)',
        ($dz->($durl, '_300x300_f') =~ m{/(\d+)x})[0], '320');
    is('Deezer: the background/quality/crop suffix is preserved untouched',
        ($dz->($durl, '_150x150_f') =~ m{(-[\d-]+\.jpg)$})[0], '-000000-80-0-0.jpg');
    is('Deezer: a spec naming no size is left alone', $dz->($durl, '.jpg'), $durl);

    # RULE 2, and the one that catches the mistake this section was written around:
    # a handler may only ever go DOWN. Deezer serves a 600 spec from its 500 source
    # today at 26,785 bytes; a ladder containing 640 would "satisfy" it properly at
    # 50,769 — a 90% regression on the very surface being optimised. Same for Tidal
    # at 1280. Asserted per service, at the spec where each would have bitten.
    is('Deezer: a hi-dpi grid tile is NOT enlarged past the source it already has',
        $dz->($durl, '_600x600_f'), $durl);
    is('Tidal: a large spec is NOT enlarged past the 640 _fitCover left',
        $td->('https://resources.tidal.com/images/aa/bb/640x640.jpg', '_1200x1200_f'),
        'https://resources.tidal.com/images/aa/bb/640x640.jpg');
    is('Qobuz: a large spec is NOT enlarged past _600',
        $qz->($qurl, '_1200x1200_f'), $qurl);

    # RULE 2 AGAIN, AND THIS IS THE HALF THE LADDER CAPS CANNOT ENFORCE. These handlers are
    # registered by CDN HOST, and ImageProxy matches on the URL rather than on which plugin
    # made the row — so every Qobuz/Tidal/Deezer cover on the server comes through here,
    # including rows PFR never authored, at sizes PFR never chose. A ladder top rung only
    # says "no bigger than OUR source"; it says nothing about a URL that already asks for
    # less than the spec, and those were being rewritten UP. The comparison has to be
    # against the width the URL actually carries.
    my $pf = \&Plugins::PitchforkReviews::Browse::pitchforkImageProxy;
    is('Tidal: an 80x80 row from ANOTHER plugin is not enlarged to meet a 300 spec',
        $td->('https://resources.tidal.com/images/aa/bb/80x80.jpg', '_300x300_f'),
        'https://resources.tidal.com/images/aa/bb/80x80.jpg');
    is('Qobuz: a _50 row from another plugin is not enlarged either',
        $qz->('https://static.qobuz.com/images/covers/aa/bb/abc123_50.jpg', '_300x300_f'),
        'https://static.qobuz.com/images/covers/aa/bb/abc123_50.jpg');
    is('Deezer: a 56x56 row from another plugin is left verbatim',
        $dz->('https://cdn-images.dzcdn.net/images/cover/abc123/56x56-000000-80-0-0.jpg', '_300x300_f'),
        'https://cdn-images.dzcdn.net/images/cover/abc123/56x56-000000-80-0-0.jpg');
    is('Pitchfork: a narrow w_ source is not widened to meet a bigger spec',
        $pf->('https://media.pitchfork.com/photos/aa/1:1/w_160,c_limit/x.jpg', '_300x300_f'),
        'https://media.pitchfork.com/photos/aa/1:1/w_160,c_limit/x.jpg');

    # A URL ALREADY AT the spec is a no-op too — not merely harmless, but right: it already
    # satisfies the request, and rewriting it to itself would only churn the proxy's cache.
    is('a source already at the target rung is returned unchanged',
        $td->('https://resources.tidal.com/images/aa/bb/320x320.jpg', '_300x300_f'),
        'https://resources.tidal.com/images/aa/bb/320x320.jpg');

    # THE OTHER HALF OF THE SAME RULE (0.9.24): A NON-SQUARE SOURCE IS NOT OURS TO RESHAPE.
    # The path carries two dimensions and the rungs are square, so the handler was capturing
    # the width and writing `${w}x${w}` — a 480x320 artist photo meeting a 150 spec became
    # 320x320, which Tidal does not serve. That is a 404 and NO picture, on the TIDAL
    # plugin's own artist and playlist views (album covers are square, which is why it
    # survived). _onlyDown cannot see it: 320 < 480 is a perfectly good shrink.
    #
    # Scaling the height proportionally is NOT the fix, for the same reason — 320x213 is no
    # more a real rendition than 320x320 (the real rung is 320x214). Anything we cannot name
    # from the ladder is left verbatim, which is _fitCover's rule since 0.8.8: a cover that
    # fails to shrink costs bandwidth, one mangled into a 404 costs the picture.
    is('Tidal: a NON-SQUARE source is returned byte-identical, never squared',
        $td->('https://resources.tidal.com/images/aa/bb/480x320.jpg', '_150x150_f'),
        'https://resources.tidal.com/images/aa/bb/480x320.jpg');
    is('Tidal: ...at a grid spec too — no size of request makes it ours to reshape',
        $td->('https://resources.tidal.com/images/aa/bb/750x500.jpg', '_300x300_f'),
        'https://resources.tidal.com/images/aa/bb/750x500.jpg');
    is('Deezer: a non-square source is left alone as well (distortion, not a 404)',
        $dz->('https://cdn-images.dzcdn.net/images/cover/abc123/500x300-000000-80-0-0.jpg', '_150x150_f'),
        'https://cdn-images.dzcdn.net/images/cover/abc123/500x300-000000-80-0-0.jpg');
    # _fitCover applies a SQUARE ceiling to our own rows and had the same latent shape.
    # Unreachable today (an album cover is square), asserted so it stays that way.
    is('_fitCover: a non-square Tidal URL is not squared by the 640 ceiling either',
        Plugins::PitchforkReviews::Browse::_fitCover('https://resources.tidal.com/images/aa/bb/1280x720.jpg'),
        'https://resources.tidal.com/images/aa/bb/1280x720.jpg');
    is('_fitCover: ...while a square one over the ceiling still comes down',
        Plugins::PitchforkReviews::Browse::_fitCover('https://resources.tidal.com/images/aa/bb/1280x1280.jpg'),
        'https://resources.tidal.com/images/aa/bb/640x640.jpg');

    # ...while everything the guard is NOT about still shrinks exactly as before. Asserted
    # here as well as above because the guard is one condition away from disabling the whole
    # feature, and a mistake in it would otherwise show up only as artwork getting slower.
    is('and a genuinely oversized source still comes DOWN',
        $td->($turl, '_150x150_f'), 'https://resources.tidal.com/images/aa/bb/320x320.jpg');

    # THE POINT OF THE WHOLE SECTION: the sizing must reach a MATCHED row, which is
    # the one that carries a service cover. This is the assertion that would have
    # failed against 0.8.8 and did not exist.
    my $spec = '_150x150_f';
    ok('a matched row\'s Tidal cover is now sized by the spec, not just capped at 640',
       $td->(Plugins::PitchforkReviews::Browse::_fitCover($turl), $spec)
           eq 'https://resources.tidal.com/images/aa/bb/320x320.jpg');
    ok('...and its Qobuz cover likewise',
       $qz->(Plugins::PitchforkReviews::Browse::_fitCover($qurl), $spec)
           eq 'https://static.qobuz.com/images/covers/aa/bb/abc123_150.jpg');

    # --- THE 30-DAY TTL CEILING. The single most expensive defect in this plugin's
    # history, and the one this suite failed to catch while appearing to cover it.
    #
    # Slim/Utils/DbCache.pm, _canonicalize_expiration_time (LMS 9.1), LMS's own comment:
    #
    #     # "If value is less than 60*60*24*30 (30 days), time is assumed to be
    #     # relative from the present. If larger, it's considered an absolute Unix time."
    #     if ( $expiry <= 2592000 && $expiry > -1 ) { $expiry += time(); }
    #
    # Over the boundary the value is an absolute epoch, so `90 * 86400` expires in
    # 1970-04-01 and every read returns undef — while `set` returns 1 and raises
    # nothing. Measured cost before the fix: a 4% resolve hit rate (was 97.6%), one
    # album resolved 8 times in a single warm pass, and five releases of misdiagnosis.
    #
    # 0.9.8 HAD a ceiling sweep here and it passed throughout, because the ceiling was
    # set to 90 days — a number taken from a hypothesis rather than from the source. A
    # guard with the wrong constant is worse than no guard: it reads as coverage. The
    # only defensible number is 2_592_000, and it is asserted literally below so that
    # changing it requires editing the number the LMS comment names.
    my $CEILING = 2_592_000;
    is('the ceiling is the value LMS actually uses, not one we chose', $CEILING, 30 * 86400);

    my @over;
    for my $pkg (qw(Plugins::PitchforkReviews::API Plugins::PitchforkReviews::Browse)) {
        no strict 'refs';
        for my $name (sort keys %{"${pkg}::"}) {
            next unless $name =~ /TTL/;
            my $sub = $pkg->can($name) or next;
            my $val = eval { $sub->() };
            next unless defined $val && $val =~ /^\d+$/;
            push @over, sprintf('%s=%.0fd', $name, $val / 86400) if $val > $CEILING;
        }
    }
    ok('NO TTL exceeds 30 days — over that, LMS never reads the entry back'
       . (@over ? ' — over: ' . join(', ', @over) : ''), !@over);

    # The sweep must be seeing something. A symbol-table walk that matches nothing
    # passes silently, which is the failure mode of the guard it replaces.
    my $seen = 0;
    for my $pkg (qw(Plugins::PitchforkReviews::API Plugins::PitchforkReviews::Browse)) {
        no strict 'refs';
        for my $name (keys %{"${pkg}::"}) {
            next unless $name =~ /TTL/;
            my $sub = $pkg->can($name) or next;
            my $val = eval { $sub->() };
            $seen++ if defined $val && $val =~ /^\d+$/;
        }
    }
    ok("the sweep actually inspected the constants ($seen found)", $seen >= 9);

    is('the resolve TTL specifically sits AT the ceiling, not over it',
        Plugins::PitchforkReviews::Browse::STREAM_FOUND_TTL(), $CEILING);

    ok('a found match outlives a week, so an immutable list stops re-resolving on a timer',
       Plugins::PitchforkReviews::Browse::STREAM_FOUND_TTL() > 7 * 86400);
}

# --- 10. THE VIEW MUST NOT BLOCK, AND THE WARM MUST GET OUT OF ITS WAY (0.9.1).
#
# Both properties here were shipped in 0.9.0 with NO test at all, and both failed in
# the field on the first install: "just 3 dots and a very long wait", "very laggy",
# "changed a year and got confronted with 3 dots only". The 25s VIEW_DEADLINE was
# reverted by hand and every suite still passed, which is how the gap was found.
{
    my $B = 'Plugins::PitchforkReviews::Browse';

    # Local fixture — the section-9 one is scoped to its own block. A Latest Reviews
    # page carrying more entries than BUILD_CONCURRENCY, so one stage can saturate.
    my $LIST = 'https://pitchfork.com/reviews/albums/';
    my $arm  = sub {
        reset_all();
        my $state = JSON::PP::encode_json({ items => [ map { {
            contentType  => 'review',
            url          => "/reviews/albums/rev-$_/",
            dangerousHed => "Album $_",
            subHed       => { name => "Artist $_" },
            dangerousDek => 'A capsule.',
            pubDate      => '2026-08-01T05:00:00.000Z',
            image        => { sources => { lg => { url => 'https://img/a.jpg', width => 768 } } },
            ratingValue  => { score => 8.0 },
            rubric       => [ { name => 'Rock' } ],
        } } 1 .. 12 ] });
        $Slim::Networking::SimpleAsyncHTTP::ROUTES{$LIST} =
            "<html><script>window.__PRELOADED_STATE__ = $state;</script></html>";
    };

    # THE DEADLINE. Asserted as a RELATIONSHIP as well as a value: a browse view may
    # never block longer than a home shelf, because the view is the one a human is
    # sitting in front of watching a placeholder. 0.9.0 had it at two and a half
    # times the shelf budget.
    # 0.9.12 INVERTS BOTH OF THESE, deliberately. The old pair asserted that a view
    # renders FAST and partial; the requirement now is that a user is never handed an
    # incomplete view, so VIEW_DEADLINE stops being a budget and becomes a backstop
    # nothing is expected to reach. 0.9.1's 5s was right for a world where the resolve
    # store discarded everything and so every open was fully cold; with it retaining,
    # the first open costs one cold pass and the rest are lookups.
    ok('VIEW_DEADLINE is long enough to COMPLETE a cold list, not merely to render one',
       $B->VIEW_DEADLINE() >= 30);
    ok('a view may block LONGER than a shelf — a shelf has a carousel it must fill, '
       . 'a view can afford to wait and be right',
       $B->VIEW_DEADLINE() > $B->BUILD_DEADLINE());
    ok('...and still clears the worst single item (four serial service timeouts)',
       $B->VIEW_DEADLINE() > 4 * $B->STREAM_SVC_TIMEOUT());

    # ...and it is the value fetchFeed actually passes. The constant alone proves
    # nothing: the bug was reachable only because the call site says VIEW_DEADLINE.
    $arm->();
    my $started = 0;
    my @held;
    my @HOLD = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                  run  => sub { $started++; push @held, $_[5] } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        my $rendered = 0;
        $B->can('fetchFeed')->(undef, sub { $rendered++ }, {},
                               { source => 'reviews', features => 'h' });
        is('a cold view holds while its searches are outstanding', $rendered, 0);

        # THE BACKSTOP IS NOT A DELAY. The view must answer the moment the last search
        # lands, not sit out the remaining 40-odd seconds — otherwise "wait for
        # complete" would make every warm open feel broken. Drained in a LOOP: the
        # fixture carries more items than BUILD_CONCURRENCY, so answering the first
        # batch lets the pump dispatch the rest.
        while (@held) { my @batch = splice @held; $_->([]) for @batch }
        is('...and answers as soon as everything settles, well inside the backstop',
            $rendered, 1);
        is('...having released its foreground count', $B->can('_fgInflight')->(), 0);
    }

    # ...AND THE BACKSTOP STILL EXISTS, for a section whose searches never settle.
    # Its own block, with its own timers: sharing the one above let the first
    # section's deadline fire into this assertion.
    reset_all(); $arm->();
    ($started, @held) = (0);
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        my $rendered = 0;
        $B->can('fetchFeed')->(undef, sub { $rendered++ }, {},
                               { source => 'reviews', features => 'h' });
        is('a view with nothing settling has not answered', $rendered, 0);
        Slim::Utils::Timers::fireWindow($B->VIEW_DEADLINE() - 2, $B->VIEW_DEADLINE() + 2);
        is('...and is released by the backstop', $rendered, 1);

        while (@held) { my @batch = splice @held; $_->([]) for @batch }

        # Drain before leaving: $FG_INFLIGHT is process-wide, so searches abandoned
        # here would still read as "a view is busy" in the yield test below. Draining
        # rather than zeroing a seam also asserts the thing that matters — that a
        # section which renders on its deadline still releases its count afterwards.
        while (@held) { my @batch = splice @held; $_->([]) for @batch }
        is('a view that rendered on its deadline still releases its count',
            $B->can('_fgInflight')->(), 0);
    }

    # THE YIELD. A view resolving keeps the full width; a warm that overlaps it must
    # start nothing at all. Against 0.9.0 this section ran 10 warm searches on top of
    # the view's 10 against the same streaming APIs.
    $arm->();
    ($started, @held) = (0);
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        my @items = map { { artist => "V$_", album => "W$_" } } 1 .. 12;
        $B->can('_resolveSection')->(undef, \@items, sub {}, $B->VIEW_DEADLINE());
        is('a view resolve dispatches at full BUILD_CONCURRENCY',
            $started, $B->BUILD_CONCURRENCY());
        is('...and those searches are counted as foreground in flight',
            $B->can('_fgInflight')->(), $B->BUILD_CONCURRENCY());

        my $fg = $started;
        Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client');
        is('the warm starts NOTHING while a view is resolving', $started, $fg);

        # A yielded warm is paused, not abandoned: draining the view and letting the
        # recheck timer fire must set it going again. Without this the fix would trade
        # the lag for a warm that never runs whenever anyone browses first.
        while (@held) { my @batch = splice @held; $_->([]) for @batch }
        is('the view drained', $B->can('_fgInflight')->(), 0);

        my $before = $started;
        Slim::Utils::Timers::fireWindow(1, $B->WARM_YIELD_RECHECK() + 1);
        ok('...and the warm resumes once the view is done', $started > $before);
    }

    ok('the warm runs narrower than a view, so it cannot crowd one out',
       $B->WARM_CONCURRENCY() < $B->BUILD_CONCURRENCY());

    # --- HOME SHELVES ARE A THIRD MODE (0.9.10), not "whatever isn't the warm".
    #
    # Measured on the 08:50 cold start: Material's home page fired three shelves, each
    # resolving 50 year-list albums at the full BUILD_CONCURRENCY against the same
    # Qobuz the user's Best New Music view was using — and the view got 20 of its 29
    # rows inside its deadline. The shelves were wide because the only distinction the
    # code had was warm/not-warm, and a shelf is not the warm.
    #
    # Two properties, and the second is the less obvious one: a shelf must NOT count
    # toward $FG_INFLIGHT. If it did, opening the Material home page would look like a
    # browsing user to the warm, and the warm would stand down for the whole time the
    # home page is on screen — suppressing the very thing that makes shelves instant.
    $arm->();
    ($started, @held) = (0);
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        my @items = map { { artist => "S$_", album => "T$_" } } 1 .. 12;
        $B->can('_resolveSection')->(undef, \@items, sub {}, $B->BUILD_DEADLINE(), 'shelf');
        is('an unopposed shelf dispatches at FULL width, so the carousel fills',
            $started, $B->BUILD_CONCURRENCY());
        is('...and a shelf is NOT counted as foreground, so it cannot mute the warm',
            $B->can('_fgInflight')->(), 0);

        while (@held) { my @batch = splice @held; $_->([]) for @batch }
    }

    # ...AND NARROWS THE MOMENT A VIEW IS RESOLVING. This is the half 0.9.11 got right
    # and 0.9.12 must not lose: a shelf runs wide because the home page is usually the
    # only thing happening, not because it outranks a view someone is watching.
    reset_all(); $arm->();
    ($started, @held) = (0);
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        # A view first, held open so $FG_INFLIGHT stays up.
        my @v = map { { artist => "V$_", album => "W$_" } } 1 .. 12;
        $B->can('_resolveSection')->(undef, \@v, sub {}, $B->VIEW_DEADLINE());
        my $viewStarted = $started;
        ok('the view took the full width', $viewStarted == $B->BUILD_CONCURRENCY());

        my @s = map { { artist => "S$_", album => "T$_" } } 1 .. 12;
        $B->can('_resolveSection')->(undef, \@s, sub {}, $B->BUILD_DEADLINE(), 'shelf');
        is('a shelf overlapping a view narrows instead of competing',
            $started - $viewStarted, $B->WARM_CONCURRENCY());

        while (@held) { my @batch = splice @held; $_->([]) for @batch }
    }

    # ...AND IT IS THE MODE THE SHELVES ACTUALLY PASS. The two assertions above go
    # through _resolveSection directly, so they hold whatever the shelves do — the
    # same gap this file already calls out for VIEW_DEADLINE ("the constant alone
    # proves nothing"). Reverting homeReviews to the default mode has to fail something.
    # (homeReviews, not homeBnm: this section's fixture arms only the reviews listing.)
    $arm->();
    ($started, @held) = (0);
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        $B->can('homeReviews')->(undef, sub {}, {});
        is('a home shelf dispatches at full width when nothing opposes it',
            $started, $B->BUILD_CONCURRENCY());
        is('...and registers no foreground load at all',
            $B->can('_fgInflight')->(), 0);

        while (@held) { my @batch = splice @held; $_->([]) for @batch }
    }

    # --- A WARM THAT COULD NOT START IS NOT A TICK THAT HAS BEEN SERVED (0.9.10).
    #
    # warmCache needs a connected player for the streaming-service API context. It used
    # to return bare when there wasn't one, and Plugin::_warmTick could not tell that
    # from success — so it re-armed at WARM_INTERVAL and the warm silently did not
    # happen for three hours (a full day before WARM_INTERVAL came down). Never seen on
    # a server whose players are always up; a fresh install on a machine that boots
    # faster than its player connects is exactly where it bites, which is the install
    # this release is about.
    #
    # Pinned here as the RETURN CONTRACT, because that is the seam Plugin.pm's retry
    # branch reads. (_warmTick's own arithmetic is not unit-tested: Plugin.pm cannot
    # load in this harness.)
    $arm->();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };
        local *Slim::Player::Client::clients = sub { () };
        ok('warmCache reports FALSE when no player is connected, so the caller retries',
           !Plugins::PitchforkReviews::Browse::warmCache());
    }
    $arm->();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };
        ok('...and TRUE once it actually starts',
           Plugins::PitchforkReviews::Browse::warmCache(bless {}, 'T::Client') ? 1 : 0);
    }

    # --- A KEY-VERSION BUMP RETIRES ITS OWN OLD ROWS (0.9.11).
    #
    # Before this, the version was inlined in the key string, so bumping it left the
    # entire previous family in the store until every row aged out — unreachable (no
    # code would ever build those keys again) but occupying the table for a full
    # STREAM_FOUND_TTL. Invisible unless you went looking, which is why it survived the
    # move to the DB.
    my $DB = 'Plugins::PitchforkReviews::DB';
    $DB->can('kvReset')->();
    $DB->can('kvSet')->($B->STREAM_KEY_PREFIX() . "11:qobuz:album $_", { items => [] })
        for 1 .. 5;
    $DB->can('kvSet')->('pfr:year:latest:4', 2025);
    $DB->can('kvSet')->('pfr:streamkeyver', 11);

    # THROUGH markStartupComplete, not by calling the sub directly: the defect being
    # pinned is that startup performs the retirement at all, and a direct call would
    # pass just as happily with it unwired.
    $B->can('markStartupComplete')->();
    ok('a version bump drops every row of the old family',
       !grep { index($_, $B->STREAM_KEY_PREFIX()) == 0 } keys %Plugins::PitchforkReviews::DB::KV);
    is('...and leaves unrelated keys alone',
        $DB->can('kvGet')->('pfr:year:latest:4'), 2025);
    is('...and records the new version',
        $DB->can('kvGet')->('pfr:streamkeyver'), $B->STREAM_KEY_VERSION());

    # A NO-OP when the version has not moved — this runs on every startup, so it must
    # not throw away a warm resolve table each time the server restarts.
    $DB->can('kvSet')->($B->STREAM_KEY_PREFIX() . $B->STREAM_KEY_VERSION() . ':q:a', { items => [] });
    my $before = $DB->can('kvCount')->();
    $B->can('markStartupComplete')->();
    is('an unchanged version retires nothing', $DB->can('kvCount')->(), $before);
    ok('...and the current family survives',
       defined $DB->can('kvGet')->($B->STREAM_KEY_PREFIX() . $B->STREAM_KEY_VERSION() . ':q:a'));
}

# ===========================================================================
# 11. THE REFRESH ROW STILL WORKS ON THE DB SCHEMA (0.9.11)
#
# Every view carries a Refresh row, and all of them reach storage through `force => 1`.
# The move off Slim::Utils::Cache changed what that has to bypass — a stored LIST in
# list_item, and a negative marker that is now a kv row — so "force still forces" is a
# fresh claim on this schema, not one inherited from the cache era.
#
# The subtle half is the OPPOSITE property: force must bypass the stored copy for the
# READ THAT DECIDES, while still loading it, so that a refresh which FAILS leaves the
# view populated instead of blanking it. Both directions are asserted.
# ===========================================================================
{
    my $YEAR2 = 'https://pitchfork.com/features/lists-and-guides/best-albums-2019/';
    my $yearPage = sub {
        my ($artist) = @_;
        my @body;
        for my $i (1 .. 3) {
            push @body,
              [ 'div', { class => 'heading-h3' }, "$i." ],
              [ 'h2', "$artist $i: ", [ 'em', "Album $i" ] ],
              [ 'p', 'x' x 200 ];
        }
        return qq{<meta property="og:title" content="The 50 Best Albums of 2019">}
             . qq{<meta property="article:published_time" content="2019-12-02T14:00:00.000Z">}
             . '<script>window.__PRELOADED_STATE__ = '
             . JSON::PP::encode_json({ transformed => { article => { body => \@body } } })
             . ';</script>';
    };

    # --- A CLOSED YEAR: stored for ever, so Refresh is the ONLY way to re-pull it.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$YEAR2} = $yearPage->('New');
    dbFresh('year:2019', [ { artist => 'Old', album => 'Stored' } ]);

    my $plain;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $plain = $_[0] });
    is('without force a stored year is served from the DB', $plain->[0]{artist}, 'Old');
    is('...with no fetch at all', gets(), 0);

    my $forced;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $forced = $_[0] }, force => 1);
    ok('Refresh on a year list re-fetches past the stored copy', gets() >= 1);
    is('...and returns the NEW parse', $forced->[0]{artist}, 'New 1');
    is('...and the DB now holds it', dbGet('year:2019')->[0]{artist}, 'New 1');

    # --- A FAILED REFRESH MUST NOT EMPTY THE VIEW. This is why getYearList reads
    # $stored even under force.
    reset_all();
    dbFresh('year:2019', [ { artist => 'Old', album => 'Stored' } ]);   # no route armed
    my $failed = 'unset';
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $failed = $_[0] }, force => 1);
    ok('a refresh that fetches nothing still answers with the stored list',
       ref $failed eq 'ARRAY' && @$failed && $failed->[0]{artist} eq 'Old');
    my $stillThere = dbGet('year:2019');
    ok('...and the stored list survives the failed refresh',
       $stillThere && @$stillThere && $stillThere->[0]{artist} eq 'Old');

    # --- REFRESH ON A FEED. Same contract, different storage path (_fetchState).
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Rebuilt');
    dbFresh($KEY, [ { album => 'Stored', artist => 'A' } ]);
    my $feed;
    Plugins::PitchforkReviews::API::getListing(sub { $feed = $_[0] }, force => 1);
    is('Refresh on a feed re-fetches past a FRESH stored copy', $feed->[0]{album}, 'Rebuilt');
    is('...and the DB is rewritten', dbGet($KEY)->[0]{album}, 'Rebuilt');

    # --- REFRESH STREAMING MATCH. _findPlayable's $force skips the kv READ but must
    # still WRITE, or the row it just corrected is re-resolved on every open.
    reset_all();
    my $B = 'Plugins::PitchforkReviews::Browse';
    my $skey = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Record'));
    Plugins::PitchforkReviews::DB::kvSet($skey, { items => [ { _svc => 'Qobuz', name => 'STALE' } ] });

    my $ran = 0;
    my @HIT = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                 run => sub { $ran++; $_[5]->([ { title => 'Record', artist => 'Band',
                                                  id => 9, image => 'https://i/c.jpg' } ]) } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HIT };

        my $cached;
        $B->can('_findPlayable')->(undef, sub { $cached = $_[0] }, 'Band', 'Record');
        is('without force the stored match is used, no search', $ran, 0);

        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record', 1);
        ok('Refresh streaming match skips the stored row and searches', $ran > 0);
        my $after = Plugins::PitchforkReviews::DB::kvGet($skey);
        ok('...and the re-resolved answer is written back, not just returned',
           $after && ref $after->{items} eq 'ARRAY'
                  && !grep { ($_->{name} // '') eq 'STALE' } @{ $after->{items} });
    }
}

# ===========================================================================
# 12. A REVIEW THAT LANDS BEFORE THE RELEASE DOES (0.9.11)
#
# Pitchfork frequently reviews an album days or weeks ahead of it appearing on Qobuz /
# Tidal / Deezer. The row is therefore legitimately unplayable when first resolved, and
# the plugin's job is to NOTICE when that changes — on a warm run, without the user
# doing anything.
#
# The whole mechanism is one constant. A confirmed "not on any service" is recorded
# under STREAM_NOMATCH_TTL so it stops being re-searched every few minutes; when that
# entry lapses the next warm searches again and picks the album up. Store it under
# STREAM_FOUND_TTL by mistake and the failure is silent and month-long: the review sits
# permanently unplayable while the album is sitting on Qobuz. Nothing asserted this.
# ===========================================================================
{
    my $B  = 'Plugins::PitchforkReviews::Browse';
    my $DB = 'Plugins::PitchforkReviews::DB';

    # The relationships the design rests on, stated as relationships rather than values
    # so that retuning any of them keeps them coherent.
    ok('a no-match is held far more briefly than a match',
       $B->STREAM_NOMATCH_TTL() < $B->STREAM_FOUND_TTL());
    ok('...and no longer than a day, so a daily warm always re-checks',
       $B->STREAM_NOMATCH_TTL() <= 86400);
    ok('an INCONCLUSIVE probe is retried sooner still than a confirmed no-match',
       $B->STREAM_INCONCLUSIVE_TTL() < $B->STREAM_NOMATCH_TTL());

    reset_all();
    my $key = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Unreleased'));

    # --- Day 0: reviewed, not yet on any service.
    my $searches = 0;
    my @NONE = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                  run  => sub { $searches++; $_[5]->([]) } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @NONE };
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Unreleased');
        ok('the unreleased album was searched for', $searches > 0);
        ok('...and the no-match is RECORDED, not left absent',
           defined $DB->can('kvGet')->($key));
        is('...under the short no-match TTL, never the 30-day found TTL',
            kvTtlFor($key), $B->STREAM_NOMATCH_TTL());

        # ...and while it stands, the warm does not re-search it every tick.
        my $before = $searches;
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Unreleased');
        is('a standing no-match suppresses re-searching on the next warm',
            $searches, $before);
    }

    # --- The TTL lapses (kvGet drops an expired row and answers absent), and by now
    # the album has been released.
    $DB->can('kvDel')->($key);

    my @NOW = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                 run  => sub { $_[5]->([ { title => 'Unreleased', artist => 'Band',
                                           id => 7, image => 'https://i/c.jpg' } ]) } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @NOW };
        my $res;
        $B->can('_findPlayable')->(undef, sub { $res = $_[0] }, 'Band', 'Unreleased');
        ok('once the no-match lapses the release IS picked up',
           $res && grep { ($_->{_svc} // '') } @{ $res->{items} || [] });
        is('...and it is now held under the FOUND TTL, so it stops being re-searched',
            kvTtlFor($key), $B->STREAM_FOUND_TTL());
    }
}

# ===========================================================================
# 13. IN-FLIGHT COALESCING (0.9.12)
#
# Measured on the live server: Material re-requested the year-end shelf NINE times in
# six minutes, each request starting its own resolve over the same 50 albums, with the
# same album searched twice inside 40ms. The stored-answer check cannot prevent that —
# a concurrent resolve has not written yet — so a second caller must WAIT on the first.
#
# The risk this introduces is a strand: a slot claimed and never released takes that
# album down for the life of the process. This file has been bitten by that shape three
# times (API.pm's %PENDING, the backfill guard, the no-player hole), so the age bound is
# asserted here as hard as the coalescing itself.
# ===========================================================================
{
    my $B = 'Plugins::PitchforkReviews::Browse';
    reset_all();

    my $searches = 0;
    my @held;
    my @HOLD2 = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                   run  => sub { $searches++; push @held, $_[5] } });
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };

        my @answers;
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        is('the first caller issues the search', $searches, 1);
        is('...and is registered as in flight', $B->can('_resolvingCount')->(), 1);

        # Four more callers for the SAME album while it is still outstanding.
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record')
            for 1 .. 4;
        is('four more callers issue NO further searches', $searches, 1);
        is('...and none has been answered yet', scalar(@answers), 0);

        # A DIFFERENT album is unaffected.
        $B->can('_findPlayable')->(undef, sub {}, 'Other', 'Thing');
        is('a different album still searches', $searches, 2);

        # Answer the first search: everyone waiting is served from it.
        my $cb = shift @held;
        $cb->([ { title => 'Record', artist => 'Band', id => 3, image => 'https://i/c.jpg' } ]);
        is('every waiter is answered from the one search', scalar(@answers), 5);
        ok('...each with a real match',
           5 == grep { $_ && grep { $_->{_svc} } @{ $_->{items} || [] } } @answers);

        # Each caller gets its OWN list — a caller may mutate what it is handed.
        ok('...and not the same arrayref shared between them',
           $answers[0]{items} != $answers[1]{items});

        ok('the slot is released once answered', $B->can('_resolvingCount')->() < 2);
    }

    # --- $force NEVER JOINS. The Refresh-match row exists to escape a stale answer, so
    # attaching it to an in-flight resolve would hand it the very thing it is escaping.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record');
        is('a resolve is in flight', $searches, 1);
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record', 1);
        is('a FORCED resolve searches anyway rather than joining', $searches, 2);
    }

    # --- A WEDGED SLOT MUST NOT BE PERMANENT. Age the claim past RESOLVE_JOIN_MAX and
    # the next caller starts fresh instead of waiting on something that will never
    # answer. Without this, one strand disables that album until the server restarts.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record');
        is('the slot is claimed', $searches, 1);

        my $key = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Record'));
        $B->can('_ageResolvingSlot')->($key, $B->RESOLVE_JOIN_MAX() + 5);

        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record');
        is('a slot older than RESOLVE_JOIN_MAX is replaced, not joined', $searches, 2);
    }

    # --- REPLACING A WEDGED SLOT MUST NOT BIN ITS WAITERS. Everything above only asserts
    # that the REPLACEMENT searches; the callers already queued on the dead claim were
    # dropped on the floor, and in _resolveSection such a callback is the ONLY thing that
    # decrements $active/$done/$FG_INFLIGHT. One dropped from a view strands the count for
    # the life of the process — and since $FG_INFLIGHT is tested for TRUTH, a single strand
    # is enough to leave the warm yielding between two-item bursts and every home shelf
    # pinned narrow for ever.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };

        my @answers;
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record')
            for 1 .. 3;
        is('three callers are waiting on the claim', $searches, 1);

        my $key = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Record'));
        $B->can('_ageResolvingSlot')->($key, $B->RESOLVE_JOIN_MAX() + 5);

        # The replacement search, which the three waiters must move across to.
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        is('the wedged slot is replaced', $searches, 2);
        is('...and nobody has been answered yet', scalar(@answers), 0);

        # Answer the REPLACEMENT. Everyone is served: the three adopted waiters, the
        # caller that replaced the slot, and the original owner's own callback is the one
        # thing still outstanding (its search never answers — that is what wedged means).
        my $replacement = $held[1];
        $replacement->([ { title => 'Record', artist => 'Band', id => 9, image => 'https://i/c.jpg' } ]);
        is('every waiter adopted from the wedged slot is answered', scalar(@answers), 4);
        ok('...each with a real match',
           4 == grep { $_ && grep { $_->{_svc} } @{ $_->{items} || [] } } @answers);
        ok('...and not one shared arrayref between them',
           $answers[0]{items} != $answers[1]{items});
        is('the replacement released its own slot', $B->can('_resolvingCount')->(), 0);

        # THE ORPHANED OWNER, arriving late. It SHOULD answer its own caller — that one has
        # been waiting since the beginning — but it must not delete a slot it no longer
        # owns, nor publish this abandoned search's answer to the waiters queued on the
        # slot that replaced it. Set that situation up exactly: a fresh claim with a waiter
        # on it, and the old owner finishing underneath.
        Plugins::PitchforkReviews::DB::kvReset();   # or the fresh calls are served the stored answer
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        is('a fresh resolve claims the key again', $B->can('_resolvingCount')->(), 1);

        my $before = scalar @answers;
        $held[0]->([ { title => 'Record', artist => 'Band', id => 1, image => 'https://i/c.jpg' } ]);
        is('the orphaned owner answers its OWN caller and nobody else',
            scalar(@answers), $before + 1);
        is('...and leaves the new claim standing, waiter and all',
            $B->can('_resolvingCount')->(), 1);
    }

    # --- AND NOW THE DAMAGE ITSELF, through _resolveSection rather than _findPlayable.
    # Everything above proves the waiters are called; this proves what calling them is FOR.
    # The callback a view queues is the only thing that decrements $FG_INFLIGHT, so a
    # dropped one strands the count — and because the count is tested for TRUTH, not
    # compared against a width, ONE strand is enough to leave the warm yielding
    # WARM_YIELD_MAX between two-item bursts and every home shelf pinned narrow for the
    # life of the process. Driven end to end because a unit test of _findPlayable cannot
    # see it: the leak is in the caller's bookkeeping, not in the resolver.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };

        is('the foreground count starts clean', $B->can('_fgInflight')->(), 0);

        # A warm claims the album first...
        $B->can('_resolveSection')->(undef, [ { artist => 'Band', album => 'Record' } ],
            sub {}, $B->WARM_DEADLINE(), 'warm');
        is('the warm claimed it', $searches, 1);

        # ...then a VIEW asks for the same album and joins that claim rather than
        # searching again. This is the state the whole coalescing feature creates.
        $B->can('_resolveSection')->(undef, [ { artist => 'Band', album => 'Record' } ],
            sub {}, $B->VIEW_DEADLINE(), 'view');
        is('the view joined it instead of searching', $searches, 1);
        is('...and a human is now counted as waiting', $B->can('_fgInflight')->(), 1);

        # The warm's search wedges. Someone asks again, which replaces the slot — and the
        # view's callback is sitting on the slot being replaced.
        my $key = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Record'));
        $B->can('_ageResolvingSlot')->($key, $B->RESOLVE_JOIN_MAX() + 5);
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record');
        is('the wedged slot is replaced', $searches, 2);

        $held[1]->([ { title => 'Record', artist => 'Band', id => 5, image => 'https://i/c.jpg' } ]);
        is('answering the REPLACEMENT drains the view\'s foreground count',
            $B->can('_fgInflight')->(), 0);
    }

    # --- THE ADOPTED WAITERS SURVIVE A CACHE HIT. A wedged slot is at least
    # RESOLVE_JOIN_MAX old, which is ample time for another resolve of the same album to
    # have stored the answer — so the early return on a stored answer is a LIKELY exit for
    # the replacing caller, not a corner, and returning through it without the waiters
    # re-drops exactly what adopting them just rescued.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };
        # _rebuildStreamItems reattaches the browse coderef by service and DROPS any item
        # whose service can't supply one — so without this the stored row never survives
        # the read and the assertions below would be measuring the no-match placeholder.
        local *Plugins::Qobuz::Plugin::QobuzGetTracks = sub { };

        my @answers;
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record')
            for 1 .. 2;

        my $key = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Record'));
        $B->can('_ageResolvingSlot')->($key, $B->RESOLVE_JOIN_MAX() + 5);

        # Somebody else's resolve landed the answer while this slot sat wedged.
        Plugins::PitchforkReviews::DB::kvSet($key,
            { items => [ { name => 'stored', _svc => 'Qobuz', _albumid => 7 } ] }, 100);

        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        is('the stored answer is served without a search', $searches, 1);
        is('...to the replacing caller AND the two it adopted', scalar(@answers), 3);
        ok('...every one of them a real match',
           3 == grep { $_ && grep { $_->{_svc} } @{ $_->{items} || [] } } @answers);
        ok('...with their own arrayrefs', $answers[0]{items} != $answers[1]{items});
        is('and nothing is left claimed', $B->can('_resolvingCount')->(), 0);
    }

    # --- A DIE ON THE WAY TO THE ANSWER MUST NOT WEDGE THE KEY. This is where the wedged
    # slots the whole join-max mechanism exists to survive most plausibly come from, rather
    # than from a service that never calls back: DB::kvSet dies outright on a character
    # string where it wants octets (the fleet-wide chars-vs-octets trap), and it used to run
    # BELOW the slot release with $resolved already latched at 1 — so every later $finish
    # returned early and the claim was held for the life of the process.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD2 };

        my @answers;
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { push @answers, $_[0] }, 'Band', 'Record');

        my $hit = [ { title => 'Record', artist => 'Band', id => 3, image => 'https://i/c.jpg' } ];
        {
            local *Plugins::PitchforkReviews::DB::kvSet = sub { die "cannot use a character string\n" };
            eval { $held[0]->($hit); 1 };
            is('a failed cache write does not cost the caller its answer', scalar(@answers), 2);
            is('...and does not strand the claim', $B->can('_resolvingCount')->(), 0);
        }

        # The same property one step further along: the log line runs _matchExactness
        # eagerly, and that sits between the release and the callbacks. A die there costs
        # this resolve its answer — bounded, one item — but must still leave the KEY usable,
        # which is the damage that would otherwise be permanent and global.
        reset_all();
        $searches = 0; @held = ();
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record');
        {
            local *Plugins::PitchforkReviews::Browse::_matchExactness = sub { die "boom\n" };
            eval { $held[0]->($hit); 1 };
        }
        is('a die between the release and the answer still frees the key',
            $B->can('_resolvingCount')->(), 0);
        # The join check runs BEFORE the stored-answer check, so a caller arriving at a
        # wedged claim inside RESOLVE_JOIN_MAX queues on it and is never answered at all —
        # which is precisely how a dropped callback strands $FG_INFLIGHT. Being answered
        # here is the proof the key came back clean.
        my $later;
        $B->can('_findPlayable')->(undef, sub { $later = $_[0] }, 'Band', 'Record');
        ok('...so a later caller is ANSWERED rather than joining a dead claim',
            defined $later);
    }
}

# ===========================================================================
# 14. THE QOBUZ SEARCH IS CAPPED (0.9.16)
#
# Qobuz was the only adapter calling out uncapped — Tidal and Deezer have always passed
# limit => 50 — and its own default is 200 (QOBUZ_DEFAULT_LIMIT, verified in the
# plugin's API.pm). Measured cold: 308 searches pulled 33,585 album objects to use 316,
# 0.94%, with 40% returning the full 200 rows.
#
# The size is sized from the `at=` instrumentation, not copied from the sibling plugin:
# across a full cold run the deepest first-match sat at position 40, median 1. So 50
# keeps 100% of observed matches with a 10-row margin, and anything tighter starts
# trading matches for bytes.
#
# Asserted at the CALL SITE by capturing what _searchQobuz actually hands the API — the
# constant alone proves nothing, which is the gap this file already documents for
# VIEW_DEADLINE and which caught two of this session's tests.
{
    my $B = 'Plugins::PitchforkReviews::Browse';

    ok('the cap clears the deepest match observed in the field (40), with margin',
       $B->QOBUZ_SEARCH_LIMIT() >= 50);

    my @sent;
    {
        no warnings 'redefine', 'once';
        local *Plugins::Qobuz::Plugin::getAPIHandler = sub { bless {}, 'T::QobuzAPI' };
        local *T::QobuzAPI::search = sub {
            my ($self, $cb, $query, $type, $args) = @_;
            push @sent, { query => $query, type => $type, args => $args };
            $cb->({ albums => { items => [] } });
        };
        $B->can('_searchQobuz')->(undef, 'Some Artist', 'some artist', 'some album',
                                  'Qobuz', sub {}, 'Some Album');
    }

    is('_searchQobuz issued exactly one search', scalar(@sent), 1);
    is('...for albums', $sent[0]{type}, 'albums');
    ok('...and PASSED AN ARGS HASH — the parameter Qobuz was never given before',
       ref $sent[0]{args} eq 'HASH');
    is('...carrying the cap, so Qobuz stops defaulting to 200 rows',
        $sent[0]{args}{limit}, $B->QOBUZ_SEARCH_LIMIT());
}

# ===========================================================================
# 15. COMBINED "A / B" REVIEWS (0.9.17)
#
# Pitchfork gives two releases issued as a pair ONE review, titled "A / B" —
# Adrianne Lenker's `songs / instrumentals`. No service carries an album under the
# joint name, so both legs of all three services miss and the row can never play.
# Observed live: `search Qobuz/albums raw=200 kept=0 q=Adrianne Lenker`, then the
# album-title retry failing on Qobuz, Tidal and Deezer in turn.
#
# WHAT MUST NOT REGRESS is bigger than what must start working: every ordinary
# title, and every genuine title that merely contains a slash, has to resolve
# EXACTLY as before and issue exactly the same searches. Hence the full title is
# tried first and the split is reachable only from a path that already failed —
# asserted here by search COUNT, not just by the answer.
{
    my $B = 'Plugins::PitchforkReviews::Browse';
    my $split  = $B->can('_splitAlbumTitles');
    my $nsplit = sub { my ($p) = $split->(@_); return scalar @{ $p || [] } };
    my $strict = sub { my (undef, $r) = $split->(@_); return $r ? 1 : 0 };

    # --- what does and does not split ------------------------------------------
    is('an ordinary title does not split',      $nsplit->('Bright Future'),  0);
    is('a space-padded pair splits',            $nsplit->('songs / instrumentals'), 2);
    is('...into the two sides',
        join('|', @{ ($split->('songs / instrumentals'))[0] }), 'songs|instrumentals');
    is('a three-sided padded title still splits', $nsplit->('aa / bb / cc'),    3);
    is('a four-sided one is a list, not a pair',  $nsplit->('aa / bb / cc / dd'), 0);
    is('a side too short to be a title is refused', $nsplit->('songs / x'),  0);
    is('a trailing separator does not make an empty query',
        $nsplit->('songs / '), 0);
    is('undef is not a combined title',         $nsplit->(undef),            0);

    # --- UNPADDED SLASHES SPLIT TOO, BUT ARE NOT TRUSTED ON ONE SIDE (0.9.19).
    # Pitchfork wrote Yaeji's two 2017 releases as 'EP/EP2', with no spaces, so a
    # padded-only rule left that review permanently unplayable. Unpadded is
    # indistinguishable in SHAPE from AC/DC and 24/7, so it splits and then demands that
    # every side resolve — corroboration replacing the padding as the safety margin.
    is('an unpadded pair splits as well',       $nsplit->('EP/EP2'),         2);
    is('...into its two sides',
        join('|', @{ ($split->('EP/EP2'))[0] }), 'EP|EP2');
    is('...and is flagged as needing an EXACT title per side', $strict->('EP/EP2'),       1);
    is('while a padded one accepts a loose match',   $strict->('songs / instrumentals'), 0);

    is('AC/DC Live splits, and is where the flag earns its keep', $nsplit->('AC/DC Live'), 2);
    is('...under the strict rule, so a fragment cannot carry it',
        $strict->('AC/DC Live'), 1);
    is('a bare S/T is refused outright — a one-character side',   $nsplit->('S/T'),   0);
    is('...as is a bare 24/7',                                   $nsplit->('24/7'),  0);
    # Unpadded is capped at EXACTLY two sides, where padded allows three: three unpadded
    # slashes is far likelier a date or a stylisation than a genuine trio, and each side
    # is another full resolve spent on a guess.
    is('an unpadded THREE-sider is refused, though padded three is allowed',
        $nsplit->('aa/bb/cc'), 0);
    is('...and a padded three-sider still splits',  $nsplit->('aa / bb / cc'), 3);
    is('a date-shaped title is refused too',        $nsplit->('1/2/3/4'),      0);

    # --- BOTH SPELLINGS IN ONE TITLE (0.9.24). Padding is a property of the SEPARATOR,
    # not of the title, and deciding it per title while splitting on every slash is a
    # silent wrong-album bug: `AC/DC / Live at Donington` contains ' / ', so it was
    # classified padded and then split on the unpadded slash too, giving three sides —
    # inside TITLE_SPLIT_MAX, so accepted. Padded splits trust a LOOSE side (0.9.21), and
    # `_albumMatches` admits 'AC' to a service title of "AC/DC Live" through
    # `index($t, "ac ") == 0`. The row played a record the review is not about, with no
    # error anywhere. The artist guard cannot reach it: it compares the WHOLE normalised
    # title, and 'ac dc live at donington' is not 'ac dc'.
    {
        my $mixed = 'AC/DC / Live at Donington';
        is('a title carrying BOTH spellings splits only on the padded one',
            $nsplit->($mixed), 2);
        is('...so the unpadded slash survives inside its side',
            join('|', @{ ($split->($mixed))[0] }), 'AC/DC|Live at Donington');
        is('...and it is still judged as a padded split, which may accept a loose side',
            $strict->($mixed), 0);
        # The consequence, stated as the property rather than as the sides: no side is the
        # bare fragment that could win a loose prefix match against the wrong album.
        ok('...and no side normalises to the bare fragment that mismatched',
           !grep { Plugins::PitchforkReviews::Browse::_norm($_) eq 'ac' }
                 @{ ($split->($mixed))[0] });
        # Same shape with the artist supplied — the guard above is not what saves this.
        is('...the artist being known does not change it either',
            $nsplit->($mixed, 'AC/DC'), 2);
    }

    # A title that IS the artist's name is never split. Mirrors _findPlayable skipping
    # its album leg for a self-titled record, and is the one case where 'AC' and 'DC'
    # would both be searched against the band most likely to match them.
    is('an album titled with the artist name is never split',
        $nsplit->('AC/DC', 'AC/DC'), 0);
    is('...and the artist is only consulted when it is given',
        $nsplit->('AC/DC'), 2);

    # --- an ordinary review is untouched ---------------------------------------
    # Both the answer AND the traffic: a split that fired here would be invisible in
    # the items and paid on every album in the plugin.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'bright future' => [ { name => 'Bright Future', image => 'c.jpg', _albumid => 7 } ] },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Adrianne Lenker', 'Bright Future');
        is('an ordinary title matches as it always did', $got->{items}[0]{name}, 'Bright Future');
        is('...on exactly one search', scalar(@QUERIES), 1);
        ok('...and is not tagged as a side', !defined $got->{items}[0]{_side});
    }

    # --- a title that CONTAINS " / " and is real ------------------------------
    # The whole title is tried FIRST, so a genuine slashed album never gets split.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'songs instrumentals' => [ { name => 'songs / instrumentals', image => 'c.jpg', _albumid => 9 } ] },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Adrianne Lenker', 'songs / instrumentals');
        is('a real slashed album matches whole', $got->{items}[0]{name}, 'songs / instrumentals');
        is('...and NO side search is ever issued', scalar(@QUERIES), 1);
    }

    # --- the actual case ------------------------------------------------------
    my $combined = sub {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => {
                'songs'         => [ { name => 'songs',         image => 'a.jpg', _albumid => 11 } ],
                'instrumentals' => [ { name => 'instrumentals', image => 'b.jpg', _albumid => 12 } ],
            },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Adrianne Lenker', 'songs / instrumentals');
        return $got;
    };
    {
        my $got = $combined->();
        my @m = grep { $_->{_svc} } @{ $got->{items} };
        is('the combined review that never resolved now returns both albums', scalar(@m), 2);
        is('...the FIRST being the review\'s first side', $m[0]{name}, 'songs');
        is('...and the second its second', $m[1]{name}, 'instrumentals');
        is('each carries the side it came from',
            join(',', map { $_->{_side} } @m), '0,1');
        is('...and Pitchfork\'s title for that side',
            join('|', map { $_->{_sidetitle} } @m), 'songs|instrumentals');
    }

    # Each side resolves under its OWN stream key, so the cache/coalescing/Refresh
    # machinery applies to it unchanged — three keys, not one composite.
    {
        $combined->();
        my @keys = grep { /^pfr:stream:/ } keys %Plugins::PitchforkReviews::DB::KV;
        is('the whole title and both sides each cache separately', scalar(@keys), 3);
    }

    # THE CAP MUST NOT EAT THE SECOND ALBUM. Side A can legitimately return a dozen
    # editions; appending side B behind them would push it past STREAM_MAX_RESULTS and
    # silently delete the very album this section exists to surface.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => {
                'songs'         => [ map { { name => "songs (edition $_)", line2 => $_, image => 'a.jpg', _albumid => $_ } } 1 .. 20 ],
                'instrumentals' => [ { name => 'instrumentals', image => 'b.jpg', _albumid => 99 } ],
            },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Adrianne Lenker', 'songs / instrumentals');
        my @m = grep { $_->{_svc} } @{ $got->{items} };
        is('the answer is still capped', scalar(@m), $B->STREAM_MAX_RESULTS());
        is('...led by the first side', $m[0]{name}, 'songs (edition 1)');
        ok('...but the second album SURVIVES the cap',
           scalar(grep { $_->{name} eq 'instrumentals' } @m));
    }

    # --- THE EXACTNESS PROBE (0.9.20 dry run) ---------------------------------
    # Instrumentation only — it decides nothing. But its OUTPUT is about to be used to
    # judge whether exact-per-side should replace all-or-nothing, so its semantics are
    # pinned here first: a reading taken with an unverified probe is worse than no
    # reading, because it looks like evidence.
    #
    # The claim under test is that _albumMatches can only admit a bogus fragment through
    # a LOOSER tier, never as an exact title. Both sides of that are asserted against the
    # real shapes from the field log.
    {
        my $ex = $B->can('_matchExactness');

        is('a service title equal to ours reads as exact',
            $ex->('EP2', { _svctitle => 'EP2' }), 'exact');
        is('...case and punctuation fold, as _norm does',
            $ex->('songs', { _svctitle => 'Songs' }), 'exact');
        is('a fragment that only PREFIXES the service title reads as loose',
            $ex->('AC', { _svctitle => 'AC/DC Live' }), 'loose');
        is('...which is exactly how _albumMatches admitted it (index($t,"ac ")==0)',
            $ex->('24', { _svctitle => '24 Hours' }), 'loose');
        is('an ep/lp-strip match is loose, not exact',
            $ex->('Songs From a Valley Girl EP', { _svctitle => 'Songs From a Valley Girl' }),
            'loose');
        is('a service that gave no title is reported, not guessed at',
            $ex->('EP2', { _svctitle => '' }), 'exactness=none');
        is('...and neither is a non-item',
            $ex->('EP2', undef), 'exactness=?');
    }

    # --- the unpadded case, end to end ----------------------------------------
    # These are THE decision, so every one is driven through _findPlayableReview and the
    # service titles are set deliberately: `_svctitle` is what exactness reads, so a
    # fixture that omitted it would be testing nothing.
    my $side = sub {
        my ($svctitle, $id) = @_;
        return { name => $svctitle, _svctitle => $svctitle, image => 'a.jpg', _albumid => $id };
    };

    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'ep' => [ $side->('EP', 21) ], 'ep2' => [ $side->('EP2', 22) ] },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Yaeji', 'EP/EP2');
        my @m = grep { $_->{_svc} } @{ $got->{items} };
        is('an unpadded pair with both sides exact resolves to both', scalar(@m), 2);
        is('...first side first', $m[0]{name}, 'EP');
    }

    # THE FIELD CASE (0.9.21). Yaeji's *EP2* matched exactly while *EP* was unfindable —
    # `q=EP` returns raw=0 on Qobuz. All-or-nothing discarded the pair and left the review
    # unplayable; exactness keeps the half that is genuinely right.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'ep2' => [ $side->('EP2', 22) ] },      # 'ep' finds nothing at all
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Yaeji', 'EP/EP2');
        my @m = grep { $_->{_svc} } @{ $got->{items} };
        is('ONE exact side is enough — the case all-or-nothing lost', scalar(@m), 1);
        is('...and it is the side that actually matched', $m[0]{name}, 'EP2');
    }

    # ...while a side that matched only LOOSELY is still dropped. This is AC/DC Live: the
    # matcher's space-delimited prefix rule genuinely returns an album for 'AC', and
    # trusting it would silently play the wrong record — worse than no match.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'ac' => [ $side->('AC/DC Live', 31) ] },   # prefix hit, not exact
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Some Band', 'AC/DC Live');
        ok('a loose-only unpadded side is dropped, not trusted',
           !grep { $_->{_svc} } @{ $got->{items} });
        is('...and the row reports no match, exactly as before any of this',
            $got->{items}[0]{name}, 'PLUGIN_PITCHFORKREVIEWS_NO_MATCH');
    }

    # A BRACKETED EDITION IS ALREADY EXACT, because _norm strips parenthesised content —
    # verified, not assumed: _norm('EP2 (Deluxe Edition)') is 'ep2'. That is the right
    # behaviour (a deluxe edition IS the album) and it means the exactness rule does not
    # quietly reject remasters. Asserted so a future _norm change cannot silently break it.
    is('a bracketed edition still reads as exact',
        $B->can('_matchExactness')->('EP2', { _svctitle => 'EP2 (Deluxe Edition)' }), 'exact');
    is('...while an UNbracketed suffix does not',
        $B->can('_matchExactness')->('EP2', { _svctitle => 'EP2 Remixes' }), 'loose');

    # So the real "exact sits behind loose" case is an unbracketed suffix returned first —
    # the search surfacing a remix album ahead of the record itself. The side must survive,
    # and the exact node must LEAD, because the row takes the first.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'ep2' => [ $side->('EP2 Remixes', 51), $side->('EP2', 52) ] },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Yaeji', 'EP/EP2');
        my @m = grep { $_->{_svc} } @{ $got->{items} };
        ok('a side whose exact match is not first still counts', scalar(@m));
        is('...and the exact one is promoted to lead the side', $m[0]{name}, 'EP2');
    }

    # A SERVICE THAT GAVE NO TITLE DROPS THE SIDE. All three adapters stash `_svctitle`
    # today, so this is unreachable in production — but the rule has to decide something,
    # and "no evidence" must fall on the safe side rather than be read as agreement.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'ep2' => [ { name => 'EP2', image => 'a.jpg', _albumid => 61 } ] },
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, 'Yaeji', 'EP/EP2');
        ok('an unpadded side with no service title is dropped, not assumed exact',
           !grep { $_->{_svc} } @{ $got->{items} });
    }

    # The PADDED spelling is deliberately NOT tightened: on the field run exact-per-side
    # and all-or-nothing agreed on 'songs / instrumentals', so this would be risk with no
    # gain. A loose single side still carries a padded split.
    {
        @QUERIES = ();
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => { 'songs' => [ $side->('Songs From the Sessions', 41) ] },   # loose
        );
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] },
            'Adrianne Lenker', 'songs / instrumentals');
        is('a PADDED split still accepts one LOOSE side out of two',
            scalar(grep { $_->{_svc} } @{ $got->{items} }), 1);
    }

    # --- and what the browse list does with it --------------------------------
    # Driven through _resolveSection, not by calling the resolver and assembling the
    # row by hand: the row's _album/_alt split is decided in the pump's callback, and
    # a test that set them itself would pass with the change reverted.
    {
        Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
        %SCRIPT = (); %BY_ALBUM = (
            Qobuz => {
                'songs'         => [ { name => 'songs',         image => 'a.jpg', _albumid => 11, type => 'playlist' } ],
                # Shaped like a DEEZER album node: a direct `play` URL alongside the
                # browse coderef. That is what makes the alt dangerous to inject into a
                # playable container, so the fixture has to carry it or the strip below
                # is asserted against a node that never had anything to strip.
                'instrumentals' => [ { name => 'instrumentals', image => 'b.jpg', _albumid => 12, type => 'playlist',
                                       play => 'deezer://album:12', on_select => 'play',
                                       url  => sub { $_[1]->({ items => [ { name => 'inst track', type => 'audio' } ] }) } } ],
                'bright future' => [ { name => 'Bright Future', image => 'c.jpg', _albumid => 7,  type => 'playlist' },
                                     { name => 'Bright Future (Deluxe)', line2 => 'd', image => 'c.jpg', _albumid => 8, type => 'playlist' } ],
            },
        );
        my @items = (
            { artist => 'Adrianne Lenker', album => 'songs / instrumentals' },
            { artist => 'Adrianne Lenker', album => 'Bright Future' },
        );
        $B->can('_resolveSection')->(undef, \@items, sub {}, $B->VIEW_DEADLINE());

        is('the combined row is playable as its FIRST release', $items[0]{_album}{name}, 'songs');
        is('...and carries the other one alongside', scalar @{ $items[0]{_alt} || [] }, 1);
        is('...which is the second release', $items[0]{_alt}[0]{name}, 'instrumentals');

        # An ordinary album's extra EDITIONS are alternatives to the SAME record, not
        # other releases — they must never become "also covered by this review".
        is('an ordinary row is unchanged', $items[1]{_album}{name}, 'Bright Future');
        ok('...and has no alt album, despite two matches', !$items[1]{_alt});

        # The drill-in. A matched row drills into the matched album's TRACKLIST, so
        # this is the ONLY route to the second album from a browse list — reviewDetail
        # is reachable only from rows that did NOT match.
        local $T::Prefs::P{group_by} = 'genre';
        $items[0]{link}    = 'https://pitchfork.com/x';
        $items[0]{capsule} = 'A capsule.';
        $items[0]{_album}{url} = sub { $_[1]->({ items => [ { name => 'track 1', type => 'audio' } ] }) };
        my $row = $B->can('_reviewRow')->(undef, $items[0], 0);

        is('the row itself stays the review', $row->{name}, 'Adrianne Lenker - songs / instrumentals');
        is('...and stays playable', $row->{type}, 'playlist');

        my $drill;
        $row->{url}->(undef, sub { $drill = $_[0] });
        my @names = map { $_->{name} // '' } @{ $drill->{items} };
        ok('the drill-in reaches the second album',
           scalar(grep { $_ eq 'Adrianne Lenker - instrumentals' } @names));
        my ($alt) = grep { ($_->{name} // '') eq 'Adrianne Lenker - instrumentals' } @{ $drill->{items} };
        # cstring is stubbed to echo its token, so this asserts the string is LOOKED UP
        # (and named correctly) rather than hardcoded English in the row builder.
        is('...labelled as part of the same review',
            $alt->{line2}, 'PLUGIN_PITCHFORKREVIEWS_ALSO_REVIEWED');
        is('...and still a container that drills into its own tracks', $alt->{type}, 'playlist');
        ok('...reachable through its own url', ref $alt->{url} eq 'CODE');

        # THE INJECTED ITEMS MUST ALL BE NON-AUDIO — the invariant _attachReviewLink's
        # header states, and what keeps Play/Add on the review row acting on the album the
        # row represents. An alt carrying a direct `play` would let a Play on side A queue
        # side B's album alongside it.
        ok('no injected item carries a direct play URL',
           !grep { $_->{play} } @{ $drill->{items} });
        ok('...nor a playlist url, nor on_select',
           !grep { $_->{playlist} || $_->{on_select} } @{ $drill->{items} });
        ok('...and the resolver\'s own cached node is left alone',
           $items[0]{_alt}[0]{play} eq 'deezer://album:12');

        ok('...while the first album\'s tracks are still there',
           scalar(grep { $_ eq 'track 1' } @names));
        ok('...and the review link too',
           scalar(grep { ($_->{weblink} // '') eq 'https://pitchfork.com/x' } @{ $drill->{items} }));
    }

    %BY_ALBUM = ();
}

# ===========================================================================
# 16. A FAILING FEED IS NOT RE-DOWNLOADED FOR EVER (0.9.24)
#
# A feed's freshness comes from `stored_at`, and that moves only when putList runs — i.e.
# only on a parse of >= 1 item. Every other outcome answers from the stored rows and
# writes nothing, so the moment a feed starts failing its age is past FEED_TTL
# PERMANENTLY: every view open and every warm tick re-issues the full ~1-2MB listing
# download, for as long as the fault lasts, with nothing in the log after the first
# warning. Coalescing bounds the CONCURRENT count, not the rate.
#
# The year path has had the answer since 0.8.9 (YEAR_MISS_TTL); the feed path never got
# the equivalent. Note the gate here is deliberately NOT conditioned on `!$stored` the way
# the year path's read was — any server that has ever fetched successfully HAS stored rows,
# so that condition would ship the whole thing inert. That is asserted below.
# ===========================================================================
{
    my $MISS = "pfr:feedmiss:$KEY";

    # --- THE HTTP FAILURE. No route armed, so the fetch 404s.
    reset_all();
    dbStale($KEY, [ { album => 'Stored', artist => 'A' } ]);

    my $first;
    Plugins::PitchforkReviews::API::getListing(sub { $first = $_[0][0]{album} });
    is('a failing feed still answers from the stored copy', $first, 'Stored');
    is('...having tried exactly one fetch', gets(), 1);
    ok('...and it records the failure as a SEPARATE kv marker', Plugins::PitchforkReviews::DB::kvGet($MISS));
    is('...held for FEED_MISS_TTL', kvTtlFor($MISS), Plugins::PitchforkReviews::API::FEED_MISS_TTL());
    # A SEPARATE key, per the rule the year path states at its own miss write: a failure
    # must never overwrite the good copy the view is reading.
    is('...and the stored list is untouched', dbGet($KEY)->[0]{album}, 'Stored');

    # THE PROPERTY: the second open inside the marker's life issues NO fetch, and still
    # answers. This is the one that fails if the gate carries the year path's `!$stored`.
    my $second;
    Plugins::PitchforkReviews::API::getListing(sub { $second = $_[0][0]{album} });
    is('a second open inside the marker issues NO fetch', gets(), 1);
    is('...and is still answered from the stored list', $second, 'Stored');

    # The warm uses nostale => 1, so it takes a different branch of _shareFetch and would
    # be the obvious place for the suppression to leak — it is the caller that fires every
    # 3h for ever, so it is the one that matters most.
    Plugins::PitchforkReviews::API::getListing(sub { }, nostale => 1);
    is('...and the WARM does not fetch through it either', gets(), 1);

    # Refresh must always be an immediate live retry — the marker is not something the
    # user can be stuck behind.
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Rebuilt');
    my $forced;
    Plugins::PitchforkReviews::API::getListing(sub { $forced = $_[0][0]{album} }, force => 1);
    is('force fetches straight through the marker', gets(), 2);
    is('...and returns the live parse', $forced, 'Rebuilt');
    ok('...and a good fetch clears the marker', !Plugins::PitchforkReviews::DB::kvGet($MISS));

    # --- ONCE IT LAPSES, fetching resumes. A marker that could not lapse would be the
    # frozen feed of 0.8.9 in a new costume, which is the failure this must not become.
    reset_all();
    dbStale($KEY, [ { album => 'Stored', artist => 'A' } ]);
    Plugins::PitchforkReviews::API::getListing(sub { });
    Plugins::PitchforkReviews::DB::kvDel($MISS);                 # the hour passes
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Recovered');
    my $after;
    Plugins::PitchforkReviews::API::getListing(sub { $after = $_[0][0]{album} });
    is('once the marker lapses the fetch resumes', gets(), 2);
    is('...and the feed picks up again', dbGet($KEY)->[0]{album}, 'Recovered');

    # --- A 0-ITEM PARSE is the other failure shape, and it is the one a Pitchfork layout
    # change produces: a 200 response that yields nothing. Same treatment.
    reset_all();
    dbStale($KEY, [ { album => 'Stored', artist => 'A' } ]);
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} =
        '<html><script>window.__PRELOADED_STATE__ = {"items":[]};</script></html>';
    my $empty;
    Plugins::PitchforkReviews::API::getListing(sub { $empty = $_[0] });
    ok('a 200 that parses 0 items answers from the stored list',
       ref $empty eq 'ARRAY' && @$empty && $empty->[0]{album} eq 'Stored');
    ok('...and is marked too, so a layout change does not become a download loop',
       Plugins::PitchforkReviews::DB::kvGet($MISS));
    Plugins::PitchforkReviews::API::getListing(sub { });
    is('...suppressing the next open', gets(), 1);
    is('...with the stored list still in place', dbGet($KEY)->[0]{album}, 'Stored');

    # --- A FRESH INSTALL HAS NOTHING TO SERVE, and the marker must not cost it an hour.
    # The gate above is deliberately not conditioned on `$stored` (that condition is what
    # shipped the year path's marker inert, and it is anti-tested below) — so with nothing
    # stored, one transient failure would answer this section `[]` for a full hour with no
    # retry: the warm passes `nostale`, not `force`, so it hits the same gate. The marker
    # still stands, for a minute rather than an hour.
    reset_all();
    my $blank;
    Plugins::PitchforkReviews::API::getListing(sub { $blank = $_[0] });
    ok('a fresh install with a failing feed answers empty', ref $blank eq 'ARRAY' && !@$blank);
    ok('...and still marks, so a 0-item parse cannot become a download loop',
       Plugins::PitchforkReviews::DB::kvGet($MISS));
    is('...but only for FEED_MISS_EMPTY_TTL, not the full hour',
       kvTtlFor($MISS), Plugins::PitchforkReviews::API::FEED_MISS_EMPTY_TTL());
    ok('...which is far shorter than the stored-rows tier',
       Plugins::PitchforkReviews::API::FEED_MISS_EMPTY_TTL()
         < Plugins::PitchforkReviews::API::FEED_MISS_TTL());
    is('...and the second open inside it still issues no fetch', do {
        Plugins::PitchforkReviews::API::getListing(sub { }); gets() }, 1);

    # ...and once the short marker lapses, a fresh install recovers on its own — no
    # Refresh tap, no restart. This is what pre-0.9.24 got for free from every open.
    Plugins::PitchforkReviews::DB::kvDel($MISS);
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('FirstEver');
    my $recovered;
    Plugins::PitchforkReviews::API::getListing(sub { $recovered = $_[0][0]{album} });
    is('a fresh install recovers by itself once the short marker lapses', $recovered, 'FirstEver');
    is('...and stores what it finally got', dbGet($KEY)->[0]{album}, 'FirstEver');

    # The stored tier keeps the full hour — the two must not collapse into one value, in
    # either direction: the long one is what bounds a ~1-2MB re-download on a real install.
    reset_all();
    dbStale($KEY, [ { album => 'Stored', artist => 'A' } ]);
    Plugins::PitchforkReviews::API::getListing(sub { });
    is('a server WITH stored rows still holds the marker for the full FEED_MISS_TTL',
       kvTtlFor($MISS), Plugins::PitchforkReviews::API::FEED_MISS_TTL());
}

# ===========================================================================
# 17. THE YEAR PATH'S MISS MARKER IS ACTUALLY CONSULTED (0.9.24)
#
# Same defect, one path over, found while validating the feed one. getYearList WROTE
# pfr:yearmiss on a failed sweep (0.8.9) but read it only `unless $stored` — and a closed
# year returns from the store long before that read, so the only caller that reached it
# with a stored list was the CURRENT year gone stale. That is exactly the case whose sweep
# costs two ~1.7MB article fetches, and exactly the case the marker was added for, so the
# marker was inert wherever it mattered.
# ===========================================================================
{
    my $now  = Plugins::PitchforkReviews::API::_nowYear();
    my $key  = "year:$now";
    my $miss = "pfr:yearmiss:$now";

    reset_all();
    dbStale($key, [ { artist => 'Kept', album => 'Kept', rank => 1 } ]);
    # Past YEAR_TTL, so the current year counts as stale and the sweep is reachable.
    # (dbStale's 99,999s is stale for a FEED at 3h and fresh for a year at 30 days.)
    $Plugins::PitchforkReviews::DB::AGE{$key} = Plugins::PitchforkReviews::API::YEAR_TTL() + 1;
    Plugins::PitchforkReviews::DB::kvSet($miss, 1, Plugins::PitchforkReviews::API::YEAR_MISS_TTL());

    my $got;
    Plugins::PitchforkReviews::API::getYearList($now, sub { $got = $_[0] });
    is('a stale CURRENT year with a live miss marker sweeps nothing', gets(), 0);
    ok('...and is still answered from the stored list, not blanked',
       ref $got eq 'ARRAY' && @$got && $got->[0]{artist} eq 'Kept');
    ok('...and the stored list survives', dbGet($key) && @{ dbGet($key) });

    # force still sweeps — the Refresh row must never sit behind a negative marker.
    my $url = "https://pitchfork.com/features/lists-and-guides/best-albums-$now/";
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$url} = yearFixture($now, 'Live');
    my $forced;
    Plugins::PitchforkReviews::API::getYearList($now, sub { $forced = $_[0] }, force => 1);
    ok('force sweeps through the marker', gets() >= 1);
    is('...and returns the live parse', $forced->[0]{artist}, 'Live 1');

    # A CLOSED year is unaffected either way: it returns from the permanent store above
    # the marker read, so the marker can neither help nor hurt it.
    reset_all();
    dbStale('year:2019', [ { artist => 'Old', album => 'Old', rank => 1 } ]);
    Plugins::PitchforkReviews::DB::kvSet('pfr:yearmiss:2019', 1, 3600);
    my $closed;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $closed = $_[0] });
    is('a closed year with a marker set still serves its stored list', $closed->[0]{artist}, 'Old');
    is('...with no fetch', gets(), 0);
}

# ===========================================================================
# 18. THE year:<Y> REFRESH ROW DOWNLOADS THE ARTICLE ONCE (0.9.24)
#
# The row does TWO jobs on purpose — re-parse this list, and re-probe for a newer one — and
# both are worth keeping. Only the duplication was the defect: getLatestYear under `force`
# walks candidates from _topYear DOWN and each probe IS a forced getYearList fetch, so on
# the way to answering "has the new list landed?" it force-fetched $y itself; the callback
# then force-fetched $y again. Two full ~1.7MB downloads of the same article per tap.
#
# BOTH DIRECTIONS ARE ASSERTED, because the obvious fix (drop `force` from the callback)
# breaks the other one: a stored year has no TTL at all, so for an OLDER year — which the
# probe stops short of and never touches — force is the only thing that can re-pull it,
# and Refresh on a closed year would silently become a no-op.
# ===========================================================================
{
    my $B    = 'Plugins::PitchforkReviews::Browse';
    my $slug = sub { "https://pitchfork.com/features/lists-and-guides/best-albums-$_[0]/" };
    my $tap  = sub {
        my ($year) = @_;
        my $row = $B->can('_refreshRow')->(undef, "year:$year");
        my $res;
        $row->{url}->(undef, sub { $res = $_[0] }, {}, $row->{passthrough}[0]);
        return $res;
    };
    my $fetchesOf = sub {
        my ($year) = @_;
        return scalar grep { $_ eq $slug->($year) } @Slim::Networking::SimpleAsyncHTTP::GETS;
    };

    # --- THE NEWEST YEAR, which is the year the view opens on and the case that doubled.
    # Only 2019 answers, so the probe walks _topYear down to it and 2019 IS the latest.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->(2019) } = yearFixture(2019, 'New');
    dbStale('year:2019', [ { artist => 'Old', album => 'Old', rank => 1 } ]);

    my $res = $tap->(2019);
    is('the newest year is downloaded ONCE per tap', $fetchesOf->(2019), 1);
    is('...and the probe still ran, so the row keeps its second job',
        Plugins::PitchforkReviews::DB::kvGet('pfr:year:latest:4'), 2019);
    is('...and the re-parse landed, so the read is fresh', dbGet('year:2019')->[0]{artist}, 'New 1');
    is('...and the row answers empty so Material re-walks the view', scalar @{ $res->{items} }, 0);
    is('...with nextWindow refresh', $res->{nextWindow}, 'refresh');

    # --- AN OLDER YEAR. The probe stops at 2025 and never touches 2019, so the callback
    # must still force or Refresh does nothing at all on a closed list.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->(2025) } = yearFixture(2025, 'Newest');
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->(2019) } = yearFixture(2019, 'Repulled');
    dbFresh('year:2019', [ { artist => 'Old', album => 'Old', rank => 1 } ]);

    $tap->(2019);
    ok('Refresh on a CLOSED year still re-pulls it', $fetchesOf->(2019) >= 1);
    is('...past the permanently stored copy', dbGet('year:2019')->[0]{artist}, 'Repulled 1');
    is('...and the probe answered with the newer year, not the one being refreshed',
        Plugins::PitchforkReviews::DB::kvGet('pfr:year:latest:4'), 2025);
}

# ===========================================================================
# 19. A STORE THAT FAILS IS A FAILURE, NOT A SUCCESS (0.9.25)
#
# putList LOGS AND RETURNS 0 on a failed write — it does not die, so nothing an eval can
# catch. Both fetch paths discarded that return value and ran kvDel($missKey)
# unconditionally, so a fetch that parsed fine but failed to store was treated as a good
# fetch: no rows landed, `stored_at` never moved, and the miss marker was actively CLEARED.
# The next open therefore found no stored rows and no marker, re-downloaded the listing,
# failed to store again, and repeated — on every view open and every warm tick, for ever.
# That is exactly the unbounded refetch FEED_MISS_TTL was added to bound, surviving in the
# one branch that bypassed it.
#
# Driven through the real getListing/getYearList with the stub's PUT_FAILS knob, because
# the defect is in what the CALLER does with the return value; a test of putList itself
# could never see it.
# ===========================================================================
{
    my $MISS = "pfr:feedmiss:$KEY";

    # --- THE FEED PATH.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Parsed');
    $Plugins::PitchforkReviews::DB::PUT_FAILS = 1;

    my $got;
    Plugins::PitchforkReviews::API::getListing(sub { $got = $_[0] });
    # The parse succeeded, so the caller is still handed the live rows — losing the store
    # must not also cost the view its answer.
    is('a fetch whose store fails still answers the caller', $got->[0]{album}, 'Parsed');
    ok('...but nothing is stored', !dbGet($KEY));
    ok('...and it is marked as a failure rather than clearing the marker',
       Plugins::PitchforkReviews::DB::kvGet($MISS));

    # THE PROPERTY THE WHOLE FINDING IS ABOUT: the next open does not re-download.
    Plugins::PitchforkReviews::API::getListing(sub { });
    is('the next open does NOT re-download the listing', gets(), 1);
    Plugins::PitchforkReviews::API::getListing(sub { }, nostale => 1);
    is('...and neither does the warm tick', gets(), 1);

    # A marker that was ALREADY standing must survive a failed store — clearing it is the
    # exact defect, and clearing it re-opens the loop even when the marker did its job.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Parsed');
    Plugins::PitchforkReviews::DB::kvSet($MISS, 1, 3600);
    $Plugins::PitchforkReviews::DB::PUT_FAILS = 1;
    Plugins::PitchforkReviews::API::getListing(sub { }, force => 1);   # force fetches past the marker
    is('a forced fetch whose store fails did fetch', gets(), 1);
    ok('...and leaves the marker standing rather than clearing it',
       Plugins::PitchforkReviews::DB::kvGet($MISS));

    # ...and the same fetch with a working store clears it, or the marker would never
    # lift and the fix would be a freeze.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Parsed');
    Plugins::PitchforkReviews::DB::kvSet($MISS, 1, 3600);
    Plugins::PitchforkReviews::API::getListing(sub { }, force => 1);
    ok('a store that LANDS still clears the marker', !Plugins::PitchforkReviews::DB::kvGet($MISS));
    is('...and the rows are there', dbGet($KEY)->[0]{album}, 'Parsed');

    # --- THE YEAR PATH, same shape, and the download it repeats is ~1.7MB rather than ~1-2MB.
    my $now  = Plugins::PitchforkReviews::API::_nowYear();
    my $yKey = "year:$now";
    my $yMiss = "pfr:yearmiss:$now";
    my $yUrl = "https://pitchfork.com/features/lists-and-guides/best-albums-$now/";

    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$yUrl} = yearFixture($now, 'Live');
    $Plugins::PitchforkReviews::DB::PUT_FAILS = 1;

    my $yGot;
    Plugins::PitchforkReviews::API::getYearList($now, sub { $yGot = $_[0] });
    is('a year whose store fails still answers the caller', $yGot->[0]{artist}, 'Live 1');
    ok('...but nothing is stored', !dbGet($yKey));
    ok('...and the sweep is marked, not cleared', Plugins::PitchforkReviews::DB::kvGet($yMiss));
    is('...held for YEAR_MISS_TTL', kvTtlFor($yMiss),
       Plugins::PitchforkReviews::API::YEAR_MISS_TTL());

    my $before = gets();
    Plugins::PitchforkReviews::API::getYearList($now, sub { });
    is('the next open does NOT re-pull the 1.7MB article', gets(), $before);
}

# ===========================================================================
# 20. ONE THROWING CALLER MUST NOT STRAND THE REST OF A COALESCED QUEUE (0.9.25)
#
# Both publish paths fanned out to their coalesced waiters with a bare
#     $_->(...) for @waiters;
# running AFTER the owner's own $callback. $callback chains into the full feed render —
# a lot of code, any of which can die — so one throw stranded EVERY waiter behind it, and
# by then the %RESOLVING / %PENDING slot has already been deleted: there is no wedged slot
# left for the RESOLVE_JOIN_MAX adoption path to rescue, and nothing else ever answers them.
#
# The blast radius is what makes this worth a section rather than a tidy-up. A stranded
# waiter that came from a `view` is a $FG_INFLIGHT that never decrements — only
# _resolveSection's resolver callback does that — and $FG_INFLIGHT is tested for TRUTH, not
# compared against a width, so ONE leak pins the warm at WARM_CONCURRENCY and every home
# shelf at the narrow width for the life of the process. That is 0.9.23's finding-1 leak
# arriving from the publish side instead of the adoption side.
# ===========================================================================
{
    my $B = 'Plugins::PitchforkReviews::Browse';
    my $searches = 0;
    my @held;
    my @HOLD = ({ name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
                  run  => sub { $searches++; push @held, $_[5] } });
    my $hit = [ { title => 'Record', artist => 'Band', id => 3, image => 'https://i/c.jpg' } ];

    # --- THE RESOLVE PATH. The owner's callback dies where the render would.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        my $served = 0;
        $B->can('_findPlayable')->(undef, sub { die "the render blew up\n" }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { $served++ }, 'Band', 'Record') for 1 .. 3;
        is('three callers joined the one search', $searches, 1);

        eval { $held[0]->($hit); 1 };
        is('a throwing owner does not strand the callers queued behind it', $served, 3);
        is('...and the slot is still released', $B->can('_resolvingCount')->(), 0);
    }

    # A THROWING WAITER is the same defect one position along: it must cost only itself.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        my $served = 0;
        $B->can('_findPlayable')->(undef, sub { $served++ }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { die "waiter one\n" }, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { $served++ }, 'Band', 'Record') for 1 .. 2;

        eval { $held[0]->($hit); 1 };
        is('a throwing WAITER costs only itself', $served, 3);
    }

    # --- THE CACHE-HIT PATH publishes to adopted waiters through the same shape, and it is
    # a LIKELY exit rather than a corner: a wedged slot is at least RESOLVE_JOIN_MAX old,
    # ample time for another resolve of the same album to have stored the answer.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };
        local *Plugins::Qobuz::Plugin::QobuzGetTracks = sub { };

        my $served = 0;
        $B->can('_findPlayable')->(undef, sub {}, 'Band', 'Record');
        $B->can('_findPlayable')->(undef, sub { $served++ }, 'Band', 'Record') for 1 .. 2;

        my $key = $B->can('_streamKey')->($B->can('_streamId')->('Band', 'Record'));
        $B->can('_ageResolvingSlot')->($key, $B->RESOLVE_JOIN_MAX() + 5);
        Plugins::PitchforkReviews::DB::kvSet($key,
            { items => [ { name => 'stored', _svc => 'Qobuz', _albumid => 7 } ] }, 100);

        # The caller that replaces the wedged slot adopts the two waiters — and dies.
        eval { $B->can('_findPlayable')->(undef, sub { die "the render blew up\n" },
                                          'Band', 'Record'); 1 };
        is('the adopted waiters are served even though the adopter threw', $served, 2);
    }

    # --- AND WHAT IT COSTS, driven through _resolveSection. Everything above proves the
    # waiters are called; this proves what calling them is FOR. A unit test of _findPlayable
    # can never see it — the leak is in the caller's bookkeeping, not in the resolver.
    reset_all();
    $searches = 0; @held = ();
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @HOLD };

        is('the foreground count starts clean', $B->can('_fgInflight')->(), 0);

        # Something else claims the album first and will die on the way to publishing.
        $B->can('_findPlayable')->(undef, sub { die "the render blew up\n" }, 'Band', 'Record');
        is('the album is claimed', $searches, 1);

        # A VIEW asks for the same album and joins that claim rather than searching again.
        # Its per-item callback is now sitting in the doomed owner's waiter list.
        $B->can('_resolveSection')->(undef, [ { artist => 'Band', album => 'Record' } ],
            sub {}, $B->VIEW_DEADLINE(), 'view');
        is('the view joined it instead of searching', $searches, 1);
        is('...and a human is now counted as waiting', $B->can('_fgInflight')->(), 1);

        eval { $held[0]->($hit); 1 };
        is('the owner throwing still drains the view\'s foreground count',
            $B->can('_fgInflight')->(), 0);
    }

    # --- THE %PENDING FAN-OUT IN API.pm IS THE SAME SHAPE, lower blast radius (feed
    # callbacks, not the full render) and the same permanence: the slot is deleted before
    # the loop runs, so a caller skipped here is never answered by anything, ever —
    # Material's three-dot placeholder, for good.
    reset_all();
    {
        $Slim::Networking::SimpleAsyncHTTP::ROUTES{$REVIEWS} = listingPage('Fresh');
        $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;

        # Nothing stored, so nobody is answered stale up front and all three genuinely
        # queue on the one in-flight fetch.
        my $served = 0;
        Plugins::PitchforkReviews::API::getListing(sub { die "a browse render blew up\n" });
        Plugins::PitchforkReviews::API::getListing(sub { $served++ }) for 1 .. 2;
        is('three callers share one fetch', gets(), 1);

        eval { Slim::Networking::SimpleAsyncHTTP::flush(); 1 };
        is('a throwing coalesced caller does not strand the others', $served, 2);

        # ...and the key is not left claimed either, or the NEXT open is adopted by a
        # fetch that already finished.
        $Slim::Networking::SimpleAsyncHTTP::DEFER = 0;
        my $later;
        Plugins::PitchforkReviews::API::getListing(sub { $later = $_[0] });
        ok('...and the key is free, so a later caller is answered', defined $later);
    }
}

# ===========================================================================
# 21. THE year:<Y> REFRESH ROW RE-DOWNLOADS ONLY THE YEAR IT IS REFRESHING (0.9.26)
#
# 0.9.24 stopped the row downloading $y TWICE. What it did not cover is that getLatestYear
# FORWARDS ITS WHOLE %opts TO EVERY PROBE, so `force => 1` was inherited by the probe's own
# getYearList calls: tapping Refresh on 2019 force-fetched the NEWEST year's ~1.7MB article
# — a list that is stored, immutable and cannot have changed — purely to answer "is there a
# newer one?", and then force-fetched 2019. Two full articles per tap on every closed year.
#
# THE OBVIOUS FIX BREAKS TWO OTHER THINGS, and both are asserted here because both are what
# would be re-proposed:
#
#   * Stripping `force` alone lets the year-miss MARKER answer the probe, so for
#     YEAR_MISS_TTL after any failed sweep the row stops being able to discover a
#     newly published list — which is the row's second job and the reason it forces at
#     all. Hence `resweep`: skip the negative markers, honour the permanent store.
#   * With the probe no longer fetching, the `$probed` shortcut (0.9.24: "the probe
#     already re-pulled $y, so don't force it again") becomes false — the probe now
#     answers from the store — and Refresh on the NEWEST year silently becomes a no-op.
#     So the order is inverted: re-pull $y first, then probe. The probe then finds $y
#     freshly stored and cannot duplicate it, which is what makes the shortcut unnecessary
#     rather than merely wrong.
#
# Date-proof: the probe walks down from _topYear, which moves in November, so the newest
# year is asked for rather than hardcoded.
# ===========================================================================
{
    my $B    = 'Plugins::PitchforkReviews::Browse';
    my $top  = Plugins::PitchforkReviews::API::_topYear();
    my $slug = sub { "https://pitchfork.com/features/lists-and-guides/best-albums-$_[0]/" };
    my $tap  = sub {
        my ($year) = @_;
        my $row = $B->can('_refreshRow')->(undef, "year:$year");
        my $res;
        $row->{url}->(undef, sub { $res = $_[0] }, {}, $row->{passthrough}[0]);
        return $res;
    };
    my $fetchesOf = sub {
        my ($year) = @_;
        return scalar grep { $_ eq $slug->($year) } @Slim::Networking::SimpleAsyncHTTP::GETS;
    };

    # --- A CLOSED YEAR, with the newest year already stored. This is the defect: the
    # probe's own fetch of a list that cannot have changed.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) }  = yearFixture($top, 'Newest');
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->(2019) }  = yearFixture(2019, 'Repulled');
    dbFresh("year:$top", [ { artist => 'Held', album => 'Held', rank => 1 } ]);
    dbFresh('year:2019',  [ { artist => 'Old',  album => 'Old',  rank => 1 } ]);

    $tap->(2019);
    is('a stored newest year is NOT re-downloaded to answer the probe', $fetchesOf->($top), 0);
    is('...and it keeps the copy it had', dbGet("year:$top")->[0]{artist}, 'Held');
    is('the year being refreshed is re-pulled exactly once', $fetchesOf->(2019), 1);
    is('...past its permanently stored copy', dbGet('year:2019')->[0]{artist}, 'Repulled 1');
    is('...and the probe still ran, so the row keeps its second job',
        Plugins::PitchforkReviews::DB::kvGet('pfr:year:latest:4'), $top);

    # --- THE NEWEST YEAR ITSELF. Still exactly one download — the property 0.9.24 fixed,
    # and the one the `$probed` shortcut would hand back the moment the probe stops
    # fetching (it would read "already re-pulled" off a plain DB hit).
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'Fresh');
    dbFresh("year:$top", [ { artist => 'Stale', album => 'Stale', rank => 1 } ]);

    my $res = $tap->($top);
    is('Refresh on the newest year still re-pulls it', $fetchesOf->($top), 1);
    is('...exactly once', dbGet("year:$top")->[0]{artist}, 'Fresh 1');
    is('...and the row answers empty so Material re-walks the view', scalar @{ $res->{items} }, 0);
    is('...with nextWindow refresh', $res->{nextWindow}, 'refresh');

    # --- A YEAR THAT WAS NEVER STORED, which is the other way the duplication can arise:
    # the probe reaches $y, finds nothing stored and fetches it, and the callback fetches
    # it again. Re-pulling first is what forecloses that.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'Cold');
    $tap->($top);
    is('a never-stored year is downloaded once, not twice', $fetchesOf->($top), 1);

    # --- THE NEGATIVE MARKER MUST NOT SILENCE A MANUAL RE-PROBE. A sweep that failed
    # within the last YEAR_MISS_TTL leaves a marker; the whole point of the Refresh row is
    # that it is an immediate live retry, so the marked year is still swept.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'JustLanded');
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->(2019) } = yearFixture(2019, 'Repulled');
    dbFresh('year:2019', [ { artist => 'Old', album => 'Old', rank => 1 } ]);
    Plugins::PitchforkReviews::DB::kvSet("pfr:yearmiss:$top", 1,
        Plugins::PitchforkReviews::API::YEAR_MISS_TTL());

    $tap->(2019);
    is('a year-miss marker cannot silence the manual re-probe',
        Plugins::PitchforkReviews::DB::kvGet('pfr:year:latest:4'), $top);
    is('...so a newly published list is discovered on the tap', $fetchesOf->($top), 1);
    is('...and the year being refreshed is still re-pulled', $fetchesOf->(2019), 1);

    # --- AND THE MARKER IS STILL OBEYED WHEN NOBODY ASKED FOR A REFRESH, or `resweep` has
    # simply reintroduced the sweep storm YEAR_MISS_TTL exists to bound.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'JustLanded');
    Plugins::PitchforkReviews::DB::kvSet("pfr:yearmiss:$top", 1,
        Plugins::PitchforkReviews::API::YEAR_MISS_TTL());
    Plugins::PitchforkReviews::API::getLatestYear(sub { });
    is('an ordinary probe still obeys the marker', $fetchesOf->($top), 0);
}

# ===========================================================================
# 22. `resweep` IS SOLO IN _shareFetch TOO (0.9.26)
#
# Section 21 gave the Refresh row's probes `resweep` instead of `force` so they stop
# re-downloading years they already hold. But `force` was carrying a SECOND meaning
# that went with it: _shareFetch tests it to decide whether a fetch may be answered
# from the stale copy and whether it joins the coalescing queue. A probe carrying only
# `resweep` failed both tests, so it could be ADOPTED by an in-flight ordinary fetch —
# and if that slot is one of the %PENDING strands this file has closed four times, the
# Refresh tap is never answered at all. The manual retry button is precisely the
# surface that has to keep working when the automatic paths have wedged.
#
# THE TWO PROPERTIES PULL AGAINST EACH OTHER, which is why both directions are pinned:
# a resweep probe must never be left unanswered by someone else's slot, and an ordinary
# probe must still coalesce — a "simplification" that drops either one looks correct
# from the side it was written for.
#
# THE THIRD ASSERTION IS THE ONE THAT CATCHES A HALF-APPLIED FIX. Exempting the two
# tests but leaving $done on the fan-out path is not a smaller version of this fix, it
# is a worse bug: with no slot claimed, `delete $PENDING{$key}` finds nothing and the
# probe is never called back at all; where another caller owns the key, it fires THEIR
# waiters with the probe's items instead. "Exactly one callback" fails on 0 and on 2.
# ===========================================================================
{
    my $top  = Plugins::PitchforkReviews::API::_topYear();
    my $slug = sub { "https://pitchfork.com/features/lists-and-guides/best-albums-$_[0]/" };
    my $fetchesOf = sub {
        my ($year) = @_;
        return scalar grep { $_ eq $slug->($year) } @Slim::Networking::SimpleAsyncHTTP::GETS;
    };

    # --- A RESWEEP PROBE IS NOT ADOPTED BY A SLOT THAT WILL NEVER ANSWER. The deferred
    # fetch below is never flushed until the assertions are done, which is exactly what a
    # stranded %PENDING slot looks like from the probe's side.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;
    my @ordinary;
    Plugins::PitchforkReviews::API::getYearList($top, sub { push @ordinary, $_[0] });
    is('an ordinary caller claims the slot and its fetch is in flight', $fetchesOf->($top), 1);

    $Slim::Networking::SimpleAsyncHTTP::DEFER = 0;
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'Landed');
    my $probed;
    Plugins::PitchforkReviews::API::getLatestYear(sub { $probed = shift }, force => 1);
    is('a resweep probe is answered, not adopted by the in-flight fetch', $probed, $top);
    is('...because it issued its own', $fetchesOf->($top), 2);
    is('...and it did not fire the waiters on a slot it never claimed', scalar @ordinary, 0);

    # Release the held fetch — both as cleanup (%PENDING is process-wide and a strand
    # left here would adopt every later block asking for this year) and because "the
    # probe left the slot intact" is only proved by the slot still working.
    Slim::Networking::SimpleAsyncHTTP::flush();
    is('the stranded caller is still answered by its own fetch', scalar @ordinary, 1);

    # --- AN ORDINARY PROBE MUST STILL COALESCE, or `resweep` has quietly disabled
    # coalescing for the year path rather than exempting one caller from it.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::DEFER = 1;
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'Shared');
    my @first;
    Plugins::PitchforkReviews::API::getYearList($top, sub { push @first, $_[0] });
    my $latest;
    Plugins::PitchforkReviews::API::getLatestYear(sub { $latest = shift });   # no force => no resweep
    is('an ordinary probe joins the in-flight fetch', $fetchesOf->($top), 1);

    Slim::Networking::SimpleAsyncHTTP::flush();
    is('...and the original caller is answered when it lands', scalar @first, 1);
    is('...as is the probe that joined it', $latest, $top);

    # --- EXACTLY ONE CALLBACK, which is the assertion a half-applied fix fails. Driven
    # on the CURRENT year with a stale stored list, the one shape that reaches _shareFetch
    # with something stale to serve — so both failure modes ($cb never called, $cb called
    # twice) are reachable from here.
    reset_all();
    my $cy = Plugins::PitchforkReviews::API::_nowYear();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($cy) } = yearFixture($cy, 'Live');
    dbStale("year:$cy", [ { artist => 'Stored', album => 'Stored', rank => 1 } ]);
    # dbStale's age is sized for FEED_TTL (3h); a YEAR is only stale past YEAR_TTL (30d),
    # so without this the call answers from the store and never reaches _shareFetch —
    # i.e. the assertions below would pass against any implementation at all.
    $Plugins::PitchforkReviews::DB::AGE{"year:$cy"} =
        Plugins::PitchforkReviews::API::YEAR_TTL() + 1;
    my @calls;
    Plugins::PitchforkReviews::API::getYearList($cy, sub { push @calls, $_[0] }, resweep => 1);
    is('a resweep fetch calls back exactly once', scalar @calls, 1);
    is('...with the live parse, never the stale copy as well', $calls[0][0]{artist}, 'Live 1');

    # --- AND IT IS STILL THE WEAKER FORM. Solo in _shareFetch must not have made it
    # solo against the STORE — that is the whole point of resweep and section 21's fix.
    reset_all();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{ $slug->($top) } = yearFixture($top, 'Downloaded');
    dbFresh("year:$top", [ { artist => 'Held', album => 'Held', rank => 1 } ]);
    my $got;
    Plugins::PitchforkReviews::API::getYearList($top, sub { $got = $_[0] }, resweep => 1);
    is('a resweep still answers from the permanent store', $got->[0]{artist}, 'Held');
    is('...without fetching', $fetchesOf->($top), 0);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

#!/usr/bin/env perl
# 0.8.8 hardening: async-driver leaks, negative caching, and two silent-failure paths.
#
# WHY THIS EXISTS. Five defects found by a code review of the 0.8.7 diff, none of which
# produces an error, a warning, or a wrong-looking screen — which is exactly why they need
# tests rather than a re-read:
#
#   1. SELF-CAPTURING CLOSURES LEAK. `my $x; $x = sub {... $x ...}` makes the closure the
#      only holder of the only reference to itself, and Perl frees by refcount, so it is
#      never collected — along with everything it captured. There were four: the two-leg
#      search driver in _findPlayable (one per adapter per resolve — ~450/day via the daily
#      warm, each retaining the matched album nodes), _resolveSection's pump, and the retry
#      drivers in getYearList/getLatestYear. Fixed by passing the sub to ITSELF, the same
#      shape the sibling ListenBrainz plugin adopted in LBF 0.9.95. A leak is invisible in
#      any functional test — hence the weak references below, which assert the closure is
#      actually gone rather than that the feature still works.
#   2. A FAILED YEAR SWEEP WAS NEVER CACHED. getLatestYear probes _topYear down to YEAR_MIN
#      and getYearList tries every candidate slug; with nothing cached on the failure path,
#      a slug change or an outage made EVERY home-shelf render, tile open and daily warm
#      re-run the whole sweep — ~17 fetches of a ~1.7MB article each time. The negative has
#      to be distinguishable from a cache miss, hence the 0 sentinel and `defined`.
#   3. _parseYear cleared its pending cover/rank only on the SUCCESS path, so a heading that
#      yielded no album leaked its artwork onto the next entry.
#   4. _setHomeYearTitle armed its dedupe guard BEFORE the call it guards, so one failure
#      suppressed every retry for that year until a server restart.
#
# Run from the repo root:  perl tools/t_hardening.pl
use strict; use warnings; use utf8;
use Scalar::Util qw(weaken);
binmode(STDOUT, ':encoding(UTF-8)');

# --- throwaway Slim::* tree (absent on a dev Mac) ---------------------------
BEGIN {
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = $INC{'Slim/Utils/Cache.pm'}
        = $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'}
        = $INC{'Slim/Utils/Strings.pm'} = $INC{'Slim/Utils/Timers.pm'}
        = $INC{'JSON/XS/VersionOneAndTwo.pm'} = $INC{'Plugins/PitchforkReviews/DB.pm'} = __FILE__;
}

{
    # In-memory stand-in for the list DATABASE (0.9.8). The suites here test feed and
    # year LOGIC, not storage — DB.pm has its own suite against real SQLite (t_db.pl).
    # Keeping it in memory also makes what was stored directly assertable.
    package Plugins::PitchforkReviews::DB;
    our (%LISTS, %VER, %AGE, $DIE_ON_PUT);
    sub getList {
        my ($k, $v) = @_;
        return undef unless $LISTS{$k};
        return undef if defined $v && defined $VER{$k} && $VER{$k} != $v;
        return $LISTS{$k};
    }
    sub putList {
        my ($k, $i, $v) = @_;
        # Section 6 needs a REAL exception on the write path: the defect it guards is
        # about who releases the coalescing slot when one escapes, so "return false"
        # would not reproduce it. The storage moved to the DB in 0.9.8, so the throw
        # has to move with it.
        die "database is locked at DB.pm\n" if $DIE_ON_PUT && $DIE_ON_PUT--;
        return 0 unless ref $i eq 'ARRAY' && @$i;
        $LISTS{$k} = $i; $VER{$k} = $v; $AGE{$k} = 0;
        return 1;
    }
    sub listAge    { exists $LISTS{$_[0]} ? ($AGE{$_[0]} // 0) : undef }
    sub forget     { delete $LISTS{$_[0]}; delete $AGE{$_[0]}; delete $VER{$_[0]}; 1 }
    sub forgetAll  { %LISTS = (); %AGE = (); %VER = (); 1 }
    sub storedKeys { sort keys %LISTS }
    sub reset_db   { %LISTS = (); %AGE = (); %VER = (); $DIE_ON_PUT = 0;  kvReset(); }
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
    # A REAL in-memory store: the caching tests are about what is written and what a
    # second call then finds, so a no-op cache would make every one of them vacuous.
    package Slim::Utils::Cache;
    our (%STORE, @SETS, $DIE_ON_SET);
    sub new   { bless {}, shift }
    sub get   { my (undef, $k) = @_; exists $STORE{$k} ? $STORE{$k} : undef }
    # $DIE_ON_SET makes the next N writes throw, the way the real DbCache does on a
    # character string (and Storable does on an unexpected ref). Section 6 needs a
    # REAL exception: the defect it guards is about who releases the coalescing slot
    # when one escapes, so a mocked "return false" would not reproduce it.
    # $MAX_BYTES reproduces what plex actually does to a large value (measured
    # 2026-08-06): `set` RETURNS SUCCESS, does not die, and the entry is simply never
    # retrievable. That silence is the whole reason the defect survived four builds, so
    # the stub has to reproduce the silence and not just the loss.
    our $MAX_BYTES;
    sub set   {
        my (undef, $k, $v, $ttl) = @_;
        die "Wide character in subroutine entry at DbCache.pm\n" if $DIE_ON_SET && $DIE_ON_SET--;
        if ($MAX_BYTES) {
            require Storable;
            return 1 if length(Storable::nfreeze({ v => $v })) > $MAX_BYTES;
        }
        $STORE{$k} = $v; push @SETS, { key => $k, ttl => $ttl }; 1
    }
    sub reset { %STORE = (); @SETS = (); $DIE_ON_SET = 0; $MAX_BYTES = 0; }
    sub ttlFor { my ($k) = @_; my $t; for (@SETS) { $t = $_->{ttl} if $_->{key} eq $k } $t }

    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
                                  # warn is captured rather than swallowed by AUTOLOAD, so
                                  # storage failures can be ASSERTED rather than assumed —
                                  # the same failure was silent from 0.9.0 to 0.9.7.
                                  our @WARNED; sub warn { push @WARNED, $_[1]; 1 }
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; our %P;
                                  sub AUTOLOAD {} sub init {}
                                  sub get { $P{$_[1]} } sub set { $P{$_[1]} = $_[2] }
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  # The home-shelf label is sprintf'd with the year, so it has
                                  # to carry a real %s or every year would render one title and
                                  # the "only write on a CHANGE" test could not fail.
                                  # Client-aware, because a home-shelf title is built with
                                  # cstring($client, …) and a server can have players carrying
                                  # different language overrides — the case that breaks a guard
                                  # keyed on the formatted string (section 4).
                                  sub cstring {
                                      my ($c, $tok) = @_;
                                      return $tok unless $tok eq 'PLUGIN_PITCHFORKREVIEWS_HOME_YEAR_LABEL';
                                      return (eval { $c->{lang} } || '') eq 'DE'
                                          ? 'Pitchfork: %s - Beste Alben' : 'Pitchfork: %s - Best Albums';
                                  }
                                  sub string  { $_[0] }
    package Slim::Utils::Timers;
    # Deliberately does NOT retain the callback: holding it would keep the very closures
    # these tests weigh alive, and every leak assertion would pass for the wrong reason.
    our $armed = 0;
    sub setTimer { $armed++; return $armed } sub killSpecific {1} sub killTimers {}

    package Plugins::PitchforkReviews::Plugin; sub dbg {}

    # Scripted HTTP. %ROUTES maps url => page body; a url that is absent 404s, which is
    # exactly how an unpublished year and a changed slug both present.
    package Slim::Networking::SimpleAsyncHTTP;
    our (%ROUTES, @GETS, $DIE_ON_GET);
    sub new { my ($c, $ok, $err) = @_; bless { ok => $ok, err => $err }, $c }
    sub get {
        my ($self, $url) = @_;
        # A SYNCHRONOUS throw out of the transport — not the error callback, which is
        # the normal, already-handled path. This is the one shape that can strand a
        # %PENDING slot claimed moments earlier (see t_hardening section 6b).
        die "synthetic transport failure\n" if $DIE_ON_GET && $DIE_ON_GET--;
        push @GETS, $url;
        return $self->{ok}->(bless { c => $ROUTES{$url} }, 'T::Resp') if defined $ROUTES{$url};
        $self->{err}->($self, '404 Not Found');
    }
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

# TTL a kv write ASKED FOR, read back off the DB stub's @KVSETS. The equivalent of the
# old Slim::Utils::Cache::ttlFor, moved with the store (0.9.11).
sub kvTtlFor {
    my ($k) = @_;
    my $t;
    for (@Plugins::PitchforkReviews::DB::KVSETS) { $t = $_->{ttl} if $_->{key} eq $k }
    return $t;
}

sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

sub httpReset { %Slim::Networking::SimpleAsyncHTTP::ROUTES = (); @Slim::Networking::SimpleAsyncHTTP::GETS = (); }
sub gets      { scalar @Slim::Networking::SimpleAsyncHTTP::GETS }

# A minimal year-end page: one entry, in the exact block run the real articles use
# (inline-embed cover -> heading-h3 rank -> h2 "Artist: <em>Album</em>" -> blurb).
sub yearPage {
    my ($year, %o) = @_;
    my @body = (
        [ 'inline-embed', { type => 'callout:inset-left' },
          { contentType => 'photo', sources => { hi => { url => "https://img/$year-cover.jpg", width => 800 } } } ],
        [ 'div', { class => 'heading-h3' }, '1.' ],
        [ 'h2', 'Artist One: ', [ 'em', 'Album One' ] ],
        [ 'p', 'x' x 200 ],
    );
    push @body, @{ $o{extra} } if $o{extra};
    my $json = JSON::XS::VersionOneAndTwo::to_json({ transformed => { article => { body => \@body } } });
    return qq{<meta property="og:title" content="The 50 Best Albums of $year">}
         . qq{<meta property="article:published_time" content="$year-12-02T14:00:00.000Z">}
         . qq{<script>window.__PRELOADED_STATE__ = $json;</script>};
}

# The smallest page _parseState will read one review out of (section 6).
sub listingPage {
    my ($album) = @_;
    my $json = JSON::XS::VersionOneAndTwo::to_json({ items => [ {
        contentType  => 'review',
        url          => "/reviews/albums/$album/",
        dangerousHed => $album,
        subHed       => { name => 'An Artist' },
        dangerousDek => 'A capsule.',
        pubDate      => '2026-08-01T05:00:00.000Z',
        image        => { sources => { lg => { url => 'https://img/a.jpg', width => 768 } } },
        ratingValue  => { score => 8.0 },
        rubric       => [ { name => 'Rock' } ],
    } ] });
    return "<html><script>window.__PRELOADED_STATE__ = $json;</script></html>";
}

print "== 1. the async drivers do not leak themselves ==\n";

# The precise assertion: a weak reference to the callback the adapter was handed. Under the
# self-capturing form that callback IS the driver, which holds itself, so it survives the
# resolve; under the self-passing form it is a thin wrapper nothing points back at.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
    my $weakCb;
    my @ADAPTERS = ({
        name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
        run  => sub {
            my (undef, undef, undef, undef, undef, $cb) = @_;
            $weakCb = $cb; weaken($weakCb);
            $cb->([ { name => 'a hit', id => 7 } ]);
        },
    });
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ADAPTERS };
    my $got;
    Plugins::PitchforkReviews::Browse::_findPlayable(undef, sub { $got = $_[0] }, 'Some Artist', 'Some Album');
    ok('_findPlayable still resolves the match', ref $got eq 'HASH' && @{ $got->{items} || [] });
    ok('...and its leg driver is freed once the resolve settles', !defined $weakCb);
}

# The consequence, for the pump: a leaked closure pins everything it captured, including
# the player. Asserted through the object's own lifetime rather than a coderef.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset();
    my @ADAPTERS = ({
        name => 'Qobuz', icon => 'i', priority => 1, query_enc => 'bytes',
        run  => sub { $_[5]->([ { name => 'hit', id => 1 } ]) },
    });
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ADAPTERS };

    my $client = bless {}, 'T::Client';
    my $weak = $client; weaken($weak);
    my $done = 0;
    Plugins::PitchforkReviews::Browse::_resolveSection($client, [ { artist => 'A', album => 'B' } ], sub { $done = 1 });
    ok('_resolveSection completes', $done);
    undef $client;
    ok('...and does not retain the player afterwards', !defined $weak);
}

# The two API retry drivers. Their callback is what a leak would pin, so weigh that.
#
# NB the callback MUST close over something. An anonymous sub that captures nothing is
# built once at compile time and shared, and the optree holds it for the life of the
# process — so a `sub { }` probe can never be collected and this test would report a leak
# whatever the code did. (It did, on the first run.)
for my $case ([ 'getYearList', sub { Plugins::PitchforkReviews::API::getYearList(2019, $_[0]) } ],
              [ 'getLatestYear', sub { Plugins::PitchforkReviews::API::getLatestYear($_[0]) } ]) {
    my ($name, $call) = @$case;
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    my @seen;
    my $cb = sub { push @seen, $_[0] };
    my $weak = $cb; weaken($weak);
    $call->($cb);
    undef $cb;
    ok("$name answered its caller", scalar @seen == 1);
    ok("$name frees its retry driver (all-404 sweep)", !defined $weak);
}

print "\n== 2. a failed sweep is cached, so it is not repeated ==\n";

{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();     # every route 404s
    my @answers;
    Plugins::PitchforkReviews::API::getLatestYear(sub { push @answers, $_[0] });
    my $first = gets();
    ok('the first sweep really does probe many years', $first > 10);
    is('...and reports nothing found', (defined $answers[0] ? 'defined' : 'undef'), 'undef');

    @Slim::Networking::SimpleAsyncHTTP::GETS = ();
    Plugins::PitchforkReviews::API::getLatestYear(sub { push @answers, $_[0] });
    is('the SECOND call fetches nothing at all', gets(), 0);
    is('...and still reports nothing found', (defined $answers[1] ? 'defined' : 'undef'), 'undef');
    # The two negatives are not redundant: getYearList's alone already stops the HTTP
    # storm, but only this one stops getLatestYear re-walking the whole probe loop, and
    # only this one makes "nothing is published" a stable answer the shelf can rely on.
    ok('the completed sweep is recorded as a negative',
        defined $Plugins::PitchforkReviews::DB::KV{'pfr:year:latest:4'});
    ok('the negative is held briefly, not for the 30d success TTL',
        (kvTtlFor('pfr:year:latest:4') // 0) == Plugins::PitchforkReviews::API::LATEST_MISS_TTL());

    # The sentinel must never surface as a year to a caller.
    is('cachedLatestYear reports "not known", never the 0 sentinel',
        (defined Plugins::PitchforkReviews::API::cachedLatestYear() ? 'defined' : 'undef'), 'undef');

    # ...and Refresh must still be able to force a real re-probe past it.
    @Slim::Networking::SimpleAsyncHTTP::GETS = ();
    Plugins::PitchforkReviews::API::getLatestYear(sub { }, force => 1);
    ok('force => 1 re-probes past the negative', gets() > 10);
}

# The negative must not outlive a list actually landing.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    Plugins::PitchforkReviews::API::getLatestYear(sub { });        # nothing published: negative cached
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{'https://pitchfork.com/features/lists-and-guides/best-albums-2025/'}
        = yearPage(2025);
    my $got = 'unset';
    Plugins::PitchforkReviews::API::getLatestYear(sub { $got = $_[0] }, force => 1);
    is('a list that lands is picked up on the next forced probe', $got, '2025');
}

{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    my @out;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { push @out, $_[0] });
    my $first = gets();
    ok('getYearList tries its candidate slugs', $first >= 1);
    is('...and reports an empty list', scalar @{ $out[0] }, 0);

    @Slim::Networking::SimpleAsyncHTTP::GETS = ();
    Plugins::PitchforkReviews::API::getYearList(2019, sub { push @out, $_[0] });
    is('a repeat call re-fetches nothing', gets(), 0);
    is('...and still reports an empty list', scalar @{ $out[1] }, 0);
}

# A miss must NEVER BLANK a good last-known copy: the fallback exists so a transient
# outage doesn't empty a list the user was just browsing, and caching [] over it would
# defeat that entirely.
#
# But the miss DOES still have to be recorded, or the negative above is only half of the
# job. Answering the caller from the stored copy and recording nothing means the next
# open re-runs the whole candidate sweep — two ~1.7MB article fetches — and so does the
# one after that, for ever: exactly the storm YEAR_MISS_TTL exists to stop, just moved
# behind the user.
#
# 0.9.8 changed WHERE the two halves live, and that split is the point of this block.
# The list is in the DB and a failed sweep must never touch it; the "this year has no
# list" marker is a short-lived NEGATIVE and stays in the cache under its own key. The
# old design wrote the answer over the working key, which is how a bad sweep could
# overwrite a good year.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    Plugins::PitchforkReviews::DB::reset_db();
    Plugins::PitchforkReviews::DB::putList('year:2019', [ { artist => 'Kept', album => 'Copy' } ], Plugins::PitchforkReviews::API::PARSE_VERSION());

    my $got;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $got = $_[0] }, force => 1);
    is('an outage falls back to the last good parse', scalar @$got, 1);
    is('...the right one',                            $got->[0]{artist}, 'Kept');

    my $held = Plugins::PitchforkReviews::DB::getList('year:2019', Plugins::PitchforkReviews::API::PARSE_VERSION());
    is('...and the STORED list is untouched by the failed sweep',
        ($held && @$held ? $held->[0]{artist} : ''), 'Kept');

    ok('...the miss marker is recorded separately, in the cache',
       defined $Plugins::PitchforkReviews::DB::KV{'pfr:yearmiss:2019'});
    is('...under the short miss TTL, so it re-probes within the hour',
        kvTtlFor('pfr:yearmiss:2019'),
        Plugins::PitchforkReviews::API::YEAR_MISS_TTL());

    # ...and the point of recording it at all: no second sweep.
    httpReset();
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $got = $_[0] });
    is('the next open does NOT sweep the candidate slugs again', gets(), 0);
    is('...and still shows the list',                            $got->[0]{artist}, 'Kept');
}

print "\n== 3. a skipped heading does not leak its cover onto the next entry ==\n";

# The leak needs two things the real pages happen not to combine today: a heading that
# yields no album (so the entry is skipped with a cover already collected), and a FOLLOWING
# entry with no embed of its own (so nothing overwrites it). Both are one hand-authored
# page away, and the result is a plausible-looking wrong cover, never an error.
{
    my $page = yearPage(2024, extra => [
        [ 'inline-embed', { type => 'callout:inset-left' },
          { contentType => 'photo', sources => { hi => { url => 'https://img/ORPHAN.jpg', width => 800 } } } ],
        [ 'h2', '' ],                                   # a heading with no album -> skipped
        [ 'h2', 'Artist Two: ', [ 'em', 'Album Two' ] ], # ...and this one carries no embed
        [ 'p', 'y' x 200 ],
    ]);
    my $items = Plugins::PitchforkReviews::API::_parseYear($page, 2024, 'u');
    is('both real entries parsed', scalar @$items, 2);
    my ($two) = grep { $_->{album} eq 'Album Two' } @$items;
    ok('the second entry exists', defined $two);
    is('...and did NOT inherit the skipped heading\'s cover', $two->{cover}, '');
    my ($one) = grep { $_->{album} eq 'Album One' } @$items;
    is('the entry that owns a cover still has it', $one->{cover}, 'https://img/2024-cover.jpg');
}

print "\n== 4. a failed home-shelf title update can be retried ==\n";

{
    my @sent;
    our $FAIL = 1;
    {
        no strict 'refs'; no warnings 'redefine', 'once';
        *Plugins::MaterialSkin::Plugin::setHomeExtraTitle = sub {
            my (undef, $tag, $title) = @_;
            die "material is restarting\n" if $FAIL;
            push @sent, $title;
            1;
        };
    }

    Plugins::PitchforkReviews::Browse::_setHomeYearTitle(undef, 2025);
    is('nothing was recorded while the call was failing', scalar @sent, 0);

    $FAIL = 0;
    Plugins::PitchforkReviews::Browse::_setHomeYearTitle(undef, 2025);
    is('the SAME year is retried after a failure', scalar @sent, 1);
    is('...with the right title', $sent[0], 'Pitchfork: 2025 - Best Albums');

    # The guard still has to do its job: every write signals Material to refresh the
    # home page, so an unchanged title must not be resent.
    Plugins::PitchforkReviews::Browse::_setHomeYearTitle(undef, 2025);
    is('an unchanged title is not resent', scalar @sent, 1);

    Plugins::PitchforkReviews::Browse::_setHomeYearTitle(undef, 2024);
    is('a changed year is sent', scalar @sent, 2);
    is('...with the new title',  $sent[1], 'Pitchfork: 2024 - Best Albums');

    # ...and the guard is keyed on the YEAR, not on the formatted title (0.8.10).
    # A home extra's title is ONE server-global string, but it is built per client —
    # so on a server whose players carry different language overrides, a title-keyed
    # guard never holds and EVERY home render re-sends it and re-fires Material's
    # home-refresh signal. Nothing about that is visible in a single-language test,
    # which is why the stub cstring above is client-aware.
    my $de = bless { lang => 'DE' }, 'T::Client';
    my $en = bless { lang => 'EN' }, 'T::Client';
    Plugins::PitchforkReviews::Browse::_setHomeYearTitle($de, 2024);
    Plugins::PitchforkReviews::Browse::_setHomeYearTitle($en, 2024);
    Plugins::PitchforkReviews::Browse::_setHomeYearTitle($de, 2024);
    is('two languages naming the same year still write once', scalar @sent, 2);
    Plugins::PitchforkReviews::Browse::_setHomeYearTitle($de, 2023);
    is('...and a genuinely new year is still sent', scalar @sent, 3);
}

print "\n== 5. the home shelf is rank-ordered regardless of the sort pref ==\n";

# A card's item_id is an INDEX PATH, and Material re-traverses it in a SEPARATE, LATER
# request to play. So the shelf's order is part of a contract that spans renders — it
# cannot depend on a pref the user can flip from another page, or a card rendered under
# one order is played under another. (browseGoHome repaints the cached topExtra before
# its re-fetch lands, which is the window where that actually bites.) The in-app list
# keeps its countdown toggle; only the shelf is pinned.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{'https://pitchfork.com/features/lists-and-guides/best-albums-2025/'}
        = yearPage(2025, extra => [
            [ 'div', { class => 'heading-h3' }, '2.' ],
            [ 'h2', 'Artist Two: ', [ 'em', 'Album Two' ] ],
            [ 'p', 'y' x 200 ],
            [ 'div', { class => 'heading-h3' }, '3.' ],
            [ 'h2', 'Artist Three: ', [ 'em', 'Album Three' ] ],
            [ 'p', 'z' x 200 ],
        ]);

    my @ADAPTERS;   # no services: rows stay unmatched, which is all the order test needs
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ADAPTERS };

    my $shelf = sub {
        my $got;
        Plugins::PitchforkReviews::Browse::homeYear(undef, sub { $got = $_[0] }, {});
        return [ map { $_->{name} // $_->{line1} // '' } @{ $got->{items} || [] } ];
    };

    $T::Prefs::P{year_sort} = 'rank';
    my $asc = $shelf->();
    is('the shelf renders every entry', scalar @$asc, 3);
    ok('...best first under the default pref', $asc->[0] =~ /Album One/ && $asc->[2] =~ /Album Three/);

    # The pref the in-app list obeys must not move the shelf.
    $T::Prefs::P{year_sort} = 'countdown';
    my $desc = $shelf->();
    ok('the countdown pref is genuinely set',
        Plugins::PitchforkReviews::Browse::_yearSort() eq 'countdown');
    is('the shelf still renders every entry', scalar @$desc, 3);
    ok('...and is STILL best first', $desc->[0] =~ /Album One/ && $desc->[2] =~ /Album Three/);
    is('the shelf order is identical under both prefs', join('|', @$desc), join('|', @$asc));

    # ...while the in-app view must still honour it, or this became a feature removal.
    my $items = [ map { { rank => $_ } } 1 .. 3 ];
    is('the LIST view still flips to countdown',
        join(',', map { $_->{rank} } @{ Plugins::PitchforkReviews::Browse::_yearOrdered($items, 'countdown') }),
        '3,2,1');
    $T::Prefs::P{year_sort} = undef;
}

print "\n== 6. a die in a fetch callback must not strand the coalescing slot ==\n";

# %PENDING (API::_shareFetch) is released by exactly ONE thing: the fetch calling its
# $done. Everything on the way there — the parse, and the STORE that follows it — must
# therefore be guarded, or a single exception poisons that key for the LIFE OF THE
# PROCESS: every later non-force caller is adopted by a fetch that can never answer.
#
# A throwing write is not theoretical. It used to be $cache->set (DbCache dies outright
# on a character string); since 0.9.8 it is the DB write, which can fail on a locked
# database or a disk error. The risk moved, it did not go away.
#
# BOTH failure shapes are silent, which is why this is here rather than left to luck:
#   - with nothing stored, the view simply never answers;
#   - WITH stored rows (i.e. any server that has fetched successfully even once) the
#     feed serves the same copy for ever and never issues another fetch — it just stops
#     updating, with nothing in the log after the one error.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    Plugins::PitchforkReviews::DB::reset_db();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{'https://pitchfork.com/reviews/albums/'}
        = listingPage('Fresh');
    Plugins::PitchforkReviews::DB::putList('reviews', [ { album => 'Stale', artist => 'A' } ], Plugins::PitchforkReviews::API::PARSE_VERSION());
    $Plugins::PitchforkReviews::DB::KV{'__age'} = 1;   # (unused; keeps the cache stub warm)
    $Plugins::PitchforkReviews::DB::AGE{'reviews'} = 99999;   # expired, so a fetch runs
    $Plugins::PitchforkReviews::DB::DIE_ON_PUT = 1;           # the next store throws

    my @got;
    eval { Plugins::PitchforkReviews::API::getListing(sub { push @got, $_[0][0]{album} }); 1 };
    ok('the caller is still answered when the store throws', scalar @got >= 1);

    $Plugins::PitchforkReviews::DB::DIE_ON_PUT = 0;
    httpReset();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{'https://pitchfork.com/reviews/albums/'}
        = listingPage('Fresh');

    my $later;
    Plugins::PitchforkReviews::API::getListing(sub { $later = $_[0][0]{album} });
    ok('...the key is released, so the next caller is answered', defined $later);
    # Served immediately from the stored rows while the refresh runs behind — that is
    # the stale-while-revalidate property, and it is unchanged by the move to a DB.
    is('...from the stored copy', $later, 'Stale');

    # PREMISE UPDATED AT 0.9.24, and the distinction is the point of that release's
    # finding 3. This used to assert that the very next caller re-fetched. It does not any
    # more: the throw above went down a failure path, which now writes a FEED_MISS_TTL
    # marker, and re-downloading a ~1-2MB listing page on every open while the upstream is
    # broken is the defect that marker exists to stop.
    #
    # What THIS section is about is unchanged and still asserted — a STRANDED key is
    # permanent and nothing can clear it, whereas the marker lapses. So the release is
    # proved by lapsing it, which no amount of suppression could fake.
    is('...and the just-failed feed is NOT re-downloaded straight away', gets(), 0);

    Plugins::PitchforkReviews::DB::kvDel('pfr:feedmiss:reviews');   # the marker lapses
    my $after;
    Plugins::PitchforkReviews::API::getListing(sub { $after = $_[0][0]{album} });
    ok('...and once it lapses a real refresh IS issued — the feed is not frozen', gets() >= 1);
    # The whole point: that refresh lands, so the feed starts moving again. Under the
    # defect the write never happened and the shelf served the old copy until a restart.
    is('...and the refresh reaches the DB, so the next open is fresh',
        Plugins::PitchforkReviews::DB::getList('reviews', Plugins::PitchforkReviews::API::PARSE_VERSION())->[0]{album}, 'Fresh');
}

# The same guarantee on the year path, whose $cb is likewise the only PENDING release.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    Plugins::PitchforkReviews::DB::reset_db();
    my $url = 'https://pitchfork.com/features/lists-and-guides/best-albums-2019/';
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$url} = yearPage(2019);
    $Plugins::PitchforkReviews::DB::DIE_ON_PUT = 1;

    my $first;
    eval { Plugins::PitchforkReviews::API::getYearList(2019, sub { $first = $_[0] }); 1 };
    ok('getYearList answers even when its store throws', ref $first eq 'ARRAY');

    $Plugins::PitchforkReviews::DB::DIE_ON_PUT = 0;
    httpReset();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$url} = yearPage(2019);
    my $second;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $second = $_[0] });
    ok('...and the year key is released for the next caller', ref $second eq 'ARRAY' && @$second);
}

# 6b. THE SAME STRANDING, ONE STEP EARLIER — and 0.8.9's guard does not reach it.
#
# 0.8.9 wrapped everything from the HTTP RESPONSE to $done. But the slot is claimed
# inside _shareFetch and the request is issued by the CALLER afterwards, so the lines
# between were still bare: _yearUrls, ->new, ->get. A synchronous throw in any of them
# strands the key exactly as a parse fault used to, just earlier — and permanently,
# because nothing else ever deletes the slot.
#
# Reproduced before it was fixed: the two calls AFTER the transport recovered were
# never answered at all. That is the assertion below, and it is the one that fails if
# _issueFetch is removed.
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    Plugins::PitchforkReviews::DB::reset_db();
    my $LIST = 'https://pitchfork.com/reviews/albums/';
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$LIST} = listingPage('Fresh');
    Plugins::PitchforkReviews::DB::putList('reviews', [ { album => 'Stale', artist => 'A' } ], Plugins::PitchforkReviews::API::PARSE_VERSION());
    $Plugins::PitchforkReviews::DB::AGE{'reviews'} = 99999;   # expired, so a fetch runs

    $Slim::Networking::SimpleAsyncHTTP::DIE_ON_GET = 1;   # the next ->get throws
    my @got;
    my $escaped = !eval { Plugins::PitchforkReviews::API::getListing(sub { push @got, $_[0] }); 1 };
    ok('a transport throw does not escape to the caller', !$escaped);
    ok('...and the caller is still answered, from the last good copy', scalar @got >= 1);

    # Transport recovers. Under the defect this is where it stayed broken for ever.
    $Slim::Networking::SimpleAsyncHTTP::DIE_ON_GET = 0;
    httpReset();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$LIST} = listingPage('Fresh');

    my $after;
    Plugins::PitchforkReviews::API::getListing(sub { $after = $_[0] });
    ok('...the slot is released, so a later caller is answered', defined $after);
    ok('...and a real fetch is issued again — not adopted by a dead one', gets() >= 1);
    is('...which reaches the DB, so the feed is moving again',
        Plugins::PitchforkReviews::DB::getList('reviews', Plugins::PitchforkReviews::API::PARSE_VERSION())->[0]{album}, 'Fresh');
}

# The year path claims its slot the same way, and has MORE unguarded lines before the
# request (_yearUrls builds the candidate slugs inside the guarded region).
{
    Slim::Utils::Cache::reset(); Plugins::PitchforkReviews::DB::kvReset(); httpReset();
    my $url = 'https://pitchfork.com/features/lists-and-guides/best-albums-2019/';
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$url} = yearPage(2019);

    $Slim::Networking::SimpleAsyncHTTP::DIE_ON_GET = 1;
    my $first;
    my $esc = !eval { Plugins::PitchforkReviews::API::getYearList(2019, sub { $first = $_[0] }); 1 };
    ok('getYearList survives a transport throw', !$esc);
    ok('...and answers rather than hanging', ref $first eq 'ARRAY');

    $Slim::Networking::SimpleAsyncHTTP::DIE_ON_GET = 0;
    httpReset();
    $Slim::Networking::SimpleAsyncHTTP::ROUTES{$url} = yearPage(2019);
    my $second;
    Plugins::PitchforkReviews::API::getYearList(2019, sub { $second = $_[0] });
    ok('...and the year key is free for the next caller',
       ref $second eq 'ARRAY' && @$second);
}

print "\n== 7. adapter detection must not freeze ANY mid-startup answer ==\n";

# The memo exists because detection cannot change without a restart — but "no services"
# is NOT the same statement as "nothing has loaded yet", and _streamingAdapters can be
# reached before the streaming plugins are up (anything hitting _orderedAdapters early).
# Freezing an empty detection silently disables EVERY match until the next restart, with
# no error anywhere. _orderedAdapters needs the same rule for a subtler reason: its cache
# stamp is built from the PREFS, and those do not change when a plugin finishes loading,
# so an empty list cached there is pinned just as hard.
#
# 0.8.10 WIDENS THAT RULE FROM "empty" TO "anything detected before startup finished",
# because a PARTIAL answer has exactly the same cause and was frozen anyway: detection is
# `->can` on three classes, so an early caller sees only what has loaded so far — and
# plugin load order is ALPHABETICAL, so it is reliably Deezer without Qobuz and TIDAL,
# frozen for the life of the process. Nothing is memoised until Plugin::postinitPlugin
# calls markStartupComplete, which runs after every plugin's initPlugin.
#
# Nothing above this point calls the real _orderedAdapters (every earlier section
# `local`-overrides it), so the memo is genuinely cold here.
{
    my $present = 0;
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_detectAdapters = sub {
        return $present ? ( { name => 'Qobuz', icon => 'i.png', query_enc => 'chars', run => sub {} } ) : ();
    };
    $T::Prefs::P{svc_priority_qobuz} = 1;

    is('before the service plugins load, detection finds nothing',
        scalar(Plugins::PitchforkReviews::Browse::_streamingAdapters()), 0);
    is('...and the ordered list is empty too',
        scalar(Plugins::PitchforkReviews::Browse::_orderedAdapters()), 0);

    $present = 1;                                  # the streaming plugin finishes loading

    is('once a service IS present, _streamingAdapters sees it',
        scalar(Plugins::PitchforkReviews::Browse::_streamingAdapters()), 1);
    is('...and so does _orderedAdapters, with no pref change to trigger it',
        scalar(Plugins::PitchforkReviews::Browse::_orderedAdapters()), 1);
    is('...and the cache-key fragment follows',
        Plugins::PitchforkReviews::Browse::_svcOrder(), 'qobuz');
}

# A PARTIAL detection: one service up, two still loading. The memo must not keep it.
{
    my $loaded = 1;
    my $svc = sub { { name => $_[0], icon => 'i.png', query_enc => 'chars', run => sub {} } };
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_detectAdapters = sub {
        # Alphabetical load order, which is what makes this deterministic in the field.
        return map { $svc->($_) } (qw(Deezer Qobuz Tidal))[0 .. $loaded - 1];
    };
    $T::Prefs::P{"svc_priority_$_"} = 1 for qw(qobuz tidal deezer);

    is('mid-startup only the loaded service is detected',
        scalar(Plugins::PitchforkReviews::Browse::_streamingAdapters()), 1);
    $loaded = 3;                                   # the other two finish loading
    is('the partial answer is NOT frozen',
        scalar(Plugins::PitchforkReviews::Browse::_streamingAdapters()), 3);
    is('...nor is it frozen in _orderedAdapters, whose stamp no plugin load can move',
        scalar(Plugins::PitchforkReviews::Browse::_orderedAdapters()), 3);
    is('...and the cache-key fragment names all three',
        Plugins::PitchforkReviews::Browse::_svcOrder(), 'deezer,qobuz,tidal');

    # ...and once startup IS over the memo does its job: a positive answer is
    # detected once and never again.
    Plugins::PitchforkReviews::Browse::markStartupComplete();
    my $calls = 0;
    local *Plugins::PitchforkReviews::Browse::_detectAdapters = sub { $calls++; map { $svc->($_) } qw(Deezer Qobuz Tidal) };
    Plugins::PitchforkReviews::Browse::_streamingAdapters() for 1 .. 4;
    is('after markStartupComplete a positive detection is memoised', $calls, 1);
    $T::Prefs::P{"svc_priority_$_"} = undef for qw(qobuz tidal deezer);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

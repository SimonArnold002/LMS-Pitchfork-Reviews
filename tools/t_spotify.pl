#!/usr/bin/env perl
# Spotify (via Spotty) as the fourth streaming service — and the registry work it needed.
#
# WHAT IS PINNED, and why each half is here:
#   1. _searchSpotify, driven against a stubbed Spotty whose shapes come from Spotty's own
#      source (verified in the ListenBrainz repo's docs/spotify-spotty-adapter-pr17.md):
#      `getAPIHandler` is a CLASS method, `search($cb, {query, type, limit})` calls back with a
#      bare arrayref of normalised albums, the title is `name`, and `OPML::_albumItem` returns a
#      coderef url + a `spotify:album:<id>` favorites_url.
#   2. The adapter registers ONLY when every method it calls exists.
#   3. Spotty's own favorites_url survives the settle loop. Decorating it breaks replay:
#      Spotty's album() extracts the id with a greedy /album:(.*)/, so the query string would be
#      captured into the id. Asserted WITH a control that the same match is decorated when the
#      flag is absent — otherwise this passes against a settle loop that decorates nothing.
#   4. _rebuildStreamItems reattaches each service's OWN `rebuild` coderef, and drops a match
#      whose service is disabled or has none.
#   5. The priority memo is invalidated by a SPOTIFY priority change. Before this build the
#      stamp was a hardcoded qw(qobuz tidal deezer), so a fourth service could never move it.
#   6. The settings page lists Spotify and sanitises its priority; the pref has a default.
#   7. (0.9.36) An EMPTY answer while Spotty reports a 429 is an error, not a verdict.
#   8. (0.9.36) _streamTtl: an `empty_unverified` service ABOVE the winner holds the row a day.
#      The call-site wiring is pinned end to end in t_releaserank.pl section 3h.
#   9. (0.9.37) The background warm runs at FULL width and backs off — one album, a gap after
#      each live resolve — only within SPOTIFY_BACKOFF_WINDOW of a refused Spotify search; never
#      a view or a shelf. (0.9.36's always-slow pacing on the default Client ID was rejected.)
#  9b. (0.9.39) The same back-off through the REAL resolver chain, for the two holes LBF 1.0.5
#      closed: a refusal answers SYNCHRONOUSLY (Spotty's getToken does `return $cb->(-429)`), so
#      the pump must hold on the `_refused` tag rather than read "synchronous" as "cached"; and the
#      gap is ONE re-armed wakeup, not a timer per completion. Section 9 stubs
#      `_findPlayableReview` and cannot see either. Anti-tested with eleven mutants of the fix
#      (tag dropped at each of the six carriers, the tag set on every answer, no `$holding` in the
#      loop, the hold ignoring `_refused`, no re-arm, the wakeup not releasing the hold): each
#      fails only its own assertions here (the stuck-hold one also fails section 9's resume), and the
#      pre-fix Browse.pm fails 14.
#
# Run from the repo root:  perl tools/t_spotify.pl
# Anti-test with PFR_BROWSE= / PFR_SETTINGS= pointed at a mutated copy.
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

# --- throwaway Slim::* tree -------------------------------------------------
BEGIN {
    $INC{$_} = __FILE__ for qw(Slim/Utils/Cache.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm
                              Slim/Utils/Strings.pm Slim/Utils/Timers.pm Slim/Web/Settings.pm);
}
{
    package Slim::Utils::Cache;   sub new { bless {}, shift } sub get { undef } sub set { 1 }
    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; our @WARNED;
                                  sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
                                  sub warn { shift; push @WARNED, join('', @_); return 1 }
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; our %P;
                                  sub AUTOLOAD {} sub get { $P{$_[1]} } sub set { $P{$_[1]} = $_[2] } sub init {}
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  sub cstring { $_[1] } sub string { $_[0] }
    package Slim::Web::Settings;  sub handler { return 'rendered' } sub new { bless {}, shift }
    package Plugins::PitchforkReviews::Plugin; sub dbg {}
    package Slim::Utils::Timers;  sub setTimer { 1 } sub killSpecific { 1 } sub killTimers {}
}
{
    # KV is a NO-OP (nothing is ever served from it), so every resolve below really runs the
    # adapter rather than answering from a store the previous section filled.
    $INC{'Plugins/PitchforkReviews/DB.pm'} = __FILE__;
    package Plugins::PitchforkReviews::DB;
    sub getList { undef } sub putList { 1 } sub listAge { undef }
    sub forget { 1 } sub forgetAll { 1 } sub storedKeys { () }
    sub kvGet { undef } sub kvSet { 1 } sub kvDel { 1 }
    sub kvForgetPrefix { 0 } sub kvCount { 0 } sub kvReset { }
}

# --- a stub Spotty, in the shapes its source actually has ---------------------
our ($API, $RESULT, $DIE_ON, @SEARCHES, $RL);
{
    package Plugins::Spotty::Plugin;
    sub getAPIHandler { my ($class, $client) = @_; return $main::API }   # CLASS method
    package Plugins::Spotty::API;
    # Spotty's own: `return $error429` — set by a 429, cleared by the next successful response.
    sub hasError429 { return $main::RL }
    package T::SpottyAPI;
    sub search { my ($self, $cb, $args) = @_; push @main::SEARCHES, $args; $cb->($main::RESULT) }
    package Plugins::Spotty::OPML;
    sub album { }
    sub _albumItem {
        my ($client, $album) = @_;
        die "renderer blew up\n"
            if defined $main::DIE_ON && ($main::DIE_ON eq '*' || $main::DIE_ON eq $album->{name});
        return {
            name          => "$album->{name}",
            type          => 'playlist',
            url           => \&album,
            passthrough   => [ { uri => $album->{uri} } ],
            favorites_url => $album->{uri},
            image         => 'https://i.scdn.co/image/abc',
        };
    }
}

my $BROWSE   = $ENV{PFR_BROWSE}   || 'PitchforkReviews/Browse.pm';
my $SETTINGS = $ENV{PFR_SETTINGS} || 'PitchforkReviews/Settings.pm';
$INC{'Plugins/PitchforkReviews/Browse.pm'} = $BROWSE;
do($BROWSE =~ m{^/} ? $BROWSE : "./$BROWSE") or die "can't load $BROWSE: " . ($@ || $!);
my $B = 'Plugins::PitchforkReviews::Browse';

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

sub alb { my (%a) = @_; return { artist => 'Band', uri => "spotify:album:$a{id}", release_date => '2024-05-01', %a } }

# Run the REAL _searchSpotify once; returns (collected result, standing flag).
sub search_spotify {
    my ($artist, $album) = @_;
    my ($got, $standing, $called);
    my $collect = sub { ($got, $standing) = @_; $called++ };
    $B->can('_searchSpotify')->(undef, $artist, $B->can('_norm')->($artist),
        $B->can('_norm')->($album), 'Spotify', $collect, $album);
    return ($got, $standing, $called);
}
sub reset_state {
    $API = bless {}, 'T::SpottyAPI'; $RESULT = []; $DIE_ON = undef; $RL = '';
    $Plugins::PitchforkReviews::Browse::SPOTIFY_REFUSED_AT = 0;
    @SEARCHES = (); @T::Log::WARNED = ();
    $B->can('_resetSvcAvailability')->();
}

# =============================================================================
print "\n# 1. _searchSpotify against Spotty's shapes\n";
# =============================================================================
{
    reset_state(); $API = undef;
    my ($got, $standing, $called) = search_spotify('Band', 'Record');
    is('no API handler: the leg is answered exactly once', $called, 1);
    ok('...as COULD NOT QUERY (undef), never as a real miss', !defined $got);
    ok('...through _svcCantAnswer, so it states the fact', grep { /Spotify: no API handler/ } @T::Log::WARNED);
    ok('...and nothing was searched', !@SEARCHES);
}
{
    reset_state(); $RESULT = undef;
    my ($got) = search_spotify('Band', 'Record');
    ok('a non-arrayref answer is COULD NOT QUERY', !defined $got);
    ok('...and says the search errored', grep { /Spotify: search errored/ } @T::Log::WARNED);
}
{
    reset_state();
    $RESULT = [ alb(id => 'abc', name => 'Record'), alb(id => 'zzz', name => 'Other Thing') ];
    my ($got) = search_spotify('Band', 'Record');
    is('the search key is `query` (not `search`)', $SEARCHES[0]{query}, 'Band');
    is('...with the SINGULAR type', $SEARCHES[0]{type}, 'album');
    is('...capped at 50', $SEARCHES[0]{limit}, 50);
    is('only the matching album is kept (title read from `name`)', scalar(@{ $got || [] }), 1);
    my $it = ($got || [])->[0] || {};
    is('_albumid from the bare id', $it->{_albumid}, 'abc');
    is('_svctitle is the service title', $it->{_svctitle}, 'Record');
    is('_year from release_date', $it->{_year}, '2024');
    is("Spotty's own favorites_url is untouched here", $it->{favorites_url}, 'spotify:album:abc');
}
{
    reset_state();
    $RESULT = [ { artists => [ { name => 'Band' } ], uri => 'spotify:album:fromUri9', name => 'Record - Band' } ];
    my ($got) = search_spotify('Band', 'Record');
    my $it = ($got || [])->[0] || {};
    is('no bare id: _albumid is parsed from the uri', $it->{_albumid}, 'fromUri9');
    is('no `artist` string: the first `artists` credit is the candidate artist', scalar(@{ $got || [] }), 1);
    is('an artist affix the service joined on is stripped from _svctitle', $it->{_svctitle}, 'Record');
}
{
    reset_state();
    $RESULT = [ alb(id => 'a1', name => 'Record'), alb(id => 'a2', name => 'Record (Deluxe)') ];
    $DIE_ON = 'Record';
    my ($got) = search_spotify('Band', 'Record');
    ok('one renderer dies: the other match is still served', ref $got eq 'ARRAY' && @$got == 1);
}
{
    reset_state();
    $RESULT = [ alb(id => 'a1', name => 'Record') ];
    $DIE_ON = '*';
    my ($got) = search_spotify('Band', 'Record');
    ok('every renderer dies: COULD NOT QUERY, not a real miss', !defined $got);
}
{
    reset_state();
    $RESULT = [];
    my ($got) = search_spotify('Band', 'Record');
    ok('an empty arrayref is a real answer (Spotty cannot tell us otherwise)', ref $got eq 'ARRAY' && !@$got);
}

# =============================================================================
print "\n# 2. the adapter registers only when every method it calls exists\n";
# =============================================================================
{
    my ($sp) = grep { $_->{name} eq 'Spotify' } $B->can('_detectAdapters')->();
    ok('Spotify is registered', $sp);
    is('...searching in characters', ($sp || {})->{query_enc}, 'chars');
    ok('...flagged native_favurl', ($sp || {})->{native_favurl});
    ok('...with OPML::album as its rebuild coderef', ($sp || {})->{rebuild} && $sp->{rebuild} == \&Plugins::Spotty::OPML::album);
}
for my $missing (qw(Plugins::Spotty::OPML::album Plugins::Spotty::OPML::_albumItem Plugins::Spotty::Plugin::getAPIHandler)) {
    no strict 'refs';
    local *{$missing};
    my ($sp) = grep { $_->{name} eq 'Spotify' } $B->can('_detectAdapters')->();
    ok("...and NOT registered without $missing", !$sp);
}

# =============================================================================
print "\n# 3. the settle loop keeps Spotty's favorites_url, and only because of the flag\n";
# =============================================================================
sub resolve_with {
    my (@adapters) = @_;
    my $answer;
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @adapters };
    $B->can('_findPlayable')->(undef, sub { $answer = $_[0] }, 'Band', 'Record');
    return grep { ref $_ eq 'HASH' && $_->{_svc} } @{ ($answer || {})->{items} || [] };
}
{
    reset_state();
    my ($sp) = grep { $_->{name} eq 'Spotify' } $B->can('_detectAdapters')->();
    $RESULT = [ alb(id => 'abc', name => 'Record') ];
    my ($it) = resolve_with({ %$sp, priority => 1 });
    is('a resolved Spotify row keeps the bare spotify:album uri', ($it || {})->{favorites_url}, 'spotify:album:abc');

    reset_state();
    $RESULT = [ alb(id => 'abc', name => 'Record') ];
    my %noflag = (%$sp, priority => 1); delete $noflag{native_favurl};
    my ($ctl) = resolve_with(\%noflag);
    ok('CONTROL: without the flag the same match IS decorated (so the flag is what saves it)',
       (($ctl || {})->{favorites_url} // '') =~ m{^spotify://album:abc\?});
}

# =============================================================================
print "\n# 4. _rebuildStreamItems reattaches each adapter's own coderef\n";
# =============================================================================
{
    my $rb = sub { };
    my @cached = (
        { name => 'sp', _svc => 'Spotify', passthrough => [ { uri => 'spotify:album:abc' } ] },
        { name => 'qb', _svc => 'Qobuz',   passthrough => [ { id => 1 } ] },
    );
    no warnings 'redefine';
    {
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { ( { name => 'Spotify', rebuild => $rb } ) };
        my $out = $B->can('_rebuildStreamItems')->(\@cached);
        is('a disabled service\'s cached match is dropped', scalar(@$out), 1);
        ok('the Spotify match gets ITS adapter\'s coderef back', $out->[0]{url} && $out->[0]{url} == $rb);
        is('...and keeps its passthrough (where the album id lives)', $out->[0]{passthrough}[0]{uri}, 'spotify:album:abc');
        ok('the cached input is not mutated', !exists $cached[0]{url});
    }
    {
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { ( { name => 'Spotify' } ) };
        is('an enabled adapter with no rebuild coderef cannot replay, so it is dropped',
           scalar(@{ $B->can('_rebuildStreamItems')->(\@cached) }), 0);
    }
}

# =============================================================================
print "\n# 5. a Spotify priority change invalidates the memo\n";
# =============================================================================
{
    %T::Prefs::P = map { ("svc_priority_$_" => 1) } qw(qobuz tidal deezer spotify);
    $B->can('markStartupComplete')->();
    my @before = map { $_->{name} } $B->can('_orderedAdapters')->();
    ok('Spotify is ordered in while its priority is 1', grep { $_ eq 'Spotify' } @before);
    $T::Prefs::P{svc_priority_spotify} = 0;
    my @after = map { $_->{name} } $B->can('_orderedAdapters')->();
    ok('priority 0 takes it out on the very next ask (the memo stamp covers it)', !grep { $_ eq 'Spotify' } @after);
    is('...and the cache-key service order follows', $B->can('_svcOrder')->(), '');
    $T::Prefs::P{svc_priority_spotify} = 1;
    is('back to 1 and it is in the key again', $B->can('_svcOrder')->(), 'spotify');

    my ($row) = grep { $_->{key} eq 'spotify' } @{ $B->can('serviceStatus')->() };
    ok('the settings page lists Spotify', $row);
    is('...as installed', ($row || {})->{installed}, 1);
}

# =============================================================================
print "\n# 6. settings + pref default\n";
# =============================================================================
{
    do($SETTINGS =~ m{^/} ? $SETTINGS : "./$SETTINGS") or die "can't load $SETTINGS: " . ($@ || $!);
    my (undef, @names) = Plugins::PitchforkReviews::Settings->prefs;
    ok('svc_priority_spotify is a saved pref', grep { $_ eq 'svc_priority_spotify' } @names);
    ok('...alongside the other three', 3 == grep { /^svc_priority_(qobuz|tidal|deezer)$/ } @names);

    %T::Prefs::P = (svc_priority_spotify => 6);
    my %params = (saveSettings => 1, pref_svc_priority_spotify => '12');
    Plugins::PitchforkReviews::Settings->handler(undef, \%params);
    is('a Spotify priority above 9 is clamped on save', $params{pref_svc_priority_spotify}, 9);
    %params = (saveSettings => 1);
    Plugins::PitchforkReviews::Settings->handler(undef, \%params);
    is('an absent Spotify field keeps the saved value', $params{pref_svc_priority_spotify}, 6);

    open my $fh, '<', 'PitchforkReviews/Plugin.pm' or die $!;
    my $src = do { local $/; <$fh> };
    my ($def) = scalar($src =~ /svc_priority_spotify\s*=>\s*(\d+)/) ? ($1) : ();
    is('Plugin.pm gives Spotify a default priority, last of the four', $def, 4);
}

# =============================================================================
print "\n# 7. an empty answer while Spotty is rate-limiting is an error, not a verdict\n";
# =============================================================================
{
    reset_state(); $RESULT = []; $RL = 'Access Rate limit exceeded; retry after 7 seconds.';
    my ($got, undef, $called) = search_spotify('Band', 'Record');
    is('rate-limited + empty: the leg is answered exactly once', $called, 1);
    ok('...as COULD NOT QUERY (undef), so it is recorded ERRORED', !defined $got);
    ok('...and the warn says why', grep { /Spotify: empty answer while Spotify is rate-limiting \(429\)/ } @T::Log::WARNED);
    ok('...and it starts the warm\'s back-off clock',
       time() - ($Plugins::PitchforkReviews::Browse::SPOTIFY_REFUSED_AT || 0) <= 1);

    reset_state(); $RESULT = []; $RL = '';
    ($got) = search_spotify('Band', 'Record');
    ok('CONTROL: empty with no 429 is still a real miss ([])', ref $got eq 'ARRAY' && !@$got);
    ok('CONTROL: ...and a real miss does not start the back-off', !$Plugins::PitchforkReviews::Browse::SPOTIFY_REFUSED_AT);

    reset_state(); $RESULT = [ alb(id => 'abc', name => 'Record') ]; $RL = 'stale';
    ($got) = search_spotify('Band', 'Record');
    is('a list WITH albums is an answer whatever the flag says', (ref $got eq 'ARRAY' ? scalar(@$got) : -1), 1);

    reset_state(); $RESULT = []; $RL = 'set';
    {
        no warnings 'redefine';
        local *Plugins::Spotty::API::hasError429;
        ($got) = search_spotify('Band', 'Record');
    }
    ok('a Spotty without hasError429 is "no signal": empty stays a real miss', ref $got eq 'ARRAY' && !@$got);
}

# =============================================================================
print "\n# 8. _streamTtl: an unverifiable empty answer ABOVE the winner holds the row a day\n";
# =============================================================================
{
    my $ttl = $B->can('_streamTtl');
    my ($A, $E, $U) = map { $B->can($_)->() } qw(OUTCOME_ANSWERED OUTCOME_ERRORED OUTCOME_UNAVAILABLE);
    my ($FOUND, $UNVAL, $NOMATCH) = map { $B->can($_)->() } qw(STREAM_FOUND_TTL STREAM_UNVALIDATED_TTL STREAM_NOMATCH_TTL);
    is('flagged service ABOVE the winner answered empty -> a day',  $ttl->([$A, $A], 2, 1, 1, [1, 0]), $UNVAL);
    is('...or errored above it -> a day',                           $ttl->([$E, $A], 2, 1, 1, [1, 0]), $UNVAL);
    is('CONTROL: the same run with no flag keeps thirty days',     $ttl->([$A, $A], 2, 1, 1, [0, 0]), $FOUND);
    is('a flagged service BELOW the winner changes nothing',       $ttl->([$A, $A], 2, 0, 1, [0, 1]), $FOUND);
    is('a flagged service that IS the winner keeps thirty days',   $ttl->([$A, $A], 2, 0, 1, [1, 0]), $FOUND);
    is('a STANDING-unavailable flagged service lost no answer',    $ttl->([$U, $A], 2, 1, 1, [1, 0]), $FOUND);
    is('flag two above the winner, unflagged one between -> a day', $ttl->([$A, $A, $A], 3, 2, 1, [1, 0, 0]), $UNVAL);
    is('no winner: a confirmed no-match is untouched (ledger B)',  $ttl->([$A, $A], 2, undef, 0, [1, 0]), $NOMATCH);
    is('a four-argument call is exactly what it was',              $ttl->([$A, $A], 2, 1, 1), $FOUND);
    my ($sp) = grep { $_->{name} eq 'Spotify' } $B->can('_detectAdapters')->();
    is('the Spotify adapter carries the flag', ($sp || {})->{empty_unverified}, 1);
}

# =============================================================================
print "\n# 9. the background warm backs off while Spotify refuses\n";
# =============================================================================
{
    reset_state();
    my ($sp) = grep { $_->{name} eq 'Spotify' } $B->can('_detectAdapters')->();
    my (@timers, @pending);
    my $SYNC = 0;
    no warnings 'redefine';
    # All three stubs live for the WHOLE block: completions below run long after _resolveSection
    # returned, and a `local` scoped to one run would hand them the real resolver.
    local *Slim::Utils::Timers::setTimer = sub { push @timers, { in => $_[1] - time(), cb => $_[2] }; scalar @timers };
    local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { ( { %$sp, priority => 1 } ) };
    local *Plugins::PitchforkReviews::Browse::_findPlayableReview = sub {
        my (undef, $cb) = @_;
        return $cb->({ items => [] }) if $SYNC;   # a cache hit answers synchronously (a REFUSAL is tagged — 9b)
        push @pending, $cb;                       # a live search answers later
    };
    my $run = sub {
        my ($mode) = @_;
        @timers = (); @pending = ();
        my $done = 0;
        $B->can('_resolveSection')->(undef, [ map { { artist => "A$_", album => "R$_" } } 1 .. 5 ],
            sub { $done++ }, $B->WARM_DEADLINE, $mode);
        return \$done;
    };
    my ($GAP, $WINDOW, $WD) = ($B->PACED_WARM_GAP, $B->SPOTIFY_BACKOFF_WINDOW, $B->WARM_DEADLINE);
    my $refused = sub { $Plugins::PitchforkReviews::Browse::SPOTIFY_REFUSED_AT = shift };
    my $drain   = sub { $_->({ items => [] }) for splice @pending };

    # HEALTHY IS THE NORMAL CASE, and it must cost nothing: 0.9.36 slowed every warm on the
    # default Client ID and was rejected for exactly that.
    $refused->(0);
    $run->('warm');
    is('healthy: the warm runs at FULL width, no waiting', scalar(@pending), 5);
    ok('...under its ordinary deadline', @timers && $timers[0]{in} <= $WD);
    $drain->();

    # Every step below is GUARDED, so a build that never backs off fails these by name rather
    # than dying on a timer that was never armed and hiding whatever would follow.
    $refused->(time());
    my $d = $run->('warm');
    is('refused moments ago: ONE album in flight', scalar(@pending), 1);
    (shift(@pending) || sub {})->({ items => [] });
    is('a LIVE completion does not dispatch the next album straight away', scalar(@pending), 0);
    ok('...it arms one PACED_WARM_GAP timer instead', @timers == 2 && $timers[1]{in} <= $GAP && $timers[1]{in} >= $GAP - 1);
    $refused->(0);                                    # the refusals stop
    $timers[1]{cb}->() if @timers == 2;
    is('once the refusals stop, the rest go out together at full width', scalar(@pending), 4);
    $drain->();
    is('the section completes', $$d, 1);

    $refused->(time() - $WINDOW - 1);
    $run->('warm');
    is('a refusal older than SPOTIFY_BACKOFF_WINDOW slows nothing', scalar(@pending), 5);
    $drain->();

    $refused->(time()); $SYNC = 1;
    $d = $run->('warm');
    is('backing off, CACHE HITS still complete in one pass', $$d, 1);
    is('...with no gap timer at all (only the deadline)', scalar(@timers), 1);
    $SYNC = 0;

    {
        local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { () };
        $run->('warm');
        is('Spotify switched off (priority 0): nothing to back off for', scalar(@pending), 5);
        $drain->();
    }
    $run->('shelf');
    is('a home SHELF never backs off', scalar(@pending), 5);
    $drain->();
    $run->('view');
    is('a VIEW never backs off', scalar(@pending), 5);
    $drain->();
    is('the warm reads the Spotify adapter\'s own probe', $sp->{pace_warm} == $B->can('_spotifyBackingOff') ? 1 : 0, 1);
    $refused->(0);
}

# =============================================================================
print "\n# 9b. the real resolver: a synchronous refusal holds the warm; one wakeup, re-armed\n";
# =============================================================================
{
    reset_state();
    my ($sp) = grep { $_->{name} eq 'Spotify' } $B->can('_detectAdapters')->();
    my (@timers, @pending);
    no warnings 'redefine';
    # A timer is a record that can be KILLED, so "one wakeup pending" means one that can still fire.
    local *Slim::Utils::Timers::setTimer     = sub { push @timers, { at => $_[1], cb => $_[2], live => 1 }; $timers[-1] };
    local *Slim::Utils::Timers::killSpecific = sub { $_[0]{live} = 0 if ref $_[0] eq 'HASH'; 1 };
    local *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { ( { %$sp, priority => 1 } ) };   # Spotify ONLY
    my $SYNC  = \&T::SpottyAPI::search;   # answers in-stack, as Spotty's refusal does
    my $ASYNC = sub {                     # a live search: answers later
        my ($self, $cb, $args) = @_;
        push @main::SEARCHES, $args;
        my ($n) = $args->{query} =~ /(\d+)/;
        push @pending, sub { $cb->([ alb(id => "i$n", name => "Record$n", artist => "Band$n") ]) };
    };
    my $GAP   = $B->PACED_WARM_GAP;
    my $gaps  = sub { grep { $_->{live} && abs($_->{at} - time() - $GAP) < 0.5 } @timers };
    my $wake  = sub { my ($t) = $gaps->(); return 0 unless $t; $t->{live} = 0; $t->{cb}->(); 1 };
    my $run   = sub {
        my ($n, $mode) = @_;
        my $done = 0;
        $B->can('_resolveSection')->(undef, [ map { { artist => "Band$_", album => "Record$_" } } 1 .. $n ],
            sub { $done++ }, $B->WARM_DEADLINE, $mode);
        return \$done;
    };
    my $got;
    my $review = sub { $got = undef; $B->can('_findPlayableReview')->(undef, sub { $got = shift }, @_); $got || {} };

    # THE DEFECT: with the window closed at the start, a Spotify-only warm sent every album into
    # the lockout in one turn and stored each as "couldn't check" for STREAM_INCONCLUSIVE_TTL.
    reset_state(); @timers = (); $RL = 1; $RESULT = [];
    my $d = $run->(10, 'warm');
    is('refused in-stack: ONE search goes out in that turn, not ten', scalar(@SEARCHES), 1);
    is('...ONE paced wakeup is armed', scalar($gaps->()), 1);
    ok('...and the section is still open', !$$d);
    my $woke = 0;
    $woke += $wake->() for 2 .. 10;
    is('each wakeup sends exactly one more search', scalar(@SEARCHES), 10);
    is('...nine wakeups for the other nine albums', $woke, 9);
    is('the section completes after the last album', $$d, 1);
    is('...and leaves no wakeup behind', scalar($gaps->()), 0);

    # THE TAG: only a refusal carries it.
    reset_state(); $RL = 1;
    ok('the resolver tags a refused answer `_refused`', $review->('BandX', 'RecordX')->{_refused});
    reset_state(); $RL = ''; $RESULT = [];
    ok('CONTROL: a real empty answer is not tagged', !$review->('BandX', 'RecordX')->{_refused});

    # EVERY WRAPPER FORWARDS IT, including when only a LATER search in the review was refused.
    # `$from`: Spotty reports the 429 from that search onwards (1-based).
    {
        my $from;
        local *Plugins::Spotty::API::hasError429 = sub { $from && @main::SEARCHES >= $from };
        my @cases = (
            [ 1,  'BandS', 'Record: The Sub', 2020, 1, 'subtitled review, everything refused' ],
            [ 3,  'BandS', 'Record: The Sub', 2020, 1, 'subtitled review, only the base-title retry refused' ],
            [ 1,  'BandC', 'Alpha / Beta',   undef, 1, 'combined review, everything refused' ],
            [ 3,  'BandC', 'Alpha / Beta',   undef, 1, 'combined review, only the sides refused' ],
            [ 99, 'BandC', 'Alpha / Beta',   undef, 0, 'CONTROL: combined review, nothing refused' ],
        );
        for my $c (@cases) {
            my ($f0, $artist, $album, $minYear, $want, $what) = @$c;
            reset_state(); $from = $f0;
            is($what, ($review->($artist, $album, undef, $minYear)->{_refused} ? 1 : 0), $want);
        }
        local *Plugins::Spotty::API::hasError429 = sub { @main::SEARCHES == 1 };
        reset_state();
        is('combined review, only the full-title search refused', ($review->('BandC', 'Alpha / Beta')->{_refused} ? 1 : 0), 1);
    }

    # CONTROLS: the hold is for refusals, not for synchronous answers, and never for a view.
    reset_state(); @timers = (); $RL = ''; $RESULT = [];
    $Plugins::PitchforkReviews::Browse::SPOTIFY_REFUSED_AT = time();
    $d = $run->(10, 'warm');
    ok('CONTROL: backing off, untagged in-stack answers (the cache-hit shape) run straight through',
       @SEARCHES >= 10 && $$d == 1);
    is('CONTROL: ...and arm no wakeup', scalar($gaps->()), 0);
    reset_state(); @timers = (); $RL = 1;
    $d = $run->(10, 'view');
    ok('CONTROL: a VIEW refused in-stack still sends all ten', @SEARCHES == 10 && $$d == 1);
    is('CONTROL: ...and arms no wakeup', scalar($gaps->()), 0);

    # ONE WAKEUP. Pre-fix, every completion armed its own timer: ten in flight when the back-off
    # began left ten wakeups, and each stray launched a search the moment it fired — straight after
    # the one before had completed.
    reset_state(); @timers = (); @pending = (); $RL = '';
    {
        local *T::SpottyAPI::search = $ASYNC;
        $run->(20, 'warm');
        my $wide = scalar @SEARCHES;
        $Plugins::PitchforkReviews::Browse::SPOTIFY_REFUSED_AT = time();   # a refusal lands now
        (shift @pending)->() for 1 .. $wide;                              # everything in flight returns
        is("$wide completions leave ONE wakeup", scalar($gaps->()), 1);
        is('...and launch nothing themselves', scalar(@SEARCHES), $wide);
        $wake->();
        is('the wakeup launches one search', scalar(@SEARCHES), $wide + 1);
        is('...and nothing else is armed while it is in flight', scalar($gaps->()), 0);
        (shift(@pending) || sub {})->();
        is('its completion re-arms ONE wakeup', scalar($gaps->()), 1);
        is('...and launches nothing until it fires', scalar(@SEARCHES), $wide + 1);
        @pending = ();
    }

    # A caller that JOINED the in-flight resolve is answered with the tag too.
    reset_state(); @pending = (); $RL = '';
    {
        my ($own, $joined);
        local *T::SpottyAPI::search = sub {
            my ($self, $cb, $args) = @_;
            push @main::SEARCHES, $args;
            push @pending, sub { $main::RL = 1; $cb->([]) };   # the 429 arrives with the answer
        };
        $B->can('_findPlayable')->(undef, sub { $own    = shift }, 'BandW', 'RecordW');
        $B->can('_findPlayable')->(undef, sub { $joined = shift }, 'BandW', 'RecordW');
        is('a second caller for the same album joins (one search)', scalar(@SEARCHES), 1);
        (shift(@pending) || sub {})->();
        ok('...and the owner AND the waiter are both answered `_refused`',
           $own && $own->{_refused} && $joined && $joined->{_refused});
    }
    $B->can('_resetResolving')->();
    reset_state();
}

print "\n$p passed, $f failed\n";
exit($f ? 1 : 0);

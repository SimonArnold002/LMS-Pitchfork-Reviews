#!/usr/bin/env perl
# The two-leg streaming search: artist first, album title as a fallback (0.7.12).
#
# WHY THIS EXISTS. `_findPlayable` searches each service for the ARTIST and filters the
# results with `_albumMatches`. That is the right default — the artist is the stable term,
# while a title drags in "EP"/"LP" and edition noise — but it fails completely when the
# artist's name is a common word. Field case: Qobuz CARRIES "Leo - Cicada Burnt" and returns
# it FIRST for the query "cicada burnt", while its album search for "leo" gives 200 rows of
# Leo Sayer, Léo Ferré, Leo Dan and Leo Kottke without it. The matcher was never the problem;
# the release never reached it.
#
# What has to stay true, and each is easy to break in an async closure:
#   1. A leg that MATCHES settles immediately — no second search, no extra service load.
#   2. A DEFINED but EMPTY leg retries on the album title, and that leg's matches win.
#   3. An UNDEF leg (no handler / timeout / error) does NOT retry — a second query would
#      spend another STREAM_SVC_TIMEOUT to reach the same inconclusive answer.
#   4. At most ONE retry per service, ever.
#   5. No retry when the album title would just repeat the artist query (self-titled), or
#      when there is no title at all.
#   6. The retry carries the ALBUM in the adapter's own encoding (Qobuz/Tidal want
#      characters, Deezer wants octets) — the leg-2 query must not fall back to the artist.
#
# Run from the repo root:  perl tools/t_searchlegs.pl
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

# --- throwaway Slim::* tree -------------------------------------------------
BEGIN {
    $INC{'Slim/Utils/Cache.pm'} = $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'}
        = $INC{'Slim/Utils/Strings.pm'} = $INC{'Slim/Utils/Timers.pm'} = __FILE__;
}
{
    package Slim::Utils::Cache;   sub new { bless {}, shift } sub get { undef } sub set { 1 }
    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; sub AUTOLOAD {} sub get { undef } sub set {} sub init {}
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  sub cstring { $_[1] } sub string { $_[0] }
    # Timers never FIRE here: every scripted leg answers synchronously, so a timer that
    # fired would mean the code settled twice. We count arm/kill instead.
    package Plugins::PitchforkReviews::Plugin; sub dbg {}
    package Slim::Utils::Timers;
    our (@armed, @killed);
    sub setTimer { push @armed, $_[2]; return scalar @armed }
    sub killSpecific { push @killed, $_[0]; 1 }
    sub killTimers {}
}
{
    # Minimal DB stub — Browse.pm reaches the key/value store through this module now.
    $INC{'Plugins/PitchforkReviews/DB.pm'} = __FILE__;
    package Plugins::PitchforkReviews::DB;
    our (%LISTS, %VER, %AGE);
    sub getList { my ($k,$v)=@_; return undef unless $LISTS{$k};
                  return undef if defined $v && defined $VER{$k} && $VER{$k} != $v; $LISTS{$k} }
    sub putList { my ($k,$i,$v)=@_; return 0 unless ref $i eq 'ARRAY' && @$i;
                  $LISTS{$k}=$i; $VER{$k}=$v; $AGE{$k}=0; 1 }
    sub listAge    { exists $LISTS{$_[0]} ? ($AGE{$_[0]} // 0) : undef }
    sub forget     { delete $LISTS{$_[0]}; delete $AGE{$_[0]}; delete $VER{$_[0]}; 1 }
    sub forgetAll  { %LISTS=(); %AGE=(); %VER=(); 1 }
    sub storedKeys { sort keys %LISTS }
    sub reset_db   { %LISTS=(); %AGE=(); %VER=(); kvReset(); }
    # KV SIDE — DELIBERATELY A NO-OP HERE, matching the no-op Slim::Utils::Cache stub
    # this suite has always used. These are SEARCH-LEG tests: they run the same album
    # through the resolver repeatedly to count legs and check fan-out, so a real store
    # would serve case 2 onward from cache and make every assertion after the first
    # vacuous. Storage behaviour is covered in t_db and t_perf.
    sub kvGet { undef }
    sub kvSet { 1 }
    sub kvDel { 1 }
    sub kvForgetPrefix { 0 }
    sub kvCount { 0 }
    sub kvReset { }
}

my $BROWSE = $ENV{PFR_BROWSE} || 'PitchforkReviews/Browse.pm';
$INC{'Plugins/PitchforkReviews/Browse.pm'} = $BROWSE;
do($BROWSE =~ m{^/} ? $BROWSE : "./$BROWSE") or die "can't load $BROWSE: " . ($@ || $!);

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

# Scripted services. @script is the reply per leg, in order: an ARRAYREF is a result
# set (empty = "searched, found nothing"), undef = "couldn't query the service".
my @QUERIES;                       # every query actually issued, in order
sub adapters_returning {
    my (%svc) = @_;                # name => { script => [...], query_enc => 'chars'|'bytes' }
    my @a;
    for my $name (sort keys %svc) {
        my $cfg  = $svc{$name};
        my @plan = @{ $cfg->{script} };
        push @a, {
            name      => $name,
            icon      => "icon-$name",
            priority  => ($cfg->{priority} || 1),
            query_enc => ($cfg->{query_enc} || 'bytes'),
            run       => sub {
                my ($client, $query, $artistNorm, $albumNorm, $svc, $collect, $albumRaw) = @_;
                push @QUERIES, { svc => $svc, query => $query };
                my $next = shift @plan;
                $collect->($next);
            },
        };
    }
    return sort { $a->{priority} <=> $b->{priority} } @a;
}

my @ADAPTERS;
{
    no warnings 'redefine';
    *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ADAPTERS };
}

sub resolve {
    my ($artist, $album, %svc) = @_;
    @QUERIES = ();
    @Slim::Utils::Timers::armed = @Slim::Utils::Timers::killed = ();
    @ADAPTERS = adapters_returning(%svc);
    my $got;
    Plugins::PitchforkReviews::Browse::_findPlayable(undef, sub { $got = $_[0] }, $artist, $album);
    return $got;
}
sub queries    { map { $_->{query} } @QUERIES }
sub matchNames { my $r = shift; map { $_->{name} // '' } @{ $r->{items} || [] } }

my $HIT = [ { name => 'Leo - Cicada Burnt', image => 'cover.jpg' } ];

# --- 1. artist leg matches: settle, do NOT search again ---------------------
{
    my $r = resolve('Radiohead', 'In Rainbows', Qobuz => { script => [ $HIT ] });
    is('one query only',            scalar(my @q = queries()), 1);
    is('and it was the artist',     ($q[0]),                   'Radiohead');
    is('the match is returned',     (matchNames($r))[0],       'Leo - Cicada Burnt');
}

# --- 2. artist leg empty: retry on the album title, and that leg wins -------
{
    my $r = resolve('Leo', 'Cicada Burnt', Qobuz => { script => [ [], $HIT ] });
    my @q = queries();
    is('two queries issued',        scalar(@q),                2);
    is('leg 1 = the artist',        $q[0],                     'Leo');
    is('leg 2 = the ALBUM TITLE',   $q[1],                     'Cicada Burnt');
    is('the album leg supplies the match', (matchNames($r))[0],'Leo - Cicada Burnt');
    ok('leg 1 watchdog was killed before leg 2 armed',
        scalar(@Slim::Utils::Timers::killed) >= 1);
    is('each leg armed its own watchdog', scalar(@Slim::Utils::Timers::armed), 2);
}

# --- 3. undef (service unreachable) must NOT retry --------------------------
{
    my $r = resolve('Leo', 'Cicada Burnt', Qobuz => { script => [ undef, $HIT ] });
    is('inconclusive does not retry', scalar(my @q = queries()), 1);
    is('and reports no match',        (matchNames($r))[0],      'PLUGIN_PITCHFORKREVIEWS_NO_MATCH');
}

# --- 4. at most ONE retry, and a double miss settles as a miss --------------
{
    my $r = resolve('Leo', 'Cicada Burnt', Qobuz => { script => [ [], [], $HIT ] });
    is('exactly two legs, never three', scalar(my @q = queries()), 2);
    is('settles as no match',           (matchNames($r))[0],      'PLUGIN_PITCHFORKREVIEWS_NO_MATCH');
}

# --- 5. nothing to gain from a second leg -----------------------------------
{
    resolve('Weezer', 'Weezer', Qobuz => { script => [ [], $HIT ] });
    is('self-titled: no second leg',  scalar(my @q = queries()), 1);

    resolve('Leo', '', Qobuz => { script => [ [], $HIT ] });
    is('no album title: no second leg', scalar(my @q2 = queries()), 1);

    # The skip is decided under _norm, not on the raw strings, so a title that only
    # differs from the artist by stylisation is still a repeat of the same query.
    resolve('Pink', 'P!nk', Qobuz => { script => [ [], $HIT ] });
    is('title equal to the artist under _norm: no second leg', scalar(my @q3 = queries()), 1);

    # ...but a title that merely LOOKS similar is not: "P!nk" folds to "pink" while a
    # spaced-out "p ! n k" does not, so these are two different queries and both run.
    resolve('P!nk', 'p ! n k', Qobuz => { script => [ [], $HIT ] });
    is('genuinely different title: second leg runs', scalar(my @q4 = queries()), 2);
}

# --- 6. the retry uses the ALBUM in each adapter's own encoding -------------
# The title carries an en dash (U+2013, above Latin-1) on purpose: a string whose every
# codepoint fits in a byte may sit in Perl WITHOUT the UTF8 flag, and then the character
# and octet spellings are indistinguishable — which would let a leg-2 encoding bug pass.
{
    my $ALBUM = "\x{c1}g\x{e6}tis byrjun \x{2013} 20th";
    my $expChars = $ALBUM;
    my $expBytes = $ALBUM; utf8::encode($expBytes);

    resolve("Sigur R\x{f3}s", $ALBUM,
        Qobuz  => { script => [ [], [] ], query_enc => 'chars', priority => 1 },
        Deezer => { script => [ [], [] ], query_enc => 'bytes', priority => 2 },
    );
    my %leg2 = map { $_->{svc} => $_->{query} } grep { $_->{query} !~ /Sigur/ } @QUERIES;
    is('all four legs ran',              scalar(my @q = queries()), 4);
    ok('leg 2 queried the ALBUM, not the artist',
        2 == grep { defined } @leg2{qw(Qobuz Deezer)});
    ok('chars adapter got the album as CHARACTERS',
        utf8::is_utf8($leg2{Qobuz}) && $leg2{Qobuz} eq $expChars);
    ok('bytes adapter got the SAME album as OCTETS',
        !utf8::is_utf8($leg2{Deezer}) && $leg2{Deezer} eq $expBytes);
    ok('the two spellings really are different strings', $expChars ne $expBytes);
}

# --- 7. priority decides, and a beaten service is never even asked (0.8.8) --
# The answer was ALWAYS only allowed to be the highest-priority match, so firing every
# service at once sent searches whose results could not be used. Now the top-priority
# service is probed alone and the rest follow only if it fails to settle the question.
# Both legs of the winner still run when the first comes back empty (section 2) — what
# disappears is the LOSER's traffic, which is most of it, since most albums match on
# the first service. See t_perf.pl for the fan-out half of this contract.
{
    my $r = resolve('Leo', 'Cicada Burnt',
        Qobuz  => { script => [ [], [ { name => 'from qobuz' } ] ], priority => 1 },
        Deezer => { script => [ [ { name => 'from deezer' } ] ],    priority => 2 },
    );
    is('higher-priority service still wins', (matchNames($r))[0], 'from qobuz');
    my @deezer = grep { $_->{svc} eq 'Deezer' } @QUERIES;
    is('the beaten service was never queried', scalar(@deezer), 0);
    my @qobuz = grep { $_->{svc} eq 'Qobuz' } @QUERIES;
    is('the winner still ran both of its own legs', scalar(@qobuz), 2);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

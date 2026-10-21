#!/usr/bin/env perl
# Which of several like-named releases wins the row, and what the others are offered as
# (0.9.27).
#
# THE FIELD CASE, and both halves of it are real measurements, not a constructed fixture.
# Pitchfork reviewed Interpol's *This Mirror Weighs a Ton* (28 Aug 2026). Qobuz carries two
# releases whose titles both satisfy `_albumMatches`:
#
#     This Mirror Weighs a Ton/See Out Loud   2 tracks   type Single   artist search pos 7
#     This Mirror Weighs a Ton               12 tracks   type Album    artist search pos 68
#
# `QOBUZ_SEARCH_LIMIT` is 50, so the ALBUM was never in the candidate set at all, and the
# single won the row by being the only thing there. Two independent defects, and either one
# alone still gets it wrong: lift the cap and the single is still first in raw order; rank
# correctly and there is still nothing to rank against.
#
# THE OPPOSITE DIRECTION IS THE HARD PART and is why this suite is not just "prefer the
# album". PFR has NO release type for the target — `_parseState` extracts artist, album,
# capsule, link, date, cover, score, genre, and the only hint that ever exists is the
# literal " EP" in Pitchfork's title, which `_stripFmt` deliberately discards to make the
# match work. Live counter-examples, both currently in the feeds:
#
#     Djrum - I Wander EP       -> service "I Wander" (6-track EP), plus same-artist
#                                  singles "I Wander (III)" / "I Wander (IV + V)" which
#                                  `_norm` (brackets stripped) also admits
#     Faith Leazae - Faith EP   -> Deezer types that same record `album`, 8 tracks
#
# So a type filter cannot be built here, and any rule keyed on strict title equality taxes
# every EP review. Both directions are pinned below; a change that fixes one by breaking
# the other fails this suite.
#
# Run from the repo root:  perl tools/t_releaserank.pl
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
    # `warn` is RECORDED rather than swallowed (0.9.32): the once-per-process suppression on
    # a signed-out service is log VOLUME, so nothing about the answer can reveal it, and a
    # regression there is ~150 identical lines in a single warm. Everything else still falls
    # through AUTOLOAD and is discarded.
    package T::Log;               our $AUTOLOAD; our @WARNED;
                                  sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
                                  sub warn { shift; push @WARNED, join('', @_); return 1 }
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; sub AUTOLOAD {} sub get { undef } sub set {} sub init {}
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  sub cstring { $_[1] } sub string { $_[0] }
    package Plugins::PitchforkReviews::Plugin; sub dbg {}
    package Slim::Utils::Timers;
    our (@armed, @killed);
    sub setTimer { push @armed, $_[2]; return scalar @armed }
    sub killSpecific { push @killed, $_[0]; 1 }
    sub killTimers {}
}
{
    # KV side is a deliberate NO-OP, as in t_searchlegs: this suite runs the same albums
    # through the resolver repeatedly, so a real store would serve every case after the
    # first from cache and make the assertions vacuous. Storage is covered in t_db/t_perf.
    $INC{'Plugins/PitchforkReviews/DB.pm'} = __FILE__;
    package Plugins::PitchforkReviews::DB;
    sub getList { undef } sub putList { 1 } sub listAge { undef }
    sub forget { 1 } sub forgetAll { 1 } sub storedKeys { () }
    # kvSet RECORDS rather than discarding (0.9.29), because the TTL a resolve chooses is
    # itself an assertion now — see section 3b. kvGet still returns undef, so nothing is
    # ever SERVED from here and the assertions above stay non-vacuous.
    sub kvGet { undef }
    # THE ITEMS ARE RECORDED TOO (0.9.31), not just the TTL. `_streamResult` runs its OWN
    # dedupe and STREAM_MAX_RESULTS cap on the way to the caller, so an assertion made
    # against the RENDERED list cannot tell what $resolve did from what the renderer did —
    # a dedupe deleted from $resolve still passes such a test. What is cached is $resolve's
    # own output, and it is also what a later open replays, so that is what gets pinned.
    sub kvSet { push @main::WROTE, { key => $_[0], ttl => $_[2],
                                     items => ($_[1] && $_[1]{items}) || [] }; 1 }
    sub kvDel { 1 }
    sub kvForgetPrefix { 0 } sub kvCount { 0 } sub kvReset { }
}

my $BROWSE = $ENV{PFR_BROWSE} || 'PitchforkReviews/Browse.pm';
$INC{'Plugins/PitchforkReviews/Browse.pm'} = $BROWSE;
do($BROWSE =~ m{^/} ? $BROWSE : "./$BROWSE") or die "can't load $BROWSE: " . ($@ || $!);
my $B = 'Plugins::PitchforkReviews::Browse';

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

# A matched candidate as an adapter builds one: the SERVICE's own title in `_svctitle`
# (artist affix already stripped), which is the only field the ranking reads.
sub cand { my ($t) = @_; return { name => "Interpol - $t", _svctitle => $t, image => 'c.jpg' } }

our @WROTE;                       # every kvSet a resolve made: { key, ttl }
sub ttl_written { return @WROTE ? $WROTE[-1]{ttl} : undef }
# What $resolve actually CACHED, before _streamResult re-dedupes and re-caps it.
sub cached_titles { return map { $_->{_svctitle} // '' } @{ (@WROTE ? $WROTE[-1]{items} : []) } }

my @QUERIES;
sub adapters_returning {
    my (%svc) = @_;
    my @a;
    for my $name (sort keys %svc) {
        my $cfg  = $svc{$name};
        my @plan = @{ $cfg->{script} };
        push @a, {
            name => $name, icon => "icon-$name", priority => ($cfg->{priority} || 1),
            query_enc => 'bytes',
            %{ $cfg->{extra} || {} },   # table fields a scenario needs (e.g. empty_unverified)
            run  => sub {
                my ($client, $query, $an, $bn, $svc, $collect) = @_;
                push @QUERIES, { svc => $svc, query => $query };
                my $next = shift @plan;
                # The two shapes that never reach $collect at all, which is the whole point
                # of the timeout/throw cases below: 'HANG' = the service takes the query and
                # never calls back, so only its watchdog can settle the leg; 'DIE' = the
                # adapter throws inside $runLeg's eval. A plain undef still CALLS BACK with
                # undef and is a different path (the service answered "couldn't query").
                return              if defined $next && !ref $next && $next eq 'HANG';
                die "adapter blew up\n" if defined $next && !ref $next && $next eq 'DIE';
                # The two ways a real adapter reports "I could not search", both routed
                # through the PLUGIN'S OWN `_svcCantAnswer` rather than faked as a bare
                # undef — the standing/transient split (0.9.31) lives in that sub, so a
                # test that hand-rolled the undef would pass whatever the sub did.
                # 'SIGNEDOUT' = the `no API handler` sites (the $standing flag, set at
                # exactly three call sites); 'ERRORED' = the search came back undef.
                if (defined $next && !ref $next && $next eq 'SIGNEDOUT') {
                    return $B->can('_svcCantAnswer')
                             ->($svc, 'no API handler (signed out?)', $query, $collect, 1);
                }
                if (defined $next && !ref $next && $next eq 'ERRORED') {
                    return $B->can('_svcCantAnswer')
                             ->($svc, 'search errored', $query, $collect);
                }
                $collect->($next);
            },
        };
    }
    return sort { $a->{priority} <=> $b->{priority} } @a;
}
my @ADAPTERS;
{ no warnings 'redefine'; *Plugins::PitchforkReviews::Browse::_orderedAdapters = sub { @ADAPTERS }; }

my $GOT;
sub resolve {
    my ($artist, $album, %svc) = @_;
    @QUERIES  = ();
    @WROTE    = ();
    @ADAPTERS = adapters_returning(%svc);
    @Slim::Utils::Timers::armed = ();
    $GOT = undef;
    $B->can('_findPlayable')->(undef, sub { $GOT = $_[0] }, $artist, $album);
    return $GOT;
}
# Fire the watchdog the last $runLeg armed. The stub setTimer only RECORDS the callback,
# so a hung leg leaves the resolve unanswered until this runs it — which is exactly what
# STREAM_SVC_TIMEOUT does on the server.
sub fire_watchdog {
    my $cb = $Slim::Utils::Timers::armed[-1] or die "no timer armed\n";
    $cb->();
    return $GOT;
}
sub titles  { my $r = shift; map { $_->{_svctitle} // '' } @{ $r->{items} || [] } }
sub queries { map { $_->{query} } @QUERIES }

# Service-availability state is process-wide (0.9.32) and outlives a block, the same hazard
# reset_all() clears for %RESOLVING — so a scenario that means "genuinely signed out" has to
# SAY so rather than inherit it from whatever ran before.
sub reset_svc { $B->can('_resetSvcAvailability')->() }
# Put a service into the signed-out-long-enough-to-count state without waiting out
# SVC_UNAVAILABLE_GRACE. Drives the REAL `_svcNoHandler` with an old timestamp, so the record
# is created exactly as production creates it rather than poked into place.
#
# THE SEED MUST COME FROM THE SAME CLOCK THE PRODUCTION PATH READS (0.9.33). `_svcNoHandler`
# now defaults `$now` to `_monoNow()` (CLOCK_MONOTONIC) rather than `time()`, because the
# grace window is relative to process uptime and an RTC-less host steps the wall clock at
# boot. Seeding with `time() - 86400` while the code under test compares against a monotonic
# reading makes the delta wildly negative, so a service seeded as long-signed-out reads as
# transient — which is exactly how these four assertions failed when the clock changed.
sub mono_now { my $m = $B->can('_monoNow'); return $m ? $m->() : time() }
sub signed_out_long { $B->can('_svcNoHandler')->($_, mono_now() - 86400) for @_; return 1 }
sub reset_warns     { @T::Log::WARNED = (); return 1 }
sub handler_warns   { return grep { /no API handler/ }            @T::Log::WARNED }
sub standing_warns  { return grep { /treating it as signed out/ } @T::Log::WARNED }

my $ALBUM  = 'This Mirror Weighs a Ton';
my $SINGLE = 'This Mirror Weighs a Ton/See Out Loud';

# --- 0. _releaseKey: an EDITION folds away, a RELEASE identifier does not ----
# This is the whole discriminator, and plain `_norm` cannot be it: `_norm` deletes every
# bracketed group, so "I Wander (III)" and "I Wander" come out identical and a one-track
# single is indistinguishable from the 6-track EP the review is about.
print "0. _releaseKey — bracketed content judged by meaning\n";
{
    my $k = $B->can('_releaseKey');
    is('a plain title is unchanged',      $k->('I Wander'), 'i wander');
    is('the EP/LP suffix folds',          $k->('I Wander EP'), 'i wander');
    is('an edition qualifier is dropped', $k->('Foo (Deluxe Edition)'), 'foo');
    is('...remastered too',               $k->('Foo (Remastered)'), 'foo');
    is('...and the 2011 Remaster form',   $k->('Foo (2011 Remaster)'), 'foo');
    is('a release identifier is KEPT',    $k->('I Wander (III)'), 'i wander iii');
    is('...including a roman-numeral pair', $k->('I Wander (IV + V)'), 'i wander iv and v');
    is('square brackets behave the same', $k->('Foo [Deluxe]'), 'foo');
    is('an unpadded pairing is untouched',
        $k->('This Mirror Weighs a Ton/See Out Loud'), 'this mirror weighs a ton see out loud');
    is('nothing in -> nothing out',       $k->(undef), '');
    # THE PINNED 0.9.21 BEHAVIOUR: a deluxe edition IS the album, and the split rule leans
    # on that. If this ever stops holding, the unpadded-split promotion breaks with it.
    ok('an edition still reads as the same record',
        $k->('EP2 (Deluxe Edition)') eq $k->('EP2'));
    # ...while the closed list fails toward OFFERING: an unrecognised bracket is part of
    # the identity, so it makes two titles distinct rather than silently merging them.
    ok('an UNKNOWN bracket makes titles distinct',
        $k->('Foo (Tokyo Sessions)') ne $k->('Foo'));
}

# --- 1. _exactFolded: the discriminator, on the three live shapes ------------
print "1. _exactFolded — folded on BOTH sides\n";
{
    my $ex = $B->can('_exactFolded');
    ok('the album IS exact',                    $ex->($ALBUM,  cand($ALBUM)));
    ok('the like-named single is NOT',         !$ex->($ALBUM,  cand($SINGLE)));
    # The EP direction. Pitchfork says "I Wander EP", every service says "I Wander" — on a
    # STRICT test that is loose, which would make every EP review permanently "nothing
    # matched exactly". Folding both sides settles it on leg 1.
    ok('"I Wander EP" folds onto "I Wander"',   $ex->('I Wander EP', cand('I Wander')));
    ok('"Faith EP" folds onto "Faith"',         $ex->('Faith EP',    cand('Faith')));
    # ...but folding must not start matching DIFFERENT records.
    ok('a bracketed single is still not exact', !$ex->('I Wander EP', cand('I Wander (III)')));
    ok('a deluxe EDITION is exact (_norm strips brackets)',
                                                $ex->($ALBUM, cand("$ALBUM (Deluxe Edition)")));
    # "No evidence" must never read as "exact" — the distinction _matchExactness keeps.
    ok('a candidate with no service title is not exact', !$ex->($ALBUM, { name => 'x' }));
    ok('a non-hash is not exact',               !$ex->($ALBUM, 'nope'));
}

# --- 2. the row takes the EXACT title, not the service's first row -----------
print "\n2. ranking — an exact title is promoted to the row\n";
{
    # Qobuz's own order: the single first, the album behind it.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE), cand($ALBUM) ] ] });
    my @t = titles($r);
    is('the ALBUM takes the row', $t[0], $ALBUM);
    is('the single is kept, behind it', $t[1], $SINGLE);
    is('nothing is dropped', scalar(@t), 2);
}
{
    # The promotion must reach past the first position — a deluxe edition in front of the
    # plain one must not cost the plain one the row when only one of them is exact.
    my $r = resolve('Interpol', $ALBUM,
        Qobuz => { script => [ [ cand($SINGLE), cand("$ALBUM Instrumentals"), cand($ALBUM) ] ] });
    is('an exact match at position 2 still wins', (titles($r))[0], $ALBUM);
}
{
    # THE EP DIRECTION. Every candidate is loose against a strict test; the fold makes the
    # EP exact and the two bracketed singles not, so the EP takes the row wherever the
    # service happened to put it. Before 0.9.27 this was raw service order — a coin flip.
    my $r = resolve('Djrum', 'I Wander', Deezer => { script => [
        [ cand('I Wander (III)'), cand('I Wander (IV + V)'), cand('I Wander') ] ] });
    is('the EP wins over same-artist singles', (titles($r))[0], 'I Wander');
}
{
    # Nothing exact anywhere: pure no-op, the service's order stands.
    my $r = resolve('Interpol', $ALBUM,
        Qobuz => { script => [ [ cand($SINGLE), cand("$ALBUM Remixes") ] ] });
    is('with no exact candidate the order is untouched', (titles($r))[0], $SINGLE);
}

# --- 3. _wantsTitleRetry: when a second search is worth spending ------------
print "\n3. the album-title retry — positive evidence only\n";
{
    my $w = $B->can('_wantsTitleRetry');
    ok('nothing found -> retry (the 0.7.12 recall case)', $w->($ALBUM, []));
    ok('loose only -> retry (the 0.9.27 case)',           $w->($ALBUM, [ cand($SINGLE) ]));
    ok('an exact match -> do NOT retry',                  !$w->($ALBUM, [ cand($ALBUM) ]));
    ok('exact anywhere in the set settles it',            !$w->($ALBUM, [ cand($SINGLE), cand($ALBUM) ]));
    # "NO EVIDENCE" IS NOT "NOT EXACT". A service that matched but stated no title has not
    # said the match is wrong, and retrying on that spends a full STREAM_SVC_TIMEOUT per
    # album to learn nothing — the same distinction _matchExactness draws between
    # `exactness=none` and `loose`.
    ok('a titleless match -> do NOT retry', !$w->($ALBUM, [ { name => 'Interpol - something' } ]));
    ok('undef (service unqueryable) -> no retry', !$w->($ALBUM, undef));
    # An EP review settles on leg 1 through the fold — otherwise every EP review pays a
    # second search on every cold resolve.
    ok('"I Wander EP" vs "I Wander" -> no retry', !$w->('I Wander EP', [ cand('I Wander') ]));
}
{
    # Driven through the real resolver: the loose-only artist leg triggers the title leg,
    # and the album the search cap hid is found by it.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [
        [ cand($SINGLE) ],              # artist leg: the cap hid the album
        [ cand($ALBUM) ],               # title leg: two rows on the real service, both right
    ] });
    my @q = queries();
    is('two legs were run',            scalar(@q), 2);
    is('leg 1 asked for the artist',   $q[0], 'Interpol');
    is('leg 2 asked for the title',    $q[1], $ALBUM);
    is('and the ALBUM takes the row',  (titles($r))[0], $ALBUM);
}
{
    # MERGE, NEVER REPLACE. Leg 2 has its own recall and can legitimately return nothing;
    # leg 1's match passed the same _albumMatches gate and must survive. Replacing would
    # turn a loose-but-correct match into a no-match on every title this leg was not
    # built for.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], [] ] });
    is('leg 1 survives an empty leg 2', (titles($r))[0], $SINGLE);
}
{
    # Leg 2 undef = the service could not be queried. We are holding real matches, so that
    # must not be reported as inconclusive and lose them.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], undef ] });
    is('leg 1 survives an undef leg 2', (titles($r))[0], $SINGLE);
}
{
    # THE LEG-2 WATCHDOG, which is the path the merge was originally on the wrong side of.
    # $runLeg's timer calls $finish DIRECTLY — $collect, where the @leg1 merge used to
    # live, is never reached — so a leg-2 timeout reported the service inconclusive and
    # threw away matches leg 1 was already holding. Since 0.9.27 fires leg 2 on a
    # LOOSE-ONLY leg 1, that is the ordinary case, not an edge one: the Interpol single
    # would be dropped and the album cached as a no-match for STREAM_INCONCLUSIVE_TTL.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], 'HANG' ] });
    ok('a hung leg 2 leaves the resolve unanswered', !defined $r);
    is('two legs were run before the hang', scalar(queries()), 2);
    $r = fire_watchdog();
    is('leg 1 survives a leg-2 TIMEOUT', (titles($r))[0], $SINGLE);
}
{
    # Same defect through $runLeg's other direct-to-$finish path: the adapter throws and
    # the eval turns it into $finish->(undef).
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], 'DIE' ] });
    is('leg 1 survives a leg-2 THROW', (titles($r))[0], $SINGLE);
}
{
    # THE OTHER DIRECTION, and the reason the fallback is gated on `@leg1` rather than
    # applied unconditionally: with nothing held, a timeout is still INCONCLUSIVE. Turning
    # it into a no-match would cache the miss for the long TTL instead of the short one.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ 'HANG' ] });
    ok('a hung leg 1 leaves the resolve unanswered', !defined $r);
    $r = fire_watchdog();
    is('a leg-1 timeout holding nothing still reports no match',
        $r->{items}[0]{name}, 'PLUGIN_PITCHFORKREVIEWS_NO_MATCH');
}
{
    # A leg-2 timeout on an EMPTY leg 1 (the 0.7.12 recall case) has nothing to fall back
    # to and must stay inconclusive as well.
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [], 'HANG' ] });
    $r = fire_watchdog();
    is('an empty leg 1 + leg-2 timeout still reports no match',
        $r->{items}[0]{name}, 'PLUGIN_PITCHFORKREVIEWS_NO_MATCH');
}
{
    my $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], [ cand($ALBUM) ] ] });
    my @t = titles($r);
    is('both legs merge into one set', scalar(@t), 2);
    ok('deduped — the single is not listed twice', 1 == grep { $_ eq $SINGLE } @t);
}

# --- 3b. HOW LONG AN UNCHECKED ANSWER IS KEPT (0.9.29) ----------------------
# 0.9.28 fixed the merge and, in doing so, made `$res` always defined once leg 1 held
# anything — so a leg-2 timeout stopped reaching the `!defined $res` inconclusive branch and
# came out the FOUND side, where the TTL is thirty days. The result is correct to SERVE
# (that is 0.9.28's whole point) and wrong to PIN: the loose candidate the second query
# existed to rule out got a month on the strength of a query that never answered, which is
# the same wrong-match-for-a-month shape 0.9.27 set out to remove.
#
# The discriminator is whether leg 2 ANSWERED, not whether it found anything. An empty
# array is a verdict — it looked and had nothing to add — so leg 1's match stands validated
# and keeps STREAM_FOUND_TTL. A watchdog, a throw, or an undef callback is not a verdict.
#
# Guard direction included deliberately: the flag is PER-ADAPTER, so a service that hung
# while LOSING the row must not shorten the winner's fully-checked answer.
print "\n3b. an answer leg 2 never checked is not pinned for a month\n";
{
    my $FOUND = $B->can('STREAM_FOUND_TTL')->();
    my $UNVAL = $B->can('STREAM_UNVALIDATED_TTL')->();
    ok('an unvalidated answer is kept for less time than a checked one', $UNVAL < $FOUND);

    resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], [ cand($ALBUM) ] ] });
    is('leg 2 answered -> long TTL', ttl_written(), $FOUND);

    resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], [] ] });
    is('an EMPTY leg 2 is still a verdict -> long TTL', ttl_written(), $FOUND);

    resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], 'HANG' ] });
    fire_watchdog();
    is('a leg-2 TIMEOUT -> short TTL', ttl_written(), $UNVAL);

    resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], 'DIE' ] });
    is('a leg-2 THROW -> short TTL', ttl_written(), $UNVAL);

    resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], undef ] });
    is('a leg-2 undef callback -> short TTL', ttl_written(), $UNVAL);

    # Aqobuz/Btidal sort by priority; the names only fix the order.
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => [ [ cand($ALBUM) ] ] },
        Btidal => { priority => 2, script => [ [ cand($SINGLE) ], 'HANG' ] });
    is('GUARD: a hung LOSING service does not shorten the winner', ttl_written(), $FOUND);

    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => [ [], [] ] },
        Btidal => { priority => 2, script => [ [ cand($SINGLE) ], 'HANG' ] });
    fire_watchdog();
    is('an unvalidated service that DOES win takes the short TTL', ttl_written(), $UNVAL);
}

# --- 3c. WHICH LEG LEADS THE MERGE (0.9.31) --------------------------------
# 0.9.27 merged the two legs as `[ @leg2, @leg1 ]` and justified leading with leg 2 on the
# grounds that "the promotion in $resolve then decides". It decides only when there is
# something to decide BETWEEN: the promotion greps for `_exactFolded` and does nothing at
# all when no candidate matches it. So with both legs loose, the merge ORDER silently
# became the adjudicator, and leg 2's first row — a title search, ordered by title
# relevance, which is precisely how a like-named rival gets to the front — took the row
# and was pinned for STREAM_FOUND_TTL, because leg 2 having answered is what marks a row
# validated.
#
# THIS IS THE REGRESSION 0.9.27 INTRODUCED WHILE FIXING THE INTERPOL CASE. The old retry
# gate was `!@$res`: a loose-only leg 1 never ran leg 2, so leg 1's match stood. Widening
# the gate is right and stays; leading with leg 2 unconditionally does not.
#
# THE SHIPPED RULE IS `[ @leg1, @$res ]` UNCONDITIONALLY — leg 2 never leads. It does not
# need to: reaching this merge proves `@leg1` is exact-free (`_wantsTitleRetry` returns 0
# on a folded-exact leg 1), so the only exact that can exist is leg 2's, and the promotion
# lifts it from wherever it sits. A conditional "lead with leg 2 when it brought the exact"
# was built and discarded as a provable no-op. Read the assertions accordingly: when leg 2
# wins below it wins by PROMOTION, never by position.
#
# Both directions are pinned. The Interpol fix (leg 2 brings the exact) must still work,
# and the EP direction — where NOTHING is exact and the leg-1 answer is the conservative
# one — must not be decided by whichever leg happened to be concatenated first.
print "\n3c. leg 1 leads the merge; an exact wins by PROMOTION, not by position\n";
{
    my $FOUND = $B->can('STREAM_FOUND_TTL')->();
    my $L1 = 'Foo (feat. Guest)';       # leg 1 (artist query) — right artist, loose title
    my $L2 = 'Foo (Remix)';             # leg 2 (title query)  — equally loose, not the record
    my $c  = sub { { name => "Interpol - $_[0]", _svctitle => $_[0], image => 'c.jpg' } };

    ok('neither rival is folded-exact, so the promotion cannot arbitrate',
        !$B->can('_exactFolded')->('Foo', $c->($L1))
     && !$B->can('_exactFolded')->('Foo', $c->($L2)));

    my $r = resolve('Interpol', 'Foo', Qobuz => { script => [ [ $c->($L1) ], [ $c->($L2) ] ] });
    is('two legs ran (the 0.9.27 loose-only gate still fires)', scalar(queries()), 2);
    is('LEG 1 takes the row when nothing is exact', (titles($r))[0], $L1);
    ok('...and leg 2 is still merged in, not discarded', 2 == scalar(titles($r)));
    is('...at the long TTL, because leg 2 did answer', ttl_written(), $FOUND);

    # THE INTERPOL DIRECTION, unchanged: leg 2 exists to reach the release the artist
    # search buried, and when it brings it back that release takes the row.
    $r = resolve('Interpol', $ALBUM,
        Qobuz => { script => [ [ cand($SINGLE) ], [ cand($ALBUM) ] ] });
    is('leg 2\'s exact still takes the row, promoted past leg 1', (titles($r))[0], $ALBUM);

    # An exact anywhere in leg 2 counts, not just at its front — the grep tests the whole
    # leg, and the promotion in $resolve then lifts it.
    $r = resolve('Interpol', $ALBUM,
        Qobuz => { script => [ [ cand($SINGLE) ], [ cand('Foo (Remix)'), cand($ALBUM) ] ] });
    is('an exact BEHIND a loose row in leg 2 still wins', (titles($r))[0], $ALBUM);

    # Leg 1 holding the exact never gets here (the retry does not fire at all), but the
    # merge must not disturb it if some future gate change lets it through.
    $r = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($ALBUM) ], [ cand($SINGLE) ] ] });
    is('an exact leg 1 settles without a second leg', scalar(queries()), 1);
    is('...and keeps the row',                        (titles($r))[0], $ALBUM);

    # Leg 2 never answering is the 0.9.29 path and must still fall back to leg 1 whole.
    $r = resolve('Interpol', 'Foo', Qobuz => { script => [ [ $c->($L1) ], 'DIE' ] });
    is('a leg-2 throw still leaves leg 1 holding the row', (titles($r))[0], $L1);

    # THE MERGE MEETS THE DEDUPE AND THE CAP, which sit either side of the promotion
    # (`_dedupeStreamItems` -> promotion -> STREAM_MAX_RESULTS). Reordering the merge
    # changes which copy of a duplicate survives and which rows the cap deletes, so both
    # boundaries are pinned rather than reasoned about.
    #
    # Overlapping legs: both searches legitimately return the same release, and after
    # 0.9.31 leg 1's copy is the one that survives. The exact must still reach the front.
    # Asserted against the CACHE, not the rendered list: _streamResult dedupes again, so a
    # dedupe deleted from $resolve would still render two rows and pass.
    resolve('Interpol', $ALBUM,
        Qobuz => { script => [ [ cand($SINGLE) ], [ cand($SINGLE), cand($ALBUM) ] ] });
    my @ov = cached_titles();
    is('an overlapping row is CACHED once, not twice', scalar(@ov), 2);
    is('...and the exact is still promoted to the row', $ov[0], $ALBUM);

    # THE CAP CANNOT EAT THE EXACT. Leg 1 returns more loose rows than STREAM_MAX_RESULTS
    # and leg 2 brings the exact LAST — so in merged order the exact sits past the cap.
    # The promotion runs BEFORE the truncation, which is what saves it; swap those two and
    # this is the assertion that fails.
    my $MAX = $B->can('STREAM_MAX_RESULTS')->();
    resolve('Interpol', $ALBUM, Qobuz => {
        script => [ [ map { cand("Filler $_") } 1 .. $MAX + 3 ], [ cand($ALBUM) ] ] });
    my @cap = cached_titles();
    is('the CACHED list is capped at STREAM_MAX_RESULTS', scalar(@cap), $MAX);
    is('...and the exact survives the cap, at the front', $cap[0], $ALBUM);
}

# --- 3d. SIGNED OUT IS NOT INCONCLUSIVE (0.9.31) ---------------------------
# `_svcCantAnswer`'s `$once` flag marks a STANDING inability — the plugin is installed but
# nobody is signed in, so `_detectAdapters` (which gates on `->can()` and nothing else)
# keeps the adapter in `@adapters` on every resolve for ever. 0.9.30 used that flag to warn
# once instead of per album and left the TTL side alone, so every genuinely unmatched album
# took STREAM_INCONCLUSIVE_TTL — an hour where a real miss earns a day, 24x the resolve
# traffic, for as long as the service stays signed out, with nothing that could ever clear
# it.
#
# The split is not "ignore it": a service that could not search has not voted. It shortens
# the TTL only when NO adapter managed to search at all.
print "\n3d. a signed-out service is out of the run, not an inconclusive answer\n";
{
    my $NOMATCH = $B->can('STREAM_NOMATCH_TTL')->();
    my $INCONC  = $B->can('STREAM_INCONCLUSIVE_TTL')->();
    my $FOUND   = $B->can('STREAM_FOUND_TTL')->();
    ok('an inconclusive answer is retried sooner than a confirmed miss', $INCONC < $NOMATCH);

    # EVERY "signed out" SCENARIO BELOW STATES THAT IT IS GENUINELY SIGNED OUT (0.9.32).
    # Standing is now measured against SVC_UNAVAILABLE_GRACE rather than declared at the call
    # site, so a service seen without a handler for the FIRST time is transient — correctly,
    # that is the startup race. These assertions are about the settled state, so they seed it;
    # section 3f covers the other side and the crossing.
    reset_svc(); signed_out_long('Aqobuz');
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => [ [], [] ] });
    is('one signed out, one really searched and missed -> a real no-match',
        ttl_written(), $NOMATCH);

    reset_svc(); signed_out_long('Aqobuz', 'Btidal');
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => ['SIGNEDOUT'] });
    is('EVERY service signed out -> nobody searched, so still no verdict',
        ttl_written(), $INCONC);

    # THE TRANSIENT SIDE IS UNTOUCHED. A search that errored, a watchdog, a throw: all of
    # these can succeed on the next open, and all still earn the short retry.
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['ERRORED'] },
        Btidal => { priority => 2, script => [ [], [] ] });
    is('a TRANSIENT error still forces the short TTL', ttl_written(), $INCONC);

    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => [ [], 'HANG' ] },
        Btidal => { priority => 2, script => [ [], [] ] });
    fire_watchdog();
    is('a TIMEOUT still forces the short TTL', ttl_written(), $INCONC);

    # A signed-out service must not shorten an answer another service actually found,
    # and must not stop the fan-out reaching it.
    reset_svc(); signed_out_long('Aqobuz');
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => [ [ cand($ALBUM) ] ] });
    is('a signed-out service does not shorten a real match', ttl_written(), $FOUND);

    # And it does not consume the retry: the signed-out leg sends undef, which
    # `_wantsTitleRetry` refuses, so no second query is spent on a service that cannot
    # answer either of them.
    resolve('Interpol', $ALBUM, Qobuz => { script => ['SIGNEDOUT', [ cand($ALBUM) ] ] });
    is('a signed-out service is asked exactly once', scalar(queries()), 1);

    # THREE ADAPTERS, THE UNAVAILABLE ONE IN THE MIDDLE. The "nobody searched" test counts
    # UNAVAILABLE against the adapter COUNT, so a partial tally must not accidentally satisfy
    # it, and the fan-out (which only adapter 0 performs) still has to reach adapter 2.
    reset_svc(); signed_out_long('Btidal');
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => [ [], [] ] },
        Btidal => { priority => 2, script => ['SIGNEDOUT'] },
        Cdeezr => { priority => 3, script => [ [], [] ] });
    is('one of three unavailable, the others really missed -> a real no-match',
        ttl_written(), $NOMATCH);

    reset_svc(); signed_out_long('Aqobuz', 'Btidal', 'Cdeezr');
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => ['SIGNEDOUT'] },
        Cdeezr => { priority => 3, script => ['SIGNEDOUT'] });
    is('all three unavailable -> no verdict', ttl_written(), $INCONC);

    # A SERVICE THAT SIGNED OUT BETWEEN ITS OWN TWO LEGS. Barely reachable in the field
    # (leg 1 succeeding means the handler existed), but it is the one shape where the
    # standing flag arrives while leg 1 is holding matches. The merge makes $res defined,
    # so the flag is correctly IGNORED — there is a match to serve — and the row takes the
    # unvalidated TTL, because leg 2 still never checked it.
    my $mid = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], 'SIGNEDOUT' ] });
    is('signed out between legs still serves leg 1', (titles($mid))[0], $SINGLE);
    is('...at the unvalidated TTL, not counted unavailable',
        ttl_written(), $B->can('STREAM_UNVALIDATED_TTL')->());
}

# --- 3f. STANDING IS MEASURED, NOT DECLARED (0.9.32) ------------------------
# 0.9.31 passed a literal `1` at the three `no API handler` sites, which is a claim about the
# FUTURE that the call site cannot make. The same signature has two opposite causes:
#
#   signed out / never configured   -> STANDING. Repeats for ever (`_detectAdapters` gates on
#       `->can()` and knows nothing about sign-in), so counting it transient costs an hourly
#       re-resolve on every unmatched album, indefinitely. That is what 0.9.31 fixed.
#   the STARTUP WARM ran before the service authenticated -> TRANSIENT, self-heals in seconds.
#       Counting it standing pins real misses for 24h when nobody actually searched — live at
#       EVERY server restart, which is what this section exists to stop.
#
# Both directions are pinned, because a fix for either one alone re-breaks the other.
print "\n3f. a missing API handler is timed, not assumed permanent\n";
{
    my $noh   = $B->can('_svcNoHandler')   or die "no _svcNoHandler\n";
    my $has   = $B->can('_svcHasHandler')  or die "no _svcHasHandler\n";
    my $GRACE = $B->can('SVC_UNAVAILABLE_GRACE')->();
    my $NOMATCH = $B->can('STREAM_NOMATCH_TTL')->();
    my $INCONC  = $B->can('STREAM_INCONCLUSIVE_TTL')->();

    # The window has to be long enough to cover plugin load + auth, and short enough that a
    # startup misclassification would self-heal well inside a confirmed miss. Asserted as a
    # RELATIONSHIP so a future retune cannot quietly land somewhere useless — same reasoning
    # as WARM_RETRY_MAX's bound against WARM_INTERVAL.
    ok('the grace window is a real duration',            $GRACE > 0);
    ok('...and far shorter than a confirmed miss',       $GRACE * 10 < $NOMATCH);

    # THE CLOCK ITSELF IS PINNED (0.9.33), not just the arithmetic. Every assertion below
    # injects $now, so all of them pass just as happily against a wall-clock default — the
    # bug this guards is invisible to them. It is real: %UNAVAIL_SINCE is process memory and
    # the window is meant to be process uptime, but an RTC-less host (most of the fleet)
    # restores the clock at boot from the last shutdown and NTP then STEPS it forward, inside
    # the very window the grace covers. A step longer than $GRACE makes a startup race read
    # as STANDING and pins unconfirmed misses at 24h.
    my $mono     = $B->can('_monoNow');
    my $has_mono = eval { Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()); 1 } ? 1 : 0;
    ok('a monotonic clock helper exists',                $mono ? 1 : 0);
    if ($mono) {
        my $a = $mono->(); my $b = $mono->();
        ok('...that never runs backwards',               $b >= $a);
        ok('...and is not wall-clock time',
           $has_mono ? (abs($mono->() - time()) > $GRACE) : 1);
    }

    # PROBED AT THE CONSUMING END, which is the only version of this that works. The three
    # assertions above pass unchanged if someone reverts `_svcNoHandler`'s default to time()
    # and simply leaves `_monoNow` sitting unused in the file — verified by anti-test, so
    # they prove the helper exists, not that the grace window reads it.
    #
    # So drive the real sub: seed the record with a WALL-CLOCK reading an hour past the
    # window, then ask it again with NO $now so it falls back to its production default.
    # Under CLOCK_MONOTONIC (counted from boot, a far smaller number) the delta is negative
    # and the service is NOT standing; under time() the delta is exactly 3600 and it would
    # be. The verdict therefore names the clock the sub actually reads.
    if ($has_mono) {
        reset_svc();
        $noh->('clockprobe', time() - 3600);
        ok('_svcNoHandler reads that clock, not time()',  $noh->('clockprobe') == 0);
        reset_svc();
    }

    # THE WINDOW ITSELF, driven at an injected clock so it does not take ten minutes.
    reset_svc();
    is('the FIRST sighting is not standing — it may be the startup race', $noh->('Q', 1000), 0);
    is('...still not standing one second before the window closes',
        $noh->('Q', 1000 + $GRACE - 1), 0);
    is('...standing exactly AT the window',        $noh->('Q', 1000 + $GRACE), 1);
    is('...and after it',                          $noh->('Q', 1000 + $GRACE * 10), 1);

    # IT TIMES FROM THE FIRST SIGHTING, NOT THE LATEST. A resolve happens per album, so the
    # record is re-stamped hundreds of times per warm; re-stamping it on every sighting would
    # restart the clock for ever and the standing state would be unreachable.
    reset_svc();
    $noh->('Q', 1000); $noh->('Q', 1100); $noh->('Q', 1200);
    is('repeated sightings do not restart the clock', $noh->('Q', 1000 + $GRACE), 1);

    # A HANDLER APPEARING CLEARS IT, which is what makes the startup case self-heal rather
    # than merely expire: the service signs in, the record goes, and a LATER outage is timed
    # from its own beginning instead of inheriting the old one.
    reset_svc();
    $noh->('Q', 1000);
    $has->('Q');
    is('signing back in clears the record', $noh->('Q', 1000 + $GRACE), 0);
    is('...and the new window is timed from the new sighting',
        $noh->('Q', 1000 + $GRACE * 2), 1);
    # Per service, not global — one signed-out service must not age another's window.
    reset_svc();
    $noh->('Q', 1000);
    is('a second service starts its own clock', $noh->('T', 1000 + $GRACE), 0);
    is('...while the first is already standing', $noh->('Q', 1000 + $GRACE), 1);

    # THE FIX, END TO END, through the real resolver. Same scenario twice; only how long the
    # service has been signed out differs, and that is the whole behavioural change.
    reset_svc();
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => [ [], [] ] });
    is('signed out only just now (the startup warm) -> transient, retried within the hour',
        ttl_written(), $INCONC);

    reset_svc(); signed_out_long('Aqobuz');
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => [ [], [] ] });
    is('...the same shape once it is genuinely signed out -> a confirmed no-match',
        ttl_written(), $NOMATCH);

    # THE WARN IS SUPPRESSED ON THE FACT, NOT ON THE CLASSIFICATION, and only a VOLUME
    # assertion can see it — nothing about the answer changes either way. Keying the
    # once-per-process guard on `$standing` looks equivalent and is not: inside the grace
    # window `$standing` is false, so the line fires for every album, which is the ~150
    # identical lines per warm that 0.9.30's `$once` was added to remove. Found by
    # anti-testing this section, which caught the code and missed this.
    reset_svc(); reset_warns();
    resolve('Interpol', $ALBUM, Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
                                Btidal => { priority => 2, script => [ [], [] ] }) for 1 .. 3;
    is('a service signed out INSIDE the grace window still warns only once',
        scalar(handler_warns()), 1);

    reset_svc(); signed_out_long('Aqobuz'); reset_warns();
    resolve('Interpol', $ALBUM, Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
                                Btidal => { priority => 2, script => [ [], [] ] }) for 1 .. 3;
    is('...and once when it is genuinely signed out', scalar(handler_warns()), 1);
}

# --- 3g. THE WARN STATES WHAT HAPPENED, IT DOES NOT PREDICT A COUNT (0.9.32) -
# `_svcCantAnswer` used to end its line "— counted unavailable" / "— counted inconclusive",
# decided several steps before anything is counted. That claim can be plainly FALSE: when leg
# 1 is holding matches, the merge in `$finish` makes `$res` defined, the row is cached as a
# MATCH at STREAM_UNVALIDATED_TTL, and no no-match tally is touched at all — so the log
# asserted one verdict for a run that reached the opposite one. Same root cause as the
# five-carrier problem (a consumer re-deriving a classification made elsewhere), same cure.
print "\n3g. the warn says what happened, not how it will be counted\n";
{
    my $UNVAL = $B->can('STREAM_UNVALIDATED_TTL')->();

    # THE FINDING, VERBATIM. A service that signs out between its own two legs, with leg 1
    # holding a match: the row really is stored as a MATCH, so any line claiming it was
    # "counted unavailable" is describing a run that did not happen.
    reset_svc(); reset_warns(); signed_out_long('Qobuz');
    my $mid = resolve('Interpol', $ALBUM, Qobuz => { script => [ [ cand($SINGLE) ], 'SIGNEDOUT' ] });
    is('the row really is stored as a match', ttl_written(), $UNVAL);
    is('...and leg 1 is what it serves', (titles($mid))[0], $SINGLE);
    ok('...so the warn claims NO count at all',
        !grep { /counted/ } @T::Log::WARNED);
    ok('...while still naming the service and the reason',
        scalar(grep { /Qobuz.*no API handler/ } @T::Log::WARNED) >= 1);

    # THE CROSSING IS ANNOUNCED, ONCE. The first line fires on the first sighting, which for
    # the common case is during boot when "not authenticated yet" is the honest reading — so
    # without a second line a service that never comes back is only ever reported as a
    # transient startup blip, and the distinction 0.9.32 introduced is invisible to the user.
    reset_svc(); reset_warns();
    resolve('Interpol', $ALBUM, Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
                                Btidal => { priority => 2, script => [ [], [] ] });
    is('inside the grace window, nothing claims it is signed out',
        scalar(standing_warns()), 0);
    is('...but the outage itself is reported once', scalar(handler_warns()), 1);

    reset_svc(); reset_warns(); signed_out_long('Aqobuz');
    resolve('Interpol', $ALBUM, Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
                                Btidal => { priority => 2, script => [ [], [] ] }) for 1 .. 3;
    is('past the window it says so exactly once, not per album',
        scalar(standing_warns()), 1);

    # A SERVICE THAT RECOVERS RE-ARMS BOTH LINES. Holding the flags for the life of the
    # process (0.9.30's shape) meant a service that failed at startup, signed in, then dropped
    # out at noon warned NOTHING — the silent-service case the warn exists for. A second warn
    # now costs a successful handler in between, so the volume is still bounded.
    # THE FIRST OUTAGE MUST GO THROUGH `_svcCantAnswer`, or the warn flag is never set and
    # the assertion cannot see the clearing at all. (It didn't, first time round: seeding via
    # `_svcNoHandler` only records the TIMESTAMP, so the test passed against a build that had
    # the clearing removed. Caught by anti-testing, and the premise was fixed, not the code.)
    reset_svc(); reset_warns();
    resolve('Interpol', $ALBUM, Zsvc => { script => ['SIGNEDOUT'] });
    is('the first outage is reported', scalar(handler_warns()), 1);
    resolve('Interpol', $ALBUM, Zsvc => { script => ['SIGNEDOUT'] });
    is('...and not repeated while it persists', scalar(handler_warns()), 1);

    $B->can('_svcHasHandler')->('Zsvc');               # the service signs back in
    reset_warns();
    resolve('Interpol', $ALBUM, Zsvc => { script => ['SIGNEDOUT'] });
    is('a NEW outage after a recovery is reported again', scalar(handler_warns()), 1);
}

# --- 3e. THE TTL TABLE, ENUMERATED EXHAUSTIVELY (0.9.32) --------------------
# WHY THIS IS NOT MORE SCENARIOS. Sections 3b/3c/3d are example-based, and examples cannot
# see this series' actual failure mode: a fix that leaves a branch in place but makes it
# UNREACHABLE, or a discriminator that is still read but no longer changes anything. 0.9.28
# orphaned the inconclusive branch that way; 0.9.30 split standing from transient for the log
# and left the TTL reading the old carrier. Both shipped green.
#
# `_streamTtl` is a pure function over a CLOSED enum, so the whole input space can be walked.
# Two properties are pinned here, and the second is the one that stops the recurrence:
#
#   1. EQUIVALENCE — `_streamTtl` agrees with the 0.9.31 ladder in every cell. That is what
#      makes the refactor safe to land on its own: it is a no-op by measurement, not by
#      argument.
#   2. COVERAGE — every TTL is still reachable, and every enum value still CHANGES some cell.
#      A future edit that makes OUTCOME_UNAVAILABLE (say) indistinguishable from
#      OUTCOME_ERRORED fails here, at the point of the mistake, instead of surfacing three
#      releases later as a wrong TTL in the field.
print "\n3e. the TTL table, enumerated\n";
{
    my $ttl = $B->can('_streamTtl') or die "no _streamTtl\n";
    my ($A, $E, $U) = map { $B->can($_)->() } qw(OUTCOME_ANSWERED OUTCOME_ERRORED OUTCOME_UNAVAILABLE);
    my $FOUND   = $B->can('STREAM_FOUND_TTL')->();
    my $UNVAL   = $B->can('STREAM_UNVALIDATED_TTL')->();
    my $INCONC  = $B->can('STREAM_INCONCLUSIVE_TTL')->();
    my $NOMATCH = $B->can('STREAM_NOMATCH_TTL')->();

    # THE ORACLE: the 0.9.31 ladder, transcribed from `$resolve` as it stood before the
    # refactor, driven from the same outcomes. Deliberately written in terms of the OLD
    # carriers ($unvalidated[$win] / $inconclusive / $unavailable) rather than by restating
    # the new sub — a test that mirrors the implementation proves nothing.
    my $old_ladder = sub {
        my ($outcome, $nadapters, $win, $nitems) = @_;
        my $unvalidated_win = defined $win && $outcome->[$win] ne $A;
        my $inconclusive    = grep { $_ eq $E } @$outcome;
        my $unavailable     = grep { $_ eq $U } @$outcome;
        return $nitems       ? ($unvalidated_win ? $UNVAL : $FOUND)
             : $inconclusive ? $INCONC
             : $unavailable == $nadapters ? $INCONC
             :                 $NOMATCH;
    };

    # Every outcome tuple of length $n, for 1..3 adapters — the real fleet maximum.
    my $tuples = sub {
        my ($n) = @_;
        my @out = ([]);
        for (1 .. $n) { @out = map { my $t = $_; map { [ @$t, $_ ] } ($A, $E, $U) } @out }
        return @out;
    };
    # Every (tuple, win, nitems) the resolver can present: a winner at each index, and the
    # no-winner case. `$win` is defined iff there are items, which the sub documents.
    my @cells;
    for my $n (1 .. 3) {
        for my $t ($tuples->($n)) {
            push @cells, [ $t, $n, undef, 0 ];
            push @cells, [ $t, $n, $_, 1 ] for 0 .. $n - 1;
        }
    }

    my @disagree = grep { $ttl->(@$_) != $old_ladder->(@$_) } @cells;
    ok(sprintf('%d cells enumerated (1-3 adapters, every outcome tuple, every winner)',
        scalar @cells), @cells == 141);
    is('every cell agrees with the 0.9.31 ladder', scalar(@disagree), 0);
    # Name the first disagreement rather than only counting, or a failure here says nothing
    # about which shape moved.
    ok('...and the first disagreement, if any, is named',
        !@disagree || printf("     first: [%s] n=%d win=%s items=%d  new=%d old=%d\n",
            join(',', @{ $disagree[0][0] }), $disagree[0][1],
            (defined $disagree[0][2] ? $disagree[0][2] : '-'), $disagree[0][3],
            $ttl->(@{ $disagree[0] }), $old_ladder->(@{ $disagree[0] })));

    # The seven rows of the documented table, asserted by NAME so a failure reads as a
    # behaviour rather than as a tuple index.
    is('winner, leg 2 answered            -> found',    $ttl->([$A],     1, 0, 1), $FOUND);
    is('winner, leg 2 errored             -> unvalidated', $ttl->([$E],  1, 0, 1), $UNVAL);
    is('winner, leg 2 had no handler      -> unvalidated', $ttl->([$U],  1, 0, 1), $UNVAL);
    is('no winner, a transient failure    -> inconclusive', $ttl->([$A,$E], 2, undef, 0), $INCONC);
    is('no winner, every svc unavailable  -> inconclusive', $ttl->([$U,$U], 2, undef, 0), $INCONC);
    is('no winner, one unavailable + one real miss -> nomatch',
        $ttl->([$U,$A], 2, undef, 0), $NOMATCH);
    is('no winner, all really missed      -> nomatch',  $ttl->([$A,$A], 2, undef, 0), $NOMATCH);
    # The winner's OWN outcome decides: a service that hung while LOSING must not shorten a
    # fully checked answer. This is the guard direction, and it is the one a "simplification"
    # to "any unvalidated adapter" would break.
    is('a hung service that LOST does not shorten the winner',
        $ttl->([$A,$E], 2, 0, 1), $FOUND);

    # COVERAGE 1 — every TTL is still reachable from some real combination. A constant no
    # cell can produce is a branch that has quietly died.
    my %seen; $seen{ $ttl->(@$_) }++ for @cells;
    is('STREAM_FOUND_TTL is reachable',        ($seen{$FOUND}   ? 'y' : 'n'), 'y');
    is('STREAM_UNVALIDATED_TTL is reachable',  ($seen{$UNVAL}   ? 'y' : 'n'), 'y');
    is('STREAM_INCONCLUSIVE_TTL is reachable', ($seen{$INCONC}  ? 'y' : 'n'), 'y');
    is('STREAM_NOMATCH_TTL is reachable',      ($seen{$NOMATCH} ? 'y' : 'n'), 'y');

    # COVERAGE 2 — EVERY ENUM VALUE MUST STILL CHANGE SOMETHING. For each ordered pair of
    # distinct values, there must be at least one cell where swapping one adapter's outcome
    # from the first to the second moves the TTL. If any pair scores zero, those two values
    # have become synonyms and the distinction between them is decorative — which is exactly
    # the state 0.9.30 left `$standing` in for a whole release.
    my %names = ($A => 'ANSWERED', $E => 'ERRORED', $U => 'UNAVAILABLE');
    for my $from ($A, $E, $U) {
        for my $to ($A, $E, $U) {
            next if $from eq $to;
            my $moves = 0;
            CELL: for my $c (@cells) {
                my ($t, $n, $win, $nitems) = @$c;
                for my $i (0 .. $#$t) {
                    next unless $t->[$i] eq $from;
                    my @swapped = @$t; $swapped[$i] = $to;
                    if ($ttl->(\@swapped, $n, $win, $nitems) != $ttl->($t, $n, $win, $nitems)) {
                        $moves++; last CELL;
                    }
                }
            }
            ok("$names{$from} -> $names{$to} still changes the TTL somewhere", $moves > 0);
        }
    }

    # THE STAND-IN FLAG, WALKED OVER THE SAME CELLS (1.0.7, code review of 1.0.6 finding 5). The
    # sixth argument (1.0.5) had two point tests only. Its whole contract, cell by cell, with and
    # without the fifth (`$unverified`, every service flagged): a winning cell is held a day
    # whatever else is true, and a cell with no winner is EXACTLY what it was without the flag.
    # The oracle is stated from the contract, not by re-reading the sub. Anti-tested: a flag
    # read ABOVE the `$nitems` test fails only here — 5e's point test ("a miss is still
    # NOMATCH") cannot see it, because STREAM_NOMATCH_TTL and STREAM_UNVALIDATED_TTL are both a
    # day; the INCONCLUSIVE cells are what tell them apart.
    my @allFlagged = (1, 1, 1);
    my @standBad;
    for my $c (@cells) {
        my (undef, undef, undef, $nitems) = @$c;
        for my $unv (undef, \@allFlagged) {
            my $want = $nitems ? $UNVAL : $ttl->(@$c, $unv, 0);
            push @standBad, $c if $ttl->(@$c, $unv, 1) != $want;
        }
    }
    is('stand-in: every cell x {no flags, all flagged} keeps its contract', scalar(@standBad), 0);
    ok('stand-in: the flag still CHANGES some cell (it is not decorative)',
        scalar grep { $ttl->(@$_, undef, 1) != $ttl->(@$_, undef, 0) } @cells);
}

# --- 4. _releaseAlts: offer the rival, never adjudicate ---------------------
print "\n4. release alts — editions collapse, releases do not\n";
{
    my $alts = $B->can('_releaseAlts');
    my $res  = sub { { items => [ map { { %$_, _svc => 'Qobuz' } } @_ ] } };

    my @a = $alts->(cand($ALBUM), $res->(cand($ALBUM), cand($SINGLE)));
    is('a differently-titled release is offered', scalar(@a), 1);
    is('...and it is the single',                 $a[0]{_svctitle}, $SINGLE);
    is('...tagged so the renderer can label it',  $a[0]{_altkind}, 'release');

    # _norm strips brackets, so every edition of one record folds to the same key. Offering
    # "Foo (Deluxe Edition)" as "another release with this name" would be nonsense.
    my @e = $alts->(cand($ALBUM), $res->(cand($ALBUM), cand("$ALBUM (Deluxe Edition)"),
                                         cand("$ALBUM (Remastered)")));
    is('editions of one record are NOT offered', scalar(@e), 0);

    # Same-artist singles that _albumMatches admits ARE different records, and the EP
    # review is exactly where the ranking is most likely to be wrong — so this is the
    # direction that most needs an escape hatch.
    my @w = $alts->(cand('I Wander'), $res->(cand('I Wander'), cand('I Wander (III)'),
                                             cand('I Wander (IV + V)')));
    is('distinct same-artist releases are offered', scalar(@w), 2);

    # ALT_RELEASE_MAX — these rows sit above a tracklist; a stack of them is a worse
    # answer than the wrong one being corrected.
    my @m = $alts->(cand($ALBUM), $res->(cand($ALBUM), cand('A'), cand('B'), cand('C')));
    is('capped at ALT_RELEASE_MAX', scalar(@m), $B->ALT_RELEASE_MAX);

    # No service title = no evidence; guessing here would offer the same record twice.
    my @n = $alts->({ name => 'no title' }, $res->(cand($ALBUM), cand($SINGLE)));
    is('a titleless primary offers nothing', scalar(@n), 0);

    # The alts must be COPIES — the primary is the node the resolver cached and handed to
    # every other caller, and tagging it in place would poison it.
    my $prim = cand($ALBUM);
    my ($alt) = $alts->($prim, $res->($prim, cand($SINGLE)));
    ok('the cached node is not tagged in place', !exists $prim->{_altkind});
    ok('the alt is a distinct hashref', $alt != $prim);
}

# =============================================================================
print "\n# 5. SIZE: a same-titled single never takes an album review's row, and is offered (1.0.3)\n";
# =============================================================================
# THE FIELD CASES, measured live 2026-10-21 (2 of 68 Qobuz rows), both a 1-track title-track
# single beside the album with the SAME title, so 0.9.27's title rule could not split them:
#   (b) Troye Sivan - She's the Best: artist search returns the single at 7, the album at 21;
#       both exact, so service order decided and the single took the row.
#   (a) @ - Autosmile (17 Oct): the artist search returned the single and NOT the album; the
#       single was exact, so the title leg (which had the album, first) never ran.
# Pitchfork files every review PFR reads under "Albums" and marks an EP in the title, so an
# exact SINGLE is evidence the album is missing or behind it. Sizes are the Discography rule.
sub scand { my ($t, $size, $who) = @_;
            return { name => ($who // 'Troye Sivan') . " - $t", _svctitle => $t, image => 'c.jpg',
                     (defined $size ? (_size => $size) : ()) } }
my $TROYE = "She's the Best";
{
    my $sz = $B->can('_candSize');
    print "5a. _candSize — counts first, duration decides a long short record\n";
    is('Qobuz 1-track single',                    $sz->({ tracks_count => 1,  duration => 213 }),  'single');
    is('Qobuz 12-track album',                    $sz->({ tracks_count => 12, duration => 2556 }), 'album');
    is('SML: 2 tracks, 48 min is an ALBUM',        $sz->({ tracks_count => 2,  duration => 2880 }), 'album');
    is('Ambarchi: 2 tracks, 43 min is an ALBUM',   $sz->({ tracks_count => 2,  duration => 2580 }), 'album');
    is('a 3-track, 23-minute EP reads single (why an EP review is exempt, 5b)',
                                                  $sz->({ tracks_count => 3,  duration => 1380 }), 'single');
    is('4 tracks, 15 min is an EP',                $sz->({ tracks_count => 4,  duration => 900 }),  'ep');
    is('7 short tracks is an album (count > 6)',   $sz->({ tracks_count => 7,  duration => 1200 }), 'album');
    is('TIDAL count field',                        $sz->({ numberOfTracks => 1 }), 'single');
    is('TIDAL stated type, no counts',             $sz->({ type => 'EP' }), 'ep');
    is('Deezer: the count beats record_type',      $sz->({ nb_tracks => 1, record_type => 'album' }), 'single');
    is('Deezer: record_type when no count',        $sz->({ record_type => 'single' }), 'single');
    is('Deezer entity `type` never outranks a count', $sz->({ nb_tracks => 10, type => 'album' }), 'album');
    ok('nothing stated -> unknown',               !defined $sz->({}));
    ok('a junk count -> unknown',                 !defined $sz->({ tracks_count => 'x' }));
    ok('not a hash -> unknown',                   !defined $sz->(undef));

    my $sv = sub { $sz->($B->can('_spotifySizeView')->(@_)) };
    is('Spotify album_type album',                 $sv->({ album_type => 'album', total_tracks => 2 }), 'album');
    is('Spotify compilation',                      $sv->({ album_type => 'compilation' }), 'album');
    is('Spotify single, 1 track',                  $sv->({ album_type => 'single', total_tracks => 1 }), 'single');
    is('Spotify files EPs as single: 5 tracks -> ep', $sv->({ album_type => 'single', total_tracks => 5 }), 'ep');
    ok('Spotify single with no count -> unknown',  !defined $sv->({ album_type => 'single' }));
    ok('Spotify with nothing -> unknown',          !defined $sv->({}));
}
{
    print "5b. _reviewIsEp — Pitchfork's only format marker\n";
    my $ep = $B->can('_reviewIsEp');
    ok('"I Wander EP" is an EP review',  $ep->('I Wander EP'));
    ok('"Faith EP" is an EP review',     $ep->('Faith EP'));
    ok('"Autosmile" is not',            !$ep->('Autosmile'));
    ok('"Foo LP" is not',               !$ep->('Foo LP'));
    ok('"Sleep" is not (a word ending in ep)', !$ep->('Sleep'));
    ok('a bare "EP" title is not (the _stripFmt rule: needs a base)', !$ep->('EP'));
}
{
    print "5c. the row — among exact titles, not a single\n";
    my $r = resolve('Troye Sivan', $TROYE,
        Qobuz => { script => [ [ scand($TROYE, 'single'), scand($TROYE, 'album') ] ] });
    my @t = map { $_->{_size} // '' } @{ $r->{items} || [] };
    is('Troye: the ALBUM takes the row',          $t[0], 'album');
    is('...the single is kept, behind it',        $t[1], 'single');
    is('...nothing dropped',                      scalar(@t), 2);
    is('...and the CACHED order agrees (what a later open replays)',
        ($WROTE[-1]{items}[0] || {})->{_size}, 'album');
    is('one query: an exact album in leg 1 settles it', scalar(queries()), 1);

    $r = resolve('Troye Sivan', $TROYE, Qobuz => { script => [ [ scand($TROYE), scand($TROYE, 'album') ] ] });
    is('CONTROL: unknown size is not single — service order stands',
        ($r->{items}[0] || {})->{_size} // 'undef', 'undef');

    $r = resolve('Troye Sivan', $TROYE, Qobuz => { script => [ [ scand($TROYE, 'album'), scand("$TROYE (Deluxe)", 'album') ] ] });
    is('CONTROL: two album-sized editions keep service order', (titles($r))[0], $TROYE);

    $r = resolve('Deafheaven', 'Bomb EP', Qobuz => { script => [
        [ scand('Bomb', 'single', 'Deafheaven'), scand('Bomb', 'album', 'Deafheaven') ] ] });
    is('an EP REVIEW keeps its single-sized match (3-track EPs exist)',
        ($r->{items}[0] || {})->{_size}, 'single');

    $r = resolve('Troye Sivan', $TROYE, Qobuz => { script => [
        [ scand($TROYE, 'single'), scand("$TROYE (Live)", 'album') ], [] ] });
    is('only EXACT titles compete: a loose album never beats an exact single', (titles($r))[0], $TROYE);

    my $pick = $B->can('_rowPick');
    is('_rowPick: nothing exact -> 0', $pick->($TROYE, [ scand('Other', 'album'), scand('Else', 'album') ]), 0);
    is('_rowPick: all exact singles -> the first', $pick->($TROYE, [ scand($TROYE, 'single'), scand($TROYE, 'single') ]), 0);
    is('_rowPick: reaches past a loose row and an exact single',
        $pick->($TROYE, [ scand('Other', 'album'), scand($TROYE, 'single'), scand($TROYE, 'album') ]), 2);
}
{
    print "5d. the title leg — an exact single does not settle an album review\n";
    my $w = $B->can('_wantsTitleRetry');
    ok('exact single only -> retry',                 $w->($TROYE, [ scand($TROYE, 'single') ]));
    ok('exact single + exact album -> no retry',    !$w->($TROYE, [ scand($TROYE, 'single'), scand($TROYE, 'album') ]));
    ok('exact album only -> no retry',              !$w->($TROYE, [ scand($TROYE, 'album') ]));
    ok('exact EP-sized -> no retry',                !$w->($TROYE, [ scand($TROYE, 'ep') ]));
    ok('exact, size unknown -> no retry (no evidence)', !$w->($TROYE, [ scand($TROYE) ]));
    ok('an EP review: exact single-sized -> no retry', !$w->('Bomb EP', [ scand('Bomb', 'single') ]));

    my $FOUND = $B->can('STREAM_FOUND_TTL')->();
    my $r = resolve('@', 'Autosmile', Qobuz => { script => [
        [ scand('Autosmile', 'single', '@') ],     # 17 Oct: the artist leg had only the single
        [ scand('Autosmile', 'album',  '@') ],     # the title leg returned the album, first
    ] });
    my @q = queries();
    is('Autosmile: two legs were run',            scalar(@q), 2);
    is('...leg 2 asked for the title',            $q[1], 'Autosmile');
    is('...and the ALBUM takes the row',          ($r->{items}[0] || {})->{_size}, 'album');
    is('...the single kept behind it',            ($r->{items}[1] || {})->{_size}, 'single');
    is('...validated: leg 2 answered',            ttl_written(), $FOUND);

    $r = resolve('@', 'Autosmile', Qobuz => { script => [
        [ scand('Autosmile', 'single', '@') ], [ scand('Autosmile', 'single', '@') ] ] });
    is('leg 2 finds no album: the single still plays', ($r->{items}[0] || {})->{_size}, 'single');
    is('...listed once',                          scalar(@{ $r->{items} }), 1);

    # 1.0.5: THE STAND-IN IS HELD A DAY, NOT THIRTY. The retry exists because an exact single on an
    # album review means the album is missing; pinning the single for STREAM_FOUND_TTL kept it
    # missing for a month after the service got it (the code review of 1.0.4, finding 1).
    my $UNVAL = $B->can('STREAM_UNVALIDATED_TTL')->();
    is('...and is held a DAY, so the album is picked up', ttl_written(), $UNVAL);
    resolve('@', 'Autosmile', Qobuz => { script => [ [ scand('Autosmile', 'single', '@') ], [] ] });
    is('leg 2 answers empty: same hold',          ttl_written(), $UNVAL);
    resolve('@', 'Autosmile', Qobuz => { script => [ [], [ scand('Autosmile', 'single', '@') ] ] });
    is('only leg 2 had the single: same hold',    ttl_written(), $UNVAL);
    # CONTROLS — every shape that is NOT a stand-in keeps the thirty days.
    resolve('Deafheaven', 'Bomb EP', Qobuz => { script => [ [ scand('Bomb', 'single', 'Deafheaven') ] ] });
    is('CONTROL: an EP review\'s single-sized EP keeps FOUND', ttl_written(), $FOUND);
    resolve('@', 'Autosmile', Qobuz => { script => [ [ scand('Autosmile', undef, '@') ] ] });
    is('CONTROL: unknown size keeps FOUND',       ttl_written(), $FOUND);
    resolve('@', 'Autosmile', Qobuz => { script => [ [ scand('Autosmile', 'ep', '@') ] ] });
    is('CONTROL: an EP-sized exact keeps FOUND',  ttl_written(), $FOUND);
    resolve('@', 'Autosmile', Qobuz => { script => [
        [ scand('Autosmile', 'single', '@') ], [ scand('Autosmile', 'album', '@') ] ] });
    is('CONTROL: the album found by leg 2 keeps FOUND (its single behind it)', ttl_written(), $FOUND);
    resolve('@', 'Autosmile', Qobuz => { script => [
        [ scand('Autosmile (Live)', 'single', '@') ], [ scand('Autosmile (Live)', 'single', '@') ] ] });
    is('CONTROL: a LOOSE single is not a stand-in (0.9.29 table unchanged)', ttl_written(), $FOUND);

    my $si = $B->can('_singleStandIn');
    ok('_singleStandIn: exact single, album review',  $si->('Autosmile', scand('Autosmile', 'single')));
    ok('_singleStandIn: not on an EP review',        !$si->('Bomb EP',   scand('Bomb', 'single')));
    ok('_singleStandIn: not a loose single',         !$si->('Autosmile', scand('Autosmile (Live)', 'single')));
    ok('_singleStandIn: not an album',               !$si->('Autosmile', scand('Autosmile', 'album')));
    ok('_singleStandIn: not an unknown size',        !$si->('Autosmile', scand('Autosmile')));
    my $st = $B->can('_streamTtl');
    my $A  = $B->can('OUTCOME_ANSWERED')->();
    is('_streamTtl: the flag shortens a checked winner',   $st->([$A], 1, 0, 1, [0], 1), $UNVAL);
    is('_streamTtl: ...and only with items (a miss is still NOMATCH)',
        $st->([$A], 1, undef, 0, [0], 1), $B->can('STREAM_NOMATCH_TTL')->());

    resolve('Deafheaven', 'Bomb EP', Qobuz => { script => [ [ scand('Bomb', 'single', 'Deafheaven') ] ] });
    is('an EP review pays no second search',      scalar(queries()), 1);

    # 1.0.6 (code review of 1.0.5, finding 6): A STAND-IN WON BELOW THE TOP SERVICE. Every case above
    # is one service, so `$win` is 0 and the stand-in sits first in the raw list too; a `$standIn` read
    # off the TOP service's list, or honoured only when `$win` is 0, passed all of them.
    reset_svc();
    resolve('@', 'Autosmile',
        Aqobuz => { priority => 1, script => [ [], [] ] },
        Btidal => { priority => 2, script => [ [ scand('Autosmile', 'single', '@') ], [] ] });
    is('a LOWER service\'s stand-in is held a day too', ttl_written(), $UNVAL);
    is('...it is the row',                        (cached_titles())[0], 'Autosmile');
    # The figure `_streamTtl`'s note states (finding 2): both legs on both services, not two.
    is('...and costs both legs on BOTH services (2 x N, not 2)', scalar(queries()), 4);
    resolve('@', 'Autosmile',
        Aspot  => { priority => 1, script => [ [], [] ], extra => { empty_unverified => 1 } },
        Bqobuz => { priority => 2, script => [ [ scand('Autosmile', 'single', '@') ], [] ] });
    is('a stand-in below an unverifiable empty answer: a day', ttl_written(), $UNVAL);
    resolve('@', 'Autosmile',
        Aqobuz => { priority => 1, script => [ [], [] ] },
        Btidal => { priority => 2, script => [ [ scand('Autosmile', 'single', '@') ],
                                                [ scand('Autosmile', 'album', '@') ] ] });
    is('CONTROL: the lower service\'s album found by leg 2 keeps FOUND', ttl_written(), $FOUND);
    is('...and takes the row',                    ($WROTE[-1]{items}[0] || {})->{_size}, 'album');

    # 1.0.6 (finding 1): THE RETRY'S DEBUG LINE NAMES THE SHAPE THAT FIRED IT. It said "loose" for an
    # exact single standing in for the album, which is the opposite of what it is.
    my $why = $B->can('_retryReason');
    is('_retryReason: nothing',                   $why->('Autosmile', []), 'no hit');
    is('_retryReason: an exact single',           $why->('Autosmile', [ scand('Autosmile', 'single') ]),
        '1 exact single(s) standing in for the album');
    is('_retryReason: loose only (the 0.9.27 wording kept)',
        $why->('Autosmile', [ scand('Autosmile (Live)', 'single'), scand('Autosmiles', 'album') ]),
        '2 loose match(es)');
    is('_retryReason: both',                      $why->('Autosmile', [ scand('Autosmile', 'single'),
                                                                        scand('Autosmile (Live)', 'album') ]),
        '1 exact single(s) standing in for the album + 1 loose match(es)');
    my @lines;
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_verbose = sub { 1 };
        local *Plugins::PitchforkReviews::Plugin::dbg      = sub { push @lines, $_[0] };
        resolve('@', 'Autosmile', Qobuz => { script => [ [ scand('Autosmile', 'single', '@') ], [] ] });
    }
    my ($line) = grep { /retrying on album/ } @lines;
    ok('the live line says exact single, not loose',
        scalar(defined $line && $line =~ /1 exact single\(s\) standing in/ && $line !~ /loose/));

    # 1.0.7 (code review of 1.0.6, finding 3): a candidate stating no title is NOT loose — the same
    # line `_wantsTitleRetry` draws. No live adapter sends one (all four set `_svctitle`).
    is('_retryReason: an untitled candidate is not counted loose',
        $why->('Autosmile', [ scand('Autosmile', 'single'), { name => '@ - ?', _size => 'album' } ]),
        '1 exact single(s) standing in for the album + 1 untitled match(es)');
    is('CONTROL: an empty title is untitled too',
        $why->('Autosmile', [ scand('Autosmile (Live)', 'album'), { name => 'x', _svctitle => '' } ]),
        '1 loose match(es) + 1 untitled match(es)');

    # 1.0.7 (finding 7): with debug OFF the reason is never built — `_dbgv` gates only after its
    # argument is evaluated, so the call site must gate. The retry itself still fires.
    my $built = 0;
    {
        no warnings 'redefine';
        my $real = $why;
        local *Plugins::PitchforkReviews::Browse::_verbose     = sub { 0 };
        local *Plugins::PitchforkReviews::Browse::_retryReason = sub { $built++; $real->(@_) };
        @QUERIES = ();
        resolve('@', 'Autosmile', Qobuz => { script => [ [ scand('Autosmile', 'single', '@') ], [] ] });
    }
    is('debug off: the reason is not built', $built, 0);
    is('...and the retry still ran (two legs)', scalar(@QUERIES), 2);
}
{
    # 1.0.6 (code review of 1.0.5, finding 5): `_reviewIsEp` and `_stripFmt` must agree on what a
    # trailing EP is. `_stripFmt` is a FLEET matcher sub (pinned in matcher_sync_check.py), so
    # `_reviewIsEp` cannot share its code; the agreement is pinned here instead. If either learns a
    # spelling the other does not, an EP review is folded to match its EP but judged as an album.
    print "5d2. _reviewIsEp agrees with _stripFmt on every spelling\n";
    my ($isEp, $norm, $strip) = map { $B->can($_) } qw(_reviewIsEp _norm _stripFmt);
    for my $t ('Foo EP', 'Foo - EP', 'Foo-EP', 'Foo ep.', 'Foo E.P.', 'Foo (EP)', 'Foo LP', 'Foo',
               'EP', 'EP2', 'Deep', 'Foo Sweep') {
        my $n = $norm->($t);
        my $s = $strip->($n);
        my $foldsEp = ($s ne $n && $n =~ /ep$/) ? 1 : 0;
        is("'$t': _reviewIsEp = _stripFmt folds an EP", $isEp->($t), $foldsEp);
    }
}
{
    print "5e. the offer — the other size is another release\n";
    my $alts = $B->can('_releaseAlts');
    my $res  = sub { { items => [ map { { %$_, _svc => 'Qobuz' } } @_ ] } };

    my @a = $alts->(scand($TROYE, 'album'), $res->(scand($TROYE, 'album'), scand($TROYE, 'single')));
    is('Troye: the single is offered under the album', scalar(@a), 1);
    is('...it is the single',                     $a[0]{_size}, 'single');
    is('...tagged with the size that sets it apart', $a[0]{_altsize}, 'single');
    is('...still a release alt',                  $a[0]{_altkind}, 'release');

    @a = $alts->(scand('Bomb', 'single'), $res->(scand('Bomb', 'single'), scand('Bomb', 'album')));
    is('the other direction: the album offered under a single-sized row', ($a[0] || {})->{_altsize}, 'album');

    @a = $alts->(scand($TROYE, 'album'), $res->(scand($TROYE, 'album'), scand("$TROYE (Deluxe Edition)", 'album')));
    is('CONTROL: editions of one size still collapse', scalar(@a), 0);

    @a = $alts->(scand($TROYE, 'album'), $res->(scand($TROYE, 'album'), scand($TROYE)));
    is('CONTROL: an unstated size offers nothing new (0.9.27 behaviour)', scalar(@a), 0);
    @a = $alts->(scand($TROYE), $res->(scand($TROYE), scand($TROYE, 'single')));
    is('CONTROL: ...nor does an unstated primary', scalar(@a), 0);

    @a = $alts->(scand($TROYE, 'album'), $res->(scand($TROYE, 'album'), scand($TROYE, 'single'),
                                                 scand("$TROYE (Remix)", 'single')));
    is('a size alt and a title alt together',     scalar(@a), 2);
    ok('...only the size alt carries _altsize',   defined $a[0]{_altsize} && !exists $a[1]{_altsize});

    @a = $alts->(cand($ALBUM), $res->(cand($ALBUM), { %{ cand($SINGLE) }, _size => 'single' }));
    ok('CONTROL: a differently-titled alt is not tagged with a size', !exists $a[0]{_altsize});
}
{
    print "5f. wiring — _resolveSection hands the offer to the row\n";
    my $it = { artist => 'Troye Sivan', album => $TROYE, date => '2026-10-09T04:00:00.000Z' };
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_findPlayableReview = sub {
            $_[1]->({ items => [ map { { %$_, _svc => 'Qobuz' } } scand($TROYE, 'album'), scand($TROYE, 'single') ] });
        };
        $B->can('_resolveSection')->(undef, [ $it ], sub {}, 10, 'view');
    }
    is('the row plays the album',                 ($it->{_album} || {})->{_size}, 'album');
    is('...and its drill-in offers the single',   (($it->{_alt} || [])->[0] || {})->{_altsize}, 'single');
}
{
    print "5g. every adapter stamps _size from the service's own album hash\n";
    no warnings 'redefine', 'once';
    my $collected;
    my $grab = sub { $collected = $_[0] };
    my $first = sub { ((ref $collected eq 'ARRAY' ? $collected : [])->[0] || {})->{_size} // 'undef' };
    my @args = ('Troye Sivan', 'troye sivan', $B->can('_norm')->($TROYE));
    {
        local *Plugins::Qobuz::Plugin::getAPIHandler = sub { bless {}, 'T::QobuzAPI5' };
        local *T::QobuzAPI5::search = sub { $_[1]->({ albums => { items => [
            { id => 'q1', title => $TROYE, artist => { name => 'Troye Sivan' }, tracks_count => 1, duration => 200 } ] } }) };
        local *Plugins::Qobuz::Plugin::_albumItem = sub { { name => 'x', url => sub {} } };
        $B->can('_searchQobuz')->(undef, @args, 'Qobuz', $grab, $TROYE);
        is('Qobuz: tracks_count + duration',      $first->(), 'single');
    }
    {
        local *Plugins::TIDAL::Plugin::getAPIHandler = sub { bless {}, 'T::TidalAPI5' };
        local *T::TidalAPI5::search = sub { $_[1]->([
            { id => 't1', title => $TROYE, artist => { name => 'Troye Sivan' }, numberOfTracks => 12, duration => 2556 } ]) };
        local *Plugins::TIDAL::Plugin::_renderAlbum = sub { { name => 'x', url => sub {} } };
        $B->can('_searchTidal')->(undef, @args, 'Tidal', $grab, $TROYE);
        is('TIDAL: numberOfTracks',               $first->(), 'album');
    }
    {
        local *Plugins::Deezer::Plugin::getAPIHandler = sub { bless {}, 'T::DeezerAPI5' };
        local *T::DeezerAPI5::search = sub { $_[1]->([
            { id => 'd1', title => $TROYE, artist => { name => 'Troye Sivan' }, nb_tracks => 5, record_type => 'single' } ]) };
        local *Plugins::Deezer::Plugin::_renderAlbum = sub { { name => 'x', url => sub {} } };
        $B->can('_searchDeezer')->(undef, @args, 'Deezer', $grab, $TROYE);
        is('Deezer: nb_tracks',                   $first->(), 'ep');
    }
    {
        local *Plugins::Spotty::Plugin::getAPIHandler = sub { bless {}, 'T::SpottyAPI5' };
        local *Plugins::Spotty::API::hasError429 = sub { 0 };
        local *T::SpottyAPI5::search = sub { $_[1]->([
            { id => 's1', name => $TROYE, artist => 'Troye Sivan', album_type => 'album', total_tracks => 12 } ]) };
        local *Plugins::Spotty::OPML::_albumItem = sub { { name => 'x', url => sub {} } };
        $B->can('_searchSpotify')->(undef, @args, 'Spotify', $grab, $TROYE);
        is('Spotify: through _spotifySizeView',   $first->(), 'album');
    }
    ok('a correctness bump retired the :27: answers (they hold no _size)',
       $B->can('STREAM_KEY_VERSION')->() >= 28);
}
{
    print "5h. the dedupe — a single and its album render IDENTICALLY on Qobuz\n";
    # Qobuz's `_albumItem` labels from artist + title + year, so the Aug single and the Oct album
    # are the same row to a display-text key. Found by 5c on its first run: the album was being
    # discarded here, before any ranking ran.
    my $d = sub { scalar @{ $B->can('_dedupeStreamItems')->([ map { { %$_, _svc => 'Qobuz', line2 => 'Troye Sivan (2026)' } } @_ ]) } };
    is('same label, different sizes: both kept',  $d->(scand($TROYE, 'single'), scand($TROYE, 'album')), 2);
    is('same label, same size: one (the duplicate the dedupe exists for)',
                                                  $d->(scand($TROYE, 'album'), scand($TROYE, 'album')), 1);
    is('CONTROL: sizes unstated collapse exactly as before', $d->(scand($TROYE), scand($TROYE)), 1);
}

# =============================================================================
print "\n# 3h. an `empty_unverified` service's empty answer ABOVE the winner holds the row a day (0.9.36)\n";
# =============================================================================
# Driven through the REAL _findPlayable: a _streamTtl that honours the flag is worth nothing if
# $resolve never hands it over, and that call site is exactly what a unit test of _streamTtl
# cannot see. Field case: Spotify at priority 1 on a rate-limited quota answered `[]` to 184
# searches, Qobuz matched below it, and the rows were pinned to Qobuz for thirty days.
{
    reset_svc();
    my $FOUND   = $B->can('STREAM_FOUND_TTL')->();
    my $UNVAL   = $B->can('STREAM_UNVALIDATED_TTL')->();
    my $NOMATCH = $B->can('STREAM_NOMATCH_TTL')->();

    resolve('Interpol', $ALBUM,
        Aspot  => { priority => 1, script => [ [], [] ], extra => { empty_unverified => 1 } },
        Bqobuz => { priority => 2, script => [ [ cand($ALBUM) ] ] });
    is('flagged top service empty, the next one matched -> a day, not thirty', ttl_written(), $UNVAL);
    is('...and the row is still the match that was found', (cached_titles())[0], $ALBUM);

    resolve('Interpol', $ALBUM,
        Aspot  => { priority => 1, script => [ [], [] ] },
        Bqobuz => { priority => 2, script => [ [ cand($ALBUM) ] ] });
    is('CONTROL: the same run without the flag keeps thirty days', ttl_written(), $FOUND);

    resolve('Interpol', $ALBUM,
        Aspot  => { priority => 1, script => ['ERRORED'], extra => { empty_unverified => 1 } },
        Bqobuz => { priority => 2, script => [ [ cand($ALBUM) ] ] });
    is('flagged top service ERRORED (a 429 lands here) -> a day', ttl_written(), $UNVAL);

    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => [ [ cand($ALBUM) ] ] },
        Bspot  => { priority => 2, script => [ [], [] ], extra => { empty_unverified => 1 } });
    is('a flagged service BELOW the winner changes nothing', ttl_written(), $FOUND);

    resolve('Interpol', $ALBUM,
        Aspot  => { priority => 1, script => [ [], [] ], extra => { empty_unverified => 1 } },
        Bqobuz => { priority => 2, script => [ [], [] ] });
    is('no winner: a confirmed no-match is untouched (ledger B)', ttl_written(), $NOMATCH);
}

# =============================================================================
print "\n# 3i. a \"Title: Subtitle\" review retries on the title before the colon — exact, dated, guarded (0.9.38)\n";
# =============================================================================
# Driven through the REAL _findPlayableReview / _findPlayable. Each guard is pinned by the real
# catalogue shape that motivated it (audit 2026-09-15): Badu fixed, Turnstile's different 2025
# record refused, a prefix sibling refused, a yearless match refused, year-list slack allowed.
sub ycand {
    my ($t, $y) = @_;
    return { name => "Erykah Badu - $t", _svctitle => $t, image => 'c.jpg', (defined $y ? (_year => $y) : ()) };
}
{
    reset_svc();
    my $ARTIST = 'Erykah Badu / The Alchemist';
    my $BADU   = 'Before the World Blows: The Abi and Alan Experiment';
    my $SHORT  = 'Before The World Blows';
    my $real   = $B->can('_realMatches');
    my $review = sub {
        my ($album, $minYear, %svc) = @_;
        @QUERIES = (); @WROTE = (); @ADAPTERS = adapters_returning(%svc);
        @Slim::Utils::Timers::armed = ();
        my $got;
        $B->can('_findPlayableReview')->(undef, sub { $got = $_[0] }, $ARTIST, $album, undef, $minYear);
        return $got;
    };

    # Script per resolve: full title leg 1 + its title leg 2, then the pre-colon resolve's legs.
    my $r = $review->($BADU, 2026, Spot => { script => [ [], [], [ ycand($SHORT, 2026) ] ] });
    is('Badu: full title missed, the title before the colon matched -> the row plays it', (titles($r))[0], $SHORT);
    is('...the full title was searched FIRST (artist, then its own title), then a second resolve',
       join('|', queries()), "$ARTIST|$BADU|$ARTIST");

    $r = $review->($BADU, 2026, Spot => { script => [ [ ycand($BADU, 2026) ] ] });
    is('a subtitled title that ALREADY matches is untouched', (titles($r))[0], $BADU);
    is('...and costs no second resolve', scalar(queries()), 1);

    $r = $review->('NEVER ENOUGH: VERSIONS', 2026, Spot => { script => [ [], [], [ ycand('NEVER ENOUGH', 2025) ] ] });
    is('Turnstile trap: an exact pre-colon title from BEFORE the review year is another record -> no match',
       scalar($real->($r)), 0);

    $r = $review->($BADU, 2026, Spot => { script => [ [], [], [ ycand("$SHORT: Porches Version", 2026) ], [] ] });
    is('a PREFIX sibling of the pre-colon title is refused (exact only)', scalar($real->($r)), 0);

    $r = $review->($BADU, 2026, Spot => { script => [ [], [], [ ycand($SHORT) ] ] });
    is('a pre-colon match stating NO year is refused (no evidence it is this record)', scalar($real->($r)), 0);

    $r = $review->($BADU, 2026, Spot => { script => [ [], [], [ ycand("$SHORT (Deluxe Edition)", 2026) ] ] });
    is('an edition bracket is still exact (_norm strips it)', scalar($real->($r)), 1);

    $r = $review->($BADU, 2020, Spot => { script => [ [], [], [ ycand($SHORT, 2020) ] ] });
    is('a year-end list\'s one year of slack admits the previous year', scalar($real->($r)), 1);

    $r = $review->($BADU, undef, Spot => { script => [ [], [], [ ycand($SHORT, 2026) ] ] });
    is('no known year for the row -> no retry at all', scalar($real->($r)), 0);
    is('...and no second resolve', scalar(queries()), 2);

    my $base = $B->can('_subtitleBase');
    is('base: the text before the first ": "', $base->($BADU, $ARTIST), 'Before the World Blows');
    is('base: Dawn Richard', $base->('Second Line: An Electro Revival', 'Dawn Richard'), 'Second Line');
    ok('base: a title that also has a slash is left to the combined-review path',
       !defined $base->("Song of Sage: Post Panic! / Navy's Reprise", 'Navy Blue'));
    ok('base: a colon with no following space (4:44) is not a subtitle', !defined $base->('4:44', 'JAY-Z'));
    ok('base: pre-colon text that IS the artist is refused', !defined $base->('Adele: Live at the Albert Hall', 'Adele'));
    ok('base: a one-character pre-colon title is refused', !defined $base->('X: Something Else', 'Band'));

    my $min = $B->can('_subtitleMinYear');
    is('min year: a review uses its own year', $min->({ date => '2026-09-04T04:03:00.000Z' }), 2026);
    is('min year: a year-end entry allows the previous year', $min->({ year => 2021, rank => 3, date => '2021-12-07T14:00:00.000Z' }), 2020);
    ok('min year: nothing known -> undef', !defined $min->({ artist => 'A' }));

    # WIRING — a guarded retry is worth nothing if the callers never hand it a year.
    my @args;
    {
        no warnings 'redefine';
        local *Plugins::PitchforkReviews::Browse::_findPlayableReview = sub { push @args, [ @_ ] };
        $B->can('_resolveSection')->(undef, [ { artist => 'A', album => 'T: Sub', date => '2026-09-04T04:03:00.000Z' } ],
            sub {}, 10, 'view');
        my $yr = { artist => 'A', album => 'T: Sub', year => 2021, rank => 4 };
        $B->can('_refreshMatchRow')->(undef, $yr)->{url}->(undef, sub {}, {}, $yr);
    }
    is('the resolve pump passes the review\'s year', ($args[0] || [])->[5], 2026);
    is('the Refresh row passes a year-end entry\'s year minus one', ($args[1] || [])->[5], 2020);
    is('...and still forces', ($args[1] || [])->[4], 1);
    ($args[0][1] || sub {})->({ items => [] });   # release the view's in-flight count
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

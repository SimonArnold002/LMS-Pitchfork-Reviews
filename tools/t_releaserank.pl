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
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
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

    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => [ [], [] ] });
    is('one signed out, one really searched and missed -> a real no-match',
        ttl_written(), $NOMATCH);

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
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => ['SIGNEDOUT'] },
        Btidal => { priority => 2, script => [ [ cand($ALBUM) ] ] });
    is('a signed-out service does not shorten a real match', ttl_written(), $FOUND);

    # And it does not consume the retry: the signed-out leg sends undef, which
    # `_wantsTitleRetry` refuses, so no second query is spent on a service that cannot
    # answer either of them.
    resolve('Interpol', $ALBUM, Qobuz => { script => ['SIGNEDOUT', [ cand($ALBUM) ] ] });
    is('a signed-out service is asked exactly once', scalar(queries()), 1);

    # THREE ADAPTERS, THE UNAVAILABLE ONE IN THE MIDDLE. `$unavailable == @adapters` is an
    # equality against the adapter COUNT, so a partial tally must not accidentally satisfy
    # it, and the fan-out (which only adapter 0 performs) still has to reach adapter 2.
    resolve('Interpol', $ALBUM,
        Aqobuz => { priority => 1, script => [ [], [] ] },
        Btidal => { priority => 2, script => ['SIGNEDOUT'] },
        Cdeezr => { priority => 3, script => [ [], [] ] });
    is('one of three unavailable, the others really missed -> a real no-match',
        ttl_written(), $NOMATCH);

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

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

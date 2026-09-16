#!/usr/bin/env perl
# THE PITCHFORK SCORE ON A REVIEW ROW (0.9.40) — display only, on line2 only.
#
# WHAT THE FEATURE HAD TO PROMISE, and therefore what is asserted here:
#
#   1. IT APPEARS ON THE THREE REVIEW SECTIONS AND NOWHERE ELSE. Best New Music, High
#      Scoring Albums and Latest Reviews carry a score; the year-end lists do not, and
#      `_parseYear` says so by hardcoding `score => undef`. So `defined $it->{score}` IS
#      the section test, and a ranked row must come back byte-for-byte as it did before.
#   2. IT NEVER TOUCHES THE ROW LABEL. A Spotify-matched row carries no `&al=` handshake,
#      so ListenLater stores that row's LABEL as the album title (measured on plex:9000:
#      `favorites_title "The Cure - Mixed Up"`). `name` and `line1` must be identical with
#      and without a score, on a matched row and an unmatched one alike — this is the
#      assertion that would catch someone "improving" the feature by prefixing the title.
#   3. IT NEVER REACHES THE MATCHER. `_reviewRow` must not write the score into the item,
#      the favurl, or anything the resolver queries on.
#   4. 0.0 IS A REAL SCORE. Pitchfork awards it (Jet, *Shine On*). A truthiness test drops
#      exactly the score most worth reading, and reads identically to "no score at all".
#   5. THE WORD IS TRANSLATED (0.9.41, "Score 8.1/10" asked for over the bare number). The
#      harness's `cstring` stub returns the TOKEN, so $S below is what a correct build emits
#      and a hardcoded English "Score" would fail every expectation here.
#
# ANTI-TESTED (each rerun with the guard removed, to prove the test can fail):
#   `defined` -> truthiness            => the 0.0 checks fail
#   sprintf   -> the raw value         => the round-score checks fail
#   the numeric pattern guard dropped  => the junk-input checks fail
#   the score moved onto line1         => the ListenLater label checks fail
#   cstring -> a hardcoded 'Score'     => every formatting check fails
#
# Run from the repo root:  perl tools/t_score.pl
use strict; use warnings; use utf8;
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
    our (%LISTS, %VER, %AGE);
    sub getList {
        my ($k, $v) = @_;
        return undef unless $LISTS{$k};
        return undef if defined $v && defined $VER{$k} && $VER{$k} != $v;
        return $LISTS{$k};
    }
    sub putList {
        my ($k, $i, $v) = @_;
        return 0 unless ref $i eq 'ARRAY' && @$i;
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
    our (%KV, @KVSETS);
    sub kvGet { my ($k) = @_; exists $KV{$k} ? $KV{$k} : undef }
    sub kvSet { my ($k, $v, $ttl) = @_; $KV{$k} = $v; push @KVSETS, { key => $k, ttl => $ttl }; 1 }
    sub kvDel { my ($k) = @_; delete $KV{$k}; 1 }
    sub kvForgetPrefix { my ($p) = @_; my $n = 0; for (keys %KV) { $n++, delete $KV{$_} if index($_, $p) == 0 } $n }
    sub kvCount { scalar keys %KV }
    sub kvReset { %KV = (); @KVSETS = (); }
}
{
    package Slim::Networking::SimpleAsyncHTTP; sub new { bless {}, shift } sub get {}
    package Slim::Utils::Cache;   sub new { bless {}, shift } sub get {} sub set {}
    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
                                  # warn is captured (not swallowed by AUTOLOAD) so the
                                  # "direction unknown" signal can be asserted — the whole
                                  # point of that fix is that it stops being silent.
                                  our @WARNED; sub warn { push @WARNED, $_[1]; 1 }
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; sub AUTOLOAD {} sub get {} sub set {} sub init {}
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  sub cstring { $_[1] } sub string { $_[0] }   # returns the token, so it is assertable
    package Slim::Utils::Timers;  sub setTimer {} sub killTimers {} sub killSpecific {}
    # LMS bundles JSON::XS; JSON::PP is core perl and decodes identically for this purpose.
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

# Browse::_dbg forwards to Plugin::dbg, and Plugin.pm is not loaded here.
{ no warnings 'once'; *Plugins::PitchforkReviews::Plugin::dbg = sub {}; }

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d (got '" . ($g // '') . "')", (($g // '') eq ($w // ''))) }

my $API_NS = 'Plugins::PitchforkReviews::API';
my $BR_NS  = 'Plugins::PitchforkReviews::Browse';

# ---------------------------------------------------------------------------
# Item fixtures. A REVIEW item is what `_parseState` builds (score, genre, a real
# publication date, no rank); a YEAR item is what `_parseYear` builds (rank + year,
# `score => undef`, no genre). Both are spelled out here rather than derived, so a
# change to either parser cannot silently make these tests agree with themselves.
# ---------------------------------------------------------------------------
sub review {
    my (%o) = @_;
    return { artist  => 'Dijon',       album => 'Baby',
             capsule => 'Short capsule.', genre => 'Pop',
             date    => '2025-12-02T14:00:00.000Z',
             (exists $o{score} ? (score => $o{score}) : ()),
             %o };
}
sub yearrow {
    my (%o) = @_;
    return { artist => 'Dijon', album => 'Baby', rank => 2, year => 2025,
             capsule => 'Short capsule.', genre => '', score => undef,
             date => '2025-12-02T14:00:00.000Z', %o };
}

# The harness's Slim::Utils::Strings stub returns the TOKEN, not the English word, so every
# expectation below is spelled with it — which is exactly what makes "someone hardcoded the
# word" a failing build rather than an invisible one.
my $S = 'PLUGIN_PITCHFORKREVIEWS_SCORE';

my $SCORE = $BR_NS->can('_scoreLabel') or die "no _scoreLabel — the feature is not there";
my $LINE2 = $BR_NS->can('_line2');
my $ROW   = $BR_NS->can('_reviewRow');

print "--- _scoreLabel: the number itself ---\n";
{
    is('one decimal is kept as printed',    $SCORE->(undef, { score => 8.4 }),   "$S 8.4/10");
    is('a round score gains its decimal',   $SCORE->(undef, { score => 8 }),     "$S 8.0/10");
    is('...a perfect 10 too',               $SCORE->(undef, { score => 10 }),    "$S 10.0/10");
    is('...and 10.0 stays 10.0',            $SCORE->(undef, { score => 10.0 }),  "$S 10.0/10");
    is('a string from JSON is accepted',    $SCORE->(undef, { score => '7.5' }), "$S 7.5/10");

    # THE 0.0 CASE, which is why the guard is `defined`. Jet's *Shine On* really scored it.
    is('0.0 is a SCORE, not an absence',    $SCORE->(undef, { score => 0 }),     "$S 0.0/10");
    is('...and 0.0 spelled out likewise',   $SCORE->(undef, { score => '0.0' }), "$S 0.0/10");

    is('no score at all renders nothing',   $SCORE->(undef, {}),                 '');
    is('an explicit undef likewise',        $SCORE->(undef, { score => undef }), '');

    # The pattern guard. `ratingValue.score` is whatever the page state holds; without this
    # a surprise string would go through sprintf and print as a score nobody awarded.
    is('a non-numeric string is refused',   $SCORE->(undef, { score => 'N/A' }), '');
    is('...an empty string too',            $SCORE->(undef, { score => '' }),    '');
    is('...and a reference is refused',     $SCORE->(undef, { score => {} }),    '');
    is('a missing item is survivable',      $SCORE->(undef, undef),              '');
}

print "--- the string token is really shipped ---\n";
{
    # A cstring for a token that is not in strings.txt does not fail — LMS renders the RAW
    # TOKEN to the user. So "the word is translated" is only true if the file says so, and
    # asserting it here is what stops a rename from shipping "PLUGIN_PITCHFORKREVIEWS_SCORE
    # 8.4/10" onto 88 live rows.
    my $st = do { local (@ARGV, $/) = ('PitchforkReviews/strings.txt'); <> } // '';
    ok("strings.txt declares $S",        $st =~ /^\Q$S\E$/m);
    ok('...with an EN translation',      $st =~ /^\Q$S\E\n\tEN\t\S/m);
    ok('...and an NL one, like its siblings', $st =~ /^\Q$S\E\n\tEN\t[^\n]*\n\tNL\t\S/m);
}

print "--- line2: the score leads, the rest of the line is unchanged ---\n";
{
    is('score, then date, then genre, then capsule',
       $LINE2->(undef, review(score => 8.4)),
       "$S 8.4/10 \x{b7} 2 December 2025 \x{b7} Pop - Short capsule.");

    # The control: the SAME item with the score taken away must give the line the plugin
    # drew before this feature existed. Without this, a broken separator passes unnoticed.
    is('a scoreless review row is exactly what it always was',
       $LINE2->(undef, review()),
       "2 December 2025 \x{b7} Pop - Short capsule.");

    is('0.0 shows on the line like any other score',
       $LINE2->(undef, review(score => 0)),
       "$S 0.0/10 \x{b7} 2 December 2025 \x{b7} Pop - Short capsule.");

    is('a review with no genre still reads cleanly',
       $LINE2->(undef, review(score => 6.1, genre => '')),
       "$S 6.1/10 \x{b7} 2 December 2025 - Short capsule.");

    is('a review with no capsule keeps the meta alone',
       $LINE2->(undef, review(score => 6.1, capsule => '')),
       "$S 6.1/10 \x{b7} 2 December 2025 \x{b7} Pop");

    # THE SECTION TEST, asserted as an ANSWER rather than as a branch: the year row is
    # built the way `_parseYear` builds it, and its line is identical to the one the
    # existing year suite already pins.
    is('a YEAR row is untouched — it leads with the year, with no score',
       $LINE2->(undef, yearrow()), '2025 - Short capsule.');

    # ...and it stays untouched even if a score somehow reaches it, because the year row's
    # line is what the year sections are asked to show. This is the one case the `defined`
    # guard alone does NOT cover, so it is stated as a known consequence, not a claim:
    ok('a year row carrying a score WOULD show it — no upstream writes one (API.pm hardcodes undef)',
       $LINE2->(undef, yearrow(score => 9.9)) eq "$S 9.9/10 \x{b7} 2025 - Short capsule.");

    my $long = 'x' x 400;
    my $l2   = $LINE2->(undef, review(score => 8.4, capsule => $long));
    ok('the capsule is still truncated with the score in front', $l2 =~ /\.\.\.$/);
    ok('...and the score survives the truncation', $l2 =~ /^\Q$S\E 8\.4\/10 \x{b7} /);
}

print "--- the ListenLater contract: line1/name never carry the score ---\n";
{
    # UNMATCHED rows (no `_album`): a plain link row built by _reviewRow itself.
    my $with = $ROW->(undef, review(score => 8.4));
    my $without = $ROW->(undef, review());
    is('name is the review label, with no score', $with->{name},  'Dijon - Baby');
    is('...line1 likewise',                       $with->{line1}, 'Dijon - Baby');
    is('name is IDENTICAL with and without a score',  $with->{name},  $without->{name});
    is('...and so is line1',                          $with->{line1}, $without->{line1});
    ok('the score IS on line2', ($with->{line2} // '') =~ /^\Q$S\E 8\.4\/10 \x{b7} /);
    ok('...and absent from line2 when there is none', ($without->{line2} // '') !~ m{/10});

    # MATCHED rows: _reviewRow copies the service album node and relabels it. This is the
    # shape a Spotify match arrives in — the one whose label LL stores verbatim.
    my $album = { name => 'Baby', line1 => 'Baby', line2 => 'Dijon',
                  type => 'playlist', url => 'spotify:album:5g9', _svc => 'spotify',
                  _svctitle => 'Baby', image => 'http://svc/cover.jpg' };
    my $m  = $ROW->(undef, review(score => 8.4, _album => { %$album }));
    my $mn = $ROW->(undef, review(              _album => { %$album }));
    is('a MATCHED row is labelled with the review, no score', $m->{name},  'Dijon - Baby');
    is('...line1 likewise',                                   $m->{line1}, 'Dijon - Baby');
    is('a matched label is IDENTICAL with and without a score', $m->{name},  $mn->{name});
    is('...and so is line1',                                    $m->{line1}, $mn->{line1});
    ok('the matched row shows the score on line2', ($m->{line2} // '') =~ /^\Q$S\E 8\.4\/10 \x{b7} /);
    is('the play url is untouched', $m->{url}, 'spotify:album:5g9');

    # A RANKED row, the same two ways: the rank prefix is the only label decoration there is.
    my $y = $ROW->(undef, yearrow());
    is('a year row still leads its label with the rank', $y->{name}, '2. Dijon - Baby');
    ok('...and its line2 carries no score', ($y->{line2} // '') !~ m{/10});
}

print "--- nothing the matcher reads is touched ---\n";
{
    # _reviewRow is handed the CACHED parsed item. The score must be READ from it and never
    # written anywhere the resolver looks — the ledger's standing rule about $it.
    my $it = review(score => 8.4);
    my %before = %$it;
    my $row = $ROW->(undef, $it);
    is('artist is unchanged', $it->{artist}, $before{artist});
    is('album is unchanged',  $it->{album},  $before{album});
    is('score is unchanged',  $it->{score},  $before{score});
    is('no key was added to the item', scalar(keys %$it), scalar(keys %before));

    # The passthrough carries the item itself, so a mutation here would reach reviewDetail.
    is('the passthrough still carries the same item', $row->{passthrough}[0], $it);

    # And the label the LL handshake would read is free of digits that are not the album's.
    ok('the label has no /10 anywhere', $row->{name} !~ m{/10});
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

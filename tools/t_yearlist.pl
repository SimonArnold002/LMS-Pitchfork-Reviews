#!/usr/bin/env perl
# Parsing Pitchfork's year-end "The 50 Best Albums of <year>" lists (0.8.0).
#
# WHY THIS EXISTS. A year-end list is NOT a review listing: its entries live in the article
# BODY prose, not in `contentType => 'review'` nodes, so `_walkReviews` cannot see them and
# `_parseYear` walks `transformed.article.body` instead. That body is hand-authored, and
# across the ten live years (2016-2025) it carries three defects that a naive reader gets
# silently wrong — each one is pinned by a test here, because each produces plausible-looking
# output rather than a crash:
#
#   1. RANK MUST COME FROM DOCUMENT ORDER, never the printed number. The real 2020 page
#      prints "25." twice and never prints 24. Trusting the digits yields a duplicate rank
#      and a hole; position is always right. The printed numbers decide ONE thing — whether
#      the list counts down (50->1, the house style) or up — and only the first is compared
#      against the last, so a single typo in the middle cannot flip the direction.
#   2. A HEADING THAT IS ONLY DIGITS IS A RANK MARKER. The real 2017 page marks one entry's
#      rank with an <h2> instead of the usual heading-h3 <div>. Without the guard that <h2>
#      is read as an entry titled "33." and every following field lands on the wrong record.
#   3. ARTIST IS THE TEXT BEFORE THE FIRST <em>, not "the heading minus the album". The real
#      2024 page has ["h2","Djrum: ",["em","Meaning's Edge"]," EP"] — text AFTER the album —
#      so the subtract-the-suffix reading gives the artist as "Djrum: Meaning's Edge EP".
#
# Also asserted: HTML entities are decoded (an "&amp;" in a title keys as "and amp" under
# `_norm` and can never match the service's spelling — the 0.7.12 bug, in a new parser), the
# affiliate "Listen/Buy:" row is never mistaken for the blurb, and the Browse-side rendering
# that only year rows get (rank on the label, year in line2, "list" not "review" on the link).
#
# Run from the repo root:  perl tools/t_yearlist.pl
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
# Build a page in the SHAPE the real articles use.
# ---------------------------------------------------------------------------
sub photo_block {
    my ($name) = @_;
    return [ 'inline-embed',
             { type => 'callout:inset-left', props => { name => 'inset-left' } },
             [ 'inline-embed',
               { props => { image => { contentType => 'photo', id => "id-$name",
                            altText => $name,
                            sources => { sm => { url => "https://media/$name-320.jpg", width => 320 },
                                         md => { url => "https://media/$name-640.jpg", width => 640 },
                                         lg => { url => "https://media/$name-960.jpg", width => 960 } } } } } ] ];
}
sub rank_div { [ 'div', { class => 'heading-h3', role => 'heading' }, "$_[0]." ] }
my $BLURB = 'A long enough paragraph to read as an entry blurb rather than a stray caption, '
          . 'well past the minimum length the parser insists on. \x{2013}A Critic';

sub page {
    my ($body, %o) = @_;
    my $json = JSON::XS::VersionOneAndTwo::to_json({ transformed => { article => { body => $body } } });
    return qq{<html><head>}
         . qq{<meta property="og:title" content="} . ($o{hed} // 'The 50 Best Albums of 2025') . qq{"/>}
         . qq{<meta property="article:published_time" content="} . ($o{pub} // '2025-12-02T14:00:00.000Z') . qq{"/>}
         . qq{</head><body><script>window.__PRELOADED_STATE__ = $json;</script></body></html>};
}

# Five entries, printed 5,4,3,3,1 — a DUPLICATE 3 and a MISSING 2, exactly the 2020 defect.
my @BODY = (
    [ 'p', 'Intro prose that belongs to no entry.' ],
    [ 'hr' ],

    photo_block('alpha'),
    rank_div(5),
    [ 'h2', 'Alpha: ', [ 'em', 'First &amp; Last' ] ],          # entity trap
    [ 'p', $BLURB ],

    photo_block('djrum'),
    rank_div(4),
    [ 'h2', 'Djrum: ', [ 'em', "Meaning\x{2019}s Edge" ], ' EP' ],   # trap 3
    [ 'p', [ 'strong', 'Listen/Buy:' ], ' ', [ 'a', { href => 'https://x' }, 'Amazon' ] ],
    [ 'p', $BLURB ],

    photo_block('gamma'),
    [ 'h2', '3.' ],                                             # trap 2: rank as an <h2>
    [ 'h2', 'Gamma: ', [ 'em', 'Third' ] ],
    [ 'p', 'Too short.' ],                                      # below CAPSULE_MIN
    [ 'p', $BLURB ],

    photo_block('delta'),
    rank_div(3),                                                # trap 1: duplicate printed rank
    [ 'h2', 'Delta: ', [ 'em', 'Fourth' ] ],
    [ 'p', $BLURB ],

    photo_block('epsilon'),
    rank_div(1),
    [ 'h2', 'Epsilon: Fifth' ],                                 # no <em> -> colon fallback
    [ 'p', $BLURB ],
);

my $items = $API_NS->can('_parseYear')->(page(\@BODY), 2025, 'https://pitchfork.com/list/');
my %by = map { $_->{rank} => $_ } @$items;

print "--- structure ---\n";
is('five entries parsed',            scalar @$items, 5);
is('sorted best-first (rank 1 lead)', $items->[0]{rank}, 1);
is('last row is rank 5',             $items->[-1]{rank}, 5);
ok('ranks are exactly 1..5, no duplicate and no hole',
   join(',', map { $_->{rank} } @$items) eq '1,2,3,4,5');

print "--- trap 1: rank from document order, not the printed number ---\n";
# Printed was 5,4,3,3,1. Position says the 4th entry is 2 and the 3rd is 3.
is('duplicate printed "3" resolves by position (Delta = 2)', $by{2}{album}, 'Fourth');
is('...and the entry before it keeps 3',                     $by{3}{album}, 'Third');
is('printed "1" on the last entry agrees with position',     $by{1}{album}, 'Fifth');
ok('the internal _printed scratch field is not left on items', !exists $items->[0]{_printed});

print "--- trap 2: an <h2> that is only digits is a rank marker ---\n";
ok('no entry was created from the bare "3." heading',
   !grep { $_->{album} =~ /^\d+\.?$/ || $_->{artist} =~ /^\d+\.?$/ } @$items);
is('Gamma kept its own blurb (fields did not shift)', substr($by{3}{capsule}, 0, 6), 'A long');

print "--- trap 3: artist is the text BEFORE the first <em> ---\n";
is('trailing " EP" stays on the ALBUM',   $by{4}{album},  "Meaning\x{2019}s Edge EP");
is('...and never leaks into the artist',  $by{4}{artist}, 'Djrum');
is('a heading with no <em> splits on the colon', $by{1}{artist}, 'Epsilon');
is('...taking the album from after it',          $by{1}{album},  'Fifth');
ok('no artist keeps a trailing separator', !grep { $_->{artist} =~ /[:\x{2013}\x{2014}-]\s*$/ } @$items);

print "--- entities (the 0.7.12 bug, in a new parser) ---\n";
is('&amp; is decoded in an album title', $by{5}{album}, 'First & Last');
ok('no residual entity anywhere',
   !grep { ($_->{artist} . $_->{album} . $_->{capsule}) =~ /&(?:[a-zA-Z]+|\#\d+);/ } @$items);

print "--- blurb selection ---\n";
ok('the "Listen/Buy:" affiliate row is never the blurb',
   !grep { $_->{capsule} =~ /Listen\/Buy/ } @$items);
is('a too-short paragraph is skipped for the real blurb', substr($by{3}{capsule}, 0, 6), 'A long');
ok('every entry got a blurb', 5 == grep { length $_->{capsule} } @$items);

print "--- cover art ---\n";
is('cover is the smallest source >= 640px', $by{5}{cover}, 'https://media/alpha-640.jpg');
ok('every entry got its OWN cover',
   5 == scalar keys %{{ map { $_->{cover} => 1 } @$items }});

print "--- item shape matches a review item (so Browse reuses everything) ---\n";
is('title is "Artist: Album"', $by{1}{title}, 'Epsilon: Fifth');
is('year is stamped',          $by{1}{year},  2025);
is('link is the list page',    $by{1}{link},  'https://pitchfork.com/list/');
is('date is the article pubDate', $by{1}{date}, '2025-12-02T14:00:00.000Z');
is('genre is empty (lists carry none)', $by{1}{genre}, '');
ok('score is undef (lists carry none)', !defined $by{1}{score});
is('list title captured from og:title', $by{1}{list_title}, 'The 50 Best Albums of 2025');

print "--- pending cover/rank never survive a heading that is not an entry ---\n";
{
    # $cover and $printed are scratch state: set by the inline-embed, consumed by the NEXT
    # entry, and therefore owned by nothing in between. The heading branch has THREE exits
    # and only two of them cleared it — 0.8.8 fixed the h2-with-no-album exit and left the
    # `next unless $tag eq 'h2'` skip alongside it, which is the same defect one line up.
    # Both directions are pinned here, because the fix is a trade rather than a certainty.
    #
    # Unreachable on any live page: across all ten years 2016-2025 this skip never fires at
    # all (500/500 entries parse clean), exactly as its sibling was unreachable when 0.8.8
    # fixed that one. The value is that the contract becomes total.
    my @stray = (
        photo_block('orphan'),
        [ 'h3', 'An interlude that is not an entry' ],
        rank_div(2),
        [ 'h2', 'Real: ', [ 'em', 'Entry' ] ],              # ...carrying no embed of its own
        [ 'p', $BLURB ],
        photo_block('own'),
        rank_div(1),
        [ 'h2', 'Second: ', [ 'em', 'Two' ] ],
        [ 'p', $BLURB ],
    );
    my $s = $API_NS->can('_parseYear')->(page(\@stray), 2025, 's');
    my %s = map { $_->{album} => $_ } @$s;
    is('both entries still parse', scalar @$s, 2);
    is('an entry after a stray sub-heading shows NO cover rather than the orphaned one',
       $s{Entry}{cover}, '');
    is('...and an entry with its own embed keeps it', $s{Two}{cover}, 'https://media/own-640.jpg');
    is('...with the ranks unshifted', join(',', map { "$_->{album}=$_->{rank}" } @$s),
       'Two=1,Entry=2');

    # THE RANK HALF, which is the one that goes further than a wrong picture: an orphaned
    # marker becomes a _printed the page never gave that entry, and _printed decides the
    # direction of the WHOLE list. Here the stray "50." would read as a countdown and turn
    # A,B,C upside down — every rank present, unique and wrong.
    my @phantom = (
        rank_div(50),
        [ 'div', { class => 'heading-h3' }, 'Honourable mentions' ],   # not a number, not an h2
        photo_block('a'), [ 'h2', 'One: ',   [ 'em', 'A' ] ], [ 'p', $BLURB ],
        photo_block('b'), rank_div(2), [ 'h2', 'Two: ',   [ 'em', 'B' ] ], [ 'p', $BLURB ],
        photo_block('c'), rank_div(3), [ 'h2', 'Three: ', [ 'em', 'C' ] ], [ 'p', $BLURB ],
    );
    my $ph = $API_NS->can('_parseYear')->(page(\@phantom), 2025, 'p');
    is('an orphaned rank marker cannot flip the direction of the list',
       join(',', map { $_->{album} } @$ph), 'A,B,C');
    is('...and the entry that followed it takes its position, not the printed number',
       $ph->[0]{rank}, 1);
}

print "--- an ASCENDING list is not force-reversed ---\n";
{
    my @up = ( photo_block('a'), rank_div(1), [ 'h2', 'One: ', [ 'em', 'A' ] ], [ 'p', $BLURB ],
               photo_block('b'), rank_div(2), [ 'h2', 'Two: ', [ 'em', 'B' ] ], [ 'p', $BLURB ],
               photo_block('c'), rank_div(3), [ 'h2', 'Three: ', [ 'em', 'C' ] ], [ 'p', $BLURB ] );
    my $u = $API_NS->can('_parseYear')->(page(\@up), 2025, 'u');
    is('counting UP, the first entry is rank 1', $u->[0]{album}, 'A');
    is('...and the last is rank 3',              $u->[-1]{album}, 'C');
}

print "--- losing the rank markers must not fail SILENTLY ---\n";
{
    # Pitchfork's house style is a 50-to-1 countdown, and the direction is read from the
    # printed numbers. With none printed there is no evidence either way, and the
    # fallback numbers 1..n in document order — which against a real countdown page puts
    # the article's LAST entry at the top labelled "1.". Every rank is still present and
    # unique, so no integrity check catches it. It has to announce itself.
    @T::Log::WARNED = ();
    my @none = ( photo_block('a'), [ 'h2', 'One: ',   [ 'em', 'A' ] ], [ 'p', $BLURB ],
                 photo_block('b'), [ 'h2', 'Two: ',   [ 'em', 'B' ] ], [ 'p', $BLURB ],
                 photo_block('c'), [ 'h2', 'Three: ', [ 'em', 'C' ] ], [ 'p', $BLURB ] );
    my $r = $API_NS->can('_parseYear')->(page(\@none), 2025, 'nomarkers');

    is('the list still parses (a warning, not a refusal)', scalar @$r, 3);
    is('...ranks are still 1..n with no hole', join(',', map { $_->{rank} } @$r), '1,2,3');
    ok('...and the loss of direction is WARNED, not silent',
       scalar(grep { /rank marker/ } @T::Log::WARNED) == 1);
    ok('...naming the page, so it can be diagnosed from the log alone',
       scalar(grep { /nomarkers/ } @T::Log::WARNED) == 1);

    # One marker is still not evidence of a direction — two is the minimum that can
    # compare first against last.
    @T::Log::WARNED = ();
    my @one = ( photo_block('a'), rank_div(1), [ 'h2', 'One: ', [ 'em', 'A' ] ], [ 'p', $BLURB ],
                photo_block('b'), [ 'h2', 'Two: ', [ 'em', 'B' ] ], [ 'p', $BLURB ] );
    $API_NS->can('_parseYear')->(page(\@one), 2025, 'onemarker');
    ok('a single marker warns too', scalar(grep { /rank marker/ } @T::Log::WARNED) == 1);

    # ...and a healthy page must stay quiet, or the warning is noise nobody reads.
    @T::Log::WARNED = ();
    my @ok = ( photo_block('a'), rank_div(3), [ 'h2', 'C: ', [ 'em', 'C' ] ], [ 'p', $BLURB ],
               photo_block('b'), rank_div(2), [ 'h2', 'B: ', [ 'em', 'B' ] ], [ 'p', $BLURB ],
               photo_block('c'), rank_div(1), [ 'h2', 'A: ', [ 'em', 'A' ] ], [ 'p', $BLURB ] );
    my $good = $API_NS->can('_parseYear')->(page(\@ok), 2025, 'healthy');
    ok('a page with markers does NOT warn', scalar(grep { /rank marker/ } @T::Log::WARNED) == 0);
    is('...and its countdown is still detected', $good->[0]{album}, 'A');
}

print "--- degenerate input is empty, never a crash ---\n";
is('no state at all',      scalar @{ $API_NS->can('_parseYear')->('<html></html>', 2025, 'u') }, 0);
is('state with no article', scalar @{ $API_NS->can('_parseYear')->(page([]), 2025, 'u') }, 0);
is('body with no entries',  scalar @{ $API_NS->can('_parseYear')->(page([['p','just prose']]), 2025, 'u') }, 0);

print "--- slug eras ---\n";
my @u25 = $API_NS->can('_yearUrls')->(2025);
my @u18 = $API_NS->can('_yearUrls')->(2018);
my @u16 = $API_NS->can('_yearUrls')->(2016);
is('2019+ uses best-albums-<year>', $u25[0], 'https://pitchfork.com/features/lists-and-guides/best-albums-2025/');
is('2017-18 use the older wording', $u18[0], 'https://pitchfork.com/features/lists-and-guides/the-50-best-albums-of-2018/');
is('2016 uses its numeric slug',    $u16[0], 'https://pitchfork.com/features/lists-and-guides/9980-the-50-best-albums-of-2016/');
ok('a future year is tried under BOTH modern forms', scalar(@{[ $API_NS->can('_yearUrls')->(2030) ]}) == 2);
ok('a pinned era year is tried once', scalar(@u16) == 1);

print "--- the self-promoting timeline (injectable clock) ---\n";
{
    use Time::Local ();
    my $at  = sub { Time::Local::timelocal(12, 0, 0, $_[1], $_[0], 126) };   # 2026, (month0, day)
    my $top = $API_NS->can('_topYear');
    my $win = $API_NS->can('_secsToWindow');
    my $min = $API_NS->can('_min');
    my $hold = sub { $min->(30 * 86400, $win->($_[0])) };

    is('in July the newest possible list is last year\'s', $top->($at->(6, 31)), 2025);
    is('on 31 October it is still last year\'s',           $top->($at->(9, 31)), 2025);
    is('on 1 November the current year becomes worth probing', $top->($at->(10, 1)), 2026);
    is('and stays so through December',                    $top->($at->(11, 15)), 2026);

    # The cap is what makes the switch deterministic: an answer cached in
    # October must NOT still be trusted in November.
    ok('a July answer is held the full 30 days',   $hold->($at->(6, 31)) == 30 * 86400);
    ok('a late-October answer is capped short',    $hold->($at->(9, 29)) < 5 * 86400);
    ok('...and expires exactly at the window edge',
       abs($at->(9, 29) + $hold->($at->(9, 29)) - $at->(10, 1)) < 90000);
    ok('inside the window the next edge is a year off (so the cap does not bite)',
       $hold->($at->(11, 15)) == 30 * 86400);
    ok('the window cap never returns a non-positive TTL',
       0 == grep { $win->($at->($_->[0], $_->[1])) <= 0 }
            ([0,1],[5,15],[9,31],[10,1],[10,30],[11,31]));

    # The composed decision, which is what getLatestYear actually stores.
    my $ttl = $API_NS->can('_latestTtl');
    ok('still waiting on this year -> re-probe in 12h',
       $ttl->(2025, 2026, $at->(10, 15)) == 12 * 3600);
    ok('...regardless of how far off the next window is',
       $ttl->(2025, 2026, $at->(11, 1)) == 12 * 3600);
    ok('nothing newer can exist in July -> hold 30d',
       $ttl->(2025, 2025, $at->(6, 31)) == 30 * 86400);
    ok('nothing newer can exist in late October -> capped to the window edge, NOT 30d',
       $ttl->(2025, 2025, $at->(9, 29)) < 5 * 86400);
    ok('the newly published list is held hard again',
       $ttl->(2026, 2026, $at->(11, 3)) == 30 * 86400);
}

print "--- Browse rendering: only year rows differ ---\n";
{
    my $yr  = { artist => 'Dijon', album => 'Baby', rank => 2, year => 2025, capsule => 'Short capsule.', genre => '', date => '2025-12-02T14:00:00.000Z' };
    my $rev = { artist => 'Dijon', album => 'Baby',            capsule => 'Short capsule.', genre => 'Pop', date => '2025-12-02T14:00:00.000Z' };

    my $row = $BR_NS->can('_reviewRow')->(undef, $yr);
    is('rank leads the row label',  $row->{name},  '2. Dijon - Baby');
    is('...on line1 too',           $row->{line1}, '2. Dijon - Baby');

    my $rrow = $BR_NS->can('_reviewRow')->(undef, $rev);
    is('a REVIEW row is unprefixed', $rrow->{name}, 'Dijon - Baby');

    is('year row line2 leads with the year', $BR_NS->can('_line2')->($yr),  '2025 - Short capsule.');
    ok('review row line2 still leads with the date',
       $BR_NS->can('_line2')->($rev) =~ /^2 December 2025 \x{b7} Pop - /);

    is('year row link says "list"',    $BR_NS->can('_linkLabel')->($yr),  'PLUGIN_PITCHFORKREVIEWS_READ_LIST');
    is('review row link says "review"', $BR_NS->can('_linkLabel')->($rev), 'PLUGIN_PITCHFORKREVIEWS_READ_REVIEW');
}

print "--- reading order: best-first vs Pitchfork's countdown ---\n";
{
    my $ord = $BR_NS->can('_yearOrdered');
    my $lbl = $BR_NS->can('_yearSortLabel');

    # Deliberately handed in scrambled, to prove the ordering is computed and not
    # just inherited from the parse.
    my @scrambled = ( { rank => 3 }, { rank => 1 }, { rank => 5 }, { rank => 2 }, { rank => 4 } );

    is('best-first puts #1 at the top',   join(',', map { $_->{rank} } @{ $ord->(\@scrambled, 'rank') }),      '1,2,3,4,5');
    is('countdown puts the last at the top', join(',', map { $_->{rank} } @{ $ord->(\@scrambled, 'countdown') }), '5,4,3,2,1');
    is('an unknown mode falls back to best-first',
       join(',', map { $_->{rank} } @{ $ord->(\@scrambled, 'nonsense') }), '1,2,3,4,5');
    is('a missing mode falls back to best-first',
       join(',', map { $_->{rank} } @{ $ord->(\@scrambled, undef) }), '1,2,3,4,5');

    ok('ordering never drops or duplicates an entry',
       5 == scalar @{ $ord->(\@scrambled, 'countdown') }
       && 5 == scalar keys %{{ map { $_->{rank} => 1 } @{ $ord->(\@scrambled, 'countdown') } }});

    # The cached parse must not be mutated -- the same arrayref is served to every
    # subsequent render, so an in-place reverse would corrupt it for good.
    $ord->(\@scrambled, 'countdown');
    is('the caller\'s list is left untouched', join(',', map { $_->{rank} } @scrambled), '3,1,5,2,4');

    is('best-first label',  $lbl->(undef, 'rank'),      'PLUGIN_PITCHFORKREVIEWS_SORT_RANK');
    is('countdown label',   $lbl->(undef, 'countdown'), 'PLUGIN_PITCHFORKREVIEWS_SORT_COUNTDOWN');

    # The toggle must advance from the LIVE pref, so a stale view cannot set it back.
    my $toggle = $BR_NS->can('_yearSortToggle')->(undef, 'rank');
    is('the toggle row refreshes the view in place', $toggle->{nextWindow}, 'refresh');
    ok('the toggle row carries the sort glyph', ($toggle->{image} // '') =~ /_MTL_icon_sort\.png$/);

    my %stored;
    no warnings 'redefine', 'once';
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };

    $stored{year_sort} = 'rank';
    $toggle->{url}->(undef, sub {});
    is('tapping from best-first selects countdown', $stored{year_sort}, 'countdown');
    $toggle->{url}->(undef, sub {});
    is('tapping again returns to best-first',       $stored{year_sort}, 'rank');

    $stored{year_sort} = 'rubbish';
    is('a corrupt pref reads as best-first', $BR_NS->can('_yearSort')->(), 'rank');
    delete $stored{year_sort};
    is('an unset pref defaults to best-first', $BR_NS->can('_yearSort')->(), 'rank');
}

# ---------------------------------------------------------------------------
# Naming the year, and the view's Options/list sections (0.8.3).
#
# The point of all of this is that ONE year is named consistently in three
# places — the app tile, the Material home shelf and the view itself. The traps:
# the tile is built INLINE (so it must never fetch), and the remembered year must
# not be able to pin a user to an old list for ever.
# ---------------------------------------------------------------------------
my %EN = (
    PLUGIN_PITCHFORKREVIEWS_YEAR_LABEL      => '%s - Best Albums',
    PLUGIN_PITCHFORKREVIEWS_HOME_YEAR_LABEL => 'Pitchfork: %s - Best Albums',
    PLUGIN_PITCHFORKREVIEWS_SECTION_OPTIONS => 'Options',
    PLUGIN_PITCHFORKREVIEWS_PICK_YEAR       => 'Choose a year',
    PLUGIN_PITCHFORKREVIEWS_YEAR            => 'Best Albums of the Year',
    PLUGIN_PITCHFORKREVIEWS_REFRESH         => 'Refresh (force update now)',
    PLUGIN_PITCHFORKREVIEWS_SORTED_BY       => 'Sorted by %s (tap to change)',
    PLUGIN_PITCHFORKREVIEWS_SORT_RANK       => 'Best first',
);
# Browse.pm imported cstring at compile time, so its OWN alias is what must be
# swapped -- overriding Slim::Utils::Strings::cstring would not be seen.
no warnings 'redefine', 'once';
local *Plugins::PitchforkReviews::Browse::cstring = sub { $EN{$_[1]} // $_[1] };

print "--- the shared year label ---\n";
is('label reads "<year> - Best Albums"', $BR_NS->can('_yearLabel')->(undef, 2025), '2025 - Best Albums');
is('...for any year',                    $BR_NS->can('_yearLabel')->(undef, 2016), '2016 - Best Albums');

print "--- the app tile carries NO year ---\n";
{
    # THE RULE (0.8.7). A page keeps the labels it was built with, and Material
    # replays a page from its history without re-asking the server -- so anything
    # on the APP MENU that depends on the chosen year goes stale the moment the
    # year is changed from inside the view, and no plugin can refresh a page the
    # user isn't standing on. The tile therefore names no year at all; the year
    # is named only where it is rendered live (list header, page title, the
    # "Choose a year" row, the home shelf).
    my $fetched = 0;
    my %stored = (year_last => 2019);
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };
    local *Plugins::PitchforkReviews::API::getLatestYear    = sub { $fetched++; $_[0]->(2025) };
    local *Plugins::PitchforkReviews::API::cachedLatestYear = sub { $fetched++; 2025 };

    my $res;
    $BR_NS->can('topLevel')->(undef, sub { $res = shift }, {});
    my ($tile) = grep { ($_->{name} // '') =~ /Best Albums/ } @{ $res->{items} };
    is('the tile is the generic name', $tile->{name}, 'Best Albums of the Year');
    ok('...naming no year at all',     $tile->{name} !~ /\d{4}/);
    ok('and the app menu NEVER fetches to build it', $fetched == 0);
    is('it still drills into the year feed', ref $tile->{url}, 'CODE');
}

print "--- _viewYear: sticky, but promotion wins ---\n";
{
    my %stored;
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };
    my $latest = 2025;
    local *Plugins::PitchforkReviews::API::getLatestYear = sub { $_[0]->($latest) };
    my $got; my $run = sub { $got = undef; $BR_NS->can('_viewYear')->(sub { $got = shift }); $got };

    %stored = (year_last => 0, year_promoted => 0);
    is('a fresh install opens on the newest', $run->(), 2025);
    is('...and records it as promoted',       $stored{year_promoted}, 2025);

    %stored = (year_last => 2019, year_promoted => 2025);
    is('a chosen year sticks', $run->(), 2019);

    $latest = 2026;                                  # December: the new list lands
    is('a NEWLY published list overrides the chosen year', $run->(), 2026);
    is('...and moves year_last with it',  $stored{year_last},     2026);
    is('...and records the promotion',    $stored{year_promoted}, 2026);
    is('the newly promoted year then sticks on the next open', $run->(), 2026);

    # A pref holding a year that cannot be served (hand-edited, or a list pulled)
    # must not strand the view on an empty page.
    $latest = 2025;
    %stored = (year_last => 1999, year_promoted => 2025);
    is('an out-of-range remembered year falls back to the newest', $run->(), 2025);
    # ...and the pref is REPAIRED, not just overridden for this render (0.8.10). Every
    # surface reads _viewYear, so `year_last` naming a year nothing can open is a value
    # no one benefits from — and the warm, which pre-resolves whatever _viewYear returns,
    # would otherwise be handed it and re-run the whole candidate-slug sweep (two ~1.7MB
    # article fetches) on every tick, for ever.
    is('...and the unopenable pref is repaired', $stored{year_last}, 2025);
    %stored = (year_last => 2030, year_promoted => 2025);
    is('a FUTURE remembered year falls back too', $run->(), 2025);
    is('...and is repaired as well',              $stored{year_last}, 2025);

    # THE INVARIANT THE WARM RELIES ON: whatever _viewYear answers, `year_last` names it.
    # 0.8.8 warmed _viewYear's year and then `year_last` as a second pass, on the theory
    # that the sticky pick would otherwise be left cold — but through _viewYear those are
    # the same year on every path, so the second pass could never fire. It is gone.
    for my $case ([0, 0], [2019, 2025], [1999, 2025], [2030, 2025]) {
        %stored = (year_last => $case->[0], year_promoted => $case->[1]);
        my $answered = $run->();
        is("year_last follows _viewYear's answer (from $case->[0])", $stored{year_last}, $answered);
    }
    ok('and the dead second warm pass is gone', !$BR_NS->can('_warmYearLast'));

    local *Plugins::PitchforkReviews::API::getLatestYear = sub { $_[0]->(undef) };
    %stored = (year_last => 2019, year_promoted => 2025);
    is('no list at all yields undef, not a stale pref', $run->(), undef);
}

print "--- section headers ---\n";
{
    my @kids = ({ name => 'a' }, { name => 'b' });
    my $h = $BR_NS->can('_sectionHeader')->(undef, 'Options', 1, \@kids);
    is('header carries the literal label', $h->{name}, 'Options');
    ok('header is a divider type, not text', $h->{type} ne 'text');
    ok('header has an image (keeps the grid toggle enabled)', length($h->{image} // ''));
    my $out; $h->{url}->(undef, sub { $out = $_[0] });
    is('tapping it returns its own children', scalar @{ $out->{items} }, 2);

    my $plain = $BR_NS->can('_sectionHeader')->(undef, 'Options', 0, \@kids);
    is('a non-header client gets plain text', $plain->{type}, 'text');
    ok('...with no drill action', !exists $plain->{url});
}

print "--- the assembled view ---\n";
{
    my %stored;
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };
    my @fake = map { { artist => "A$_", album => "B$_", rank => $_, year => 2025, capsule => '', genre => '' } } (1 .. 3);
    local *Plugins::PitchforkReviews::API::getYearList = sub { $_[1]->([ @fake ]) };
    local *Plugins::PitchforkReviews::Browse::_resolveSection = sub { $_[2]->() };

    my $res;
    $BR_NS->can('fetchYearFeed')->(undef, sub { $res = shift }, {}, { year => 2025, features => 'h' });
    my @it = @{ $res->{items} };

    is('the feed carries the year as its page title', $res->{title}, '2025 - Best Albums');
    is('row 0 is the Options header',                 $it[0]{name}, 'Options');
    ok('...as a divider',                             $it[0]{type} ne 'text');
    ok('the three option rows follow, in order',
       $it[1]{name} =~ /^Refresh/ && $it[2]{name} =~ /^Choose a year/ && $it[3]{name} =~ /^Sorted by/);
    is('then the list header, naming the year in full', $it[4]{name}, '2025 - Best Albums (3)');
    ok('...also a divider',                             $it[4]{type} ne 'text');
    is('then the albums',                               $it[5]{name}, '1. A1 - B1');
    is('...all of them',                                scalar(@it), 8);
    is('choosing a year remembers it',                  $stored{year_last}, 2025);

    # A non-Material client must still get every row, just without dividers.
    $BR_NS->can('fetchYearFeed')->(undef, sub { $res = shift }, {}, { year => 2025, features => '' });
    my @plain = @{ $res->{items} };
    is('a plain client gets the same row count', scalar(@plain), 8);
    is('...with the headers as text',            $plain[0]{type}, 'text');
}

print "--- the year picker pops back to the list, it does not drill in ---\n";
{
    # THE BUG THIS PINS (0.8.5). The picker used to open the chosen year as a
    # THIRD level, leaving itself in the back stack still titled with the row
    # that opened it -- "Choose a year (2024)". Backing out of the 2025 list then
    # landed on a page announcing 2024. So a picker row must only STORE the
    # choice and pop.
    #
    # 'parent' pops the picker and re-fetches the page underneath -- the year
    # view, which rebuilds from the pref -- so the chosen list is what you land
    # on. It stops there: the app menu above names no year (0.8.7), so there is
    # nothing further up to correct.
    my %stored = (year_last => 2024, year_promoted => 2025);
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };
    local *Plugins::PitchforkReviews::API::getLatestYear   = sub { $_[0]->(2025) };
    local *Plugins::PitchforkReviews::API::yearsAvailable  = sub { $_[0]->([ 2025, 2024, 2023 ]) };

    my $res;
    $BR_NS->can('yearPicker')->(undef, sub { $res = shift }, {}, {});
    my @rows = @{ $res->{items} };
    is('the picker names itself, not the year it was opened from', $res->{title}, 'Choose a year');
    is('newest year first', $rows[0]{name}, '2025 - Best Albums');
    is('one row per year',  scalar(@rows), 3);

    ok('no picker row drills into the feed',
       !grep { ref($_->{url}) eq 'CODE' && $_->{url} == \&Plugins::PitchforkReviews::Browse::fetchYearFeed } @rows);
    ok('every row pops back to the view underneath',
       3 == grep { ($_->{nextWindow} // '') eq 'parent' } @rows);

    # The home shelf's title is REGISTERED, not re-rendered, so picking a year has
    # to push it -- nothing else will.
    my $shelf;
    { no warnings 'once'; *Plugins::MaterialSkin::Plugin::setHomeExtraTitle = sub { $shelf = "$_[1]=$_[2]" }; }

    my $out;
    $rows[2]{url}->(undef, sub { $out = $_[0] });
    is('picking 2023 stores it',                $stored{year_last}, 2023);
    is('...and returns NO items (Material only honours nextWindow when empty)',
       scalar @{ $out->{items} }, 0);
    is('...with the pop repeated on the response', $out->{nextWindow}, 'parent');
    is('...and the home shelf title follows immediately',
       $shelf, 'PFRYear=Pitchfork: 2023 - Best Albums');

    # The view popped back to must rebuild on the picked year, not the newest.
    my $got; $BR_NS->can('_viewYear')->(sub { $got = shift });
    is('the view underneath re-opens on the picked year', $got, 2023);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

#!/usr/bin/env perl
# Grouping the review lists by genre or by week, flipped ON THE VIEW (0.8.2).
#
# WHY THIS EXISTS. The grouping mode used to be a radio on the Settings page; it is now a
# "Grouped by … (tap to change)" row on the review views themselves, matching the year list's
# sort toggle and the sibling ListenBrainz plugin's convention for per-view reading choices.
# The pref (`group_by`) and both grouping implementations are UNCHANGED — only the control
# moved — so what needs guarding is that the move didn't quietly cost anything:
#
#   1. BOTH MODES STILL EMIT MATERIAL DIVIDERS. This is the whole point of the feature and the
#      easiest thing to lose: switching mode must change what the headers SAY, never whether
#      there are headers at all. Asserted for genre and week alike, including the branded
#      header icon and the `header`/`header-basic` divider type, and that a header-less client
#      still gets plain 'text' dividers rather than nothing.
#   2. THE TOGGLE ADVANCES FROM THE LIVE PREF, not from the value the render captured, so a
#      stale view cannot set it backwards. Same trap as the year sort toggle.
#   3. A CORRUPT OR UNSET PREF READS AS 'genre' (the shipped default) rather than rendering an
#      arbitrary grouping. The old Settings handler sanitised the enum on save; with the radio
#      gone that guard has to live at the READ.
#
# Run from the repo root:  perl tools/t_grouptoggle.pl
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

BEGIN {
    $INC{'Slim/Utils/Cache.pm'} = $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'}
        = $INC{'Slim/Utils/Strings.pm'} = $INC{'Slim/Utils/Timers.pm'} = __FILE__;
}
{
    package Slim::Utils::Cache;   sub new { bless {}, shift } sub get {} sub set {}
    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             our $AUTOLOAD; sub AUTOLOAD {} sub get {} sub set {} sub init {}
    package Slim::Utils::Strings; use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                  sub cstring { $_[1] } sub string { $_[0] }
    package Slim::Utils::Timers;  sub setTimer {} sub killTimers {} sub killSpecific {}
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

my $BROWSE = $ENV{PFR_BROWSE} || 'PitchforkReviews/Browse.pm';
$INC{'Plugins/PitchforkReviews/Browse.pm'} = $BROWSE;
do($BROWSE =~ m{^/} ? $BROWSE : "./$BROWSE") or die "can't load $BROWSE: " . ($@ || $!);

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d (got '" . ($g // '') . "')", (($g // '') eq ($w // ''))) }

my $NS = 'Plugins::PitchforkReviews::Browse';

# Two genres across two calendar weeks, so genre and week bucket DIFFERENTLY and a
# mode that silently ignored its argument could not pass both.
my @ITEMS = (
    { artist => 'A', album => 'one',   genre => 'Rock', date => '2026-07-30T00:00:00.000Z' },
    { artist => 'B', album => 'two',   genre => 'Pop',  date => '2026-07-29T00:00:00.000Z' },
    { artist => 'C', album => 'three', genre => 'Rock', date => '2026-07-21T00:00:00.000Z' },
    { artist => 'D', album => 'four',  genre => 'Pop',  date => '2026-07-20T00:00:00.000Z' },
);

sub dividers {
    my ($rows) = @_;
    return grep { ($_->{type} // '') =~ /^(header|header-basic|text)$/ && !exists $_->{line1} } @$rows;
}

print "--- both modes still emit Material dividers ---\n";
for my $mode ('genre', 'date') {
    my $rows = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, $mode);
    my @div  = dividers($rows);
    my @revs = grep { exists $_->{line1} } @$rows;

    ok("$mode: dividers are present", scalar(@div) >= 2);
    is("$mode: every review row survives", scalar(@revs), 4);
    ok("$mode: every divider is a real Material header type",
       0 == grep { ($_->{type} // '') !~ /^header(-basic)?$/ } @div);
    ok("$mode: every divider carries the branded header icon",
       0 == grep { ($_->{image} // '') !~ /PitchforkReviewsIcon_svg\.png$/ } @div);
    ok("$mode: a divider precedes the first review row",
       exists $rows->[0]{type} && !exists $rows->[0]{line1});
}

print "--- the two modes group DIFFERENTLY (not one implementation twice) ---\n";
{
    my $g = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, 'genre');
    my $d = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, 'date');
    my $names = sub { join('|', map { $_->{name} } dividers($_[0])) };
    ok('genre dividers name the genres', $names->($g) =~ /Rock/ && $names->($g) =~ /Pop/);
    ok('week dividers do NOT name the genres', $names->($d) !~ /Rock/);
    ok('the two orderings differ',
       join(',', map { $_->{line1} // '' } @$g) ne join(',', map { $_->{line1} // '' } @$d));
}

print "--- a header-less client still gets plain-text dividers ---\n";
for my $mode ('genre', 'date') {
    my $rows = $NS->can('_groupedRows')->(undef, \@ITEMS, 0, $mode);
    my @div  = dividers($rows);
    ok("$mode: dividers still emitted without header support", scalar(@div) >= 2);
    ok("$mode: they degrade to 'text', never a Material header",
       0 == grep { ($_->{type} // '') ne 'text' } @div);
}

print "--- the score mode is a DIFFERENT shape, and the dispatch is total ---\n";
{
    my $sc = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, 'score', 'reviews');
    my @div  = dividers($sc);
    my @revs = grep { exists $_->{line1} } @$sc;

    is('every review row survives the flat view', scalar(@revs), 4);
    is('exactly ONE header, not a divider per bucket', scalar(@div), 1);
    ok('...and it leads the list', !exists $sc->[0]{line1});
    ok('the header names the section and counts the rows',
       ($sc->[0]{name} // '') =~ /\(4\)$/);

    # THE DISPATCH IS TOTAL. Before 0.9.42 _groupedRows read "genre, else weekly", so a
    # mode it did not know rendered WEEKS — and 'score' is reachable straight from the
    # pref. Compare against the week view's own output: if the score branch is dropped,
    # these two become identical and this assertion is the one that says so.
    my $wk = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, 'date');
    ok('score does NOT fall through to the weekly grouping',
       join('|', map { $_->{name} // '' } @$sc) ne join('|', map { $_->{name} // '' } @$wk));
    ok('...and emits no week dividers at all',
       0 == grep { ($_->{name} // '') =~ /^Week of/ } @$sc);

    # An unrecognised mode must still land on genre — the same value _groupBy falls
    # back to — rather than on whichever branch happens to be last.
    my $bogus = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, 'nonsense');
    my $genre = $NS->can('_groupedRows')->(undef, \@ITEMS, 1, 'genre');
    is('an unknown mode renders as genre',
       join('|', map { $_->{name} // '' } @$bogus),
       join('|', map { $_->{name} // '' } @$genre));
}

print "--- the toggle row ---\n";
{
    my $t = $NS->can('_groupToggle')->(undef, 'genre');
    is('refreshes the view in place', $t->{nextWindow}, 'refresh');
    ok('carries the sort glyph', ($t->{image} // '') =~ /_MTL_icon_sort\.png$/);

    # THE ROW TEXT COMES FROM A TOKEN, NOT A LITERAL. This harness's cstring stub returns
    # the token, so a correct build yields the token here — and a hardcoded English
    # "View: %s (tap to change)" would render perfectly in EN while silently losing the
    # NL translation the plugin ships. That is invisible to every other assertion.
    is('the row text is a string token', $t->{name}, 'PLUGIN_PITCHFORKREVIEWS_VIEW_BY');

    # ...and the token has to actually BE in strings.txt: a cstring for a missing token
    # does not fail, LMS renders the raw token to the user.
    my $st = do { local (@ARGV, $/) = ('PitchforkReviews/strings.txt'); <> } // '';
    for my $tok (qw(PLUGIN_PITCHFORKREVIEWS_VIEW_BY PLUGIN_PITCHFORKREVIEWS_VIEW_SCORE)) {
        ok("strings.txt declares $tok with EN and NL",
           $st =~ /^\Q$tok\E\n\tEN\t[^\n]*\n\tNL\t\S/m);
    }
    ok('the retired GROUPED_BY token is gone from strings.txt',
       $st !~ /^PLUGIN_PITCHFORKREVIEWS_GROUPED_BY$/m);
    is('genre label',  $NS->can('_groupLabel')->(undef, 'genre'), 'PLUGIN_PITCHFORKREVIEWS_GROUP_BY_GENRE');
    is('week label',   $NS->can('_groupLabel')->(undef, 'date'),  'PLUGIN_PITCHFORKREVIEWS_GROUP_WEEK');
    is('score label',  $NS->can('_groupLabel')->(undef, 'score'), 'PLUGIN_PITCHFORKREVIEWS_VIEW_SCORE');
    # An unknown mode must land on the SAME value _groupBy falls back to, or the row
    # names one layout while the renderer draws another.
    is('an unknown mode labels as genre', $NS->can('_groupLabel')->(undef, 'nonsense'),
       'PLUGIN_PITCHFORKREVIEWS_GROUP_BY_GENRE');

    my %stored;
    no warnings 'redefine', 'once';
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };

    # Trap 2: advance from the LIVE pref. The row was built showing 'genre'; if the
    # pref has since moved to 'date', tapping must go on to 'score', not back to 'date'.
    $stored{group_by} = 'date';
    $t->{url}->(undef, sub {});
    is('advances from the LIVE pref, not the captured render', $stored{group_by}, 'score');

    # THE FULL CYCLE, asserted as a ring rather than as one step (0.9.42). A third mode
    # is exactly where an off-by-one in the wrap hides: with two modes ANY rotation is
    # the identity every other tap, so the old two-step check could not have caught a
    # reversed or skipping cycle. Genre -> Week -> Score -> Genre.
    $stored{group_by} = 'genre';
    my @seen;
    for (1 .. 4) { $t->{url}->(undef, sub {}); push @seen, $stored{group_by}; }
    is('the cycle is genre -> date -> score -> genre', join(',', @seen), 'date,score,genre,date');

    # Trap 3: the enum guard moved from the Settings save to the read.
    $stored{group_by} = 'nonsense';
    is('a corrupt pref reads as genre', $NS->can('_groupBy')->(), 'genre');
    delete $stored{group_by};
    is('an unset pref reads as genre',  $NS->can('_groupBy')->(), 'genre');
    $stored{group_by} = 'date';
    is('a valid pref is honoured',      $NS->can('_groupBy')->(), 'date');
}

print "--- _groupedRows falls back to the pref when given no mode ---\n";
{
    my %stored = (group_by => 'date');
    no warnings 'redefine', 'once';
    local *T::Prefs::get = sub { $stored{$_[1]} };
    my $rows  = $NS->can('_groupedRows')->(undef, \@ITEMS, 1);
    my $names = join('|', map { $_->{name} } dividers($rows));
    ok('no explicit mode -> uses the pref (week dividers here)', $names !~ /Rock/);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

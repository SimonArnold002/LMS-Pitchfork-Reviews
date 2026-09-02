#!/usr/bin/env perl
# 0.9.8 — the list DATABASE, tested against a REAL SQLite file in a temp dir.
#
# WHAT THIS PROTECTS, and why it is not "just storage":
#
# From 0.9.0 to 0.9.7 the year lists were not stored at all. `$cache->set` reported
# success, raised nothing, and the next `$cache->get` returned undef — so every year
# article (1.75MB) was re-downloaded on every warm pass, ~80 needless requests a day,
# for five releases. The cause was found in 0.9.9 and is now documented beside
# STREAM_FOUND_TTL in Browse.pm: LMS reads any TTL over 2,592,000s as an ABSOLUTE Unix
# timestamp, so the 365-day year TTL was stored expiring in 1971. That bug has a
# one-line fix; the table is here because a 30-day maximum still cannot express "this
# list is finished for ever", and only if the table itself is honest about what it does
# and does not hold.
#
# So the assertions here are mostly about FAILURE shapes, not happy paths:
#   - a half-written list must read as ABSENT, never as a short list (a truncated year
#     would look exactly like a successful read while silently losing albums);
#   - a stale PARSE_VERSION must read as absent, because a permanent store would
#     otherwise keep a parsing mistake permanently;
#   - a replaced rolling feed must DELETE what rotated off, or the table grows for ever;
#   - an unavailable DB must degrade to "not held" and never take the plugin down.
use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

BEGIN {
    $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'} = __FILE__;
}
{
    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; our (@WARNED, @ERRORED);
                                  sub AUTOLOAD {}
                                  sub warn  { push @WARNED,  $_[1]; 1 }
                                  sub error { push @ERRORED, $_[1]; 1 }
                                  sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs;   use Exporter 'import'; our @EXPORT = qw(preferences);
                                  our %P;
                                  sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;             sub get { $Slim::Utils::Prefs::P{$_[1]} }
                                  sub set { $Slim::Utils::Prefs::P{$_[1]} = $_[2] }
}
$Slim::Utils::Prefs::P{cachedir} = $DIR;

my $DB = $ENV{PFR_DB} || "$FindBin::Bin/../PitchforkReviews/DB.pm";
do $DB or die "can't load $DB: " . ($@ || $!);
my $NS = 'Plugins::PitchforkReviews::DB';

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . (defined $g ? $g : '') . "'",
                                 ((defined $g ? $g : '') eq (defined $w ? $w : ''))) }
sub section { printf "\n== %s\n", $_[0] }

# A year item exactly as _parseYear emits it, and a feed item exactly as _parseState
# does. Both shapes must survive the same table — that is the point of one schema.
sub yearItem {
    my ($n) = @_;
    return {
        artist => "Artist $n", album => "Album $n", title => "Artist $n: Album $n",
        capsule => ('blurb ' x 30), link => 'https://pitchfork.com/features/x/',
        date => '2024-12-02T14:00:00.000Z', cover => "https://img/$n.jpg",
        score => undef, genre => '', is_bnm => 0, year => 2024,
        list_title => 'The 50 Best Albums of 2024', rank => $n,
    };
}
sub feedItem {
    my ($n) = @_;
    return {
        artist => "Band $n", album => "Record $n", title => "Band $n: Record $n",
        capsule => 'A capsule.', link => "https://pitchfork.com/reviews/albums/r$n/",
        date => '2026-08-01T05:00:00.000Z', cover => "https://img/f$n.jpg",
        score => 8.4, genre => 'Rock / Experimental', is_bnm => 1,
    };
}

# ---------------------------------------------------------------------------
section 'a year list round-trips with its shape intact';

my @year = map { yearItem($_) } 1 .. 50;
ok('putList reports success', $NS->can('putList')->('year:2024', \@year, 1));

my $back = $NS->can('getList')->('year:2024', 1);
ok('the list reads back', defined $back);
is('...complete', scalar(@{ $back || [] }), 50);
is('...in stored order', join(',', map { $_->{rank} } @{$back}[0, 11, 49]), '1,12,50');
is('...with the capsule intact', $back->[0]{capsule}, ('blurb ' x 30));
is('...and the year restored from the key', $back->[0]{year}, 2024);

# The DB is the only thing between the parser and the renderer, so an item that comes
# back subtly different is a rendering bug waiting to happen.
my $src = yearItem(1);
my $got = $back->[0];
ok('every field the parser set survives the round trip',
   !grep { my $k = $_;
           defined $src->{$k} ? (($got->{$k} // '') ne $src->{$k}) : defined $got->{$k} }
     qw(artist album title capsule link date cover genre list_title rank year score));

section 'a feed item survives the same table (one schema, both shapes)';

my @feed = map { feedItem($_) } 1 .. 30;
$NS->can('putList')->('reviews', \@feed, 1);
my $fb = $NS->can('getList')->('reviews', 1);
is('30 items back', scalar(@{ $fb || [] }), 30);
is('...score preserved as a number', $fb->[0]{score}, '8.4');
is('...is_bnm preserved', $fb->[0]{is_bnm}, 1);
is('...genre preserved', $fb->[0]{genre}, 'Rock / Experimental');
ok('...and a feed item gains NO year (only year lists carry one)', !defined $fb->[0]{year});

section 'unicode survives — the trap that bit the fleet elsewhere';

# LMS-Discography documented DbCache dying on character strings; sqlite_unicode keeps
# that boundary inside DBD::SQLite. If this ever regresses, non-ASCII artists silently
# corrupt, which is the hardest kind of bug to notice.
my $uni = [ { %{ feedItem(1) }, artist => "Bj\x{f6}rk", album => "Utopi\x{e1} \x{2014} \x{201c}live\x{201d}" } ];
$NS->can('putList')->('unicode', $uni, 1);
my $u = $NS->can('getList')->('unicode', 1);
is('a non-ASCII artist round-trips exactly', $u->[0]{artist}, "Bj\x{f6}rk");
is('...and curly quotes / em-dashes too', $u->[0]{album}, "Utopi\x{e1} \x{2014} \x{201c}live\x{201d}");

section 'ROTATION: replacing a rolling feed deletes what rotated off';

$NS->can('putList')->('reviews', [ map { feedItem($_) } 100 .. 104 ], 1);
my $rot = $NS->can('getList')->('reviews', 1);
is('the new set is what reads back', scalar(@{ $rot || [] }), 5);
is('...and it is the NEW items', $rot->[0]{artist}, 'Band 100');
{
    my $h = $NS->can('dbh')->();
    my ($n) = $h->selectrow_array("SELECT COUNT(*) FROM list_item WHERE list_key = 'reviews'");
    is('...with no orphan rows left behind from the 30-item set', $n, 5);
}

section 'a stale PARSE_VERSION reads as absent, so a parser fix re-fetches';

ok('stored at version 1, asked for at version 2 -> not held',
   !defined $NS->can('getList')->('year:2024', 2));
ok('...and asking at the version it was stored with still works',
   defined $NS->can('getList')->('year:2024', 1));
ok('...while omitting the version entirely skips the check (callers that do not care)',
   defined $NS->can('getList')->('year:2024'));

section 'a HALF-WRITTEN list reads as absent, never as a short list';

# The failure that matters: a truncated year would look like a successful hit while
# silently dropping albums off the end.
{
    my $h = $NS->can('dbh')->();
    $h->do("DELETE FROM list_item WHERE list_key = 'year:2024' AND position > 20");
    @T::Log::WARNED = ();
    ok('rows != item_count -> not held', !defined $NS->can('getList')->('year:2024', 1));
    ok('...and it says so, rather than failing quietly',
       scalar(grep { /DB holds 21 rows but meta says 50/ } @T::Log::WARNED) == 1);
}

section 'forget / storedKeys';

$NS->can('putList')->('year:2019', [ map { yearItem($_) } 1 .. 3 ], 1);
$NS->can('putList')->('bnm',       [ feedItem(1) ], 1);
my @keys = $NS->can('storedKeys')->();
ok('storedKeys lists what is held', scalar(grep { $_ eq 'year:2019' } @keys) == 1);

$NS->can('forget')->('year:2019');
ok('forget drops the list', !defined $NS->can('getList')->('year:2019', 1));
{
    my $h = $NS->can('dbh')->();
    my ($n) = $h->selectrow_array("SELECT COUNT(*) FROM list_item WHERE list_key = 'year:2019'");
    is('...and its rows, not just its meta row', $n, 0);
}

section 'listAge';

ok('a stored list has an age', defined $NS->can('listAge')->('bnm'));
ok('...that is fresh', $NS->can('listAge')->('bnm') < 5);
ok('an absent list has no age', !defined $NS->can('listAge')->('nope'));

section 'empty and malformed writes are refused, not stored';

ok('an empty list is not stored', !$NS->can('putList')->('empty', [], 1));
ok('a non-arrayref is not stored', !$NS->can('putList')->('bad', { a => 1 }, 1));
ok('...and neither leaves a meta row',
   !defined $NS->can('getList')->('empty', 1) && !defined $NS->can('getList')->('bad', 1));

section 'an UNAVAILABLE database degrades — it must never take the plugin down';

# The plugin has to keep working (by re-fetching every time) if the DB cannot be opened
# at all: a read-only cachedir, a corrupt file, DBD::SQLite missing.
#
# RUN IN A CHILD PROCESS, deliberately. `$dbh` and `$broken` are file-lexicals, so an
# in-process attempt to reset them does nothing — the first version of this block
# "passed" against the working handle it had already opened, proving nothing at all.
# A fresh interpreter with a poisoned cachedir is the only honest way to reach the
# failure path.
{
    my $bad = tempdir(CLEANUP => 1);
    mkdir "$bad/pitchforkreviews.db";   # a DIRECTORY where the file must go

    my $child = <<'CHILD';
use strict; use warnings;
BEGIN { $INC{'Slim/Utils/Log.pm'} = $INC{'Slim/Utils/Prefs.pm'} = __FILE__; }
{
    package Slim::Utils::Log;   use Exporter 'import'; our @EXPORT = qw(logger);
                                sub logger { bless {}, 'T::Log' }
    package T::Log;             our $AUTOLOAD; our @ERRORED;
                                sub AUTOLOAD {} sub error { push @ERRORED, $_[1]; 1 }
                                sub warn {1} sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs; use Exporter 'import'; our @EXPORT = qw(preferences);
                                sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;           sub get { $ENV{PFR_TEST_CACHEDIR} } sub set {}
}
do $ENV{PFR_TEST_DB} or die "load failed: " . ($@ || $!);
my $NS = 'Plugins::PitchforkReviews::DB';
my @r;
push @r, (eval { $NS->can('getList')->('year:2024', 1); 1 } ? 'noThrow' : 'THREW');
push @r, (defined $NS->can('getList')->('year:2024', 1)     ? 'HELD'    : 'notHeld');
push @r, ($NS->can('putList')->('year:2024', [ { artist => 'A' } ], 1) ? 'WROTE' : 'refused');
push @r, (grep({ /DB unavailable/ } @T::Log::ERRORED) ? 'reported' : 'SILENT');
print join(',', @r), "\n";
CHILD

    my $script = "$DIR/child.pl";
    open my $fh, '>', $script or die $!;
    print $fh $child;
    close $fh;

    local $ENV{PFR_TEST_CACHEDIR} = $bad;
    local $ENV{PFR_TEST_DB}       = "$FindBin::Bin/../PitchforkReviews/DB.pm";
    chomp(my $out = `$^X $script 2>&1`);
    is('a broken DB: no throw, not held, write refused, reported',
        $out, 'noThrow,notHeld,refused,reported');
}

# ===========================================================================
# THE KEY/VALUE SIDE (0.9.11) — against real SQLite, like the rest of this file.
#
# This is where the resolve cache now lives, and the resolve cache is what the 30-day
# boundary destroyed for eight releases. The point of these tests is that the defect
# CANNOT BE EXPRESSED here: expires_at is an absolute epoch computed by us, so a
# 90-day or 365-day TTL is just a long time, not an accidental 1970.
# ===========================================================================
{
    my $NS = 'Plugins::PitchforkReviews::DB';

    $NS->can('kvSet')->('k:plain', 'hello', 3600);
    is('a scalar round-trips', $NS->can('kvGet')->('k:plain'), 'hello');

    $NS->can('kvSet')->('k:ref', { items => [ { name => 'A' }, { name => 'B' } ] }, 3600);
    my $got = $NS->can('kvGet')->('k:ref');
    is('a nested structure round-trips', ref $got eq 'HASH' ? $got->{items}[1]{name} : '', 'B');

    $NS->can('kvSet')->('k:uni', { t => "Sigur R\x{00F3}s \x{2014} \x{00C1}g\x{00E6}tis" }, 3600);
    is('unicode survives the round trip',
        $NS->can('kvGet')->('k:uni')->{t}, "Sigur R\x{00F3}s \x{2014} \x{00C1}g\x{00E6}tis");

    # THE SENTINEL. getLatestYear stores 0 for "a completed sweep that found nothing",
    # and that has to stay distinguishable from "never stored" or the sweep re-runs
    # every render. A bare freeze of 0 would come back looking like a miss.
    $NS->can('kvSet')->('k:zero', 0, 3600);
    is('a stored 0 reads back as 0, not as absent', $NS->can('kvGet')->('k:zero'), 0);
    ok('...and is distinguishable from a key that was never stored',
       defined $NS->can('kvGet')->('k:zero') && !defined $NS->can('kvGet')->('k:never'));

    # THE WHOLE POINT. Every one of these TTLs is over LMS's 2,592,000 ceiling — the
    # value that silently meant "expired in 1970" in Slim::Utils::Cache. Here they are
    # simply long.
    for my $days (30, 90, 365) {
        $NS->can('kvSet')->("k:ttl$days", "held$days", $days * 86400);
        is("a ${days}-day TTL stores and reads back — no 30-day boundary",
            $NS->can('kvGet')->("k:ttl$days"), "held$days");
    }

    # An expiry in the past reads as absent rather than as a stale value.
    $NS->can('kvSet')->('k:dead', 'stale', -10);
    ok('an expired key reads as absent', !defined $NS->can('kvGet')->('k:dead'));

    # ...and 0/undef TTL means never, which is what an immutable answer wants.
    $NS->can('kvSet')->('k:forever', 'kept', 0);
    is('a 0 TTL means never expires', $NS->can('kvGet')->('k:forever'), 'kept');

    $NS->can('kvDel')->('k:plain');
    ok('kvDel removes it', !defined $NS->can('kvGet')->('k:plain'));

    # Prefix retirement — how a version bump drops a whole family without touching lists.
    $NS->can('kvSet')->("pfr:stream:12:x$_", $_, 3600) for 1 .. 3;
    $NS->can('kvSet')->('pfr:year:latest:4', 2025, 3600);
    my $n = $NS->can('kvForgetPrefix')->('pfr:stream:12:');
    is('kvForgetPrefix drops exactly that family', $n, 3);
    is('...and leaves everything else alone', $NS->can('kvGet')->('pfr:year:latest:4'), 2025);

    # The lists and the kv rows are separate storage: retiring one must not touch the
    # other. This is the property 0.9.8 wanted when it argued for keeping the layers
    # apart — now expressed as two tables rather than as two different databases.
    $NS->can('putList')->('year:2001', [ { artist => 'A', album => 'B' } ], 1);
    $NS->can('kvForgetPrefix')->('pfr:');
    my $still = $NS->can('getList')->('year:2001', 1);
    ok('wiping every kv row leaves the stored lists intact', $still && @$still == 1);

    # --- kvSweep (0.9.11). The rows that need collecting are the ones NOTHING WILL EVER
    # READ AGAIN — a review that rotated off the Pitchfork listing keeps its resolve row
    # for the full TTL and is never asked for — so neither the per-read cleanup in kvGet
    # nor the once-per-process sweep in _migrate can reach them. Without a periodic
    # sweep the table grows with uptime, which is invisible on a server that a backup
    # restarts every morning.
    # kvForgetPrefix deliberately REFUSES an empty prefix rather than wiping the table,
    # so this starts from a known delta instead of a clean slate.
    $NS->can('kvSweep')->();                                 # drain anything already dead
    my $base = $NS->can('kvCount')->();
    $NS->can('kvSet')->("dead:$_", 'x', -10)   for 1 .. 4;   # already expired
    $NS->can('kvSet')->('live:1',  'x', 3600);               # still good
    $NS->can('kvSet')->('keep:1',  'x', 0);                  # never expires
    is('kvSweep collects exactly the expired rows', $NS->can('kvSweep')->(), 4);
    is('...and only those', $NS->can('kvCount')->(), $base + 2);
    is('...the live one still reads', $NS->can('kvGet')->('live:1'), 'x');
    is('...as does the permanent one', $NS->can('kvGet')->('keep:1'), 'x');
    ok('...and every expired key is gone',
       !grep { defined $NS->can('kvGet')->("dead:$_") } 1 .. 4);
    is('a second sweep with nothing to do collects nothing', $NS->can('kvSweep')->(), 0);
    ok('an empty prefix is refused, not treated as "everything"',
       $NS->can('kvForgetPrefix')->('') == 0 && $NS->can('kvCount')->() == $base + 2);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

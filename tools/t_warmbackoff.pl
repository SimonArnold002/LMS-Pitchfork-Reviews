#!/usr/bin/env perl
# 0.9.23 — the warm's no-player RETRY CADENCE.
#
# WARM_PLAYER_RETRY exists because warmCache needs a connected player and returning bare
# was indistinguishable from success, which switched the warm off for three hours on a
# machine whose player joins late (0.9.10). The fix was right and the re-arm around it was
# unbounded: `$started ? WARM_INTERVAL : WARM_PLAYER_RETRY`, forever. On a server where the
# warm can NEVER start — headless, no player ever connected, or any persistent throw out of
# warmCache — that is a 20-second tick for the life of the process: ~4,320 wake-ups a day
# that cannot succeed, each also running a kvSweep DELETE.
#
# WHY THIS NEEDED ITS OWN SUITE. t_perf pins the warm cadence by READING Plugin.pm's source,
# and says why: Plugin.pm cannot load in that harness. It also pre-stubs
# Plugins::PitchforkReviews::Plugin::dbg for Browse.pm's benefit, so loading the real module
# there would collide. The arithmetic is exactly the kind that regresses silently — an
# off-by-one in the doubling, or a cap that does not cap — so it gets a harness that can run
# the real sub rather than a test that reads the constants and infers.
#
# Run from the repo root:  perl tools/t_warmbackoff.pl
use strict; use warnings;

# --- throwaway Slim::* tree (absent on a dev Mac) ---------------------------
BEGIN {
    # LMS defines these as compile-time constants in its own main::, and initPlugin
    # branches on WEBUI at compile time — without it Plugin.pm won't even parse here.
    *main::WEBUI    = sub () { 0 };
    *main::SLIM_SERVICE = sub () { 0 };
    *main::ISWINDOWS    = sub () { 0 };
    $INC{$_} = __FILE__ for qw(
        Slim/Plugin/OPMLBased.pm Slim/Utils/Log.pm Slim/Utils/Prefs.pm
        Slim/Utils/PluginManager.pm Slim/Utils/Strings.pm Slim/Utils/OSDetect.pm
        Slim/Utils/Timers.pm Slim/Music/Import.pm
    );
}

{
    package Slim::Plugin::OPMLBased;   sub initPlugin {} sub new {}
    package Slim::Utils::Log;          use Exporter 'import'; our @EXPORT = qw(logger);
                                       sub addLogCategory {} sub logger { bless {}, 'T::Log' }
    package T::Log;                    our $AUTOLOAD; sub AUTOLOAD {} sub is_debug {0} sub is_info {0}
    package Slim::Utils::Prefs;        use Exporter 'import'; our @EXPORT = qw(preferences);
                                       sub preferences { bless {}, 'T::Prefs' }
    package T::Prefs;                  our $AUTOLOAD; our %P;
                                       sub AUTOLOAD {} sub init {} sub setChange {}
                                       sub get { $P{$_[1]} } sub set { $P{$_[1]} = $_[2] }
    package Slim::Utils::PluginManager; sub dataForPlugin {} sub allPlugins { () }
    package Slim::Utils::Strings;      use Exporter 'import'; our @EXPORT_OK = qw(cstring string);
                                       sub cstring { $_[1] } sub string { $_[0] }
    package Slim::Utils::OSDetect;     sub dirsFor { '/tmp' } sub details { {} }
    package Slim::Music::Import;       our $SCANNING = 0; sub stillScanning { $SCANNING }
    package Slim::Utils::Timers;       our @T;
                                       sub setTimer { my (undef, $when, $cb) = @_;
                                                      push @T, { when => $when, cb => $cb }; scalar @T }
                                       sub killSpecific {1} sub killTimers {}
                                       sub reset { @T = () }
}

my $PLUGIN = $ENV{PFR_PLUGIN} || 'PitchforkReviews/Plugin.pm';
$INC{'Plugins/PitchforkReviews/Plugin.pm'} = $PLUGIN;
do($PLUGIN =~ m{^/} ? $PLUGIN : "./$PLUGIN") or die "can't load $PLUGIN: " . ($@ || $!);

my $P = 'Plugins::PitchforkReviews::Plugin';
my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

my $delay = $P->can('_warmRetryDelay') or die "no _warmRetryDelay\n";
my $reset = $P->can('_resetWarmBackoff');

# ---------------------------------------------------------------------------
# 1. The constants, and the relationship that is the whole point of them
# ---------------------------------------------------------------------------
# The ceiling has to sit WELL BELOW WARM_INTERVAL. Capping at WARM_INTERVAL — the obvious
# reading of "back off to the normal cadence" — re-opens the very hole WARM_PLAYER_RETRY was
# added to close: a player connecting late would wait up to three hours for its first warm,
# which is the three-hour no-player hole with extra steps. Asserted as a RELATIONSHIP so a
# future retune cannot quietly land back there.
ok('the retry ceiling is far below the normal interval, not equal to it',
   $P->WARM_RETRY_MAX() * 4 < $P->WARM_INTERVAL());
ok('...and above the first retry, or there is no backoff to speak of',
   $P->WARM_RETRY_MAX() > $P->WARM_PLAYER_RETRY());

# ---------------------------------------------------------------------------
# 2. It backs off, it stops backing off, and it never exceeds the ceiling
# ---------------------------------------------------------------------------
$reset->();
my @seq = map { $delay->(0) } 1 .. 12;
is('the first failure retries at WARM_PLAYER_RETRY', $seq[0], $P->WARM_PLAYER_RETRY());
is('...the second at double', $seq[1], $P->WARM_PLAYER_RETRY() * 2);
is('...the third at double again', $seq[2], $P->WARM_PLAYER_RETRY() * 4);

ok('the delay never decreases while the warm keeps failing',
   !grep { $seq[$_] < $seq[$_ - 1] } 1 .. $#seq);
ok('...and never exceeds the ceiling, however long it goes on',
   !grep { $_ > $P->WARM_RETRY_MAX() } @seq);
is('...settling exactly ON the ceiling rather than near it',
   $seq[-1], $P->WARM_RETRY_MAX());

# THE ACTUAL DEFECT, stated as the number it costs. A flat 20s re-arm is 4,320 wake-ups a
# day; the point of the change is that the steady state is the ceiling, not the floor.
my $perDay = int(86400 / $seq[-1]);
ok("the steady state is ~$perDay wake-ups a day, not 4320",
   $perDay < 400);

# ---------------------------------------------------------------------------
# 3. A single success snaps straight back to the normal cadence
# ---------------------------------------------------------------------------
# Not "decays back" — a warm that started is a tick that was SERVED, and the next one is
# due at the ordinary interval. Anything slower would make one late player connection cost
# the rest of the day's freshness.
$reset->();
$delay->(0) for 1 .. 6;
is('a success returns the normal interval', $delay->(1), $P->WARM_INTERVAL());
is('...and the counter is cleared, so the NEXT failure starts from the floor again',
   $delay->(0), $P->WARM_PLAYER_RETRY());

# A run that never fails must never see a retry delay at all.
$reset->();
ok('a warm that always starts is always on the normal interval',
   !grep { $delay->(1) != $P->WARM_INTERVAL() } 1 .. 5);

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

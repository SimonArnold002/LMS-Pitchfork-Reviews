package Plugins::PitchforkReviews::Plugin;

# Pitchfork Reviews — a Lyrion Music Server plugin.
#
# Browse curated album reviews (v1: Pitchfork "Best New Music" and "Latest
# Reviews", parsed from the listing pages' embedded Verso state) and play each
# reviewed album from the user's streaming library (Qobuz / Tidal / Deezer). The
# review→streaming resolver mirrors
# the album-match engine from the ListenBrainz Fresh Releases plugin, adapted to
# resolve at album level from an "artist / album" pair (see Browse.pm).
#
# Pure Perl, async HTTP, no extra server software (cross-platform). Display is
# metadata + capsule + a "Read review" link out — no full review text is stored.

use strict;
use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::OSDetect;
use Slim::Utils::Timers;
use Slim::Music::Import;
use File::Spec;

# Background warm cadence. Staggered later than the sibling ListenBrainz plugin's
# 60s warm so, when both are installed, they don't hit the streaming APIs at boot
# together. The daily tick is cheap — resolver matches are cached, so it only does
# real work for reviews new since the last run.
use constant WARM_DELAY      => 150;         # seconds after startup
use constant WARM_INTERVAL   => 24 * 3600;   # daily
use constant WARM_SCAN_RETRY => 120;         # seconds between library-scan re-checks

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.pitchforkreviews',
    # WARN in production keeps server.log quiet (INFO logs every feed fetch, cache
    # hit and resolver decision). Raise to INFO via Settings -> Logging when
    # diagnosing.
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_PITCHFORKREVIEWS',
});

my $prefs = preferences('plugin.pitchforkreviews');

$prefs->init({
    # Streaming-service search priority. Services are searched in ascending order
    # and the album resolver stops at the first one that matched; 0 = never search
    # it. Same convention as the ListenBrainz plugin so the two stay familiar.
    svc_priority_qobuz  => 1,
    svc_priority_tidal  => 2,
    svc_priority_deezer => 3,

    # Latest Reviews grouping: 'date' (weekly dividers) or 'genre'. Default 'genre'
    # for now so a fresh install shows the genre grouping without a settings visit.
    group_by => 'genre',

    # Opt-in extra logging (also always mirrored to server.log at INFO).
    debug_log => 0,
});

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::PitchforkReviews::Settings;
        Plugins::PitchforkReviews::Settings->new();
    }

    require Plugins::PitchforkReviews::Browse;
    require Plugins::PitchforkReviews::API;

    # NB: OPMLBased takes the app/menu icon from install.xml <icon>
    # (_pluginDataFor('icon')) and ignores an icon => arg — same as the
    # ListenBrainz plugin. The _svg.png convention lets Material recolour the
    # sibling .svg per theme: PitchforkReviewsIcon.svg is the Pitchfork round mark
    # (ring in #000 so Material themes it; the arrows stay Pitchfork red).
    $class->SUPER::initPlugin(
        tag    => 'pitchforkreviews',
        feed   => \&Plugins::PitchforkReviews::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    return;
}

# Runs after all plugins have initialised, so Material Skin is available to
# check. Registers the home-page shelves (Best New Music + Latest Reviews),
# mirroring how the ListenBrainz plugin / Qobuz / Bandcamp do it. A quiet no-op
# when Material Skin isn't installed or is too old to expose registerHomeExtra.
sub postinitPlugin {
    my $class = shift;

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
      && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
        eval {
            require Plugins::PitchforkReviews::HomeExtras;
            Plugins::PitchforkReviews::HomeExtras->initPlugin();
            $log->info("Registered Material Skin home extras (Best New Music + High Scoring Albums + Latest Reviews)");
            1;
        } or $log->error("Failed to register Material home extras: $@");
    }

    # Pre-resolve the two listings to streaming shortly after startup, then daily,
    # so the home shelves (and browse lists) open from a warm cache instead of
    # running an up-to-18s resolve live on the Material home carousel. Delayed so
    # it doesn't compete with boot; the whole build benefits (not just Material).
    Slim::Utils::Timers::setTimer(undef, time() + WARM_DELAY, \&_warmTick);

    return;
}

# Run the warm, then re-arm for the next day. Deferred while a library scan is in
# progress so a match never resolves against a half-scanned library (mirrors the
# sibling ListenBrainz plugin's warm).
sub _warmTick {
    if ( Slim::Music::Import->stillScanning() ) {
        dbg("warm: library scan in progress — deferring " . WARM_SCAN_RETRY . "s");
        Slim::Utils::Timers::setTimer(undef, time() + WARM_SCAN_RETRY, \&_warmTick);
        return;
    }

    eval {
        require Plugins::PitchforkReviews::Browse;
        Plugins::PitchforkReviews::Browse::warmCache();
        1;
    } or $log->error("Home-shelf warm failed: $@");

    Slim::Utils::Timers::setTimer(undef, time() + WARM_INTERVAL, \&_warmTick);
}

# ---------------------------------------------------------------------------
# Dedicated, opt-in debug log for feed/resolve tracking (ported from the
# ListenBrainz Fresh Releases plugin). Always mirrors to server.log at info;
# when the debug_log pref is on, ALSO appends a timestamped line to
# pfr-debug.log (beside server.log) so the resolve timeline is easy to follow
# without wading through the rest of server.log. Size-capped (~1 MB, one .old
# rotation) so it can't grow unbounded. Fully eval-guarded — a logging failure
# never disrupts the caller.
# ---------------------------------------------------------------------------
my $DBG_FILE;   # memoised path

sub _dbgFile {
    return $DBG_FILE if defined $DBG_FILE;
    my $dir = eval { scalar Slim::Utils::OSDetect::dirsFor('log') };
    $dir = preferences('server')->get('cachedir') if !$dir || !-d $dir;
    $DBG_FILE = File::Spec->catfile($dir // '.', 'pfr-debug.log');
    return $DBG_FILE;
}

sub dbg {
    my $msg = shift;
    $log->info($msg);
    return unless $prefs->get('debug_log');
    eval {
        my $file = _dbgFile();
        rename($file, "$file.old") if (-s $file // 0) > 1_000_000;   # ~1 MB cap, keep one rotation
        open(my $fh, '>>:encoding(UTF-8)', $file) or die "open $file: $!";
        my @t = localtime(time);
        printf $fh "%04d-%02d-%02d %02d:%02d:%02d  %s\n",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0], $msg;
        close $fh;
        1;
    } or $log->warn("debug-log write failed: $@");
}

sub getDisplayName { 'PLUGIN_PITCHFORKREVIEWS' }

sub playerMenu { undef }

1;

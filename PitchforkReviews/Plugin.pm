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
# together. The tick is cheap — resolver matches are cached, so it only does real
# work for reviews new since the last run.
#
# 3h, not daily (0.8.8), because that is API::FEED_TTL: on the old daily tick the
# listing cache spent most of the day expired, so the FIRST person to open a view
# paid the page fetch (0.9-2.0MB, up to 4s measured) plus the resolve of anything
# published since the last tick. Matching the two means the warm is what pays that,
# every time, before anyone looks. Stale-while-revalidate covers the gap if a tick
# is ever missed.
# 150 -> 15 (0.9.10). The 150 was never derived from anything: the only reason on
# record was one comment, "delayed so it doesn't compete with boot". Measured against
# the server log, postinitPlugin arms this timer and `main::init - Server done init`
# lands 0.2 SECONDS later, so the remaining ~150s was guarding against a boot that had
# already finished. It was the single largest item in the cold start — longer than the
# 54s it takes to warm all three feed lists — and it ran every morning, because the
# backup stops and starts the server daily.
#
# A library scan is the other thing worth not competing with, and that is handled
# properly and separately below (stillScanning + WARM_SCAN_RETRY), not by this number.
#
# What the 150 WAS covering, by accident, is that warmCache needs a connected player.
# That is now an explicit retry (WARM_PLAYER_RETRY) instead of a delay long enough to
# usually get away with it. 15s still lets startup settle without being the dominant
# cost of a fresh install.
use constant WARM_DELAY      => 15;          # seconds after startup
use constant WARM_PLAYER_RETRY => 20;        # no player yet — try again shortly
use constant WARM_INTERVAL   => 3 * 3600;    # matches API::FEED_TTL
use constant WARM_SCAN_RETRY => 120;         # seconds between library-scan re-checks

# THE RETRY BACKS OFF, because WARM_PLAYER_RETRY answers "no player has connected YET" and
# nothing bounded how long "yet" could last. The re-arm was unconditional: on a server where
# warmCache can never start — headless, no player ever connected, which is a real LMS
# configuration, or any persistent throw out of warmCache — it fired every 20 seconds for
# the life of the process. ~4,320 wake-ups a day that cannot succeed, each one also running
# a kvSweep DELETE.
#
# WARM_RETRY_MAX IS DELIBERATELY WELL BELOW WARM_INTERVAL, and that is the whole design.
# Capping at WARM_INTERVAL would re-open the exact hole WARM_PLAYER_RETRY was added to
# close — a player connecting late waits up to three hours for its first warm, which is
# the three-hour no-player hole with extra steps. At 300s the runaway is gone (288
# wake-ups a day worst case instead of 4,320) while a player connecting at ANY point is
# still picked up within five minutes.
use constant WARM_RETRY_MAX  => 300;         # ceiling on the no-player backoff

# Consecutive ticks that could not start a warm. File-scoped rather than passed through the
# timer, because Slim::Utils::Timers hands the callback no state of its own.
my $_warmFails = 0;

# The delay before the next tick. Doubles WARM_PLAYER_RETRY per consecutive failure up to
# WARM_RETRY_MAX; a single success drops straight back to the normal cadence.
sub _warmRetryDelay {
    my ($started) = @_;
    if ($started) {
        $_warmFails = 0;
        return WARM_INTERVAL;
    }
    my $delay = WARM_PLAYER_RETRY * (2 ** $_warmFails);
    $_warmFails++;
    return $delay > WARM_RETRY_MAX ? WARM_RETRY_MAX : $delay;
}

sub _resetWarmBackoff { $_warmFails = 0; return }   # test seam
sub _warmFailCount    { return $_warmFails }        # test seam

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
    # Spotify (via Spotty) last: it only competes once the others have missed, and its
    # Pipeline cannot tell a failed search from an empty one.
    svc_priority_spotify => 4,

    # How the three review sections are laid out: 'genre' (genre dividers), 'date'
    # (weekly dividers) or 'score' (ONE FLAT LIST, highest score first — no dividers).
    # Default 'genre' so a fresh install shows the genre grouping without a settings visit.
    #
    # THE PREF NAME IS HISTORICAL. It predates 'score', which is a SORT and not a grouping,
    # so the name under-describes it now. Kept anyway: renaming would orphan every user's
    # stored choice, and the browse code reads it through _groupBy() in one place. The row
    # the user actually taps says "View: …" for the same reason — see Browse::_groupToggle.
    group_by => 'genre',

    # Best Albums of the Year ordering: 'rank' (#1 at the top — the browse-list
    # default) or 'countdown' (50 first, Pitchfork's own reading order). Flipped in
    # place by the "Sorted by …" row in that view, NOT on the settings page —
    # the same convention as the sibling ListenBrainz plugin's sort toggles.
    year_sort => 'rank',

    # Which year the Best Albums view opens on, and the newest list already
    # promoted. The view REMEMBERS the year you last looked at, so the tile, the
    # Material home shelf and the view itself all name the same year — but a newly
    # published list still wins: when getLatestYear reports a year newer than
    # `year_promoted`, the view jumps to it and both prefs move up. 0 = never set,
    # so a fresh install simply opens on the newest. See Browse::_viewYear.
    year_last     => 0,
    year_promoted => 0,

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

    # Pitchfork's own artwork, sized to the thumbnail actually being asked for
    # (0.8.8). XMLBrowser routes every row `image` through the image proxy and
    # Material asks it for _150x150_f / _300x300_f, but the proxy downloads the
    # ORIGINAL to resize — w_768 = 82KB per cover, against 9KB at w_320. The width
    # is a path segment on media.pitchfork.com, so the handler just names a smaller
    # one. Guarded on getRightSize (absent on older LMS): artwork sizing is never a
    # reason to fail a plugin load. Registered unconditionally — a `match` handler
    # is consulted whatever the useLocalImageproxy pref says (that pref selects an
    # EXTERNAL resizing proxy, see Slim/Web/ImageProxy.pm).
    eval {
        require Slim::Web::ImageProxy;
        if ( UNIVERSAL::can('Slim::Web::ImageProxy', 'getRightSize') ) {
            Slim::Web::ImageProxy->registerHandler(
                match => qr/media\.pitchfork\.com/,
                func  => \&Plugins::PitchforkReviews::Browse::pitchforkImageProxy,
            );
            # ...and the SERVICES' own CDNs, which is where a MATCHED row's artwork
            # actually comes from (see the note on qobuzImageProxy). 0.8.8 left these
            # out on the reasoning that they belong to their own plugins; the effect
            # was that the sizing applied only to unmatched rows.
            Slim::Web::ImageProxy->registerHandler(
                match => qr/static\.qobuz\.com/,
                func  => \&Plugins::PitchforkReviews::Browse::qobuzImageProxy,
            );
            Slim::Web::ImageProxy->registerHandler(
                match => qr/resources\.tidal\.com/,
                func  => \&Plugins::PitchforkReviews::Browse::tidalImageProxy,
            );
            Slim::Web::ImageProxy->registerHandler(
                match => qr/dzcdn\.net/,
                func  => \&Plugins::PitchforkReviews::Browse::deezerImageProxy,
            );
            $log->info("Registered Pitchfork + Qobuz/Tidal/Deezer artwork image-proxy handlers");
        }
        1;
    } or $log->warn("Image-proxy handler registration failed: $@");

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

    # Streaming-service detection is `->can` on the three service classes, so it is
    # only trustworthy once every plugin has loaded — which is exactly here. Until
    # this call Browse refuses to memoise what it detects, since an answer taken
    # mid-startup can be short a service (or all of them) and would then be frozen
    # for the life of the process. (0.8.10)
    eval {
        require Plugins::PitchforkReviews::Browse;
        Plugins::PitchforkReviews::Browse::markStartupComplete();
        1;
    } or $log->error("Adapter detection could not be armed: $@");

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin')
      && Plugins::MaterialSkin::Plugin->can('registerHomeExtra') ) {
        eval {
            require Plugins::PitchforkReviews::HomeExtras;
            Plugins::PitchforkReviews::HomeExtras->initPlugin();
            $log->info("Registered Material Skin home extras (Best New Music + High Scoring Albums + Latest Reviews + Best Albums of the Year)");
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

    # COLLECT EXPIRED ROWS. Not just at startup: the sweep in DB::_migrate runs once per
    # process (dbh() caches the handle), and the rows that need collecting are the ones
    # nothing will read again — a review that rotated off the listing keeps its resolve
    # row for the full TTL and is never asked for — so the per-read cleanup in kvGet
    # cannot reach them either. Without this the table grows with UPTIME, which was
    # invisible on a server a backup restarts every morning.
    eval {
        require Plugins::PitchforkReviews::DB;
        my $gone = Plugins::PitchforkReviews::DB::kvSweep();
        dbg("kv: swept $gone expired row(s), " . Plugins::PitchforkReviews::DB::kvCount()
            . " remaining") if $gone;
        1;
    } or $log->warn("kv sweep failed: $@");

    # A warm that could not START (no player connected yet) is not a tick that has
    # been served — re-arm in seconds, not in WARM_INTERVAL. See warmCache.
    my $started = 0;
    eval {
        require Plugins::PitchforkReviews::Browse;
        $started = Plugins::PitchforkReviews::Browse::warmCache();
        1;
    } or $log->error("Home-shelf warm failed: $@");

    my $delay = _warmRetryDelay($started);
    dbg("warm: could not start (attempt $_warmFails) — retrying in ${delay}s") unless $started;
    Slim::Utils::Timers::setTimer(undef, time() + $delay, \&_warmTick);
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

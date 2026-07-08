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
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::OSDetect;
use File::Spec;

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

    # Hide reviews that didn't resolve to a playable streaming album (off = show all).
    hide_unmatched => 0,

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

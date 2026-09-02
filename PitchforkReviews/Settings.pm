package Plugins::PitchforkReviews::Settings;

# Settings page: streaming-service search priorities + the debug-log toggle.
#
# Per-view reading choices (how the review lists are grouped, how the year list is
# ordered) are NOT here — they are tap-to-change rows on the views themselves, the
# same convention as the sibling ListenBrainz plugin's sort toggles.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.pitchforkreviews');

sub name { 'PLUGIN_PITCHFORKREVIEWS' }

sub page { 'plugins/PitchforkReviews/settings.html' }

sub prefs {
    # NB `group_by` is deliberately absent: since 0.8.2 the grouping mode is flipped
    # by the "Grouped by …" row on the review views themselves (the fleet convention
    # for per-view reading choices), not here. The pref itself is unchanged.
    return ($prefs, qw(svc_priority_qobuz svc_priority_tidal svc_priority_deezer debug_log));
}

sub handler {
    my ($class, $client, $params) = @_;

    if ($params->{saveSettings}) {
        # Normalise the service priorities to integers 0-9 (0 = never search).
        # If a field is absent from the POST (a partial / non-form submission)
        # keep the CURRENT saved value rather than forcing 0 — forcing 0 would
        # silently disable that service on any incomplete save. (Ported from the
        # ListenBrainz Fresh Releases plugin.) These prefs are in the prefs()
        # list, so write the sanitised value back into $params BEFORE
        # SUPER::handler re-sets each pref from $params->{pref_*}.
        for my $svc (qw(qobuz tidal deezer)) {
            my $p = $params->{"pref_svc_priority_$svc"};
            if (defined $p && $p =~ /^\d+$/) {
                $p = 9 if $p > 9;
                $params->{"pref_svc_priority_$svc"} = $p + 0;
            }
            else {
                $params->{"pref_svc_priority_$svc"} = $prefs->get("svc_priority_$svc") // 0;
            }
        }

    }

    return $class->SUPER::handler($client, $params);
}

# Slim::Web::Settings::handler persists the POST, refreshes its own `prefs`
# template var from the store, and THEN calls this — the last hook before the
# template renders.
#
# ANY template variable derived from a pref MUST be built here, not in handler().
# `pfr_services` carries each service's CURRENT priority; built in handler() it
# was read BEFORE the save, so saving a new priority re-rendered the page with
# the old number still in the input (the save had actually applied — a reload
# showed it). Fixed 0.7.4.
sub beforeRender {
    my ($class, $params, $client) = @_;

    # Expose the detected streaming services (installed + current priority) to
    # the template so it can render each as detected / not installed.
    require Plugins::PitchforkReviews::Browse;
    $params->{pfr_services} = Plugins::PitchforkReviews::Browse::serviceStatus();
}

1;

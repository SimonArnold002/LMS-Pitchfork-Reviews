package Plugins::PitchforkReviews::Settings;

# Settings page: streaming-service search priorities + the debug-log toggle.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.pitchforkreviews');

sub name { 'PLUGIN_PITCHFORKREVIEWS' }

sub page { 'plugins/PitchforkReviews/settings.html' }

sub prefs {
    return ($prefs, qw(svc_priority_qobuz svc_priority_tidal svc_priority_deezer group_by debug_log));
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

        # Grouping mode is a fixed enum — keep the current value on any unexpected
        # (or absent) POST rather than writing garbage into the pref.
        my $gb = $params->{pref_group_by};
        unless (defined $gb && ($gb eq 'date' || $gb eq 'genre')) {
            $params->{pref_group_by} = $prefs->get('group_by') // 'date';
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

package Plugins::PitchforkReviews::Settings;

# Settings page: streaming-service search priorities + the debug-log toggle.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.pitchforkreviews');

sub name { 'PLUGIN_PITCHFORKREVIEWS' }

sub page { 'plugins/PitchforkReviews/settings.html' }

sub prefs {
    return ($prefs, qw(svc_priority_qobuz svc_priority_tidal svc_priority_deezer hide_unmatched debug_log));
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

    # Expose the detected streaming services (installed + current priority) to
    # the template so it can render each as detected / not installed.
    require Plugins::PitchforkReviews::Browse;
    $params->{pfr_services} = Plugins::PitchforkReviews::Browse::serviceStatus();

    return $class->SUPER::handler($client, $params);
}

1;

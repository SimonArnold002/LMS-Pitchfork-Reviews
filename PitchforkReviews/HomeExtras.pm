package Plugins::PitchforkReviews::HomeExtras;

# Material Skin home-page scrollable rows. Three shelves, each its own
# HomeExtraBase subclass (own tag -> own CLI dispatch -> own feed; separate
# packages avoid any shared per-class feed state):
#   - Best New Music       (PFRBnm     -> Browse::homeBnm)
#   - High Scoring Albums  (PFRHsa     -> Browse::homeHsa)
#   - Latest Reviews       (PFRReviews -> Browse::homeReviews)
# Each feed returns a FLAT card list that does not vary by request quantity, so
# deep home-shelf playback resolves the right item (see Browse::homeReviews for
# the item_id / quantity-stability rule).
#
# NB (cachetime): HomeExtraBase subclasses Slim::Plugin::OPMLBased and its
# handleExtra runs executeRequest($client, [<tag>,'items',...]) — the SAME
# Slim::Control::XMLBrowser path as the browse menu — so the `cachetime => 0` the
# home* feeds set (Browse.pm) is honoured here exactly as on the browse feeds.

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::PitchforkReviews::Browse;

use constant ICON => 'plugins/PitchforkReviews/html/images/PitchforkReviewsIcon_svg.png';

sub initPlugin {
    my ($class) = @_;

    # Best New Music
    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'PFRBnm',
        extra => { title => 'PLUGIN_PITCHFORKREVIEWS_HOME_BNM', icon => ICON, needsPlayer => 0 },
    );

    # High Scoring Albums + Latest Reviews (own packages, below)
    Plugins::PitchforkReviews::HomeHsa->initPlugin();
    Plugins::PitchforkReviews::HomeReviews->initPlugin();
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::PitchforkReviews::Browse::homeBnm($client, $cb, $args);
}


package Plugins::PitchforkReviews::HomeHsa;

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::PitchforkReviews::Browse;

sub initPlugin {
    my ($class) = @_;
    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'PFRHsa',
        extra => {
            title       => 'PLUGIN_PITCHFORKREVIEWS_HOME_HSA',
            icon        => Plugins::PitchforkReviews::HomeExtras::ICON,
            needsPlayer => 0,
        },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::PitchforkReviews::Browse::homeHsa($client, $cb, $args);
}


package Plugins::PitchforkReviews::HomeReviews;

use strict;
use base qw(Plugins::MaterialSkin::HomeExtraBase);

use Plugins::PitchforkReviews::Browse;

sub initPlugin {
    my ($class) = @_;
    $class->SUPER::initPlugin(
        feed  => \&feed,
        tag   => 'PFRReviews',
        extra => {
            title       => 'PLUGIN_PITCHFORKREVIEWS_HOME_REVIEWS',
            icon        => Plugins::PitchforkReviews::HomeExtras::ICON,
            needsPlayer => 0,
        },
    );
}

sub feed {
    my ($client, $cb, $args) = @_;
    Plugins::PitchforkReviews::Browse::homeReviews($client, $cb, $args);
}

1;

#!/usr/bin/env perl
# The Options/section headers across the list views and the detail page (0.8.4).
#
# WHY THIS EXISTS. Every view now leads with an "Options" Material divider and puts its
# content under its own heading — the fleet shape the sibling ListenBrainz plugin uses. Two
# things about that are easy to get wrong and invisible until someone looks at a real skin:
#
#   1. THE DETAIL PAGE CANNOT SEE `features`. XMLBrowser hands `features` to the TOP feed
#      only, never to a coderef sub-feed, so reviewDetail can't ask whether the client draws
#      headers — it has to be TOLD. `_reviewRow` stashes the answer as a SECOND passthrough
#      element; if that regresses, the detail page silently falls back to plain text on
#      Material, the one skin these dividers exist for, and nothing else breaks to warn you.
#   2. `$it` IS THE CACHED PARSED ITEM. The stash must never be written into it — a stray
#      key there is cached for the feed's whole TTL and travels into every other view.
#
# Also pinned: the $noIcon split (LIST headers keep the logo, because an image-less item
# disables Material's grid/list toggle for the WHOLE page; DETAIL headers drop it, as there
# is nothing to drill into), an empty Streaming section is omitted rather than shown empty,
# and a year-end entry's prose section is NOT called "Review" — it isn't one.
#
# Run from the repo root:  perl tools/t_sections.pl
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

# --- throwaway Slim::* tree (absent on a dev Mac) ---------------------------
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
{ no warnings 'once'; *Plugins::PitchforkReviews::Plugin::dbg = sub {}; }

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d (got '" . ($g // '') . "')", (($g // '') eq ($w // ''))) }

my $BR = 'Plugins::PitchforkReviews::Browse';

my %EN = (
    PLUGIN_PITCHFORKREVIEWS_SECTION_OPTIONS   => 'Options',
    PLUGIN_PITCHFORKREVIEWS_SECTION_STREAMING => 'Streaming',
    PLUGIN_PITCHFORKREVIEWS_SECTION_REVIEW    => 'Review',
    PLUGIN_PITCHFORKREVIEWS_SECTION_ENTRY     => 'About this album',
    PLUGIN_PITCHFORKREVIEWS_READ_REVIEW       => 'Read the full review',
    PLUGIN_PITCHFORKREVIEWS_READ_LIST         => 'Read the full list',
    PLUGIN_PITCHFORKREVIEWS_GENRE             => 'Genre',
    PLUGIN_PITCHFORKREVIEWS_REFRESH_MATCH     => 'Refresh streaming match',
    PLUGIN_PITCHFORKREVIEWS_REFRESH           => 'Refresh (force update now)',
    PLUGIN_PITCHFORKREVIEWS_GROUPED_BY        => 'Grouped by %s (tap to change)',
    PLUGIN_PITCHFORKREVIEWS_GROUP_BY_GENRE    => 'Genre',
    PLUGIN_PITCHFORKREVIEWS_EMPTY             => 'No reviews found',
    PLUGIN_PITCHFORKREVIEWS_GENRE_OTHER       => 'Other',
);
# Browse.pm imported cstring at compile time, so its OWN alias is what must be swapped.
no warnings 'redefine', 'once';
*Plugins::PitchforkReviews::Browse::cstring = sub { $EN{$_[1]} // $_[1] };

my $REVIEW = { artist => 'Dijon', album => 'Baby', capsule => 'A capsule.',
               genre => 'Pop', link => 'https://pitchfork.com/r/', date => '2025-12-02T00:00:00Z' };
my $ENTRY  = { artist => 'Dijon', album => 'Baby', capsule => 'A capsule.', rank => 2,
               year => 2025, genre => '', link => 'https://pitchfork.com/list/' };

sub detail {
    my ($it, $stream, $headers) = @_;
    local *Plugins::PitchforkReviews::Browse::_findPlayable =
        sub { $_[1]->({ items => $stream }) };
    my $res;
    $BR->can('reviewDetail')->(undef, sub { $res = shift }, {}, $it, { headers => $headers });
    return @{ $res->{items} };
}

my @ALBUM = ({ name => 'Qobuz album', type => 'playlist', _svc => 'Qobuz' });

print "--- detail page: three sections ---\n";
{
    my @it = detail($REVIEW, [@ALBUM], 1);
    is('row 0 is the Options header',      $it[0]{name}, 'Options');
    is('...then the refresh action',       $it[1]{name}, 'Refresh streaming match');
    is('then the Streaming header',        $it[2]{name}, 'Streaming');
    is('...then the playable album',       $it[3]{name}, 'Qobuz album');
    is('then the Review header',           $it[4]{name}, 'Review');
    is('...genre',                         $it[5]{name}, 'Genre: Pop');
    is('...capsule',                       $it[6]{name}, 'A capsule.');
    is('...and the link last',             $it[7]{name}, 'Read the full review');
    is('nothing else',                     scalar(@it), 8);
    ok('the album row is still playable',  $it[3]{type} eq 'playlist');

    # THE trap: reviewDetail is a coderef sub-feed, so it never receives
    # `features` and can only know this from the row's stash. If that stash stops
    # being read, every header here silently degrades to plain text on Material
    # and nothing else about the page changes.
    ok('all three headers render as real dividers, not text',
       3 == grep { $_->{name} =~ /^(Options|Streaming|Review)$/ && $_->{type} ne 'text' } @it);
}

print "--- detail page: an empty Streaming section is omitted, not shown empty ---\n";
{
    my @it = detail($REVIEW, [], 1);
    ok('no Streaming header when nothing resolved', !grep { $_->{name} eq 'Streaming' } @it);
    is('Options still leads',                       $it[0]{name}, 'Options');
    is('and the Review section still renders',      $it[2]{name}, 'Review');
    is('the capsule survives an unmatched review',  $it[4]{name}, 'A capsule.');
}

print "--- detail page: ...and what _findPlayable ACTUALLY hands back is not a list ---\n";
# THE ABOVE TEST WAS VACUOUS UNTIL 0.8.10, and this is the one that isn't. A literal []
# is a shape the resolver never produces: _findPlayable answers through _streamResult,
# which turns a no-match into a ONE-ELEMENT "No matching album" text row. So the real
# no-match page went down the `if @$streamItems` branch every time and drew the Streaming
# divider directly over the placeholder it was written to suppress. Only the detail
# watchdog (which passes a literal []) ever reached the omission. The section must
# therefore be decided by whether a row is a real service node (`_svc`), not by count.
{
    my @it = detail($REVIEW, [ { name => 'No matching album found on your services', type => 'text' } ], 1);
    ok('no Streaming header over a no-match placeholder',
       !grep { $_->{name} eq 'Streaming' } @it);
    ok('...and no bare placeholder row left behind either',
       !grep { ($_->{name} // '') =~ /^No matching album/ } @it);
    is('Options still leads',                  $it[0]{name}, 'Options');
    is('and the Review section still renders', $it[2]{name}, 'Review');

    # ...while a REAL match is still sectioned exactly as before.
    my @m = detail($REVIEW, [ @ALBUM, { name => 'A note', type => 'text' } ], 1);
    is('a real match still draws the Streaming header', $m[2]{name}, 'Streaming');
    is('...with the album under it',                    $m[3]{name}, 'Qobuz album');
    ok('and a non-service row is not carried into the section',
       !grep { ($_->{name} // '') eq 'A note' } @m);
}

print "--- detail page: a year entry is not a review ---\n";
{
    my @it = detail($ENTRY, [@ALBUM], 1);
    is('prose section is "About this album"', $it[4]{name}, 'About this album');
    is('...and the link says "list"',         $it[-1]{name}, 'Read the full list');
    ok('no section claims to be a Review',    !grep { $_->{name} eq 'Review' } @it);
    ok('no empty Genre row (entries carry none)', !grep { ($_->{name}//'') =~ /^Genre:/ } @it);
}

print "--- detail page: headers off ---\n";
{
    my @rich  = detail($REVIEW, [@ALBUM], 1);
    my @plain = detail($REVIEW, [@ALBUM], 0);
    is('a plain client loses no rows', scalar(@plain), scalar(@rich));
    is('the headers become text',      $plain[0]{type}, 'text');
    ok('...all of them',
       3 == grep { $_->{type} eq 'text' && $_->{name} =~ /^(Options|Streaming|Review)$/ } @plain);
    ok('and carry no drill action', !grep { $_->{name} =~ /^(Options|Streaming|Review)$/ && $_->{url} } @plain);
}

print "--- detail headers drop the icon, list headers keep it ---\n";
{
    my @it = detail($REVIEW, [@ALBUM], 1);
    ok('no detail section header carries an image',
       !grep { $_->{name} =~ /^(Options|Streaming|Review)$/ && defined $_->{image} } @it);

    # A LIST header must keep its image: an image-less item sets haveWithoutIcons
    # and disables Material's grid/list toggle for the whole page.
    my $listHdr = $BR->can('_sectionHeader')->(undef, 'Options', 1, [], 0);
    ok('a list section header keeps its image', length($listHdr->{image} // ''));
}

print "--- the header capability reaches the detail page from the row ---\n";
{
    my $row = $BR->can('_reviewRow')->(undef, $REVIEW, 1);
    is('the row drills into the detail page', ref $row->{url}, 'CODE');
    is('$it is passthrough 0',                $row->{passthrough}[0], $REVIEW);
    is('headers ride as a SEPARATE element',  $row->{passthrough}[1]{headers}, 1);

    my $off = $BR->can('_reviewRow')->(undef, $REVIEW, 0);
    is('...and is 0 when the client has none', $off->{passthrough}[1]{headers}, 0);
    my $undef = $BR->can('_reviewRow')->(undef, $REVIEW);
    is('an omitted argument coerces to 0, never undef', $undef->{passthrough}[1]{headers}, 0);

    # The cached parsed item must come back untouched.
    ok('the stash is NOT written into the cached item', !exists $REVIEW->{headers});
    is('...and the item still has exactly its own keys',
       join(',', sort keys %$REVIEW), 'album,artist,capsule,date,genre,link');
}

print "--- list view: Options section then the grouped content ---\n";
{
    my %stored = (group_by => 'genre');
    local *T::Prefs::get = sub { $stored{$_[1]} };
    local *T::Prefs::set = sub { $stored{$_[1]} = $_[2] };
    my @items = ( { %$REVIEW }, { %$REVIEW, album => 'Second' } );
    local *Plugins::PitchforkReviews::API::getListing = sub { $_[0]->([ @items ]) };
    local *Plugins::PitchforkReviews::Browse::_resolveSection = sub { $_[2]->() };

    my $res;
    $BR->can('fetchFeed')->(undef, sub { $res = shift }, {}, { source => 'reviews', features => 'h' });
    my @it = @{ $res->{items} };

    is('row 0 is the Options header',   $it[0]{name}, 'Options');
    ok('...as a divider',               $it[0]{type} ne 'text');
    ok('...keeping its image',          length($it[0]{image} // ''));
    ok('the action rows follow',
       $it[1]{name} =~ /^Refresh/ && $it[2]{name} =~ /^Grouped by/);
    ok('then a genre divider before the reviews', $it[3]{type} ne 'text');
    is('then the review rows',          $it[4]{name}, 'Dijon - Baby');

    ok('tapping the Options header returns its own two rows',
       do { my $o; $it[0]{url}->(undef, sub { $o = $_[0] }); scalar @{ $o->{items} } } == 2);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

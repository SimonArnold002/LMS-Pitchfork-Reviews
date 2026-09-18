#!/usr/bin/env perl
# THE OLD WEB SKINS (Default / Classic) — the web pass ported from the sibling
# ListenBrainz plugin (LBF 1.0.7-1.0.12). Those skins render the feed server-side
# through Slim::Web::XMLBrowser (isWeb at every level); Material goes through
# Slim::Control::XMLBrowser and never sets it. So every web assertion here is paired
# with a CONTROL proving the Material shape did not move.
#
# Run from the repo root:  perl tools/t_webskin.pl      (PFR_BROWSE=<copy> to anti-test)
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
    PLUGIN_PITCHFORKREVIEWS_VIEW_BY           => 'View: %s (tap to change)',
    PLUGIN_PITCHFORKREVIEWS_GROUP_BY_GENRE    => 'Genre',
    PLUGIN_PITCHFORKREVIEWS_VIEW_SCORE        => 'Score',
    PLUGIN_PITCHFORKREVIEWS_EMPTY             => 'No reviews found',
    PLUGIN_PITCHFORKREVIEWS_GENRE_OTHER       => 'Other',
);
# Browse.pm imported cstring at compile time, so its OWN alias is what must be swapped.
no warnings 'redefine', 'once';
*Plugins::PitchforkReviews::Browse::cstring = sub { $EN{$_[1]} // $_[1] };


$EN{PLUGIN_PITCHFORKREVIEWS_WEB_BACK} = 'Updated - back to the list';
$EN{PLUGIN_PITCHFORKREVIEWS_SETTINGS} = 'Settings';
{ package Slim::Web::ImageProxy;
  sub proxiedImage { my ($u) = @_; (my $e = $u) =~ s/([^A-Za-z0-9._~-])/sprintf('%%%02X', ord $1)/ge;
                     return "imageproxy/$e/image.jpg" } }

my $W = sub { $BR->can('_webify')->(@_) };
my $REVIEW = { artist => 'Dijon', album => 'Baby <3', capsule => 'A <b>capsule</b> & more.',
               genre => 'Pop', link => 'https://pitchfork.com/r/', date => '2025-12-02T00:00:00Z' };

sub detail {
    my ($it, $stream, $headers) = @_;
    local *Plugins::PitchforkReviews::Browse::_findPlayable = sub { $_[1]->({ items => $stream }) };
    local *Plugins::PitchforkReviews::Browse::_findPlayableReview = sub { $_[1]->({ items => $stream }) };
    my $res;
    $BR->can('reviewDetail')->(undef, sub { $res = shift }, {}, $it, { headers => $headers });
    return $res;
}
my @ALBUM = ({ name => 'Qobuz album', type => 'playlist', _svc => 'Qobuz', image => 'q.jpg' });

print "--- 1. the discriminator ---\n";
ok('isWeb is a web skin', $BR->can('_webSkin')->({ isWeb => 1 }));
ok('a CLI request with feedMode is a web skin', $BR->can('_webSkin')->({ isControl => 1, params => { feedMode => 1 } }));
ok('CONTROL: Material (no isWeb, no feedMode) is not', !$BR->can('_webSkin')->({ isControl => 1, params => { features => 'hi' } }));

print "--- 2. the release page ---\n";
{
    my $web = $W->(detail($REVIEW, [@ALBUM], 0));
    my @it  = @{ $web->{items} };
    my @div = grep { ($_->{name} // '') =~ /^<div style="font-weight:bold/ } @it;
    is('three styled headings (Options, Streaming, Review)', scalar(@div), 3);
    ok('... all textarea, with no image and no drill url',
       !grep { $_->{type} ne 'textarea' || exists $_->{image} || exists $_->{url} } @div);
    ok('... and the label is inside the heading', scalar(grep { $_->{name} =~ />Options<\/div>$/ } @div) == 1);
    ok('... in Pitchfork red, text and rule alike', !grep { $_->{name} !~ /color:#e8292e;.*border-bottom:2px solid #e8292e/ } @div);
    my ($cap) = grep { ($_->{name} // '') =~ /capsule/ } @it;
    is('the capsule is a textarea', $cap->{type}, 'textarea');
    is('... and ESCAPED, since a textarea is printed raw', $cap->{name}, 'A &lt;b&gt;capsule&lt;/b&gt; &amp; more.');
    my ($read) = grep { ($_->{weblink} // '') eq 'https://pitchfork.com/r/' } @it;
    ok('Read the full review carries the Pitchfork mark on the web', ($read->{image} // '') =~ /PitchforkReviewsIcon\.png$/);
    my ($ref) = grep { ($_->{nextWindow} // '') eq 'refresh' } @it;
    ok('Refresh streaming match carries the refresh icon on the web', ($ref->{image} // '') =~ /pfr-refresh_MTL_icon_refresh\.png$/);
    ok('no private key leaks into a web row', !grep { exists $_->{_div} || exists $_->{_webimg} } @it);
    my ($alb) = grep { ($_->{_svc} // '') eq 'Qobuz' } @it;
    is('CONTROL: the playable album row keeps its type', $alb->{type}, 'playlist');

    my $mat = detail($REVIEW, [@ALBUM], 1);
    my @m   = @{ $mat->{items} };
    is('CONTROL: Material keeps three header dividers', scalar(grep { ($_->{type} // '') =~ /^header/ } @m), 3);
    my ($mref) = grep { ($_->{nextWindow} // '') eq 'refresh' } @m;
    ok('CONTROL: Material\'s Refresh row gets NO image', !exists $mref->{image});
    my ($mread) = grep { ($_->{weblink} // '') eq 'https://pitchfork.com/r/' } @m;
    ok('CONTROL: Material\'s review link gets NO image', !exists $mread->{image});
    my ($mcap) = grep { ($_->{name} // '') =~ /capsule/ } @m;
    is('CONTROL: Material\'s capsule is untouched text', $mcap->{type}, 'text');
}

print "--- 3. list dividers (genre / week) ---\n";
for my $fn (qw(_genreRows _weeklyRows)) {
    my $rows = $BR->can($fn)->(undef, [ { %$REVIEW }, { %$REVIEW, genre => 'Rock' } ], 0);
    my @w = @{ $W->($rows) };
    my @d = grep { ($_->{type} // '') eq 'textarea' } @w;
    ok("$fn: web dividers are styled textareas with no logo thumbnail",
       @d >= 1 && !grep { exists $_->{image} || $_->{name} !~ /^<div style="font-weight:bold/ } @d);
    my @raw = @{ $BR->can($fn)->(undef, [ { %$REVIEW } ], 0) };
    ok("CONTROL: $fn untouched by the pass still emits text + logo (a plain controller)",
       ($raw[0]{type} // '') eq 'text' && ($raw[0]{image} // '') =~ /_svg\.png$/);
}

print "--- 4. toggles bounce back instead of opening a dead page ---\n";
{
    no warnings 'redefine';
    local *Plugins::PitchforkReviews::Browse::_setHomeYearTitle = sub {};
    local *T::Prefs::set = sub {};
    my ($tog) = @{ $W->([ $BR->can('_groupToggle')->(undef, 'genre') ]) };
    my $got; $tog->{url}->(undef, sub { $got = shift }, {});
    ok('View toggle: the empty answer becomes a one-level bounce',
       ($got->{items}[0]{name} // '') =~ /i\.splice\(-1,1\)/ && $got->{items}[0]{type} eq 'textarea');
    local *Plugins::PitchforkReviews::API::yearsAvailable = sub { $_[0]->([2025, 2024]) };
    my $picker; $BR->can('yearPicker')->(undef, sub { $picker = shift }, {});
    my ($row) = @{ $W->([ $picker->{items}[0] ]) };
    my $g2; $row->{url}->(undef, sub { $g2 = shift }, {});
    ok('a year pick (nextWindow parent) bounces TWO levels', ($g2->{items}[0]{name} // '') =~ /i\.splice\(-2,2\)/);
    my $plain = $W->([ { name => 'x', type => 'link', url => sub { $_[1]->({ items => [] }) } } ])->[0];
    my $g3; $plain->{url}->(undef, sub { $g3 = shift }, {});
    ok('CONTROL: an empty answer from a row with no nextWindow is passed through', !@{ $g3->{items} });
    my $seen;
    my $kid = $W->([ { name => 'k', type => 'link', url => sub { $seen = $_[2]; $_[1]->({ items => [ { name => 'a<b', type => 'text' } ] }) } } ])->[0];
    my $g4; $kid->{url}->(undef, sub { $g4 = shift }, { lbf => 1 });
    ok('a wrapped child is called with isWeb', $seen->{isWeb} && $seen->{lbf});
    is('... and its answer is webified too', $g4->{items}[0]{name}, 'a&lt;b');
}

print "--- 5. the top level ---\n";
{
    my $web; $BR->can('topLevel')->(undef, sub { $web = shift }, { isWeb => 1 });
    my ($s) = grep { defined $_->{weblink} } @{ $web->{items} };
    is('web: Settings links RELATIVE to the browse page, so it opens in that skin', $s->{weblink}, '../PitchforkReviews/settings.html');
    require URI;
    is('... which resolves inside the skin',
       URI->new_abs($s->{weblink}, 'http://plex:9000/Classic/plugins/pitchforkreviews/index.html?player=x')->path,
       '/Classic/plugins/PitchforkReviews/settings.html');
    my @tiles = grep { ref $_->{url} eq 'CODE' } @{ $web->{items} };
    ok('web: every tile\'s url is WRAPPED (not the raw feed sub), so levels below know it is a web skin',
       @tiles == 4 && !grep { $_->{url} == \&Plugins::PitchforkReviews::Browse::fetchFeed
                           || $_->{url} == \&Plugins::PitchforkReviews::Browse::fetchYearFeed } @tiles);
    my $matT; $BR->can('topLevel')->(undef, sub { $matT = shift }, {});
    ok('CONTROL: Material\'s tiles are the raw feed subs',
       scalar(grep { ref $_->{url} eq 'CODE' && $_->{url} == \&Plugins::PitchforkReviews::Browse::fetchFeed } @{ $matT->{items} }) == 3);
    my $mat; $BR->can('topLevel')->(undef, sub { $mat = shift }, { params => { features => 'hi' } });
    my ($ms) = grep { defined $_->{weblink} } @{ $mat->{items} };
    is('CONTROL: Material keeps the absolute settings path', $ms->{weblink}, '/plugins/PitchforkReviews/settings.html');
}

print "\n$p passed, $f failed\n";
exit($f ? 1 : 0);

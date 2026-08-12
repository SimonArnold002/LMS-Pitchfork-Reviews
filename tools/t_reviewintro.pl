#!/usr/bin/env perl
# What a MATCHED review row's drill-in hands back (0.7.12).
#
# WHY THIS EXISTS. The review capsule used to live in exactly one place — `reviewDetail` —
# and a MATCHED row never reaches it: `_reviewRow` returns the streaming album node instead,
# and its tracklist drill-in is wrapped by `_attachReviewLink`. So the better a review
# resolved, the less of it you could read; the capsule only ever appeared when the album
# could NOT be found on Qobuz/Tidal/Deezer. 0.7.12 moved it into the wrapper.
#
# Two things are asserted together, because the fix is only correct if BOTH hold: the review
# rows are there, AND the tracklist underneath is untouched (same rows, same order, nothing
# injected that play traversal could mistake for audio) — the row is a `type => 'playlist'`
# node and Play/Add from the list must still queue the album.
#
# Runs the REAL sub from Browse.pm against throwaway Slim::* stubs defined below, so a change
# to the sub fails here. Run from the repo root:  perl tools/t_reviewintro.pl
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
                                  sub cstring { $_[1] } sub string { $_[0] }   # returns the token, so it is assertable
    package Slim::Utils::Timers;  sub setTimer {} sub killTimers {}
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
my $PATH   = $BROWSE =~ m{^/} ? $BROWSE : "./$BROWSE";   # `do` searches @INC for a bare relative path
$INC{'Plugins/PitchforkReviews/Browse.pm'} = $BROWSE;
do $PATH or die "can't load $BROWSE: " . ($@ || $!);

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d (got '" . ($g // '') . "')", (($g // '') eq ($w // ''))) }

# A service tracklist coderef as Qobuz/Tidal/Deezer supply it — INCLUDING the non-audio
# tail Qobuz appends after the tracks, which is why an injected "Genre: …" row of our own
# would be a duplicate title (see below).
my @TRACKS = (
    { name => 'kiss me',    type => 'audio', play => 'qobuz://1' },
    { name => 'stay',       type => 'audio', play => 'qobuz://2' },
    { name => 'Genre: Pop', type => 'text' },
);
sub inner_hash  { my (undef, $cb) = @_; $cb->({ items => [ @TRACKS ] }) }
sub inner_array { my (undef, $cb) = @_; $cb->([ @TRACKS ]) }

sub render {
    my ($it, $innerRef) = @_;
    my $row = { name => 'Ariana Grande - petal', type => 'playlist', url => ($innerRef || \&inner_hash) };
    Plugins::PitchforkReviews::Browse::_attachReviewLink(undef, $row, $it);
    my @out;
    $row->{url}->(undef, sub { @out = @{ $_[0]{items} } }, {}, {});
    return ($row, \@out);
}

my $CAP  = 'On its third album, the Philadelphia sibling duo crafts folk-pop gems.';
my $LINK = 'https://pitchfork.com/reviews/albums/x/';

# --- 1. capsule + link: the whole point of the change ------------------------
{
    my ($row, $out) = render({ capsule => $CAP, link => $LINK, genre => 'Pop' });
    is('capsule is row 0, IN FULL',          $out->[0]{name}, $CAP);
    is('capsule row is text',                $out->[0]{type}, 'text');
    is('review link is row 1',               $out->[1]{name}, 'PLUGIN_PITCHFORKREVIEWS_READ_REVIEW');
    is('link keeps its weblink',             $out->[1]{weblink}, $LINK);
    is('spacer is row 2',                    $out->[2]{name}, "\x{a0}");
    is('tracks start at row 3',              $out->[3]{name}, 'kiss me');
    ok('the whole tracklist survives, in order',
        $out->[3]{name} eq 'kiss me' && $out->[4]{name} eq 'stay' && $out->[5]{name} eq 'Genre: Pop');
    is('nothing else injected',              scalar @$out, 6);
    ok('row stays playable (type playlist)', $row->{type} eq 'playlist');
    ok('no injected row is audio',
        !grep { ($_->{type} // '') eq 'audio' || $_->{play} } @$out[0..2]);
    # The Material duplicate-title trap: non-playable plugin rows key by parent id + TITLE,
    # so our "Genre: Pop" and the service's own would collide and one would vanish.
    ok('no second "Genre:" row injected',
        1 == grep { ($_->{name} // '') =~ /^Genre:/ } @$out);
}

# --- 2. capsule but NO link (the old guard dropped BOTH) ---------------------
{
    my (undef, $out) = render({ capsule => $CAP, link => '' });
    is('capsule still shown without a link', $out->[0]{name}, $CAP);
    is('spacer follows it',                  $out->[1]{name}, "\x{a0}");
    is('then the tracks',                    $out->[2]{name}, 'kiss me');
}

# --- 3. link but NO capsule: unchanged 0.7.11 behaviour ---------------------
{
    my (undef, $out) = render({ link => $LINK });
    is('link is row 0 when there is no capsule', $out->[0]{name}, 'PLUGIN_PITCHFORKREVIEWS_READ_REVIEW');
    is('spacer is row 1',                        $out->[1]{name}, "\x{a0}");
    is('tracks start at row 2',                  $out->[2]{name}, 'kiss me');
}

# --- 4. neither: the node must be left completely alone ---------------------
{
    my $row = { name => 'x', type => 'playlist', url => \&inner_hash };
    Plugins::PitchforkReviews::Browse::_attachReviewLink(undef, $row, { capsule => '', link => '' });
    ok('no capsule and no link -> url NOT wrapped', $row->{url} == \&inner_hash);
}

# --- 5. a service that hands back a bare ARRAY ------------------------------
{
    my (undef, $out) = render({ capsule => $CAP, link => $LINK }, \&inner_array);
    is('ARRAY response: capsule first', $out->[0]{name}, $CAP);
    is('ARRAY response: tracks kept',   $out->[3]{name}, 'kiss me');
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

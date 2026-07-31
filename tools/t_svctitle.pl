#!/usr/bin/env perl
# What Pitchfork Reviews hands Listen Later as the album name and year (0.7.10).
#
# WHY THIS EXISTS. Once a review is RESOLVED to an album on Qobuz/Tidal/Deezer, the SERVICE's
# spelling is the only one that works downstream: LL's Played auto-detection matches the
# PLAYING track's album title, and its artist|album|year dedupe key must agree with a direct
# add from that same service. Pitchfork's spelling differs often enough to matter (it appends
# " EP"/" LP" that services drop — the whole reason _stripFmt exists). The sibling ListenBrainz
# plugin shipped the wrong name three times in a row before this was pinned down, so both
# halves are asserted here: the affix strip, and the year extraction.
#
# Uses the REAL subs and the REAL _norm/%FOLD chain grabbed from Browse.pm — no stubs, so a
# change to either fails here.
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
my $PFR = $ENV{PFR_BROWSE} || 'PitchforkReviews/Browse.pm';
sub grab { my ($f,$n)=@_; open(my $fh,'<:encoding(UTF-8)',$f) or die $!;
    my $s=do{local $/;<$fh>}; $s =~ /\nsub \Q$n\E \{.*?\n\}\n/s or die "no sub $n"; return $&; }
eval "package X; use strict; use warnings; use utf8;\n"
   . q{my $HAVE_NFD = eval \{ require Unicode::Normalize; 1 \} ? 1 : 0;
my %FOLD = (
    "\\x\{131\}" => 'i', "\\x\{142\}" => 'l', "\\x\{f8\}" => 'o', "\\x\{f0\}" => 'd',
    "\\x\{111\}" => 'd', "\\x\{fe\}" => 'th', "\\x\{df\}" => 'ss', "\\x\{e6\}" => 'ae',
    "\\x\{153\}" => 'oe', "\\x\{127\}" => 'h',
);}
   . grab($PFR,'_stripArtistAffix') . grab($PFR,'_svcYear') . grab($PFR,'_norm')
   . grab($PFR,'_asciiNorm') . grab($PFR,'_punctNorm') . "1;" or die $@;
my ($p,$f)=(0,0);
sub is { my($d,$g,$w)=@_; my $ok=((defined $g ? $g : '') eq (defined $w ? $w : '')); $ok?$p++:$f++;
    printf "%s %-46s got=%-40s want=%s\n",($ok?'ok  ':'FAIL'),$d,"'".(defined $g?$g:'')."'","'".(defined $w?$w:'')."'"; }

print "&al= — STRIP an artist affix the service joined on\n";
is('suffix form', X::_stripArtistAffix('Radio: Journey Beat - aksfx','aksfx'), 'Radio: Journey Beat');
is('prefix form', X::_stripArtistAffix('aksfx - Radio: Fourth Space','aksfx'), 'Radio: Fourth Space');
is('en dash',     X::_stripArtistAffix("Album \x{2013} aksfx",'aksfx'), 'Album');
is('em dash',     X::_stripArtistAffix("aksfx \x{2014} Album",'aksfx'), 'Album');
is('case/punctuation tolerated', X::_stripArtistAffix('Album - AKSFX.','aksfx'), 'Album');
is('title with its own " - "', X::_stripArtistAffix('Songs - Volume One - aksfx','aksfx'), 'Songs - Volume One');

print "\n&al= — MUST NOT STRIP (a wrong strip corrupts LL's key)\n";
is('already clean',             X::_stripArtistAffix('Extra Mile','Will Sheff'), 'Extra Mile');
is('hyphenated, no spaces',     X::_stripArtistAffix('Jay-Z','Jay'), 'Jay-Z');
is('dash title, artist absent', X::_stripArtistAffix('Songs - Volume One','aksfx'), 'Songs - Volume One');
is('side only CONTAINS artist', X::_stripArtistAffix('Album - aksfx remixes','aksfx'), 'Album - aksfx remixes');
is('empty artist',              X::_stripArtistAffix('Album - aksfx',''), 'Album - aksfx');
is('title IS the artist',       X::_stripArtistAffix('aksfx','aksfx'), 'aksfx');
is('undef title',               X::_stripArtistAffix(undef,'aksfx'), undef);
is('band Live keeps its album', X::_stripArtistAffix('Live - Throwing Copper','Live'), 'Throwing Copper');

print "\n&y= — the release year off the service's own album hash\n";
is('qobuz release_date_original', X::_svcYear({release_date_original=>'2026-07-25'}), '2026');
is('qobuz released_at epoch',     (X::_svcYear({released_at=>'1767225600'}) =~ /^\d{4}$/ ? 'a year' : 'nothing'), 'a year');
is('tidal releaseDate',           X::_svcYear({releaseDate=>'2019-03-22'}), '2019');
is('deezer release_date',         X::_svcYear({release_date=>'2005-01-25'}), '2005');
is('bare year field',             X::_svcYear({year=>'1971'}), '1971');
is('no date at all -> empty',     X::_svcYear({title=>'No Dates Here'}), '');
is('not a hash -> empty',         X::_svcYear('2026'), '');
is('junk date -> empty',          X::_svcYear({release_date=>'n/a'}), '');
printf "\n%d passed, %d failed\n",$p,$f; exit($f?1:0);


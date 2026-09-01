#!/usr/bin/env perl
# HTML-entity decoding of Pitchfork's review text (0.7.12).
#
# WHY THIS EXISTS. Pitchfork's Verso state carries entity-encoded text — `&#8212;` in 16 of
# 133 live capsules, plus `&amp;` and `&quot;` — and the plugin was showing it raw. That was
# never only cosmetic: `_norm` folds "&" to the word "and", so an album titled
# "Love &amp; Devotion" keyed as "love and amp devotion" and could not match the service's
# "Love & Devotion", leaving the review permanently unresolved. The last assertion here is
# that payoff, checked against the REAL `_norm` grabbed from Browse.pm.
#
# The traps this guards, in order of how easy they are to reintroduce:
#   1. ONE PASS. "&amp;lt;" must decode to "&lt;" — what the review wrote — not to "<".
#      A decode-until-stable loop, or handling &amp; in its own substitution, double-decodes.
#   2. STRIP TAGS FIRST, THEN DECODE. "&lt;em&gt;" is literal text; decoding first turns it
#      into a tag that the strip then eats.
#   3. UNKNOWN ENTITIES PASS THROUGH VERBATIM rather than being guessed at or dropped.
#   4. Codepoints that are not safe to substitute (controls, surrogates, past Unicode) are
#      refused — chr() would hand back something that later breaks an md5 cache key.
#
# Run from the repo root:  perl tools/t_entities.pl
use strict; use warnings; use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

# --- throwaway stubs: enough to LOAD API.pm, nothing more -------------------
BEGIN {
    $INC{'Slim/Networking/SimpleAsyncHTTP.pm'} = $INC{'Slim/Utils/Cache.pm'}
        = $INC{'Slim/Utils/Log.pm'} = $INC{'JSON/XS/VersionOneAndTwo.pm'} = $INC{'Plugins/PitchforkReviews/DB.pm'} = __FILE__;
}

{
    # In-memory stand-in for the list DATABASE (0.9.8). The suites here test feed and
    # year LOGIC, not storage — DB.pm has its own suite against real SQLite (t_db.pl).
    # Keeping it in memory also makes what was stored directly assertable.
    package Plugins::PitchforkReviews::DB;
    our (%LISTS, %VER, %AGE);
    sub getList {
        my ($k, $v) = @_;
        return undef unless $LISTS{$k};
        return undef if defined $v && defined $VER{$k} && $VER{$k} != $v;
        return $LISTS{$k};
    }
    sub putList {
        my ($k, $i, $v) = @_;
        return 0 unless ref $i eq 'ARRAY' && @$i;
        $LISTS{$k} = $i; $VER{$k} = $v; $AGE{$k} = 0;
        return 1;
    }
    sub listAge    { exists $LISTS{$_[0]} ? ($AGE{$_[0]} // 0) : undef }
    sub forget     { delete $LISTS{$_[0]}; delete $AGE{$_[0]}; delete $VER{$_[0]}; 1 }
    sub forgetAll  { %LISTS = (); %AGE = (); %VER = (); 1 }
    sub storedKeys { sort keys %LISTS }
    sub reset_db   { %LISTS = (); %AGE = (); %VER = ();  kvReset(); }
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
{
    package Slim::Networking::SimpleAsyncHTTP; sub new { bless {}, shift } sub get {}
    package Slim::Utils::Cache;   sub new { bless {}, shift } sub get {} sub set {}
    package Slim::Utils::Log;     use Exporter 'import'; our @EXPORT = qw(logger);
                                  sub logger { bless {}, 'T::Log' }
    package T::Log;               our $AUTOLOAD; sub AUTOLOAD {}
    package JSON::XS::VersionOneAndTwo; use Exporter 'import'; our @EXPORT = qw(from_json to_json);
                                  sub from_json { die 'not used by this test' } sub to_json { die }
}

my $API = $ENV{PFR_API} || 'PitchforkReviews/API.pm';
$INC{'Plugins/PitchforkReviews/API.pm'} = $API;
do($API =~ m{^/} ? $API : "./$API") or die "can't load $API: " . ($@ || $!);

my ($p, $f) = (0, 0);
sub ok { my ($d, $c) = @_; $c ? $p++ : $f++; printf "%s %s\n", ($c ? 'ok  ' : 'FAIL'), $d }
sub is { my ($d, $g, $w) = @_; ok("$d  ->  '" . ($g // '') . "'", (($g // '') eq ($w // ''))) }

sub dec  { Plugins::PitchforkReviews::API::_decodeEntities($_[0]) }
sub strip { Plugins::PitchforkReviews::API::_stripTags($_[0]) }

# --- the entities Pitchfork actually emits (all four seen in live data) ------
is('&amp; (album titles)',     dec('Love &amp; Devotion'),        'Love & Devotion');
is('&#8212; em dash (16/133 capsules)', dec('spectrum&#8212;techno'), "spectrum\x{2014}techno");
is('&quot;',                   dec('a 2x12&quot;, another pin'),  'a 2x12", another pin');
is('&amp; mid-capsule',        dec('her R&amp;B ethos'),          'her R&B ethos');

# --- the rest of the table + numeric forms ----------------------------------
is('&lt; &gt;',                dec('&lt;3 &gt;_&lt;'),            '<3 >_<');
is('&apos;',                   dec('Don&apos;t'),                 "Don't");
is('&nbsp; -> PLAIN space, not U+00A0', dec('Sun&nbsp;Ra'),       'Sun Ra');
is('&rsquo;',                  dec('Kelela&rsquo;s'),             "Kelela\x{2019}s");
is('&hellip;',                 dec('and then&hellip;'),           "and then\x{2026}");
is('hex numeric &#x2014;',     dec('a&#x2014;b'),                 "a\x{2014}b");
is('hex numeric, capital X',   dec('a&#X2014;b'),                 "a\x{2014}b");
is('decimal &#233;',           dec('caf&#233;'),                  "caf\x{e9}");
is('several in one string',    dec('R&amp;B&#8212;&quot;yes&quot;'), "R&B\x{2014}\"yes\"");

# --- TRAP 1: one pass, no double-decoding -----------------------------------
is('&amp;lt; decodes ONCE',    dec('&amp;lt;'),                   '&lt;');
is('&amp;amp; decodes ONCE',   dec('&amp;amp;'),                  '&amp;');
is('&amp;#8212; decodes ONCE', dec('&amp;#8212;'),                '&#8212;');

# --- TRAP 3: anything unrecognised is left exactly as it was -----------------
is('unknown named entity kept',dec('&nosuchthing; here'),         '&nosuchthing; here');
is('bare & kept',              dec('Simon & Garfunkel'),          'Simon & Garfunkel');
is('& with no semicolon kept', dec('AT&amp T'),                   'AT&amp T');
is('empty entity kept',        dec('&; &#;'),                     '&; &#;');
is('no & at all: untouched',   dec('nothing to do here'),         'nothing to do here');
is('undef in, empty out',      dec(undef),                        '');

# --- TRAP 4: codepoints we refuse to substitute -----------------------------
is('NUL refused',              dec('a&#0;b'),                     'a&#0;b');
is('bell refused',             dec('a&#7;b'),                     'a&#7;b');
is('DEL refused',              dec('a&#127;b'),                   'a&#127;b');
is('surrogate refused',        dec('a&#xD800;b'),                 'a&#xD800;b');
is('past Unicode refused',     dec('a&#x110000;b'),               'a&#x110000;b');
is('absurd decimal refused',   dec('a&#99999999;b'),              'a&#99999999;b');
is('tab IS allowed',           dec('a&#9;b'),                     "a\tb");

# --- TRAP 2: _stripTags order (strip, THEN decode, THEN trim) ---------------
is('tags stripped and entity decoded', strip('<em>Love &amp; Devotion</em>'), 'Love & Devotion');
is('escaped tag survives as TEXT',     strip('&lt;em&gt; is a tag'),          '<em> is a tag');
is('trailing &nbsp; is trimmed',       strip('Album&nbsp;'),                  'Album');
is('leading &nbsp; is trimmed',        strip('&nbsp;Album'),                  'Album');
is('interior &nbsp; is kept',          strip('Sun&nbsp;Ra'),                  'Sun Ra');

# --- the payoff: the matcher can now see the album --------------------------
# Uses the REAL _norm from Browse.pm. %FOLD is stubbed empty, which is honest here:
# every string below is ASCII, so no fold entry can apply.
{
    my $BROWSE = $ENV{PFR_BROWSE} || 'PitchforkReviews/Browse.pm';
    open(my $fh, '<:encoding(UTF-8)', $BROWSE) or die "$BROWSE: $!";
    my $src = do { local $/; <$fh> };
    $src =~ /\nsub _norm \{.*?\n\}\n/s or die "could not find _norm in $BROWSE";
    my $norm = $&;
    eval "package N; use strict; use warnings; my \$HAVE_NFD = 0; my %FOLD = ();\n$norm\n1;" or die $@;

    my $service = N::_norm('Love & Devotion');           # what Qobuz/Tidal/Deezer call it
    is('service spelling normalises',      $service,                          'love and devotion');
    is('OLD raw text did NOT match',       N::_norm('Love &amp; Devotion'),   'love and amp devotion');
    is('DECODED text matches the service', N::_norm(dec('Love &amp; Devotion')), $service);
    ok('decoding is what closes the gap',  N::_norm('Love &amp; Devotion') ne $service);
}

printf "\n%d passed, %d failed\n", $p, $f;
exit($f ? 1 : 0);

package Plugins::PitchforkReviews::API;

# Fetches Pitchfork's album-reviews and Best New Music LISTING PAGES and parses
# the embedded Verso state (window.__PRELOADED_STATE__) into clean, structured
# review items. This is far better than the RSS feed: the state gives, per review,
#   artist  = subHed.name          album  = dangerousHed (HTML-stripped)
#   capsule = dangerousDek         date   = pubDate (ISO)
#   cover   = image.sources        link   = url        score = ratingValue.score
#   genre   = rubric[].name (deduped, joined " / ")
# directly — no filename/slug derivation, and from_json yields proper characters
# (so no mojibake). Only metadata + the short capsule is stored; the full review
# is linked out, never reproduced.
#
# Two sources, same parser:
#   getListing() -> the album-reviews page (all recent reviews, capped)
#   getBnm()     -> the Best New Music page (its items ARE the BNM picks)

use strict;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use JSON::XS::VersionOneAndTwo;   # from_json — bundled in LMS

my $log   = Slim::Utils::Log::logger('plugin.pitchforkreviews');
my $cache = Slim::Utils::Cache->new();

# Listing pages update through the day; short working TTL + a long fallback so a
# transient fetch/parse failure keeps the menu populated.
use constant FEED_TTL          => 3 * 3600;        # 3h
use constant FEED_FALLBACK_TTL => 7 * 86400;       # 7d
use constant HTTP_TIMEOUT      => 20;
use constant REVIEWS_MAX       => 30;              # cap the reviews list (~ RSS window / last ~2 weeks)

use constant UA => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
                 . 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

use constant SITE        => 'https://pitchfork.com';
use constant REVIEWS_URL => 'https://pitchfork.com/reviews/albums/';
use constant BNM_URL     => 'https://pitchfork.com/reviews/best/albums/';

# getListing($cb, force => 0|1) / getBnm($cb, force => 0|1)
# Each calls back with an arrayref of normalised items (newest-first):
#   { artist, album, title, capsule, link, date, cover, score, genre, is_bnm }
sub getListing { my ($cb, %o) = @_; _fetchState(REVIEWS_URL, 'pfr:listing:3', REVIEWS_MAX, $cb, %o); }
sub getBnm     { my ($cb, %o) = @_; _fetchState(BNM_URL,     'pfr:bnm:3',     0,           $cb, %o); }

sub _fetchState {
    my ($url, $key, $cap, $cb, %opts) = @_;
    my $fbKey = "$key:fb";

    if (!$opts{force} && (my $c = $cache->get($key))) {
        $log->info("$key cache hit (" . scalar(@$c) . " items)");
        return $cb->($c);
    }

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http  = shift;
            my $items = _parseState($http->content);
            $items = [ @{$items}[0 .. $cap - 1] ] if $cap && @$items > $cap;
            if (@$items) {
                $cache->set($key,   $items, FEED_TTL);
                $cache->set($fbKey, $items, FEED_FALLBACK_TTL);
                $log->info("$key fetched (" . scalar(@$items) . " items)");
            }
            else {
                $log->warn("$key parsed 0 items from " . length($http->content) . " bytes ($url)");
                $items = $cache->get($fbKey) || [];
            }
            $cb->($items);
        },
        sub {
            my ($http, $error) = @_;
            $log->warn("fetch failed ($url): $error");
            $cb->($cache->get($fbKey) || []);
        },
        { timeout => HTTP_TIMEOUT },
    )->get($url, 'User-Agent' => UA);
}

# ---------------------------------------------------------------------------
# Parse window.__PRELOADED_STATE__ -> normalised review items.
# ---------------------------------------------------------------------------
sub _parseState {
    my ($content) = @_;

    my $json = _extractState($content);
    return [] unless length $json;

    my $state = eval { from_json($json) };
    if ($@ || !ref $state) {
        $log->warn("state JSON parse error: $@");
        return [];
    }

    my @raw;
    _walkReviews($state, \@raw);

    my (%seen, @items);
    for my $r (@raw) {
        my $link = $r->{url} // '';
        next unless length $link;
        $link = SITE . $link if $link =~ m{^/};
        next if $seen{$link}++;

        my $album = _stripTags($r->{dangerousHed} // '');
        $album =~ s/^\*+//; $album =~ s/\*+$//;          # *markdown emphasis*
        $album =~ s/^\s+//; $album =~ s/\s+$//;
        next unless length $album;

        my $artist  = (ref $r->{subHed} eq 'HASH' ? $r->{subHed}{name} : '') // '';
        my $capsule = _stripTags($r->{dangerousDek} // '');
        my $rv      = ref $r->{ratingValue} eq 'HASH' ? $r->{ratingValue} : {};

        # Genre(s) from the "rubric" list (can repeat / hold several) — dedupe,
        # keep order, join for display. Missing on the odd review.
        my (@g, %gs);
        for my $x (@{ ref $r->{rubric} eq 'ARRAY' ? $r->{rubric} : [] }) {
            my $n = ref $x eq 'HASH' ? $x->{name} : undef;
            next unless defined $n && length $n;
            push @g, $n unless $gs{$n}++;
        }

        push @items, {
            artist  => $artist,
            album   => $album,
            title   => (length $artist ? "$artist: $album" : $album),
            capsule => $capsule,
            link    => $link,
            date    => ($r->{pubDate} // ''),          # ISO 8601 (sorts + week-groups)
            cover   => _coverUrl($r->{image}),
            score   => $rv->{score},
            genre   => join(' / ', @g),
            is_bnm  => ($rv->{isBestNewMusic} ? 1 : 0),
        };
    }

    # Newest-first (ISO pubDate sorts lexicographically = chronologically).
    @items = sort { ($b->{date} // '') cmp ($a->{date} // '') } @items;
    return \@items;
}

# Recursively collect Verso "review" content nodes.
sub _walkReviews {
    my ($node, $out) = @_;
    if (ref $node eq 'HASH') {
        if (($node->{contentType} // '') eq 'review'
            && ($node->{url} // '') =~ m{/reviews/album}) {
            push @$out, $node;
        }
        _walkReviews($_, $out) for values %$node;
    }
    elsif (ref $node eq 'ARRAY') {
        _walkReviews($_, $out) for @$node;
    }
}

# Extract the JSON object assigned to window.__PRELOADED_STATE__ by scanning for
# the matching close brace (string/escape aware). Fast: the [^{}"\\]* run lets the
# regex engine skip long spans between significant characters.
sub _extractState {
    my ($content) = @_;
    my $i = index($content, 'window.__PRELOADED_STATE__');
    return '' if $i < 0;
    my $eq = index($content, '=', $i);
    return '' if $eq < 0;
    my $start = index($content, '{', $eq);
    return '' if $start < 0;

    pos($content) = $start;
    my $depth = 0;
    my $instr = 0;
    while ($content =~ /\G[^{}"\\]*([{}"\\])/gc) {
        my $ch = $1;
        if ($instr) {
            if    ($ch eq '\\') { pos($content) += 1; }   # skip the escaped char
            elsif ($ch eq '"')  { $instr = 0; }
            # braces inside a string are ignored
        }
        else {
            if    ($ch eq '"') { $instr = 1; }
            elsif ($ch eq '{') { $depth++; }
            elsif ($ch eq '}') {
                $depth--;
                return substr($content, $start, pos($content) - $start) if $depth == 0;
            }
        }
    }
    return '';
}

# Pick a reasonable cover URL from a Verso image node: the smallest source >= 640px
# wide (a good thumbnail; LMS's proxy can resize down), else the largest available,
# else a constructed master URL from the id.
sub _coverUrl {
    my ($image) = @_;
    return '' unless ref $image eq 'HASH';

    my $src = $image->{sources};
    if (ref $src eq 'HASH') {
        my @cands = grep { ref $_ eq 'HASH' && $_->{url} } values %$src;
        if (@cands) {
            my @sorted = sort { ($a->{width} || 0) <=> ($b->{width} || 0) } @cands;
            for my $c (@sorted) { return $c->{url} if ($c->{width} || 0) >= 640; }
            return $sorted[-1]{url};
        }
    }
    return 'https://media.pitchfork.com/photos/' . $image->{id} . '/1:1/w_800,c_limit/a.jpg'
        if $image->{id};
    return '';
}

sub _stripTags {
    my $s = shift // '';
    $s =~ s/<[^>]+>//g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    return $s;
}

1;

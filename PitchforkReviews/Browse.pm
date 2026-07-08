package Plugins::PitchforkReviews::Browse;

# All browse feeds for the Pitchfork Reviews plugin, plus the album-level streaming
# resolver.
#
# Menu shape:
#   Pitchfork Reviews
#     - Best New Music      -> feed of reviews  -> tap a review -> detail page
#     - Latest Reviews      -> feed of reviews  -> tap a review -> detail page
#     - Plugin Settings
#
#   A review detail page resolves the reviewed album against the user's streaming
#   services (Qobuz / Tidal) and shows each match as a directly-playable album
#   node, followed by the review capsule and a "Read review" link out.
#
# The resolver (_findPlayable and friends) is a trimmed port of the album-match
# engine in the ListenBrainz Fresh Releases plugin: search the ARTIST only on each
# service, then filter candidates locally by _albumMatches (title + artist). This
# has far better recall than sending "artist album" as one fuzzy query. The known
# matcher edge cases carry over (accents/punctuation/shorter titles) — see the
# ListenBrainz plugin's match_check tooling if a specific album won't resolve.

use strict;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);
use Slim::Utils::Timers;
use Time::Local;

my $log   = Slim::Utils::Log::logger('plugin.pitchforkreviews');
my $prefs = preferences('plugin.pitchforkreviews');
my $cache = Slim::Utils::Cache->new();

# Opt-in resolve/feed timeline → server.log at info always, plus pfr-debug.log
# when the debug_log pref is on (server.log at INFO always; pfr-debug.log too).
sub _dbg { Plugins::PitchforkReviews::Plugin::dbg(@_) }

use constant STREAM_FOUND_TTL        => 7 * 86400;   # a found match is stable
use constant STREAM_NOMATCH_TTL      => 1 * 86400;   # confirmed "not on any service"
use constant STREAM_INCONCLUSIVE_TTL => 3600;        # couldn't query a service -> retry soon
use constant STREAM_SVC_TIMEOUT      => 8;           # per-service search watchdog (s)
use constant STREAM_MAX_RESULTS      => 12;

use constant ROW_CAPSULE_MAX => 110;   # capsule length on a list row
use constant DETAIL_TIMEOUT  => 15;    # detail-page render watchdog (s)
use constant DIVIDER_ICON    => 'html/images/albums.png';   # neutral core LMS icon on week headers (keeps Material's grid toggle enabled)
use constant REFRESH_ICON    => 'plugins/PitchforkReviews/html/images/pfr-refresh_MTL_icon_refresh.png';   # same Material refresh glyph LBF uses
use constant SETTINGS_ICON   => 'plugins/PitchforkReviews/html/images/pfr-cog_MTL_icon_settings.png';     # Material cog font-icon (like LBF)
use constant BNM_TILE        => 'plugins/PitchforkReviews/html/images/menu-best-new-music.png';           # branded section cover
use constant REVIEWS_TILE    => 'plugins/PitchforkReviews/html/images/menu-latest-reviews.png';           # branded section cover
use constant HSA_TILE        => 'plugins/PitchforkReviews/html/images/menu-high-scoring-albums.png';      # branded section cover
use constant LOGO_ICON       => 'plugins/PitchforkReviews/html/images/PitchforkReviewsIcon.png';          # Pitchfork round mark (full-colour raster) — marks the "Read the full review" link
use constant HEADER_ICON     => 'plugins/PitchforkReviews/html/images/PitchforkReviewsIcon_svg.png';      # divider/header icon — MUST be the `_svg.png` Material-recolour form: Material renders an icon on a header-basic divider ONLY for `_svg.png`/`_MTL_*` icons, NOT a plain .png (verified vs LBF, whose dividers use its _svg.png)

# ===========================================================================
# Browse feeds
# ===========================================================================

# Top-level app menu.
sub topLevel {
    my ($client, $cb, $args) = @_;

    # All three source tiles share one grouped feed (fetchFeed, dispatched by
    # `source`): each groups into Material header dividers per the group_by pref.
    # A second provider (AllMusic, v2) drops in here as another _feedTile.
    my $features = _featuresOf($args);   # 'h' => client (Material) supports header dividers

    my @items = (
        _feedTile($client, 'bnm',     'PLUGIN_PITCHFORKREVIEWS_BNM',     BNM_TILE,     $features),
        _feedTile($client, 'hsa',     'PLUGIN_PITCHFORKREVIEWS_HSA',     HSA_TILE,     $features),
        _feedTile($client, 'reviews', 'PLUGIN_PITCHFORKREVIEWS_REVIEWS', REVIEWS_TILE, $features),
        {
            name    => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_SETTINGS'),
            type    => 'link',
            image   => SETTINGS_ICON,
            weblink => '/plugins/PitchforkReviews/settings.html',
        },
    );

    # cachetime => 0: Material client-caches browse views per player; force a
    # re-fetch each open so a refreshed feed shows without navigating away.
    $cb->({ items => \@items, cachetime => 0 });
}

sub _feedTile {
    my ($client, $source, $nameKey, $image, $features) = @_;
    return {
        name        => cstring($client, $nameKey),
        type        => 'link',
        image       => $image,
        url         => \&fetchFeed,
        # Thread `features` through passthrough: XMLBrowser gives it only to the TOP
        # feed, not a coderef sub-feed, so fetchFeed can't read it from $args.
        passthrough => [ { source => $source, features => $features } ],
    };
}

# A source listing (page state), grouped into Material header dividers by the
# group_by pref (week or genre — same as Latest Reviews). All three sources —
# Latest Reviews, Best New Music, High Scoring Albums — share this feed, keyed by
# $pt->{source}. Resolves each item to streaming during the build so matched rows
# play from the list with the service's artwork; unmatched rows keep the Pitchfork
# cover and drill to the detail page.
sub fetchFeed {
    my ($client, $cb, $args, $pt) = @_;
    my $source  = $pt->{source} // 'reviews';
    my $headers = _wantHeaders($pt->{features} // _featuresOf($args));

    my $fetch = $source eq 'bnm' ? \&Plugins::PitchforkReviews::API::getBnm
              : $source eq 'hsa' ? \&Plugins::PitchforkReviews::API::getHsa
              :                    \&Plugins::PitchforkReviews::API::getListing;

    $fetch->(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            my @rows = ( _refreshRow($client, $source) );
            if (@$items) {
                push @rows, @{ _groupedRows($client, $items, $headers) };
            }
            else {
                push @rows, { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_EMPTY'), type => 'text' };
            }
            $cb->({ items => \@rows, cachetime => 0 });
        });
    });
}

# ---------------------------------------------------------------------------
# Material Skin home-page shelves (registered in Plugin::postinitPlugin via
# HomeExtras.pm). Each is a FLAT card list — no Refresh row, no week/genre
# dividers. Material uses the SAME feed for the carousel AND its "show all"
# click-in, and re-traverses by item_id at quantity 1 for playback, so a header
# at index 0 (or any quantity-varying shape) would shift every card's item_id and
# break deep streaming playback. So: always the WHOLE flat list — every review,
# matched or not, at every request quantity — the same rule the ListenBrainz
# plugin's home shelves follow. (We deliberately do NOT filter to matched-only
# here: which items are matched varies as the resolver cache fills, which would
# make the list membership — and thus every item_id — unstable between the
# carousel render and the play re-traversal, breaking deep playback.)
#
# The per-item streaming resolve is pre-warmed by Plugin's background warm
# (warmCache, below), so on a warm cache this build is all cache hits and
# returns immediately — the home carousel never has to wait out an 18s live
# resolve. On a cold cache (fresh install / first tick not yet run) it still
# resolves during the build, degrading to the browse-list behaviour.
# ---------------------------------------------------------------------------
sub homeReviews {
    my ($client, $cb, $args) = @_;
    Plugins::PitchforkReviews::API::getListing(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            $cb->({ items => [ map { _reviewRow($client, $_) } @$items ], cachetime => 0 });
        });
    });
}

sub homeBnm {
    my ($client, $cb, $args) = @_;
    Plugins::PitchforkReviews::API::getBnm(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            $cb->({ items => [ map { _reviewRow($client, $_) } @$items ], cachetime => 0 });
        });
    });
}

sub homeHsa {
    my ($client, $cb, $args) = @_;
    Plugins::PitchforkReviews::API::getHsa(sub {
        my $items = shift;
        _resolveSection($client, $items, sub {
            $cb->({ items => [ map { _reviewRow($client, $_) } @$items ], cachetime => 0 });
        });
    });
}

# ---------------------------------------------------------------------------
# Background warm: pre-resolve the Latest Reviews + Best New Music listings to
# streaming so the Material home shelves (and the browse lists) open instantly
# instead of running an up-to-18s resolve live on the home carousel — which
# Material can time out waiting for, leaving the shelf empty/hung (the reason
# the sibling ListenBrainz plugin never resolves inside its home feeds either).
# Scheduled by Plugin::postinitPlugin shortly after startup, then daily, and
# deferred while a library scan runs. Cheap on the daily tick: _findPlayable
# matches are cached (7d found), so real work only happens for reviews that are
# new since the last run. Needs a connected player for the streaming-service API
# context; a quiet no-op (resolution deferred to first open) when none is
# connected.
# ---------------------------------------------------------------------------
sub warmCache {
    my ($client) = @_;
    $client ||= (Slim::Player::Client::clients())[0];
    unless ($client) {
        _dbg("warm: no connected player — deferring resolve to first open");
        return;
    }

    # Resolve the three listings sequentially (Latest Reviews, Best New Music, then
    # High Scoring Albums) so the warm stays gentle on the streaming APIs.
    Plugins::PitchforkReviews::API::getListing(sub {
        my $items = shift || [];
        _dbg("warm: resolving " . scalar(@$items) . " Latest Reviews");
        _resolveSection($client, $items, sub {
            Plugins::PitchforkReviews::API::getBnm(sub {
                my $bnm = shift || [];
                _dbg("warm: resolving " . scalar(@$bnm) . " Best New Music");
                _resolveSection($client, $bnm, sub {
                    Plugins::PitchforkReviews::API::getHsa(sub {
                        my $hsa = shift || [];
                        _dbg("warm: resolving " . scalar(@$hsa) . " High Scoring Albums");
                        _resolveSection($client, $hsa, sub { _dbg("warm: done"); });
                    });
                });
            });
        });
    });
}

# Resolve every item to a streaming album (bounded concurrency), stashing the
# matched album node on $it->{_album}. Renders once all settle OR a deadline hits
# (partial: unresolved items render with the Pitchfork cover + drill, and self-heal
# from cache on the next open). Cheap after the first build — matches are cached.
use constant BUILD_CONCURRENCY => 6;
use constant BUILD_DEADLINE    => 18;   # seconds before rendering with whatever resolved

sub _resolveSection {
    my ($client, $items, $cb) = @_;

    my @queue = @$items;
    my $total = scalar @queue;
    return $cb->() unless $total;

    my $done     = 0;
    my $active   = 0;
    my $finished = 0;

    my $timer = Slim::Utils::Timers::setTimer(undef, time() + BUILD_DEADLINE, sub {
        return if $finished;
        $finished = 1;
        $log->warn("resolve deadline hit ($done/$total matched-or-tried)");
        $cb->();
    });

    my $complete = sub {
        return if $finished;
        $finished = 1;
        Slim::Utils::Timers::killSpecific($timer);
        $cb->();
    };

    my $pump;
    $pump = sub {
        while ($active < BUILD_CONCURRENCY && @queue) {
            my $it = shift @queue;
            $active++;
            _findPlayable($client, sub {
                my $res = shift;
                for my $node (@{ $res->{items} || [] }) {
                    next unless ref $node eq 'HASH' && $node->{_svc};
                    $it->{_album} = $node;   # first matched streaming album
                    last;
                }
                $active--;
                $done++;
                $complete->() if $done >= $total;
                $pump->();   # keep resolving to warm the cache even past the render deadline
            }, $it->{artist}, $it->{album});
        }
    };
    $pump->();
}

# Force-refresh this section and reload the view in place. Material honours
# nextWindow => 'refresh' only on an EMPTY response, so return no items.
sub _refreshRow {
    my ($client, $source) = @_;
    return {
        name        => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_REFRESH'),
        type        => 'link',
        image       => REFRESH_ICON,   # Material refresh glyph (same as LBF); also keeps Material's grid view enabled
        nextWindow  => 'refresh',
        passthrough => [ { source => $source } ],
        url         => sub {
            my ($c, $cb, $args, $pt) = @_;
            my $reload = sub { $cb->({ items => [], nextWindow => 'refresh' }); };
            my $src    = $pt->{source} // '';
            if    ($src eq 'bnm') { Plugins::PitchforkReviews::API::getBnm($reload, force => 1); }
            elsif ($src eq 'hsa') { Plugins::PitchforkReviews::API::getHsa($reload, force => 1); }
            else                  { Plugins::PitchforkReviews::API::getListing($reload, force => 1); }
        },
    };
}

# One review row. If it resolved to a streaming album ($it->{_album}), render THAT
# node — playable from the list (Play/Add), with the service's album artwork —
# relabelled with the review artist/album + capsule, AND its tracklist drill-in is
# wrapped so it also offers "Read the full review" (see _attachReviewLink). Otherwise
# a Pitchfork-cover row that drills to the detail page (capsule + Read review +
# Refresh streaming match).
sub _reviewRow {
    my ($client, $it) = @_;

    my $artist = $it->{artist};
    my $album  = $it->{album};
    my $line1  = length $artist ? "$artist - $album" : $album;

    if (my $al = $it->{_album}) {
        my %row = %$al;                                   # playable album node (url coderef, type playlist)
        # The service node carries its own name/line1/line2 (which Material prefers),
        # so relabel ALL of them to the review's "Artist - Album" + capsule.
        $row{name}  = $line1;
        $row{line1} = $line1;
        $row{line2} = _line2($it);
        # Prefer the album cover, then the Pitchfork cover, then the service logo —
        # so a match with no album art still shows real artwork, not just the logo.
        $row{image} = $al->{_cover} || $it->{cover} || $al->{image} || DIVIDER_ICON;
        # Keep it playable from the list, but make the drill-in also carry the review
        # link (the row was purely the album node before, so tapping went straight to
        # the tracklist and the "Read the full review" link was unreachable).
        _attachReviewLink($client, \%row, $it);
        return \%row;
    }

    return {
        name        => $line1,
        line1       => $line1,
        line2       => _line2($it),
        image       => ($it->{cover} || DIVIDER_ICON),   # always set (keeps Material's grid view enabled)
        type        => 'link',
        url         => \&reviewDetail,
        passthrough => [ $it ],
    };
}

# Wrap a matched album node's tracklist coderef so drilling into the album shows a
# "Read the full review" link above the tracks, WITHOUT losing playability: the row
# stays a `type => 'playlist'` node (Play/Add from the list still queue the album),
# and the injected item is a non-audio weblink so play traversal skips it. The wrapper
# is built fresh each render (live feed, cachetime => 0) — no caching concern.
sub _attachReviewLink {
    my ($client, $row, $it) = @_;
    my $link = $it->{link};
    return unless length($link // '') && ref $row->{url} eq 'CODE';

    my $inner = $row->{url};                              # service tracklist coderef (QobuzGetTracks / getAlbum)
    my $item  = {
        name    => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_READ_REVIEW'),
        type    => 'link',
        weblink => $link,
        image   => LOGO_ICON,                             # Pitchfork mark so it stands out from the album art
    };
    my $spacer = { name => "\x{a0}", type => 'text' };    # blank row → gap separating the link from the tracks
    $row->{url} = sub {
        my ($c, $cb, $a, $pt) = @_;
        $inner->($c, sub {
            my $res   = shift;
            my @items = ref $res eq 'HASH'  ? @{ $res->{items} || [] }
                      : ref $res eq 'ARRAY' ? @$res : ();
            $cb->({ items => [ $item, $spacer, @items ] });   # link, gap, then the tracks
        }, $a, $pt);
    };
}

# Second line: "date · genre - truncated capsule" (each part dropped if absent).
sub _line2 {
    my ($it) = @_;
    my $cap = $it->{capsule} // '';
    $cap = substr($cap, 0, ROW_CAPSULE_MAX) . '...' if length($cap) > ROW_CAPSULE_MAX;
    my $meta = join(" \x{b7} ", grep { length } _shortDate($it->{date}), ($it->{genre} // ''));
    return join(' - ', grep { length } $meta, $cap);
}

# Detail page: streaming matches (playable) + capsule + Read review link.
sub reviewDetail {
    my ($client, $cb, $args, $it) = @_;

    my $done = 0;
    my $finish = sub {
        return if $done;
        $done = 1;
        my $streamItems = shift || [];

        my @rows = @$streamItems;

        if (length($it->{genre} // '')) {
            push @rows, {
                name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_GENRE') . ': ' . $it->{genre},
                type => 'text',
            };
        }
        if (length($it->{capsule} // '')) {
            push @rows, { name => $it->{capsule}, type => 'text' };
        }
        if (length($it->{link} // '')) {
            push @rows, {
                name    => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_READ_REVIEW'),
                type    => 'link',
                weblink => $it->{link},
            };
        }

        # Refresh row at the TOP of the streaming section (per the fleet action-row
        # convention) — force a re-match past the resolver cache. Lets the user
        # retry a "no match" (or a wrong match) immediately instead of waiting out
        # the cache TTL (7d found / 1d no-match).
        unshift @rows, _refreshMatchRow($client, $it);

        $cb->({ items => \@rows, cachetime => 0 });
    };

    # Watchdog: if a streaming search never calls back, still render the capsule
    # + link rather than hanging the page.
    Slim::Utils::Timers::setTimer(undef, time() + DETAIL_TIMEOUT, sub { $finish->([]) });

    _findPlayable($client, sub {
        my $res = shift;
        $finish->($res->{items} || []);
    }, $it->{artist}, $it->{album});
}

# "Refresh streaming match": force-re-resolve THIS album past the cache (which
# rewrites the cached result), then reload the detail page in place so it renders
# the fresh match. Material honours nextWindow => 'refresh' on an empty response.
sub _refreshMatchRow {
    my ($client, $it) = @_;
    return {
        name        => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_REFRESH_MATCH'),
        type        => 'link',
        nextWindow  => 'refresh',
        passthrough => [ $it ],
        url         => sub {
            my ($c, $cb, $args, $pt) = @_;
            _findPlayable($c, sub {
                $cb->({ items => [], nextWindow => 'refresh' });
            }, $pt->{artist}, $pt->{album}, 1);   # $force = 1 -> skip the cache read
        },
    };
}

# "Wed, 02 Jul 2025 05:00:00 GMT" -> "02 Jul 2025" (best-effort; pass through
# anything that doesn't match).
# Short date for a row's line2. Handles ISO ("2026-07-07T...") -> "7 July 2026",
# and passes through an already-short string.
sub _shortDate {
    my $d = shift // '';
    return _fmtDate($1) if $d =~ /^(\d{4}-\d{2}-\d{2})/;
    return $1 if $d =~ /(\d{1,2}\s+\w{3}\s+\d{4})/;
    return $d;
}

# ---------------------------------------------------------------------------
# Week dividers (Material headers) — ports the ListenBrainz plugin's mechanics.
# Group the (newest-first) feed into weeks and insert a divider before each. On a
# header-capable client the divider is a real Material header (bold/accent); other
# skins get plain text. XMLBrowser forces a drill action onto the older 'header'
# type, so the header carries a url returning that week's rows (header-basic, on
# Material 6.4.3+, is non-actionable and ignores it).
# ---------------------------------------------------------------------------

sub _featuresOf {
    my ($args) = @_;
    return (ref $args->{params} eq 'HASH') ? ($args->{params}{features} // '') : '';
}

sub _wantHeaders {
    my ($features) = @_;
    return (defined $features && $features =~ /h/) ? 1 : 0;
}

my $_headerTypeCache;
sub _headerType {
    return $_headerTypeCache if defined $_headerTypeCache;
    my $ver = eval { Plugins::MaterialSkin::Plugin->getPluginVersion() };
    my $useBasic;
    if    (!defined $ver)                  { $useBasic = 0; }                                       # can't tell -> safe 'header'
    elsif ($ver =~ /^(\d+)\.(\d+)\.(\d+)/) { $useBasic = (($1 <=> 6) || ($2 <=> 4) || ($3 <=> 3)) >= 0 ? 1 : 0; }  # >= 6.4.3
    else                                   { $useBasic = 1; }                                       # dev/test build -> new type
    return $_headerTypeCache = $useBasic ? 'header-basic' : 'header';
}

# Dispatch the Latest Reviews list to a grouping mode (Settings -> group_by):
# 'date' (default) keeps the weekly dividers; 'genre' groups under each Pitchfork
# genre instead. Either way the feed items arrive newest-first (API sorts by date),
# so date order is preserved within every bucket.
sub _groupedRows {
    my ($client, $items, $headers) = @_;
    return _genreRows($client, $items, $headers)
        if ($prefs->get('group_by') // 'date') eq 'genre';
    return _weeklyRows($client, $items, $headers);
}

# Divider header shared by both grouping modes: the Pitchfork logo (not the neutral
# record icon) so headers are branded, and still an image so Material keeps the grid
# toggle enabled. On a header-capable client XMLBrowser forces a drill onto the older
# 'header' type, so carry a url returning that bucket's rows (ignored by header-basic).
sub _divHeader {
    my ($client, $label, $divType, $headers, $rowsFor) = @_;
    my $hdr = { name => $label, type => $divType, image => HEADER_ICON };
    if ($headers) {
        $hdr->{url} = sub {
            my ($c, $cb) = @_;
            $cb->({ items => [ map { _reviewRow($c, $_) } @$rowsFor ] });
        };
        $hdr->{passthrough} = [ {} ];
    }
    return $hdr;
}

# Group items into weeks, emitting a divider header + that week's review rows.
sub _weeklyRows {
    my ($client, $items, $headers) = @_;
    my $divType = $headers ? _headerType() : 'text';

    my (@order, %bucket);
    for my $it (@$items) {
        my $ws = _weekStartOf($it->{date});
        push @order, $ws unless exists $bucket{$ws};
        push @{ $bucket{$ws} }, $it;
    }

    my @rows;
    for my $ws (@order) {
        my $wk = $bucket{$ws};
        push @rows, _divHeader($client, _weekLabel($client, $ws), $divType, $headers, $wk);
        push @rows, map { _reviewRow($client, $_) } @$wk;
    }
    return \@rows;
}

# Group items by their PRIMARY Pitchfork genre, emitting a genre divider + that
# genre's rows. Genres appear in the order their newest review does (so the genre
# with the most recent review leads), and rows within a genre stay newest-first —
# the "in date order" the feed already provides.
sub _genreRows {
    my ($client, $items, $headers) = @_;
    my $divType = $headers ? _headerType() : 'text';

    my (@order, %bucket);
    for my $it (@$items) {
        my $g = _genreKey($it);
        push @order, $g unless exists $bucket{$g};
        push @{ $bucket{$g} }, $it;
    }

    my @rows;
    for my $g (@order) {
        my $grp = $bucket{$g};
        push @rows, _divHeader($client, _genreLabel($client, $g), $divType, $headers, $grp);
        push @rows, map { _reviewRow($client, $_) } @$grp;
    }
    return \@rows;
}

# Bucket key = the primary genre (Pitchfork's first rubric; the row's `genre` is the
# list joined " / "). Split ONLY on that " / " join delimiter (spaces required) — a
# bare "/" is part of a genre NAME (Pitchfork's "Pop/R&B", "Folk/Country") and must
# not be split. Falls to '' when a review carries no genre.
sub _genreKey {
    my ($it) = @_;
    my ($g) = split m{\s+/\s+}, ($it->{genre} // ''), 2;
    $g //= '';
    $g =~ s/^\s+//; $g =~ s/\s+$//;
    return $g;
}

# Divider label for a genre bucket ('' -> "Other").
sub _genreLabel {
    my ($client, $g) = @_;
    return length $g ? $g : cstring($client, 'PLUGIN_PITCHFORKREVIEWS_GENRE_OTHER');
}

# Monday (YYYY-MM-DD, UTC) of the week containing an RFC-822 pubDate
# ("Tue, 07 Jul 2026 04:03:00 +0000"); '' if unparseable.
my %_MON = (
    jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6,
    jul => 7, aug => 8, sep => 9, oct => 10, nov => 11, dec => 12,
);
sub _weekStartOf {
    my ($pub) = @_;
    my ($y, $mon, $d);
    if (($pub // '') =~ /^(\d{4})-(\d{2})-(\d{2})/) {           # ISO 8601 (page state)
        ($y, $mon, $d) = ($1, $2 + 0, $3);
    }
    elsif (($pub // '') =~ /(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})/) {   # RFC-822 (legacy)
        ($d, $mon, $y) = ($1, $_MON{ lc $2 }, $3);
    }
    else {
        return '';
    }
    return '' unless $mon;
    my $epoch = eval { Time::Local::timegm(0, 0, 12, $d, $mon - 1, $y) };
    return '' unless defined $epoch;
    my $wday = (gmtime $epoch)[6];                             # 0 = Sunday
    my @m    = gmtime($epoch - (($wday + 6) % 7) * 86400);     # step back to Monday
    return sprintf('%04d-%02d-%02d', $m[5] + 1900, $m[4] + 1, $m[3]);
}

my @_MONTHS = qw(January February March April May June
                 July August September October November December);
sub _fmtDate {
    my ($d) = @_;
    return '' unless ($d // '') =~ /^(\d{4})-(\d{2})-(\d{2})/;
    return sprintf('%d %s %d', $3 + 0, $_MONTHS[$2 - 1], $1);
}

# "Week of 30 June 2026" for a week-start (Monday) date.
sub _weekLabel {
    my ($client, $ws) = @_;
    return cstring($client, 'PLUGIN_PITCHFORKREVIEWS_WEEK') unless $ws =~ /^\d{4}-\d{2}-\d{2}$/;
    return cstring($client, 'PLUGIN_PITCHFORKREVIEWS_WEEK_OF') . ' ' . _fmtDate($ws);
}

# ===========================================================================
# Album streaming resolver (trimmed port of the ListenBrainz plugin's engine).
# ===========================================================================

# Installed, integrable services. v1 ships Qobuz + Tidal — both fully-working
# album search/render in the sibling plugin, and both round-trip through the
# cache (their play node is a coderef url reattached on read by
# _rebuildStreamItems). Bandcamp (manual, loop-blocking) and Deezer can be ported
# from the ListenBrainz plugin later.
sub _streamingAdapters {
    my @adapters;

    push @adapters, {
        name => 'Qobuz', icon => _pluginIcon('Plugins::Qobuz::Plugin'),
        run  => \&_searchQobuz,
    } if Plugins::Qobuz::Plugin->can('getAPIHandler')
      && Plugins::Qobuz::Plugin->can('_albumItem')
      && Plugins::Qobuz::Plugin->can('QobuzGetTracks');   # reattach method for cached matches (see _rebuildStreamItems)

    push @adapters, {
        name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'),
        run  => \&_searchTidal,
    } if Plugins::TIDAL::Plugin->can('getAPIHandler')
      && Plugins::TIDAL::Plugin->can('getAlbum')
      && Plugins::TIDAL::Plugin->can('_renderAlbum');

    # Deezer (michaelherger/lms-deezer) — same modern plugin family as Qobuz/Tidal.
    # `_renderAlbum` sets `url => \&getAlbum` (a COREF, album id in passthrough) exactly
    # like Tidal, and `play => deezer://album:<id>` (the string is the play/favourites
    # value, NOT the browse url). So it round-trips the cache identically: coderef
    # stripped by _cacheStream, reattached by _rebuildStreamItems. getAlbum is required
    # for that reattach (else a cached match drops on re-read).
    push @adapters, {
        name => 'Deezer', icon => _pluginIcon('Plugins::Deezer::Plugin'),
        run  => \&_searchDeezer,
    } if Plugins::Deezer::Plugin->can('getAPIHandler')
      && Plugins::Deezer::Plugin->can('_renderAlbum')
      && Plugins::Deezer::Plugin->can('getAlbum');

    return @adapters;
}

# Enabled adapters in search order: ascending svc_priority_<name>, dropping 0.
sub _orderedAdapters {
    my @out;
    for my $a (_streamingAdapters()) {
        my $prio = $prefs->get('svc_priority_' . lc $a->{name});
        $prio = 1 unless defined $prio;
        next unless $prio > 0;
        push @out, { %$a, priority => $prio };
    }
    return sort { $a->{priority} <=> $b->{priority} } @out;
}

# Detection + priority for every known service (installed or not) — drives the
# settings page's service list.
sub serviceStatus {
    my @known = ( [ 'qobuz', 'Qobuz' ], [ 'tidal', 'Tidal' ], [ 'deezer', 'Deezer' ] );
    my %installed = map { lc($_->{name}) => 1 } _streamingAdapters();
    return [ map {
        {   key       => $_->[0],
            name      => $_->[1],
            installed => $installed{ $_->[0] } ? 1 : 0,
            priority  => $prefs->get('svc_priority_' . $_->[0]) // 0,
        }
    } @known ];
}

sub _pluginIcon {
    my ($class) = @_;
    return eval { $class->_pluginDataFor('icon') } || undef;
}

# Cache key for an album's matches. Keyed by the current service set (order +
# enabled) so any streaming-config change re-matches on next open instead of
# serving links to a service the user removed/disabled.
sub _streamKey {
    my ($idPart) = @_;
    my $svcOrder = join(',', map { lc $_->{name} } _orderedAdapters());
    my $key = 'pfr:stream:3:' . $svcOrder . ':' . ($idPart // '');   # :3: = adds ListenLater favorites_url (+_albumid); re-resolves cached matches
    utf8::encode($key) if utf8::is_utf8($key);   # octet key — non-Latin can't crash md5
    return $key;
}

# Album-identifying part of the key: the normalised "artist album" string.
sub _streamId {
    my ($artist, $album) = @_;
    return join(' ', grep { length } _norm($artist), _norm($album));
}

# Resolve an album to playable streaming nodes. Calls back { items => [...] }.
# $force skips the cache READ (still writes) so the "Refresh streaming match" row
# can re-resolve past a stale no-match/wrong-match.
sub _findPlayable {
    my ($client, $callback, $artist, $album, $force) = @_;

    my $albumNorm  = _norm($album);
    my $artistNorm = _norm($artist);

    # Send the RAW artist to each service search (normalisation turns punctuation
    # into spaces, which the services' own search can't match); keep the normalised
    # forms for our _albumMatches validation only.
    my $queryEnc = $artist;
    utf8::encode($queryEnc) if utf8::is_utf8($queryEnc);

    my @adapters = _orderedAdapters();
    unless (@adapters) {
        $callback->({ items => _streamResult($client, []) });
        return;
    }

    my $key = _streamKey(_streamId($artist, $album));
    if (!$force && (my $c = $cache->get($key))) {
        _dbg("resolve cache hit: $key");
        $callback->({ items => _streamResult($client, _rebuildStreamItems($c->{items})) });
        return;
    }

    # Search all services in parallel; resolve to the highest-priority one that
    # matched as soon as that's decided (every higher-priority service has come
    # back). Per-service watchdog so a hung service can't stall the result.
    my @result       = map { undef } @adapters;   # undef=pending, []=miss, [..]=match
    my $resolved     = 0;
    my $inconclusive = 0;

    my $resolve = sub {
        return if $resolved;
        my $win;
        for my $i (0 .. $#adapters) {
            return if !defined $result[$i];
            if (@{ $result[$i] }) { $win = $i; last; }
        }
        $resolved = 1;
        my $items = defined $win ? $result[$win] : [];
        my $ttl = @$items       ? STREAM_FOUND_TTL
                : $inconclusive ? STREAM_INCONCLUSIVE_TTL
                :                 STREAM_NOMATCH_TTL;
        _cacheStream($key, $items, $ttl);
        _dbg("resolve '$artistNorm / $albumNorm': "
            . (defined $win ? "matched on $adapters[$win]{name} (" . scalar(@$items) . ")"
                            : "no match" . ($inconclusive ? " ($inconclusive inconclusive)" : "")));
        $callback->({ items => _streamResult($client, $items) });
    };

    for my $i (0 .. $#adapters) {
        my $a    = $adapters[$i];
        my $svc  = $a->{name};
        my $icon = $a->{icon};

        my $settled = 0;
        my $svcTimer;
        my $settle  = sub {
            return if $settled || $resolved;
            $settled = 1;
            Slim::Utils::Timers::killSpecific($svcTimer) if $svcTimer;
            # undef = couldn't query the service (no handler / timeout / error /
            # broken renderer) -> inconclusive (short-TTL retry), not a real miss.
            if (!defined $_[0]) {
                $inconclusive++;
                $result[$i] = [];
                $resolve->();
                return;
            }
            my @matched = (ref $_[0] eq 'ARRAY') ? @{ $_[0] } : ();
            for my $it (@matched) {
                $it->{_cover} = $it->{image} if defined $it->{image};   # native album cover (for list rows)
                $it->{image}  = $icon if $icon;   # service logo as the detail-row thumbnail
                $it->{_svc}   = $svc;             # for the cache rebuild
                # ListenLater interop: give the row a real favorites_url
                # (<scheme>://album:<id>?cover=…&a=…) — without it a Qobuz match carries
                # no favurl and the coderef `url` leaks through as a broken link, so
                # ListenLater can't tell the service or replay the album. Same handshake
                # the sibling plugin uses. (Cover rides ?cover=; artist rides &a= because
                # Material sends these rows no $ARTISTNAME.)
                _attachFavUrl($it, $svc, $it->{_cover}, $artist);
            }
            $result[$i] = \@matched;
            $resolve->();
        };

        $svcTimer = Slim::Utils::Timers::setTimer(undef, time() + STREAM_SVC_TIMEOUT, sub {
            return if $settled || $resolved;
            $log->warn("resolve $svc timed out");
            $settle->(undef);
        });

        eval { $a->{run}->($client, $queryEnc, $artistNorm, $albumNorm, $svc, $settle); 1 } or do {
            $log->warn("resolve $svc failed: $@");
            $settle->(undef);
        };
    }
}

# Cache matched items. Qobuz/Tidal/Deezer album nodes all carry a CODEREF url that
# Storable can't serialise — stripped here, reattached per service on read by
# _rebuildStreamItems (the album id rides `passthrough`, which survives the cache).
# Guarded: Storable dies on unexpected nested refs and that must not stop the page.
# Decorate a matched streaming album with a ListenLater-friendly favorites_url:
#   <scheme>://album:<nativeId>[?cover=<url-encoded art>][&a=<url-encoded artist>]
# XMLBrowser copies an explicit $item->{favorites_url} into presetParams.favorites_url
# (which Material exposes as $FAVURL) — without it the coderef `url` leaks as the favurl
# and ListenLater sees a broken link with no service/id. ListenLater reads the scheme as
# the source, album:<id> for direct replay, and the private ?cover=/&a= params (which it
# strips before saving) for artwork + artist. Same handshake as the sibling plugin.
# No native id → no favurl (the row still displays + plays here; it just can't be added
# to ListenLater with full fidelity). Ported from ListenBrainz Fresh Releases.
sub _attachFavUrl {
    my ($it, $svc, $art, $artist) = @_;
    my $id = $it->{_albumid};
    return unless defined $id && length $id;

    my $fav = lc($svc) . '://album:' . $id;   # scheme = ListenLater's qobuz/tidal/deezer source tag
    my @params;

    if (defined $art && !ref $art && length $art) {   # plain URL string only (not a coderef/other ref)
        require URI::Escape;
        push @params, 'cover=' . URI::Escape::uri_escape_utf8($art);
    }
    # Material sends these matched rows no $ARTISTNAME (subtitle is the date/genre/capsule,
    # not the artist), so pack the review artist as a private &a= param; ListenLater reads
    # it as a fallback when $ARTISTNAME is empty, then strips it.
    if (defined $artist && !ref $artist && length $artist) {
        require URI::Escape;
        push @params, 'a=' . URI::Escape::uri_escape_utf8($artist);
    }

    $fav .= '?' . join('&', @params) if @params;
    $it->{favorites_url} = $fav;
}

sub _cacheStream {
    my ($key, $items, $ttl) = @_;
    my @store = map { my %x = %$_; delete $x{url}; \%x } @$items;
    eval { $cache->set($key, { items => \@store }, $ttl); 1 }
        or $log->warn("resolve cache set failed: $@");
}

# Dedupe by service + display text (services sometimes return the same album
# twice; different editions differ in name and are kept).
sub _dedupeStreamItems {
    my ($items) = @_;
    my (%seen, @out);
    for my $it (@{ $items || [] }) {
        my $k = join('|', $it->{_svc} // '', $it->{name} // '', $it->{line2} // '');
        next if $seen{$k}++;
        push @out, $it;
    }
    return \@out;
}

# Cap + dedupe; a no-match yields a single informational text row.
sub _streamResult {
    my ($client, $items) = @_;
    $items = _dedupeStreamItems($items);
    $items = [ @{$items}[0 .. STREAM_MAX_RESULTS - 1] ] if @$items > STREAM_MAX_RESULTS;
    return @$items
        ? $items
        : [ { name => cstring($client, 'PLUGIN_PITCHFORKREVIEWS_NO_MATCH'), type => 'text' } ];
}

# Rebuild playable items from cached (url-stripped) data by reattaching each
# service's native play coderef. Items whose service is no longer enabled/present
# are dropped (so disabling a service hides its cached matches immediately).
sub _rebuildStreamItems {
    my ($cached) = @_;

    my %enabled = map { $_->{name} => 1 } _orderedAdapters();

    my @out;
    for my $c (@{ $cached || [] }) {
        my %item = %$c;
        my $svc  = $item{_svc} // '';
        next unless $enabled{$svc};

        if ($svc eq 'Qobuz' && Plugins::Qobuz::Plugin->can('QobuzGetTracks')) {
            $item{url} = \&Plugins::Qobuz::Plugin::QobuzGetTracks;
        }
        elsif ($svc eq 'Tidal' && Plugins::TIDAL::Plugin->can('getAlbum')) {
            $item{url} = \&Plugins::TIDAL::Plugin::getAlbum;
        }
        elsif ($svc eq 'Deezer' && Plugins::Deezer::Plugin->can('getAlbum')) {
            # Same shape as Tidal: `_renderAlbum` set `url => \&getAlbum` (stripped on
            # cache) with the album id in `passthrough` (preserved), so getAlbum
            # resolves the tracklist on read. (The `deezer://album:<id>` string is the
            # `play`/favourites value, not this browse url.)
            $item{url} = \&Plugins::Deezer::Plugin::getAlbum;
        }
        else {
            next;
        }

        push @out, \%item;
    }

    return \@out;
}

# Qobuz: search albums via the plugin's own API, keep title+artist matches, and
# reuse the plugin's _albumItem so each result is a native, playable album node.
sub _searchQobuz {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return; }   # undef -> inconclusive

    $api->search(sub {
        my $res = shift;
        return $collect->(undef) unless defined $res;   # errored, not "no results"
        my @out;
        my $rendererFailed = 0;
        for my $album (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
            my $candArtist = ref $album->{artist} eq 'HASH' ? $album->{artist}{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            next if defined $album->{streamable} && !$album->{streamable};   # drop bogus non-streamable dupes
            # Guard the foreign renderer — a die here is inside this async callback,
            # outside _findPlayable's eval; skip a bad item, don't stall the service.
            my $item = eval { Plugins::Qobuz::Plugin::_albumItem($client, $album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Qobuz _albumItem failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            push @out, $item;
        }
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, lc($query), 'albums');
}

# Tidal: mirror of _searchQobuz using the Tidal plugin's own API + renderer.
sub _searchTidal {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return; }

    $api->search(sub {
        my $albums = shift;   # raw album hashes (type => albums)
        return $collect->(undef) unless defined $albums;
        my @out;
        my $rendererFailed = 0;
        for my $album (@{ $albums || [] }) {
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            my $item = eval { Plugins::TIDAL::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Tidal _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            push @out, $item;
        }
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { type => 'albums', search => $query, limit => 50 });
}

# Deezer: mirror of _searchTidal (ported from the ListenBrainz plugin). getAPIHandler
# returns a Plugins::Deezer::API::Async; ->search calls back with a bare arrayref of
# raw album hashes; `_renderAlbum` returns a native album node (`url => \&getAlbum`
# coderef, id in passthrough) that round-trips the cache exactly like Tidal's.
sub _searchDeezer {
    my ($client, $query, $artistNorm, $albumNorm, $svc, $collect) = @_;

    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return; }

    $api->search(sub {
        my $albums = shift;
        return $collect->(undef) unless defined $albums;
        # Tolerate a hash-wrapped list so a shape mismatch degrades to a clean miss
        # rather than dying in this async callback (outside _findPlayable's eval).
        $albums = $albums->{data} || $albums->{albums} || [] if ref $albums eq 'HASH';
        return $collect->([]) unless ref $albums eq 'ARRAY';
        my @out;
        my $rendererFailed = 0;
        for my $album (@$albums) {
            next unless ref $album eq 'HASH';
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            next unless _albumMatches($artistNorm, $albumNorm, $candArtist, $album->{title});
            my $item = eval { Plugins::Deezer::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Deezer _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            $item->{_albumid} = $album->{id};   # native id → ListenLater favurl (album:<id>)
            push @out, $item;
        }
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { search => $query, type => 'album', strict => 'off', limit => 50 });
}

# ===========================================================================
# Matching (verbatim from the ListenBrainz plugin — keep in sync if that changes)
# ===========================================================================

# A candidate album matches when its title equals or begins with our album title
# (word boundary) AND the artist matches. With no artist to disambiguate, only an
# exact title match counts.
sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle) = @_;

    return 0 if length $albumNorm < 2;
    my $t = _norm($candTitle);
    return 0 if $t eq '';

    my $ok = ($t eq $albumNorm || index($t, "$albumNorm ") == 0);

    # Fallback for the trailing FORMAT descriptor Pitchfork appends ("… EP", "… LP")
    # that streaming services usually omit from the album title — e.g. Pitchfork
    # "Songs From a Valley Girl EP" vs Qobuz "Songs From a Valley Girl". Compare again
    # with a trailing standalone "ep"/"lp" token stripped from BOTH sides, gated so a
    # 1-2 char base can't false-match.
    if (!$ok) {
        my $ab = _stripFmt($albumNorm);
        my $tb = _stripFmt($t);
        $ok = 1 if length($ab) >= 3 && length($tb) >= 3
                && ($tb eq $ab || index($tb, "$ab ") == 0);
    }

    # Fallback for DECORATIVE non-ASCII glyphs that differ between sources — e.g.
    # Pitchfork "3x6x𐕣 =666…" (Teller Bank$) vs Qobuz "3x6x* =666…", where the
    # syllabics glyph is a Unicode "letter" _norm keeps but the service spells it
    # "*". Compare again with all non-ASCII stripped, but ONLY when both titles
    # still carry ASCII content: a genuine CJK/Cyrillic title strips to empty and
    # keeps the strict comparison above, so it can't false-match a different album.
    if (!$ok) {
        my $aa = _asciiNorm($albumNorm);
        my $ta = _asciiNorm($t);
        $ok = 1 if length($aa) >= 2 && length($ta) >= 2
                && ($ta eq $aa || index($ta, "$aa ") == 0);
    }
    return 0 unless $ok;

    # With no artist to disambiguate, require an exact FULL-norm title (the ascii
    # fallback is only trusted alongside an artist match).
    return ($t eq $albumNorm) ? 1 : 0 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
}

# Strip a trailing standalone format descriptor ("ep"/"lp") that Pitchfork appends
# to a title but streaming services usually leave off. Only the LAST token.
sub _stripFmt {
    my $s = shift // '';
    $s =~ s/\s+(?:ep|lp)$//;
    return $s;
}

# _norm with all non-ASCII stripped — used only as an album-title fallback (see
# _albumMatches) to bridge decorative-glyph spelling differences between sources.
sub _asciiNorm {
    my $s = shift // '';
    $s =~ s/[^\x00-\x7f]+/ /g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

# Token-subset artist match: every word of the shorter credit must appear in the
# longer (tolerates word order, & vs , and partial credits).
sub _artistMatch {
    my ($a, $b) = @_;
    return 0 if $a eq '' || $b eq '';

    my %at = map { ($_ => 1) } split ' ', $a;
    my %bt = map { ($_ => 1) } split ' ', $b;
    my ($small, $big) = (scalar keys %at <= scalar keys %bt) ? (\%at, \%bt) : (\%bt, \%at);

    for my $tok (keys %$small) {
        return 0 unless $big->{$tok};
    }
    return 1;
}

# Diacritic folding for _norm (see the ListenBrainz plugin for the full rationale).
my $HAVE_NFD = eval { require Unicode::Normalize; 1 } ? 1 : 0;
my %FOLD = (
    "\x{131}" => 'i', "\x{142}" => 'l', "\x{f8}" => 'o', "\x{f0}" => 'd',
    "\x{111}" => 'd', "\x{fe}" => 'th', "\x{df}" => 'ss', "\x{e6}" => 'ae',
    "\x{153}" => 'oe', "\x{127}" => 'h',
);

# Normalise a title/artist for fuzzy matching: decode octets, lowercase, fold
# Latin diacritics, drop bracketed qualifiers + punctuation, collapse whitespace.
# Keeps alphanumerics from any script so non-Latin names survive.
sub _norm {
    my $s = shift // '';
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);   # only adopt if valid UTF-8
    }
    $s = lc($s);
    if ($HAVE_NFD && utf8::is_utf8($s)) {
        $s = Unicode::Normalize::NFC(
             Unicode::Normalize::NFD($s) =~ s/[\x{0300}-\x{036F}]+//gr );
        $s =~ s/([^\x00-\x7f])/exists $FOLD{$1} ? $FOLD{$1} : $1/ge;
    }
    # Fold common STYLISED letter substitutions so a Pitchfork spelling matches the
    # service's (and vice-versa): "WOR$T" == "Worst", "$uicideboy$" == "Suicideboys",
    # "P!nk" == "Pink". These map to a letter BEFORE the punctuation pass below turns
    # them into spaces. (The currency signs also cover €/£/¥ stylisations.)
    $s =~ s/\$/s/g;
    $s =~ s/\x{20ac}/e/g;   # €
    $s =~ s/\x{a3}/l/g;     # £
    $s =~ s/\x{a5}/y/g;     # ¥
    $s =~ s/!/i/g;
    $s =~ s/\@/a/g;
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

1;

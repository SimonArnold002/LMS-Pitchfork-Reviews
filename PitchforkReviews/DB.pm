package Plugins::PitchforkReviews::DB;

# PERSISTENT storage for every Pitchfork list: Latest Reviews, Best New Music, High
# Scoring Albums, and each year-end list. Not a cache — a database.
#
# WHY, AND WHAT WAS LEARNED THE EXPENSIVE WAY.
#
# Simon proposed a database for this early on — "they are fixed entities with one new
# list per year" — and was talked out of it on the grounds that a cache would do. That
# was the right call and should have been taken then; five releases went into trying to
# make a cache hold data that a table holds without argument.
#
# Two independent reasons, and the second only became clear after the first was chased
# to a standstill:
#
#   1. DURABILITY. A published year-end list is IMMUTABLE — Pitchfork does not revise
#      "The 50 Best Albums of 2019". A cache is disposable by design: LMS may purge it,
#      a settings "clear caches" wipes it, DbCache may evict under pressure. No TTL,
#      however long, expresses "this never needs fetching again". 365 days was only ever
#      an approximation of a requirement that is really "keep it".
#
#   2. THE CACHE WAS BEING MISUSED, AND THE CAUSE IS NOW KNOWN (0.9.9).
#      From 0.9.0 to 0.9.7 the year lists were not cached AT ALL: `$cache->set` returned
#      success, raised nothing, and the very next `$cache->get` returned undef. The
#      reason is in Slim/Utils/DbCache.pm, _canonicalize_expiration_time:
#
#          # "If value is less than 60*60*24*30 (30 days), time is assumed to be
#          # relative from the present. If larger, it's considered an absolute Unix time."
#          if ( $expiry <= 2592000 && $expiry > -1 ) { $expiry += time(); }
#
#      YEAR_CLOSED_TTL was 365 days, so it was stored as an absolute epoch of
#      1971-01-01 — expired before it was written. The full mechanism is documented
#      beside STREAM_FOUND_TTL in Browse.pm.
#
#      THREE WRONG DIAGNOSES WERE SHIPPED BEFORE THAT WAS FOUND, and the pattern is the
#      part worth keeping:
#
#        0.9.3  blamed the TTL — CORRECTLY — then "disproved" itself by lowering the
#               ceiling 365 -> 90 days, which is STILL over the boundary. Nothing
#               changed, so the right hypothesis was thrown away.
#        0.9.5  blamed value size          -> every failing write carried a 90-day TTL
#        0.9.6  blamed the shared cache.db -> so did those
#
#      Each later experiment varied size or location while holding the TTL fixed at the
#      suspect value, so every "disproof" was measuring the same broken write. The rule:
#      move the variable ACROSS the suspected boundary, and when a fix changes nothing,
#      treat the FIX as unproven rather than the hypothesis as disproven.
#
# So this module is NOT a workaround for the bug above — that bug has a one-line fix and
# it has been applied. The data wants a table on its own merits, and reason (1) is the
# whole of it: immutable once published, tiny as rows (10 years x 50 albums = 500),
# expensive to re-derive (a 1.75MB article and a parse per year), and needing to outlive
# a cache purge. Even with the ceiling respected, 30 days is the longest a cache entry
# can live here, and "30 days" is not what "this list is finished for ever" means.
#
# Modelled on Plugins::ListenLater::DB, which has run this pattern in the same fleet for
# a long time: a plain SQLite file via DBI/DBD::SQLite, both of which ship with LMS (the
# library database uses them). `sqlite_unicode => 1` is load-bearing — it keeps the
# character/octet boundary inside DBD::SQLite instead of leaving it to callers, which is
# the trap documented at length across LMS-Discography.
#
# ONE ROW PER ALBUM, not one blob per list. That is what makes this a database rather
# than a cache with extra steps: the rows are queryable, so a later feature (search
# across every year, "which lists is this artist on") needs no new storage.

use strict;
use warnings;

use DBI;
use Storable ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log = Slim::Utils::Log::logger('plugin.pitchforkreviews');

my $dbh;      # lazily-opened handle
my $broken;   # set once when the DB cannot be opened, so we complain once and degrade

# The columns that actually vary per entry. `year` is deliberately NOT among them: it is
# recoverable from the list key, and storing it would repeat one value across 50 cells.
my @COLS = qw(rank artist album title capsule link date cover genre list_title score is_bnm);

# NULLABLE columns. The two item shapes are not identical: a year entry has a `rank` and
# a `list_title` and no score; a feed entry has a `score` and neither of the others. So
# the columns only one of them fills must accept NULL, and everything else must be
# defaulted on the way in — passing an explicit undef into a NOT NULL column aborts the
# whole transaction, which showed up as a feed list simply refusing to store.
my %NULLABLE = map { $_ => 1 } qw(rank score);

sub _path {
    my $dir = preferences('server')->get('cachedir') || '/tmp';
    return "$dir/pitchforkreviews.db";
}

sub dbh {
    return undef if $broken;
    return $dbh if $dbh && eval { $dbh->ping };

    my $path = _path();
    $dbh = eval {
        my $h = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
            RaiseError     => 1,
            PrintError     => 0,
            AutoCommit     => 1,
            sqlite_unicode => 1,
        });
        $h->do('PRAGMA journal_mode=WAL');
        _migrate($h);
        $h;
    };

    unless ($dbh) {
        # DEGRADE, NEVER DIE. Without the DB the plugin still works — it re-fetches each
        # list exactly as it did before this module existed. A storage layer that can
        # take the whole plugin down with it would be worse than the bug it replaces.
        $broken = 1;
        $log->error("year/list DB unavailable at $path ($@) — lists will be re-fetched each time");
        return undef;
    }

    $log->info("Pitchfork list DB ready at $path");
    return $dbh;
}

sub _migrate {
    my ($h) = @_;

    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS list_item (
    list_key   TEXT    NOT NULL,
    position   INTEGER NOT NULL,
    rank       INTEGER,
    artist     TEXT    NOT NULL DEFAULT '',
    album      TEXT    NOT NULL DEFAULT '',
    title      TEXT    NOT NULL DEFAULT '',
    capsule    TEXT    NOT NULL DEFAULT '',
    link       TEXT    NOT NULL DEFAULT '',
    date       TEXT    NOT NULL DEFAULT '',
    cover      TEXT    NOT NULL DEFAULT '',
    genre      TEXT    NOT NULL DEFAULT '',
    list_title TEXT    NOT NULL DEFAULT '',
    score      REAL,
    is_bnm     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (list_key, position)
)
SQL

    # stored_at drives the only lists that still expire (the rolling feeds, and the
    # CURRENT year while it can still be corrected). A closed year has no expiry at all.
    # parse_version is what makes that safe — see getList.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS list_meta (
    list_key      TEXT PRIMARY KEY,
    stored_at     INTEGER NOT NULL,
    item_count    INTEGER NOT NULL,
    parse_version INTEGER NOT NULL DEFAULT 0
)
SQL

    $h->do('CREATE INDEX IF NOT EXISTS list_item_artist ON list_item (artist)');

    # THE KEY/VALUE SIDE (0.9.11) — everything that used to live in Slim::Utils::Cache.
    #
    # 0.9.8 moved the LISTS here and deliberately left the streaming resolve behind in
    # `pfr:stream`, arguing that a matcher fix should cost re-resolution but not
    # re-downloading 17.5MB of articles. That argument is for keeping the two layers
    # SEPARATE — which two tables do — and was never an argument for leaving one of them
    # in the store that had just been proved to eat data silently. The resolve cache is
    # the most expensive thing in the plugin to rebuild (588 items, five measured
    # minutes) and it was the layer still exposed to the 30-day boundary.
    #
    # `expires_at` IS AN ABSOLUTE EPOCH, ALWAYS, and 0 means never. There is no
    # relative/absolute guessing, so there is no boundary and no value of a TTL that
    # silently means "already expired" — the entire defect class that cost 0.9.0-0.9.9
    # cannot be expressed here.
    $h->do(<<'SQL');
CREATE TABLE IF NOT EXISTS kv (
    k          TEXT PRIMARY KEY,
    v          BLOB,
    expires_at INTEGER NOT NULL DEFAULT 0
)
SQL
    $h->do('CREATE INDEX IF NOT EXISTS kv_expiry ON kv (expires_at)');

    # Sweep on open. NOT sufficient on its own — see kvSweep, which the warm calls.
    eval { $h->do('DELETE FROM kv WHERE expires_at > 0 AND expires_at < ?', undef, time()) };

    return;
}

# ---------------------------------------------------------------------------
# Key/value store — the resolve cache, the newest-year answer, the negative markers.
#
# Storable rather than JSON so a plain scalar, an undef and a hashref all round-trip
# without the caller having to care. The value is wrapped in a hash because 0 and undef
# are both MEANINGFUL here: getLatestYear stores 0 as "a completed sweep that found
# nothing", which has to stay distinguishable from "not stored". A bare freeze of 0
# would come back indistinguishable from a miss the moment anything tested truth.
# ---------------------------------------------------------------------------

# undef when absent OR expired. A caller that needs to tell those apart should store a
# sentinel, exactly as getLatestYear does.
sub kvGet {
    my ($key) = @_;
    my $h = dbh() or return undef;
    return undef unless defined $key && length $key;

    my $row = eval {
        $h->selectrow_arrayref('SELECT v, expires_at FROM kv WHERE k = ?', undef, $key)
    } or return undef;

    my ($blob, $exp) = @$row;
    if ($exp && $exp < time()) {
        eval { $h->do('DELETE FROM kv WHERE k = ?', undef, $key) };
        return undef;
    }

    my $wrapped = eval { Storable::thaw($blob) };
    unless (ref $wrapped eq 'HASH') {
        $log->warn("kv: unreadable value for $key — treating as absent");
        return undef;
    }
    return $wrapped->{v};
}

# $ttl is SECONDS FROM NOW, or undef/0 for "never expires". Any duration is valid —
# see the note on expires_at in _migrate.
sub kvSet {
    my ($key, $value, $ttl) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;

    my $exp = $ttl ? time() + $ttl : 0;
    my $ok  = eval {
        $h->do('INSERT OR REPLACE INTO kv (k, v, expires_at) VALUES (?, ?, ?)',
               undef, $key, Storable::nfreeze({ v => $value }), $exp);
        1;
    };
    $log->warn("kv: store failed for $key: $@") unless $ok;
    return $ok ? 1 : 0;
}

sub kvDel {
    my ($key) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;
    eval { $h->do('DELETE FROM kv WHERE k = ?', undef, $key); 1 } or return 0;
    return 1;
}

# Wipe every kv row whose key starts with $prefix — how a version bump retires a whole
# family of keys (all `pfr:stream:*`, say) without touching the lists.
sub kvForgetPrefix {
    my ($prefix) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $prefix && length $prefix;
    my $n = eval { $h->do('DELETE FROM kv WHERE k LIKE ?', undef, $prefix . '%') } || 0;
    return int($n);
}

sub kvCount {
    my $h = dbh() or return 0;
    return int(eval { $h->selectrow_array('SELECT COUNT(*) FROM kv') } || 0);
}

# Delete every expired row. Returns how many went.
#
# WHY THIS EXISTS SEPARATELY FROM THE SWEEP IN _migrate (0.9.11). That one runs from
# dbh(), which returns early once the handle is cached — so it fires ONCE PER SERVER
# START and never again. The rows that need collecting are precisely the ones nothing
# will ever read again (a review that rotated off the Pitchfork listing keeps its
# resolve row for STREAM_FOUND_TTL, and by definition nobody asks for it), so the
# per-read cleanup in kvGet cannot reach them either. On a server that stays up for
# months the table therefore grows with uptime.
#
# It was invisible here because Simon's server is stopped and started by a backup every
# morning, which swept it daily by accident. "Bounded because this machine happens to
# restart" is not a cleanup strategy, and it is the same shape as the TTL bug: correct
# on the box it was written on, wrong everywhere else. The warm tick calls this every
# WARM_INTERVAL, which makes collection independent of uptime.
sub kvSweep {
    my $h = dbh() or return 0;
    my $n = eval {
        $h->do('DELETE FROM kv WHERE expires_at > 0 AND expires_at < ?', undef, time())
    } || 0;
    return int($n);
}

# ---------------------------------------------------------------------------
# Read / write
# ---------------------------------------------------------------------------

# The stored list for $key, in stored order, or undef when it is not held.
#
# TWO RULES, BOTH ANSWERING "not held" RATHER THAN SOMETHING PLAUSIBLE:
#
#   COUNT MISMATCH. Rows != item_count means a half-written list. Handing that back
#   would look exactly like a successful read while silently losing albums, which is
#   the worst failure available here — wrong and quiet.
#
#   PARSE VERSION. A permanent store keeps a PARSING MISTAKE permanently too. When
#   _parseYear/_parseState change what they extract, bumping PARSE_VERSION makes every
#   stored list read as absent, so it is re-fetched with the corrected parser. This
#   replaces the hand-maintained `pfr:year:3` / `pfr:listing:5` key suffixes, which had
#   to be edited in several files at once and were got wrong more than once.
#
#   NB a MATCHER fix needs none of this: which streaming album a row resolves to is not
#   stored here at all — it lives in pfr:stream and is versioned there. This table holds
#   Pitchfork's data, never the resolution.
sub getList {
    my ($key, $parseVersion) = @_;
    my $h = dbh() or return undef;
    return undef unless defined $key && length $key;

    my $meta = eval {
        $h->selectrow_hashref(
            'SELECT stored_at, item_count, parse_version FROM list_meta WHERE list_key = ?',
            undef, $key)
    } or return undef;
    return undef unless $meta->{item_count};

    if (defined $parseVersion && $meta->{parse_version} != $parseVersion) {
        $log->info("$key: stored by parse version $meta->{parse_version}, "
                 . "current is $parseVersion — re-fetching");
        return undef;
    }

    my $rows = eval {
        $h->selectall_arrayref(
            'SELECT ' . join(', ', @COLS) . ' FROM list_item WHERE list_key = ? ORDER BY position',
            { Slice => {} }, $key)
    } or return undef;

    if (scalar(@$rows) != $meta->{item_count}) {
        $log->warn("$key: DB holds " . scalar(@$rows) . " rows but meta says "
                 . "$meta->{item_count} — treating as not stored");
        return undef;
    }

    # Restore the exact item shape the parsers emit, so nothing downstream (row builder,
    # resolver, ListenLater handshake) can tell where the list came from. A year list
    # carries a `year`; the rolling feeds do not, and must not gain one.
    my ($year) = $key =~ /^year:(\d+)$/;
    for my $r (@$rows) {
        $r->{year} = $year if defined $year;
        # rank and list_title belong to year lists only. Handing a feed item back with
        # an empty `list_title` it never had would be a subtly different hash from the
        # one the parser produces, and "subtly different" is how a renderer picks the
        # wrong branch six months later.
        delete $r->{rank}       unless defined $r->{rank};
        delete $r->{list_title} unless length($r->{list_title} // '');
    }
    return $rows;
}

# Replace everything held for $key, in ONE transaction. Returns 1 on success.
#
# The transaction is what makes rotation free: the three feeds are rolling lists, so
# every fetch replaces the whole set and the entries that rotated off the page are
# deleted in the same statement. Nothing accumulates and no separate sweep is needed.
sub putList {
    my ($key, $items, $parseVersion) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;
    return 0 unless ref $items eq 'ARRAY' && @$items;

    my $ok = eval {
        $h->begin_work;
        $h->do('DELETE FROM list_item WHERE list_key = ?', undef, $key);

        my $ins = $h->prepare(
            'INSERT INTO list_item (list_key, position, ' . join(', ', @COLS) . ') VALUES (?, ?, '
          . join(', ', ('?') x @COLS) . ')');

        my $pos = 0;
        for my $it (@$items) {
            $ins->execute($key, $pos++,
                map { $NULLABLE{$_} ? $it->{$_}
                    : $_ eq 'is_bnm' ? ($it->{$_} ? 1 : 0)
                    :                  ($it->{$_} // '') } @COLS);
        }

        $h->do('INSERT OR REPLACE INTO list_meta (list_key, stored_at, item_count, parse_version) '
             . 'VALUES (?, ?, ?, ?)',
               undef, $key, time(), scalar @$items, ($parseVersion // 0));
        $h->commit;
        1;
    };

    unless ($ok) {
        my $err = $@;
        eval { $h->rollback };
        $log->warn("$key: DB write failed ($err) — will re-fetch next time");
        return 0;
    }

    $log->info("$key: stored " . scalar(@$items) . " items in the DB");
    return 1;
}

# Seconds since $key was stored, or undef when it is not held. The rolling feeds and the
# current year use this to decide on a refresh; a closed year never asks.
sub listAge {
    my ($key) = @_;
    my $h = dbh() or return undef;
    my $at = eval {
        $h->selectrow_array('SELECT stored_at FROM list_meta WHERE list_key = ?', undef, $key)
    };
    return defined $at ? (time() - $at) : undef;
}

# Drop one list — what the Refresh row does before re-fetching.
sub forget {
    my ($key) = @_;
    my $h = dbh() or return 0;
    return 0 unless defined $key && length $key;
    eval {
        $h->begin_work;
        $h->do('DELETE FROM list_item WHERE list_key = ?', undef, $key);
        $h->do('DELETE FROM list_meta WHERE list_key = ?', undef, $key);
        $h->commit;
        1;
    } or do { my $e = $@; eval { $h->rollback }; $log->warn("$key: DB delete failed: $e") };
    return 1;
}

sub forgetAll {
    my $h = dbh() or return 0;
    eval { $h->do('DELETE FROM list_item'); $h->do('DELETE FROM list_meta'); 1 }
        or $log->warn("DB clear failed: $@");
    return 1;
}

sub storedKeys {
    my $h = dbh() or return ();
    my $r = eval { $h->selectcol_arrayref('SELECT list_key FROM list_meta ORDER BY list_key') } || [];
    return @$r;
}

1;

# Code review — 0.7.11 → 0.9.23

Reviewed: full working-tree diff on `dev` (~4,200 lines across `API.pm`, `Browse.pm`,
`Plugin.pm`, `Settings.pm`, `HomeExtras.pm`, `strings.txt`, plus the new `DB.pm`).

**Cleared, no action needed:** all 11 committed test suites pass (741 assertions); the zip
matches the working tree; version and `<sha>` consistent across `install.xml` and
`repo.xml`; no missing or orphaned string tokens; no calls to undefined subs.

Traced and held up: the `%PENDING` / `%RESOLVING` coalescing and token release, the
wedged-slot adoption, `$FG_INFLIGHT` accounting, the warm's two-phase fetch/resolve chain
and its watchdog, `_parseYear`'s rank/cover state machine, the `Storable`+SQLite blob
round-trip (verified empirically against real DBD::SQLite — it round-trips correctly), the
entity decoder's one-pass rule, and the adapter memo gating.

Four findings, most severe first.

---

## 1. `tidalImageProxy` squares a non-square image, so the URL it writes 404s

**Severity:** medium — cross-plugin, user-visible as missing artwork.
**Where:** `PitchforkReviews/Browse.pm:2273-2274`, in `tidalImageProxy`
(`Browse.pm:2265`).

### What happens

The handler captures the current width out of a two-dimension path segment and then
substitutes a **square**:

```perl
my ($cur) = $url =~ m{/(\d+)x\d+\.\w+$};
$url =~ s{/\d+x\d+(\.\w+)$}{/${w}x${w}$1} if _onlyDown($cur, $w);
```

Height is matched but never carried through. A TIDAL image at `/480x320.jpg` against a
150px spec is rewritten to `/320x320.jpg` — a rendition Tidal does not serve, so the
proxy fetch 404s and the row shows no picture at all.

`_onlyDown` compares width only, so it does not stop this: 320 < 480 reads as a shrink and
the substitution proceeds.

**It is not confined to our rows.** 0.9.23's own finding 3 established that
`Slim::Web::ImageProxy->registerHandler` matches on the URL, not on which plugin produced
it, so this rewrites *every* `resources.tidal.com` image on the server — the TIDAL
plugin's own artist and playlist views included, which is where the non-square sources
live. Album covers are square and unaffected, which is why this survived.

`_fitCover`'s Tidal branch (`Browse.pm:2151`) already preserves `$1x$2` on its pass-through
branch, so the two-dimension case was known on that side of the file.

### Fix

Capture both dimensions and scale them together, preserving the aspect ratio:

```perl
my ($cw, $ch) = $url =~ m{/(\d+)x(\d+)\.\w+$};
```

then write `/${w}x${h}` where `$h` is `$ch` scaled by `$w/$cw` (rounded). Simplest safe
alternative if a proportional height is not wanted: **leave a non-square URL alone** —
return it verbatim unless `$cw == $ch`. That preserves every case PFR authors (all square)
and stops touching the ones it should never have been rewriting.

### Verifying

Table test: a square Tidal URL shrinks as today; a `480x320` URL at a 150 spec comes back
either proportionally scaled or byte-identical, never `320x320`.

---

## 2. `_splitAlbumTitles` classifies padding from the whole title but splits every slash

**Severity:** medium — silent wrong-album playback, the exact failure the split rules exist
to prevent.
**Where:** `PitchforkReviews/Browse.pm:2432-2433`, in `_splitAlbumTitles`
(`Browse.pm:2422`).

### What happens

```perl
my $padded = $album =~ m{\s/\s};
my @parts  = split m{\s*/\s*}, $album;
```

`$padded` is a property of the **whole title**, but the split pattern accepts *any* slash,
padded or not. A title carrying both spellings gets the padded treatment applied to
unpadded fragments.

`AC/DC / Live at Donington` is the case. It contains ` / `, so `$padded` is true; the split
then also breaks the unpadded `AC/DC`, giving three sides — `AC`, `DC`, `Live at
Donington` — which is within `TITLE_SPLIT_MAX` (3), so the split is accepted.

That matters because 0.9.21 restricted the exactness gate to **unpadded** splits: a padded
split still trusts a **loose** side. `_albumMatches` admits a fragment through
`index($t, "$albumNorm ") == 0`, so `AC` matches a service title of "AC/DC Live" and
becomes the row's playable album. The row plays a record the review is not about, with no
error anywhere.

The artist-name guard does not reach this: it compares the **whole** normalised title
against the artist, and `ac dc live at donington` is not `ac dc`.

### Fix

Decide padding **per separator**, not per title — split only on the spelling that was
detected:

```perl
my $padded = $album =~ m{\s/\s};
my @parts  = $padded ? split(m{\s+/\s+}, $album) : split(m{/}, $album);
```

A padded title then keeps its unpadded slashes intact (`AC/DC` survives as one side), and
the exactness gate still governs genuinely unpadded titles as 0.9.21 designed. Trim as
today afterwards.

### Verifying

Add `AC/DC / Live at Donington` to the split table: assert exactly two sides, `AC/DC` and
`Live at Donington`, and that a loose prefix match on a bare `AC` is not reachable.
Anti-test by restoring the permissive split — it should produce three sides.

---

## 3. The feed path has no negative marker, so a failing feed re-downloads for ever

**Severity:** medium — unbounded repeated ~1–2MB fetches, invisible in the log after the
first warning.
**Where:** `PitchforkReviews/API.pm:479` (the freshness gate) with the failure paths at
`API.pm:511-513`, `517-520` and `523-526`, all in `_fetchState` (`API.pm:466`).

### What happens

The gate is age-based and the age comes from the stored list:

```perl
my $age = $stored ? DB::listAge($key) : undef;
if (!$opts{force} && $stored && defined $age && $age < FEED_TTL) { return $cb->($stored); }
```

`stored_at` moves only when `putList` runs, and `putList` runs **only on the success path**
— a parse of ≥1 item. Every other outcome answers the caller from `$stored` and writes
nothing:

| outcome | line | writes `stored_at`? |
|---|---|---|
| parsed 0 items | `API.pm:511-513` | no |
| parse/store threw | `API.pm:517-520` | no |
| HTTP fetch failed | `API.pm:523-526` | no |

So once a feed starts failing, `$age` stays past `FEED_TTL` permanently. Every view open
and every warm tick re-issues the full listing-page download — indefinitely, for as long as
the upstream fault lasts. Coalescing bounds the *concurrent* count, not the rate.

The year path already has the answer to this: `YEAR_MISS_TTL` / `LATEST_MISS_TTL`
(`API.pm:103-104`), written as separate kv keys at `API.pm:352` and `API.pm:421`
specifically so a failed sweep is not re-walked. 0.8.9 finding 2 is this same defect on the
year path, and the feed path never got the equivalent.

### Fix

Mirror the year path exactly: on a fetch failure or a 0-item parse, write a short-TTL kv
marker under a separate key (`FEED_MISS_TTL`, 1h, matching the existing pair), and skip the
fetch while it stands — still answering from `$stored`, which is what keeps a failed
refresh from blanking the view. `force => 1` must skip the marker, as it does for the year
keys, so Refresh is always an immediate live retry.

Keep it a **separate key**, per the note already at `API.pm:348`: a miss must never
overwrite the good stored copy.

### Verifying

Drive `_fetchState` with a stub that fails: assert one fetch, then that a second call
inside the TTL issues **no** fetch and still answers from the stored list, then that the
fetch resumes once the marker lapses. Anti-test by dropping the marker write — the second
call should fetch again.

---

## 4. The `year:<Y>` Refresh downloads the same article twice per tap

**Severity:** low — wasteful, not incorrect.
**Where:** `PitchforkReviews/Browse.pm:1425-1429`, in `_refreshRow` (`Browse.pm:1409`).

### What happens

```perl
elsif ($src =~ /^year:(\d+)$/) {
    my $y = $1;
    API::getLatestYear(sub {
        API::getYearList($y, $reload, force => 1);
    }, force => 1);
}
```

Both calls carry `force`. `getLatestYear` under `force` re-probes candidate slugs from
`_topYear` down — and its probe *is* a `getYearList` fetch per candidate, so on the way to
answering "is a newer list published?" it force-fetches `$y` itself. The callback then
force-fetches `$y` again.

That is two full downloads of the same ~1.7MB article per tap. During the Nov–Dec waiting
window the probe also tries the unpublished current year first, so a single Refresh is four
large requests.

The behaviour is correct — the row is deliberately both "re-parse this list" and "has the
new list landed yet?", and that is worth keeping. Only the duplication is the defect.

### Fix

Let the probe's own fetch count: run `getLatestYear(force => 1)` first, then call
`getYearList($y, $reload)` **without** `force` if the probe has already fetched `$y` in
this pass. Simplest version that needs no plumbing: force only the probe, and have the
probe's fetch of `$y` be the re-parse — the list is written by `putList` either way, so the
callback's read is a fresh DB hit rather than a second download.

### Verifying

Count fetches through a stubbed transport across one `year:<Y>` Refresh: assert `$y` is
downloaded once, and that the newest-year probe still runs (i.e. the row keeps its second
job).

---

## Suggested order

1. **Finding 2** — the only one that silently plays the wrong record.
2. **Finding 1** — user-visible missing artwork, and it affects other plugins' views.
3. **Finding 3** — unbounded bandwidth against pitchfork.com under a fault.
4. **Finding 4** — housekeeping.

Findings 1 and 4 are render-time / control-flow only. Finding 2 changes match decisions for
titles of that shape, so it wants a `pfr:stream` key bump; finding 3 adds a new kv key and
needs none.

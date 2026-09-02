# Code review — 0.7.11 → 0.9.25

Reviewed: full working-tree diff on `dev` (`API.pm`, `Browse.pm`, `Plugin.pm`,
`Settings.pm`, `HomeExtras.pm`, `strings.txt`, the settings template, the new `DB.pm`) —
`git diff @{upstream}...HEAD` is empty (`dev` == `origin/dev`), so the scope is
`git diff HEAD` plus the untracked `DB.pm`: ~5,900 inserted lines covering the 0.9.25
hardening pass on top of everything from 0.7.11.

**Packaging is deliberately OUT OF SCOPE.** The tree is 0.9.25 while `install.xml`,
`repo.xml` and the shipped `PitchforkReviews.zip` are still 0.9.24 (the zip contains no
`_serveWaiters`, i.e. none of the four 0.9.25 fixes). That is not a finding — 0.9.25 was
sent straight to review without being built, so version, sha and zip contents are the
build step's job and are expected to be stale here.

**Cleared, no action needed:** all 11 committed suites pass (**819 assertions, 0
failures**); no missing or orphaned string tokens (every `PLUGIN_PITCHFORKREVIEWS_*` the
code or template uses exists in `strings.txt`; only `_DESC` is unreferenced, by design,
being `install.xml`'s); every `sprintf` placeholder count lines up; no calls to undefined
private subs across all four modules (the only apparent hits are inside comments); no
`Slim::Utils::Cache` usage survives outside commentary.

**Verified empirically rather than by inspection:** the `Storable::nfreeze` →
`DBD::SQLite` (`sqlite_unicode => 1`) → `thaw` round-trip that `DB::kvSet`/`kvGet` depend
on. That boundary is the one this file's own history says was got wrong repeatedly
(characters-vs-octets, the 0.9.0–0.9.7 silent-write era), so it was round-tripped against
real SQLite rather than reasoned about. It survives intact.

Traced and held up: the `%PENDING` / `_shareFetch` / `_issueFetch` coalescing (no caller
can be answered twice or zero times across all four force/nostale/adopted paths); the
`%RESOLVING` token-stamped slot release and waiter adoption; `$FG_INFLIGHT` accounting
under the per-iteration `$counted` flag; the `$pumping` re-entrancy guard and the warm
yield's wakeup path (no lost wakeup — `$active` is decremented before the re-pump, and the
recheck timer is armed exactly when `$active` is 0); the two-phase warm's closure-assignment
ordering against synchronous DB-hit callbacks; the combined-review split, exactness gate and
round-robin interleave against `STREAM_MAX_RESULTS`; `_entChr`/`_decodeEntities` single-pass
semantics; and the four image-proxy handlers' `_onlyDown` + square-only guards.

Two findings. Neither is a live defect on today's pages — one is a cost, one is latent —
which is worth stating plainly given how much of the reviewed span *was* live defects.

---

## 1. The `year:<Y>` Refresh row downloads a second full article on any closed year

**Severity:** low (cost only). **Where:** `PitchforkReviews/Browse.pm:1439`.

```perl
Plugins::PitchforkReviews::API::getLatestYear(sub {
    my $latest = shift;
    my $probed = defined $latest && $latest == $y;
    Plugins::PitchforkReviews::API::getYearList(
        $y, $reload, ($probed ? () : (force => 1)) );
}, force => 1);
```

The `$probed` condition is correct and 0.9.24 finding 4 is genuinely fixed — for the
**newest** year. What it does not cover is that **`getLatestYear` forwards its whole
`%opts` to every probe**:

```perl
getYearList($probe, sub { ... }, %opts);      # API.pm:474
```

So `force => 1` is inherited by the probe itself. Tapping Refresh on **2019** runs
`getYearList(2025, force => 1)` — a real ~1.7MB download of the current newest article,
re-parsed and re-stored — purely to answer "is there a newer list?", and then
`getYearList(2019, force => 1)` for the list the user actually asked to refresh. Two full
article fetches per tap, on every year except the newest.

The re-store is the part that grates: a published year-end list is immutable, which is the
premise the whole permanent-store design rests on, so forcing 2025's list to be
re-downloaded and rewritten is work that cannot change any stored byte.

**Why the probe wants force at all** is real and must be preserved: the row's second job is
"has the new list landed yet?", and without `force` the `pfr:year:latest:4` kv read
short-circuits the sweep entirely (`API.pm:445`), so the button would stop being a manual
retry.

**Fix:** force the *probe decision*, not the probe's fetches — skip the latest-year kv read
without pushing `force` down into `getYearList`. Either give `getLatestYear` a distinct
option for that (`resweep => 1`, which bypasses the kv gate but leaves `%opts` clean), or
strip `force` before it is forwarded:

```perl
my %probeOpts = %opts;
delete $probeOpts{force};
getYearList($probe, sub { ... }, %probeOpts);
```

Note the interaction to keep asserted in both directions: a probe that is no longer forced
reads the *current* year from store when it is fresh, which is what makes this cheap — and
`YEAR_TTL` still governs it, so a stale current year is still swept live. The closed-year
Refresh must still re-pull (the existing 0.9.24 assertion), and the newest-year Refresh must
still fetch exactly once (the other one).

---

## 2. `_parseYear` leaks a pending cover on the non-`h2` heading skip

**Severity:** low (latent). **Where:** `PitchforkReviews/API.pm:778`.

```perl
if ($t =~ /^(\d+)\.?$/) {           # trap 2: a bare number is a rank marker
    $printed = $1 + 0;
    next;
}
next unless $tag eq 'h2';           # sub-headings that aren't entries   <-- leaks
...
unless (length $album) {
    $cover = $printed = undef;      # 0.8.8's fix, on the adjacent branch
    next;
}
```

`$cover` and `$printed` are pending state, set by the `inline-embed` branch above and reset
on exactly two paths: the push (`API.pm:808`) and the h2-with-no-album branch
(`API.pm:789`). The `next unless $tag eq 'h2'` skip is a third exit and clears neither.

So an `h3` (or a `div.heading-h3` whose text is not a bare number) sitting between an
inline-embed and the next `h2` entry carries that embed's artwork forward: the following
entry, if it has no embed of its own, renders **the wrong album's cover**, and inherits a
`_printed` rank the page never gave it — which then feeds the countdown-direction test in
`_yearDirection`.

That is the identical defect 0.8.8 found and fixed on the branch two lines below, and its
description there applies verbatim: *"Both defects are silent: plausible output, no error."*

**Not reachable on any current page** — all ten live years 2016–2025 parse to 500/500 clean
entries with correct covers, and the sibling branch was equally unreachable when 0.8.8 fixed
it. The value here is that the pending-state contract becomes total (*every* exit that is
not an entry clears it) rather than true on two of three paths.

**Fix:** clear on the skip as well.

```perl
unless ($tag eq 'h2') {             # sub-headings that aren't entries
    $cover = $printed = undef;
    next;
}
```

**One caveat worth deciding on rather than absorbing**, because it is the reason this is
not a one-line certainty: the two skips are not quite the same shape. An h2 that yields no
album is an *entry-shaped* heading that failed, so the embed before it unambiguously
belonged to it. A decorative sub-heading between an embed and its entry — if Pitchfork ever
emits one that way round — would have its cover cleared by this fix and the entry would
render coverless. Coverless is the safe failure (the row still resolves and plays; only the
artwork falls back) against silently-wrong artwork plus a phantom rank, so the trade is the
right way round — but it is a trade, and the test should pin both directions: an embed
followed by a stray sub-heading then an entry, and an entry that legitimately follows a
sub-heading with its own embed.

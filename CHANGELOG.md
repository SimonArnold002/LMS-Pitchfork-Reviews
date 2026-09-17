# Changelog

All notable changes to **Pitchfork Reviews** are listed here.
Versions follow `MAJOR.MINOR.PATCH`.

## 1.0.0 — 2026-09-17

Spotify joins as a fourth service, every review shows its Pitchfork score, and the review lists
can be read highest score first.

### Improvements

- **Spotify.** Reviews now match and play from Spotify too, through the **Spotty** plugin. It
  sits fourth in the search order by default, so it is used when Qobuz, Tidal and Deezer don't
  have the album. Change its priority, or set it to 0 to turn it off, on the settings page like
  any other service.
- **The Pitchfork score on every review.** Best New Music, High Scoring Albums and Latest
  Reviews show the score at the start of each row's second line, as **Score 8.4/10**. The year-end
  lists are ranked rather than scored, so they show none.
- **View: Score.** The control at the top of each review list now cycles **View: Genre →
  Week → Score**. Score gives one flat list, highest first, headed with the number of albums
  matched. Your existing Genre or Week choice carries over.
- **Reviews titled "Title: Subtitle" now find their album.** When a service has nothing
  under the full title, the plugin searches again on the part before the colon.

### Fixes

- **A busy Spotify no longer marks albums as unmatched.** When Spotify is refusing requests
  (rate-limiting), an empty answer is treated as "try again later", not as "not on Spotify".
  The background refresh also slows down while this lasts, instead of adding to the
  load.

## 0.9.34 — Best Albums of the Year, reviews that cover two records, and matching that stops getting it quietly wrong

The largest release so far, and the one that adds a whole section. It also fixes a class of
fault that never announced itself: a review that played the *wrong* album, or one that could
never play at all, both looked exactly like a review that had simply not been matched yet.

### Added

- **Best Albums of the Year.** Pitchfork's annual top-50 as a fourth section — ranked, with
  each entry's cover and write-up, and a tap to play the album from Qobuz, Tidal or Deezer.
  It opens on the newest list published and every year back to **2016** sits behind the
  "Choose a year" row.
- **It promotes itself.** The plugin works out which year-end list is the newest rather than
  having it built in, and checks back while it is waiting — so when December's list goes live
  it simply becomes the one you land on. No update to install.
- **Read the year list either way** — #1 at the top, or in Pitchfork's own 50-to-1 countdown
  order. Tap "Sorted by" on the list to switch.
- **Grouping moved onto the list itself.** Switch the review lists between genre and week
  dividers with a tap, instead of a trip to the settings page — and the choice now applies to
  **all three** review lists, not only Latest Reviews. Your existing setting carries over.
- **Every view leads with an Options section.** Refresh, Choose a year, Sorted by and Grouped
  by sit under a proper Material heading instead of floating above the list, and a review's
  detail page is divided into Options, Streaming and the write-up.
- **The chosen year is named where you can see it** — above the list, in the page title and on
  the Material home shelf — so you always know which year you are looking at.
- **A review that covers two records now resolves both.** Pitchfork gives a pair issued
  together one review, titled `A / B` — Adrianne Lenker's *songs / instrumentals*, Yaeji's
  *EP/EP2*. No service carries an album under the joint name, so those reviews could never
  play. The first release is now the playable row and the second rides into the drill-in,
  labelled "Also covered by this review".
- **Not the right album? Change it.** Where a service carries another release under the same
  name, it is offered on the album page as "Another release with this name" — and **Refresh
  streaming match is finally reachable from a matched row**. Previously the one control that
  could correct a bad match was available only to rows with nothing to correct.
- **The review write-up now shows on albums that matched.** It used to appear only when
  nothing was found, so the better a review resolved, the less of it you could read.
- **A list still filling in says so** — "27 of 50 matched — still loading" in the header or
  page title, rather than presenting a partial list as though it were finished.
- **A Material home shelf for Best Albums of the Year**, alongside the three existing ones.
- **Dutch.** Every label, row and setting is translated, so an LMS set to Dutch reads in Dutch
  throughout. Contributed by **Blackfiction** ([PR #2]) and extended to cover the strings
  added since.

### Fixed

- **The year-end lists were never actually being stored.** Every open re-downloaded and
  re-parsed a ~1.7MB article — the server reported the write as successful and the next read
  found nothing. All of the plugin's lists now live in a real database of their own, and a
  published year-end list is kept permanently, because Pitchfork does not revise them.
  **Start-up to a fully populated set of lists went from 206 seconds to 39.**
- **A review whose title contained `&` could never match anything.** `Love &amp; Devotion` was
  being read literally, so the album was silently unplayable. HTML in Pitchfork's titles,
  capsules, artist names and genres is now decoded properly.
- **An album buried by a common-word artist name is now found.** Searching Qobuz for "Leo"
  returns 200 albums by other people and not the one under review, so *Cicada Burnt* never
  entered the running. When a service comes back empty the plugin now searches again on the
  album title.
- **A review no longer resolves to a like-named single.** Interpol's *This Mirror Weighs a
  Ton* was playing the 2-track single instead of the 12-track album released the same day.
  An exact title now takes the row, and the runner-up is offered rather than hidden.
- **A wrong match is no longer kept for a month.** Several routes could pin an answer that
  nothing had actually checked — a search that timed out, a service that was signed out, a
  merge that let a like-named rival lead. Each is now kept only as long as it has been
  verified for.
- **A slow service no longer throws away a match already found.** If one search timed out
  while another had already succeeded, the successful result was discarded and the review
  reported no match.
- **A service you are not signed in to no longer poisons everything else.** It used to force
  every unmatched album onto an hourly re-search for as long as it stayed signed out, and — at
  every server restart — pin genuinely unmatched albums for 24 hours on the strength of a
  service that had not finished starting up.
- **Artists whose names contain an apostrophe matched nothing at all.** Jane's Addiction,
  Sinéad O'Connor, D'Angelo, The B-52's — the mark was being read as a word break, so the
  review and the album no longer looked like the same record. Character handling is much
  wider generally now, covering ligatures, stroked and accented letters and archaic forms.
- **Titles that differ only by a space now match** — *England's Newest Hit Makers* against
  *…Hitmakers*.
- **`AC/DC`-style titles are no longer split in the wrong place**, which could play a record
  the review was not about, with nothing to indicate anything had gone wrong.
- **Artwork stopped pulling far more than it needed.** Drawing 50 thumbnails could fetch
  ~28MB of full-size originals. Covers are now requested at a size that fits the row. The
  plugin was also quietly *enlarging* other plugins' artwork on your server, and breaking
  non-square Tidal images outright; it now only ever asks for something smaller than what a
  row already carries, and leaves images it does not own alone.
- **Home shelves are no longer mostly unplayable cards after a restart.** For about ninety
  seconds following every start-up the Material carousel resolved almost nothing.
- **A feed that starts failing no longer re-downloads indefinitely** — on every view open and
  every background pass, invisibly, for as long as it kept failing.
- **The background refresh now actually runs.** On a server whose player connects late it
  could sit idle for three hours, and on a headless one it retried every 20 seconds for ever
  without ever being able to start.
- **The settings page no longer shows stale service priorities after a save.** The save had
  applied; only a reload showed it.
- **A review published before the album reaches the shops is picked up when it lands**,
  unprompted, rather than staying unplayable.

### Changed

- **Grouping is no longer a settings-page option** — it moved onto the list. The setting
  itself is unchanged and your choice carries over; only the control moved.
- **The app tile no longer names a year.** It was the one surface that could not be redrawn
  when you changed year, so it could sit there naming the wrong one. Every surface that does
  name the year is rebuilt when it changes.
- **The Best Albums home shelf is always in rank order**, whichever way you have the in-app
  list set to read. A shelf card is played by its position, and that position has to mean the
  same thing on the next tap.
- **An unmatched review's detail page no longer shows a "No matching album found" row.** It
  said only that the plugin had tried; "Refresh streaming match" sits above it and does the
  useful half of that job.

[PR #2]: https://github.com/SimonArnold002/LMS-Pitchfork-Reviews/pull/2

## 0.7.11

The last release on this channel before 0.9.34. See the repository history for the
0.1.0 – 0.7.11 series.

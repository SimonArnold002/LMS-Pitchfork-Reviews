# Pitchfork Reviews — for Lyrion Music Server

Browse curated album reviews inside **Lyrion Music Server (LMS)** and play the reviewed album straight from your **streaming library** — one tap to play or add to the queue. Reviews come from **Pitchfork** (Best New Music, High Scoring Albums, Latest Reviews + the annual Best Albums of the Year countdown); each one is matched to a directly-playable album on **Qobuz, Tidal, Deezer or Spotify**, with the service's own artwork.

Tested on LMS 9.x with the **Material Skin** (the classic skin works for the basics).

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Best New Music** | Pitchfork's curated Best New Music picks as a browsable list | Browse: nothing · **Play: a streaming plugin** |
| **High Scoring Albums** | Pitchfork's curated high-scoring picks as a second browsable list | Browse: nothing · **Play: a streaming plugin** |
| **Latest Reviews** | The most recent album reviews, grouped by genre or week, or ranked by score | Browse: nothing · **Play: a streaming plugin** |
| **Best Albums of the Year** | Pitchfork's annual top-50 countdown, ranked and playable — opens on the newest list, with every year back to 2016; the chosen year is named above the list, in the page title and on the home shelf | Browse: nothing · **Play: a streaming plugin** |
| **Best first or countdown** | Read the year list with #1 at the top, or in Pitchfork's own 50-to-1 countdown order | Nothing |
| **One-tap playback** | A matched review plays straight from your streaming service — no searching | A streaming plugin |
| **Real album artwork** | Matched rows swap the Pitchfork thumbnail for the service's own cover | A streaming plugin |
| **View by genre, week or score** | Divide the review lists by Pitchfork genre (default) or into weekly sections, or show one flat list highest score first — tap to change, on the list itself | Nothing |
| **Pitchfork score** | Each review row shows its score, e.g. *Score 8.4/10* | Nothing |
| **Genres** | Each review shows its Pitchfork genre(s) on the row and detail page | Nothing |
| **Read the full review** | Links out to Pitchfork; the plugin shows only artist, album, date, genre and the short capsule | Nothing |
| **Refresh** | A row at the top of each list re-fetches the feed and re-matches on demand | Nothing |
| **Not the right album?** | Where a service carries another release under the same name it is offered on the album page, alongside a Refresh that re-searches from scratch | A streaming plugin |
| **Reviews covering two records** | A review titled *A / B* — a pair issued together — resolves both; the first plays from the row, the second rides into the drill-in | A streaming plugin |
| **Grid or list view** | Every row carries artwork, so Material's thumbnail/grid toggle stays available | Material Skin |
| **Material home shelves** | Best New Music, High Scoring Albums, Latest Reviews and Best Albums of the Year as scrollable rows on the Material home page | Material Skin · **Play: a streaming plugin** |
| **Add to Listen Later** | Matched albums carry the data the *Listen Later* plugin needs to save & replay them | Listen Later plugin + a streaming plugin |
| **Choose your services** | Set the search order for Qobuz / Tidal / Deezer / Spotify (or turn one off) | A streaming plugin |
| **Dutch** | Every label, row and setting in Dutch when LMS is set to that language, alongside English | Nothing |

**"A streaming plugin" means Qobuz, Tidal, Deezer or Spotty (for Spotify)**, installed in LMS and signed in. Reading the lists, the capsules and the genres needs nothing beyond the plugin itself, but **playing an album always goes through one of those services**: the plugin has no audio of its own and does not download anything. A review it can't match to a service you have still appears, with its Pitchfork artwork and a link to the review — it just isn't playable.

---

## Requirements

- **Lyrion Music Server 9.0.0+** (tested with the Material Skin; the classic skin covers browse/play).
- For playback, at least one matching streaming plugin installed and signed in: **Qobuz**, **Tidal**, **Deezer** and/or **Spotty** (Spotify).
- **Pure Perl, cached, no extra server software** — no image libraries or external tools required, so it runs the same on a Raspberry Pi or a NAS.

Every streaming integration is optional and degrades gracefully: a review that can't be matched to an installed service still shows, with its Pitchfork artwork, and links out to the review.

---

## Installation

**Via repository (recommended).** In LMS go to **Settings → Plugins → Additional Repositories** and add:

```
https://simonarnold002.github.io/LMS-Pitchfork-Reviews/repo.xml
```

Then install **Pitchfork Reviews** from the plugin list and restart.

**Manual.** Download `PitchforkReviews.zip` from the [repository](https://github.com/SimonArnold002/LMS-Pitchfork-Reviews), unzip it into your LMS `Plugins/` directory so it sits as `Plugins/PitchforkReviews/`, and restart:

```bash
sudo rm -rf /var/lib/squeezeboxserver/Plugins/PitchforkReviews
sudo unzip PitchforkReviews.zip -d /var/lib/squeezeboxserver/Plugins/
sudo chown -R squeezeboxserver:nogroup /var/lib/squeezeboxserver/Plugins/PitchforkReviews
sudo systemctl restart lyrionmusicserver
```

---

## Quick start

1. Open **Apps → Pitchfork Reviews**.
2. Choose **Best New Music**, **High Scoring Albums**, **Latest Reviews** or **Best Albums of the Year**.
3. Tap a matched album to play it, or open a row to read the capsule and follow **Read the full review**.
4. Use the thumbnail/grid toggle to switch between list and cover views.

---

## Using it

### Best New Music, High Scoring Albums & Latest Reviews
The top menu has three feeds. **Best New Music** is Pitchfork's curated pick list, and **High Scoring Albums** is Pitchfork's companion list of its highest-rated recent records — both flat, curated lists. **Latest Reviews** is the most recent reviews, grouped by **genre** (the default) or by **date** — see below. All are refreshed through the day and cached, so they open quickly.

Tap **View** at the top of any review list to cycle through **Genre** (the default) — reviews under their Pitchfork genre, newest first within each, with the genre carrying the most recent review at the top — **Week**, which keeps weekly headers (newest first), and **Score**, one flat list with the highest-scored review first. The dividers carry the Pitchfork mark. Your choice sticks and is shared by all three review lists.

Each review row shows its **Pitchfork score** at the start of its second line (*Score 8.4/10*).

### Best Albums of the Year
Every December Pitchfork publishes its **50 Best Albums of the Year**. This section opens straight on the **newest published list**, ranked from #1 down, each entry with its cover art, its write-up and a tap to play the album from your streaming service — the same one-tap playback as any review.

**It keeps itself current.** The plugin works out which list is the newest rather than having it built in, and keeps checking while it waits — so when this December's list goes live it simply becomes the one you land on, with no update to install. The **Refresh** row at the top forces that check immediately if you want to prod it.

Tap **Sorted by** to switch between **Best first** (#1 at the top, the default) and **Countdown** (50 first, the order Pitchfork publishes it in — how you'd read the article). Your choice sticks. The Material home shelf always stays in **Best first** order, so that a card you tap is always the album you were looking at.

To browse an earlier year, tap **Choose a year** — every list back to **2016** is there. Picking one takes you straight to that list, and the year you chose is remembered, so the section opens on it next time. Because these entries are a ranked list rather than dated reviews, the rows are numbered and shown in rank order instead of under genre or week dividers, and the link out goes to the list itself (Pitchfork doesn't publish a separate review link for each entry).

**The year is always named.** Whichever year you're on is shown as **"2025 - Best Albums"** in bold above the list, in the page title, on the **Choose a year** row, and on the Material home shelf — so you never have to guess which one you're reading, and changing the year updates all of them at once. (The app tile itself stays "Best Albums of the Year": it's the one surface that can't be redrawn when the year changes, so it names no year rather than showing a stale one.) The one exception is deliberate: when a **newer list is published**, it takes over from the year you'd been on, so you always land on the current one in December.

**Refresh**, **Choose a year** and **Sorted by** sit together in an **Options** section at the top of the view, with the albums below under their own heading.

The same shape is used throughout: every list view opens with an **Options** section holding its action rows, and a review's detail page is split into **Options**, **Streaming** (the playable matches) and the write-up.

### Playing a review
When a review is opened, the plugin searches your enabled streaming services for the album and, on a match, turns the row into a **directly-playable album** with the **service's own artwork** — so you can play it or add it to the queue without searching. Unmatched reviews keep their Pitchfork cover and open a detail page with the capsule and a **Read the full review** link.

### Genres
Each review carries its Pitchfork genre(s) — shown on the row's second line (next to the date) and on the detail page.

### Refresh
A **Refresh** row sits at the top of each feed. It re-fetches the latest reviews and re-runs the streaming match — handy if an album has only just appeared on a service, or a match was missed.

### Choosing services
Under **Plugin Settings** you set a search **priority** for Qobuz, Tidal, Deezer and Spotify (lower number = searched first; **0 = never use it**). The matcher stops at the first service that has the album, so ordering lets you prefer, say, Qobuz over Tidal.

### Material home shelves
With the **Material Skin**, four scrollable rows — **Pitchfork: Best New Music**, **Pitchfork: High Scoring Albums**, **Pitchfork: Latest Reviews** and **Pitchfork: Best Albums of the Year** — appear on your home page, so a matched album is a tap away without opening the app. Tap **show all** on a row to open the full list. (The home rows are a flat, playable card list — the genre/week dividers live in the in-app **Latest Reviews** view.) The plugin pre-warms the matches in the background so the shelves open instantly rather than pausing to resolve. The shelves appear automatically when Material Skin is installed; no setup needed.

---

## Settings reference

Open **Plugin Settings** from the top of the plugin's page (or **Settings → Advanced → Pitchfork Reviews**).

| Setting | What it does | Default |
|---|---|---|
| **Qobuz search priority** | Order Qobuz is searched in (0 = never) | 1 |
| **Tidal search priority** | Order Tidal is searched in (0 = never) | 2 |
| **Deezer search priority** | Order Deezer is searched in (0 = never) | 3 |
| **Spotify search priority** | Order Spotify (via Spotty) is searched in (0 = never) | 4 |
| **Extra debug logging** | Logs feed fetches and match decisions to the server log while diagnosing | Off |

---

## Notes & limitations

- **What's shown vs. the full review.** Only the album, artist, date, genre and Pitchfork's short one-line capsule are stored — the full review is always linked out to Pitchfork, never reproduced.
- **Coverage is the active window** (roughly the last two weeks / ~30 reviews, RSS-style). Pitchfork's deep archive isn't browsed.
- **Matching stylised titles.** The matcher folds decorative spellings so, e.g., *WOR$T* matches *Worst* and *P!nk* matches *Pink*, and tolerates a trailing "EP"/"LP" that streaming services drop. A few reviews genuinely can't be matched — e.g. when a service abbreviates a title to an initialism the review spells out — and are left showing their Pitchfork cover.
- **Add to Listen Later.** A matched album carries a proper `favorites_url` (service + album id), so the companion **Listen Later** plugin can save it and replay it from the right service. Adding directly from a browse row uses a Material feature that ships in **Material 6.4.4+**.
- **AllMusic** reviews are planned for a future version; today the source is Pitchfork.

---

Full release history: [CHANGELOG.md](CHANGELOG.md).

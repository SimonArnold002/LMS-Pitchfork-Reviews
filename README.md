# Pitchfork Reviews — for Lyrion Music Server

Browse curated album reviews inside **Lyrion Music Server (LMS)** and play the reviewed album straight from your **streaming library** — one tap to play or add to the queue. Reviews come from **Pitchfork** (Best New Music + Latest Reviews); each one is matched to a directly-playable album on **Qobuz, Tidal or Deezer**, with the service's own artwork.

Tested on LMS 9.x with the **Material Skin** (the classic skin works for the basics).

---

## Features at a glance

| Feature | What it gives you | Needs |
|---|---|---|
| **Best New Music** | Pitchfork's curated Best New Music picks as a browsable list | Nothing |
| **Latest Reviews** | The most recent album reviews, grouped into weeks | Nothing |
| **One-tap playback** | A matched review plays straight from your streaming service — no searching | A streaming plugin |
| **Real album artwork** | Matched rows swap the Pitchfork thumbnail for the service's own cover | A streaming plugin |
| **Genres** | Each review shows its Pitchfork genre(s) on the row and detail page | Nothing |
| **Read the full review** | Links out to Pitchfork; the plugin shows only artist, album, date, genre and the short capsule | Nothing |
| **Grid or list view** | Every row carries artwork, so Material's thumbnail/grid toggle stays available | Material Skin |
| **Add to Listen Later** | Matched albums carry the data the *Listen Later* plugin needs to save & replay them | Listen Later plugin |
| **Refresh** | A row at the top of each list re-fetches the feed and re-matches on demand | Nothing |
| **Choose your services** | Set the search order for Qobuz / Tidal / Deezer (or turn one off) | Nothing |

---

## Requirements

- **Lyrion Music Server 9.0.0+** (tested with the Material Skin; the classic skin covers browse/play).
- For playback, at least one matching streaming plugin installed and signed in: **Qobuz**, **Tidal** and/or **Deezer**.
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
2. Choose **Best New Music** or **Latest Reviews**.
3. Tap a matched album to play it, or open a row to read the capsule and follow **Read the full review**.
4. Use the thumbnail/grid toggle to switch between list and cover views.

---

## Using it

### Best New Music & Latest Reviews
The top menu has two feeds. **Best New Music** is Pitchfork's curated pick list. **Latest Reviews** is the most recent reviews, split into **week headers** so you can see what landed each week. Both are refreshed through the day and cached, so they open quickly.

### Playing a review
When a review is opened, the plugin searches your enabled streaming services for the album and, on a match, turns the row into a **directly-playable album** with the **service's own artwork** — so you can play it or add it to the queue without searching. Unmatched reviews keep their Pitchfork cover and open a detail page with the capsule and a **Read the full review** link.

### Genres
Each review carries its Pitchfork genre(s) — shown on the row's second line (next to the date) and on the detail page.

### Refresh
A **Refresh** row sits at the top of each feed. It re-fetches the latest reviews and re-runs the streaming match — handy if an album has only just appeared on a service, or a match was missed.

### Choosing services
Under **Plugin Settings** you set a search **priority** for Qobuz, Tidal and Deezer (lower number = searched first; **0 = never use it**). The matcher stops at the first service that has the album, so ordering lets you prefer, say, Qobuz over Tidal.

---

## Settings reference

Open **Plugin Settings** from the top of the plugin's page (or **Settings → Advanced → Pitchfork Reviews**).

| Setting | What it does | Default |
|---|---|---|
| **Qobuz search priority** | Order Qobuz is searched in (0 = never) | 1 |
| **Tidal search priority** | Order Tidal is searched in (0 = never) | 2 |
| **Deezer search priority** | Order Deezer is searched in (0 = never) | 3 |
| **Extra debug logging** | Logs feed fetches and match decisions to the server log while diagnosing | Off |

---

## Notes & limitations

- **What's shown vs. the full review.** Only the album, artist, date, genre and Pitchfork's short one-line capsule are stored — the full review is always linked out to Pitchfork, never reproduced.
- **Coverage is the active window** (roughly the last two weeks / ~30 reviews, RSS-style). Pitchfork's deep archive isn't browsed.
- **Matching stylised titles.** The matcher folds decorative spellings so, e.g., *WOR$T* matches *Worst* and *P!nk* matches *Pink*, and tolerates a trailing "EP"/"LP" that streaming services drop. A few reviews genuinely can't be matched — e.g. when a service abbreviates a title to an initialism the review spells out — and are left showing their Pitchfork cover.
- **Add to Listen Later.** A matched album carries a proper `favorites_url` (service + album id), so the companion **Listen Later** plugin can save it and replay it from the right service. Adding directly from a browse row uses a Material feature that ships in **Material 6.4.4+**.
- **AllMusic** reviews are planned for a future version; today the source is Pitchfork.

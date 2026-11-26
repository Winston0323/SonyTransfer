# Sony Transfer

Pulls JPEGs off a Sony A7R III (ILCE-7RM3) onto Android over Wi-Fi, without Sony's
Imaging Edge Mobile app.

The camera hosts its own access point and speaks UPnP/DLNA over plain HTTP while it
is in **Send to Smartphone** mode. That is all this app needs, so the entire
protocol lives in Dart with no vendor SDK and no native networking code.

## Why this protocol

The A7R III offers three plausible transfer paths. Only one of them is pleasant:

| Path | Verdict |
| --- | --- |
| **Send to Smartphone** (HTTP + SOAP, port 64321) | **Used here.** No pairing, no native code, works from Dart sockets. |
| Send to Computer (PTP/IP, port 15740) | Needs a one-time PTP-GUID registered over USB with native tooling, plus non-standard keep-alive packets. |
| Sony Camera Remote SDK | Does not support the A7R III at all — the supported list starts at the A7R IV generation. |

## Using it

The app opens on **the album**: every shot it has ever transferred, grouped by
day newest-first, independent of the camera being anywhere nearby. Three ways
to get shots off the camera:

- **Live monitor** — Ctrl w/ Smartphone. The phone shows a live view and copies
  each new JPEG while you keep shooting on the body. This is the mode that
  does not take the camera out of shooting.
- **USB cable** — plug in the camera; the app opens the cable-transfer screen
  and lets you pick which SD card to read (defaults to the JPEG card).
- **Wi-Fi** — tap the camera icon and join the camera's `DIRECT-…` network as
  described further below. That path is Send to Smartphone: the camera leaves
  shooting until the send ends, which is why it is separate from the monitor.

### Live monitor

Use this when you want to watch the frame and have each new photo land on the
phone without stopping to send.

1. On the camera: `MENU → Network → Ctrl w/ Smartphone → On`, then open
   **Connection** and leave that screen up. It shows a `DIRECT-` name and a
   password. Turn **Send to Smartphone** off; that mode cannot show a live
   view and it pauses shooting.
2. In the app, tap the monitor icon. Scan, or type the name and password from
   the camera, then **Start monitor**. The camera name looks like
   `DIRECT-xxxx:ILCE-7RM3` — keep the colon. If the phone says it could not
   establish a connection, join that same network in system Wi-Fi settings
   while the camera Connection screen stays up, then tap **Use this Wi-Fi**.
3. Shoot on the camera. The phone stays on the live view, and each new JPEG is
   copied into the album in the background. You can leave the monitor for the
   album — or turn the screen off — and the copy keeps going. **Disconnect**
   is what ends it.

The copy prefers the original JPEG when the camera offers it. Many bodies only
offer a 2M preview over this link; RAW always stays on the card. A burst that
is faster than the camera's Wi-Fi can still be shot — the shutter is not held
for the copy — but a frame the phone did not finish receiving is still on the
card and can be pulled later with Send to Smartphone or the USB cable.

Going back does **not** cut an active monitor or Wi-Fi session: that flow is kept alive
behind the album rather than being torn down, so you can browse the album
mid-session — or even mid-transfer — and return to find everything exactly as
you left it, still connected. Unplugging the USB cable does close the cable
session.

### USB cable transfer (dual SD cards)

This is the path that can see **both** memory cards. Sony's MTP mode only
exposes Slot 1; Mass Storage with Multi LUN is what makes Slot 2 (often the
JPEG card when shooting `Sort(RAW/JPEG)`) reachable.

On the camera:

1. `MENU → Network → Ctrl w/ Smartphone → Off` (otherwise USB stays locked to
   the smartphone control mode).
2. `MENU → Setup → USB Connection → Mass Storage`.
3. `MENU → Setup → USB LUN Setting → Multi`.
4. Plug the camera into the phone with a data-capable USB cable (OTG / USB
   host on the phone). Approve the USB access prompt.

The app opens the **USB transfer** screen as soon as the camera appears. Each
card shows up as a chip (`Card 1 · JPEG`, `Card 2 · RAW`, …); the one with the
most JPEGs is selected by default. Switch chips to read the other card, pick
shots, and Transfer — same destination-folder rules as Wi-Fi.

If the app says the camera was found but shows **no photo cards**:

- Wait ~10s after plugging in, allow USB + Photos permission, then tap
  **Retry** (vivo and similar OEMs mount exFAT slowly).
- Prefer camera **USB Connection → Mass Storage** and **LUN → Multi** for both
  cards. Many phones still force **MTP**; the app falls back to MTP and can
  read Slot 1, but Slot 2 usually stays unavailable until Mass Storage works.
- A charge-only cable also produces this symptom.

### Wi-Fi transfer (Send to Smartphone)

Wi-Fi exposes only the card currently selected for playback on the camera
(`Playback → Select PB Media`). It cannot switch slots from the phone — use
USB when you need the other card.

1. `MENU → Network → Send to Smartphone Func. → Send to Smartphone`.
2. Pick **Select on Smartphone** to expose the whole card, or select individual
   shots on the camera first.
3. The camera displays an SSID beginning with `DIRECT-` and a password.
4. From the album, tap the camera icon. Turn **Location** on (Android hides
   Wi-Fi names without it), tap **Scan**, and pick the camera network — or
   type the `DIRECT-…` name from the camera screen.
5. Type the password and tap **Connect**. Approve Android's temporary network
   prompt. The camera network is not saved and is released on **Disconnect**.
6. Pick the shots you want from the timeline and tap **Transfer**.

If **Scan** finds nothing, the hint names the cause (Wi-Fi off, Location off,
permission refused, or rate-limited). Use **Open Location settings** /
**Open app settings** / **Open Wi-Fi settings** under the hint.

The SSID and password only need to be typed once. With **Auto-connect** on
(the default), the app rescans every ten seconds while idle, and joins by
itself as soon as it sees that remembered network again — so the usual
routine is just "turn the camera's Send to Smartphone mode on" and wait.
Turning it off goes back to scanning and joining only on demand.

The app also notices the other direction: while connected, browsing, or
transferring, it polls every five seconds for the camera's Wi-Fi still being
associated. Two misses in a row — the camera switched off, walked out of
range, or the phone drifted onto another network — send the app straight
back to the setup screen (cancelling an in-progress transfer first) rather
than leaving a now-unreachable session on screen.

By default transferred shots are added to a **SonyTransfer** album in the Photos
app. Tap **Choose folder** (shown once connected) to redirect them anywhere
reachable through Android's folder picker instead — an SD card, `Downloads`, a
synced cloud folder. The choice is remembered across sessions; **Reset** goes back
to the Photos album. If the chosen folder becomes unreachable mid-transfer (an SD
card pulled, a permission revoked), that shot fails with an error rather than
quietly landing in the Photos album — pick the folder again, or Reset.

### The album (home page)

The home page is an album of shots **this app has transferred**, not of
whatever else happens to live in the Photos app or a chosen destination
folder — those may already hold unrelated pictures, and a destination folder
picked through Android's document UI cannot be listed back out of without
extra permissions the app does not ask for.

Instead, every downloaded shot is left in the app's own private cache folder
even after also being copied into the Photos album or a chosen destination
folder (see below) — nothing else ever writes there, so it is a ready-made,
always-available record of exactly what this app has moved off the camera.
The album lists that folder's contents, grouped by **the day the shot was
taken** (newest first), with the same tap-to-preview / swipe-through-everything
behaviour as the camera timeline. Pull to refresh re-scans it, which mainly
matters if files were removed from outside the app.

The shot date survives without a database: as each file finishes downloading,
its modification time is stamped with the capture date the camera reported.
Shots the camera reports no date for — and files transferred before the app
started stamping — group under the day they were downloaded instead.

In the full-screen preview, the **info** button opens a sheet with the shot's
details: file name, size on disk, pixel dimensions, shot date, focal length
and lens (read from the JPEG's EXIF block), and the file's local path.

Swiping through the preview stays quick even though every file is a full
42-megapixel frame: each shot is decoded at roughly twice the screen's width
rather than full size (about a tenth of the pixels), and the neighbours of
the shot on screen are decoded ahead of time, so they are ready before the
swipe that reveals them.

Long-press a shot to start selecting (tap then extends the selection; the app
bar offers **Select all**), and the trash icon deletes the selection after a
confirmation. Deleting only removes shots from this album's own cache — copies
already saved to the Photos app or a chosen destination folder are kept — and
a deleted shot becomes transferable from the camera again, since the
skip-already-transferred check looks at this same cache.

### The timeline

Shots are grouped by capture day, newest day first and newest shot first within
each day, from the `dc:date` the camera reports. Anything undated keeps the
camera's own ordering and collects into a trailing **No date** section.

The card is listed progressively: the newest shots appear two round trips after
connecting, and older ones keep filling in below while you browse. You can select
and start transferring straight away — there is no need to wait for the footer to
stop saying "Loading older shots".

Tap a thumbnail to open it full-screen; the checkbox in its corner (or a
long-press) selects it without leaving the grid. **All** / **None** on a day
header covers that day; the toolbar buttons cover the whole card. Nothing is
selected to begin with, and raw shots cannot be selected at all — they show a
`RAW` badge instead.

The full-screen preview is its own page, not a popup: swipe left or right to
step through every shot in the timeline in the same order the grid shows them,
across day boundaries. It carries a page counter (`3 / 128`), pinch-zoom, and
the same select control, now in the app bar, so a shot can be picked after a
proper look without going back to the grid.

Tiles load the camera's `_SM` (640×480) rendition rather than the `_TN` thumbnail,
which is too small to judge a shot on a modern phone screen; the preview uses
`_LRG`. Both are a fraction of the ~20MB original, and the grid only fetches what
scrolls into view.

Every thumbnail and preview is cached to disk the first time it is fetched, so
scrolling away and back — or reconnecting in a later session — costs nothing
further; and no more than 4 are ever requested from the camera at once, since
its embedded web server queues up (and each request slows down) if the grid
asks for a dozen at the same moment while scrolling fast.

### Finding the camera

The camera hosts the access point and runs its own DHCP server, so it *is* the
gateway of the network the phone just joined. On connect the app reads that gateway
and tries it first, falling back to the first host on the subnet if the access point
advertises no default route, and then to the well-known `192.168.122.1`. Each
candidate gets a short timeout so a wrong guess doesn't hold up the next one.

Turning **Detect camera address** off lets you pin an address by hand. Aiming at the
wrong subnet is what produces `No route to host` — the phone has no path to, say,
`192.168.0.x` while sitting on the camera's `192.168.122.x` network.

### If the transfer stalls

The camera's access point has no internet. Android notices this and keeps its
default route on mobile data, so requests aimed at `192.168.122.1` never leave the
device. The app calls `ConnectivityManager.bindProcessToNetwork` to pin its own
sockets to Wi-Fi, which handles this on most phones — but if a device still refuses
to cooperate, turning mobile data off is the reliable fallback.

### Disconnect

**Disconnect** ends the camera session and leaves the DIRECT- Wi-Fi — but only when
the app itself joined that network. Enter the SSID and password from the camera
screen before Connect; Android shows a system prompt, and releasing that temporary
link on Disconnect actually drops the AP.

If you joined the camera Wi-Fi in Android Settings instead, the OS will not let a
normal app force-leave it. Disconnect then opens the system Wi-Fi panel so you can
leave the DIRECT- network in one tap.

## Limitations

- **Raw is not transferable.** Over this protocol the camera serves only the
  embedded preview JPEGs for an ARW, never the raw data. Raw shots are listed and
  marked, then skipped. Use the SD card for those.
- The camera's Wi-Fi is 2.4GHz single-stream, which realistically caps throughput
  around 2–3 MB/s. A 42MP JPEG is 15–25MB, so budget roughly 8 seconds per shot.
  The bottom bar shows live MB/s next to the negotiated link speed (and, once a
  transfer is running, the signal strength if it's weak), so you can tell a slow
  link apart from a slow app. While connected, the app holds a Wi-Fi lock (and a
  CPU wake lock) so the phone's own power-saving policy can't throttle the radio
  mid-transfer — this is the single biggest software-fixable gap between a phone
  and a tablet on the same camera. What's left after that is hardware: some phones
  simply carry a lower-throughput Wi-Fi chipset than a tablet, and no software
  change closes that gap. Downloads are also always sequential (one shot at a
  time) — running several in parallel doesn't help on a link this slow and only
  adds contention.
- The camera drops the connection shortly after it leaves sending mode, and it will
  time out on its own if left idle.
- **Live monitor is Ctrl w/ Smartphone, not a second copy of Send to Smartphone.**
  The A7R III has no automatic full-size FTP-while-shooting transfer. The monitor
  copies the JPEG the remote-shooting API hands back (original when the body
  allows it, otherwise 2M) and does not pull RAW.

## How it works

The two modes on the camera behave differently. Picking shots **on the camera**
serves them under `PushRoot` alongside a Sony `XPushList` service that drives the
"Sending…" display. Picking **Select on Smartphone** exposes the whole card under
`PhotoRoot` and serves no `XPushList` at all, so `X_TransferStart` answers 404. The
app treats those calls as best-effort and falls back between the two roots, so
either mode works.

`ContentDirectory:Browse` returns a SOAP envelope whose `Result` element contains a
second, XML-escaped DIDL-Lite document — so the response is parsed twice. Each
`<item>` carries several `<res>` renditions (`_TN` thumbnail, `_SM`, `_LRG`, and the
original). Only the original has a `size` attribute, which is what the app keys on
both to choose the best download and to detect raw-only shots. The smaller
renditions are what the timeline displays, so browsing costs almost nothing.

### Listing backwards

`Browse` is paginated, and the camera enumerates a card oldest-first. Read forwards
in the obvious way, a 3000-shot card costs 50 sequential round trips before the
most recent frame — the one you actually want — is even known about. So
`SonyCameraClient.browse` reads the first page to learn `TotalMatches`, then walks
pages *backwards* from the end and reverses each page's contents, streaming them as
they arrive. The newest shots are on screen after two requests no matter how full
the card is.

Two details this depends on. Pages are stepped by `NumberReturned` rather than the
`RequestedCount` that was asked for, because a server is free to cap a page and
striding by the larger figure would silently skip shots. And because positions are
addressed relative to a total the camera could report inconsistently, results are
de-duplicated by object id on the way out.

```
lib/
├── main.dart
├── models/
│   ├── camera_item.dart             shots, their renditions and capture date
│   ├── timeline.dart                pure day-grouping and header labels
│   ├── transferred_photo.dart       a shot already in the local cache
│   └── usb_card.dart                mass-storage volume / SD-card summary
├── services/
│   ├── sony_camera_client.dart      probe, X_TransferStart/End, newest-first Browse
│   ├── scalar_camera.dart           Ctrl w/ Smartphone live view and shutter wait
│   ├── live_view_parser.dart        JPEG frames out of the live-view stream
│   ├── monitor_session.dart         live view plus background JPEG copy
│   ├── shot_ingest.dart             save a shutter JPEG into the album cache
│   ├── network_binding.dart         Wi-Fi pinning via platform channel
│   ├── destination_folder.dart      SAF folder picker, via platform channel
│   ├── transfer_service.dart        streaming download (HTTP + USB), gallery save
│   ├── usb_camera.dart              cable Mass Storage API via platform channel
│   └── thumbnail_cache.dart         disk-cached, concurrency-capped camera images
├── widgets/
│   ├── timeline_view.dart           date headers, thumbnail grid, selection
│   ├── preview_page.dart            swipeable full-screen preview (camera shots)
│   └── cached_camera_image.dart     Image.network stand-in backed by the cache
└── screens/
    ├── home_shell.dart              album + Wi-Fi + USB panes kept alive
    ├── album_screen.dart            home page: cache path + camera actions
    ├── transfer_screen.dart         Wi-Fi connect → browse → select → transfer
    ├── usb_transfer_screen.dart     USB card pick → browse JPEGs → transfer
    └── monitor_screen.dart          live view and background copy
```

The day-grouped album grid, preview, and EXIF sheet live in
[`image_album`](https://github.com/Winston0323/image_album), checked out at
`../image-album` next to this repo. It takes a folder path and shows the
images in that folder. `AlbumScreen` points it at the transfer cache.

```
../image-album/lib/
├── image_album.dart                 public exports
└── src/
    ├── image_album.dart             three-column day grid
    ├── album_photo.dart             scan a directory and group by day
    ├── album_preview_page.dart      swipeable full-screen preview
    └── photo_info_sheet.dart        file/EXIF details
```

The Kotlin half lives in `MainActivity.kt` (Wi-Fi / SAF) and `UsbMassStorage.kt`
(libaums Mass Storage + Multi LUN).

## Development

```bash
flutter pub get
flutter test        # protocol parsing is covered against recorded camera payloads
flutter analyze
flutter run
```

The library checkout is `../image-album`
([image_album](https://github.com/Winston0323/image_album)). Push library
changes from that directory. This app depends on it by path, so a fresh clone
also needs that checkout next to this repo. The demo app is `../image-album/example`.

The first Android build downloads the Gradle 8.14 distribution (~230MB), which this
machine did not have cached. Let it finish rather than interrupting it — a killed
wrapper leaves a lock file behind in
`~/.gradle/wrapper/dists/gradle-8.14-all/` that stalls the next build for two
minutes before failing.

The protocol tests use `MockClient` with realistic DIDL-Lite payloads, so the
parsing, backwards pagination, folder recursion, `PushRoot`→`PhotoRoot` fallback and
raw detection can all be verified without the camera present. One test simulates a
3000-shot card and asserts the first page reaches the caller after two requests,
which is the regression guard for the slow-connect problem. Grouping lives in a pure
function so timeline ordering is tested without any widgets, and the widget tests
date their fixtures to 2020 — recent dates render as "Today", which would make them
depend on the wall clock.

## Credit

Protocol behaviour follows the reverse-engineering work in
[ImagingEdge4Linux](https://github.com/schorschii/ImagingEdge4Linux), with the
PTP/IP alternative documented in
[sony-pm-alt](https://github.com/falk0069/sony-pm-alt).

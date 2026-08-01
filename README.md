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

On the camera:

1. `MENU → Network → Send to Smartphone Func. → Send to Smartphone`.
2. Pick **Select on Smartphone** to expose the whole card, or select individual
   shots on the camera first.
3. The camera displays an SSID beginning with `DIRECT-` and a password.

On the phone:

4. Open Sony Transfer. Turn **Location** on (Android hides Wi-Fi names without
   it), tap **Scan**, and pick the camera network — or type the `DIRECT-…`
   name from the camera screen.
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
card pulled, a permission revoked), affected shots fall back to the Photos album
rather than failing outright.

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
│   └── timeline.dart                pure day-grouping and header labels
├── services/
│   ├── sony_camera_client.dart      probe, X_TransferStart/End, newest-first Browse
│   ├── network_binding.dart         Wi-Fi pinning via platform channel
│   ├── destination_folder.dart      SAF folder picker, via platform channel
│   └── transfer_service.dart        streaming download, skip logic, gallery save
├── widgets/timeline_view.dart       date headers, thumbnail grid, selection
└── screens/home_screen.dart         connect → browse → select → transfer UI
```

The Kotlin half is a single `MethodChannel` in `MainActivity.kt`.

## Development

```bash
flutter pub get
flutter test        # protocol parsing is covered against recorded camera payloads
flutter analyze
flutter run
```

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

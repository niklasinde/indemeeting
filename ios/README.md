# Meeting Recorder for iPhone

A read-only viewer for the Mac app's data over your local network. The Mac is the only server; the phone has no accounts,
no analytics and talks to nothing but the paired Mac (and links you tap, which open in Safari). The contract it implements
is [../docs/phone-api.md](../docs/phone-api.md).

Screens: **Meetings** (search, grouped by day, summary, notes, transcript, action items, audio player, share as Markdown,
ask about a meeting), **Activity** (day and week totals and timeline), **GitHub** (Created, Review requested, Assigned,
Mentioned), **Chat** (streamed answers, lookups, citations that open the meeting) and **Settings**.

## Install on your phone

1. On the Mac: Meeting Recorder > Settings > iPhone, turn on **Allow iPhone access**. If macOS asks whether the app may
   accept incoming connections, allow it.
2. Open `ios/MeetingRecorderPhone.xcodeproj` in Xcode (26 or later). Nothing needs installing; the project is committed.
   (`ios/project.yml` is the XcodeGen source if you want to regenerate it with `xcodegen generate`.)
3. Select the target **MeetingRecorderPhone** > Signing & Capabilities > pick your **Team** (a free Apple ID works; the bundle
   id `com.niklasinde.MeetingRecorderPhone` may need to be changed to something unique to you).
4. On the iPhone: Settings > Privacy & Security > **Developer Mode** > on, then restart. Connect the phone, choose it as
   the run destination and press Run.
5. First launch of a free-account build: Settings > General > VPN & Device Management > your Apple ID > **Trust**.
6. Apps signed with a free Apple ID expire after **7 days**; run it from Xcode again to re-sign. Paired keys stay in the
   Keychain, so you do not pair again.

## Pair

On the Mac, Settings > iPhone > **Pair a device**. In the app choose **Scan QR on your Mac**, or scan the QR code with the
system camera (the `meetingrecorder://` link opens the app). Without a camera, **Enter code instead** takes the 32-character
code and the host and port shown beside it. A pairing lasts five minutes and one device. Allow **Local Network** when iOS
asks.

Settings in the app shows the Mac's status, the server address (Bonjour finds the Mac, with the address from pairing as the
fallback, or one you type), and **Forget this Mac**, which deletes the key and the cache. To remove the phone on the Mac side
too, revoke it in the Mac's iPhone settings; the app then asks you to pair again.

## How it works

- **Transport.** `URLSession` cannot do TLS pre-shared keys, so `Net/PhoneHTTPClient.swift` is a small HTTP/1.1 client on
  `NWConnection` using `Sources/Shared/PhoneTransport.swift`. One connection per request (`Connection: close`), so
  cancelling a request closes the socket, which also cancels a chat generation on the Mac. Content-Length, chunked and
  NDJSON streaming are handled by `HTTPResponseParser`, connect and idle timeouts are enforced, a GET is retried once, and
  several addresses are tried in turn (typed, Bonjour, paired).
- **Audio.** `AVPlayer` cannot speak PSK either, so `Net/AudioProxy.swift` serves a plain HTTP listener on `127.0.0.1` on a
  random port, behind a random path token, and forwards each request with its `Range` header to the Mac. AVPlayer streams
  and seeks as for any server. (An `AVAssetResourceLoaderDelegate` would also work; the proxy was chosen because it keeps
  AVPlayer's own buffering, seeking and background behaviour untouched.)
- **Keys.** The device key is in the iOS Keychain (`AfterFirstUnlockThisDeviceOnly`); the pairing key is used once and
  discarded. The paired Mac's name and address are in `UserDefaults`.
- **Offline.** Lists, meeting details, activity and pull requests are cached in `Application Support/cache.sqlite`
  (excluded from backups) using the same `SQLiteDatabase` as the Mac app. Audio is streamed, not stored.
- Shared with the Mac app from `../Sources/Shared`: the API types, the transport and `PhoneFormat` (durations, day grouping,
  Markdown export, times in answers).

## Tests

- Unit tests (parser, requests, error mapping, pairing input, formatting, cache, and the HTTP client against an in-process
  PSK server): `xcodebuild test -project MeetingRecorderPhone.xcodeproj -scheme MeetingRecorderPhone -destination 'platform=iOS Simulator,name=<a simulator>'`.
- Tested on the iOS 27.0 simulator (iPhone 18 Pro, and an iPhone SE for the small screen) with the iOS 26 code paths (Liquid Glass,
  the tab bar accessory), in light and dark and at the largest accessibility text size. The simulator has no Local Network
  prompt, so that permission flow and Bonjour across devices still need a real phone. `xcodebuild` may keep running after
  the UI tests finish; stop it once the summary line has been printed.
- End to end: the `MeetingRecorderPhoneE2E` scheme drives the app with XCUITest against the Mac's headless server and saves a
  screenshot per state. Start the server on a copy of your data (`MeetingRecorder --serve --port N --data-dir <copy>`, then
  type `pair`), and pass `TEST_RUNNER_E2E_CODE`, `TEST_RUNNER_E2E_ADDRESS` (`host:pairing-port`) and `TEST_RUNNER_E2E_SHOTS`.

## Troubleshooting

- **"Mac not reachable".** The Mac must be awake and on the same Wi-Fi (guest and VPN networks often isolate devices).
  Check Settings > iPhone on the Mac says "Listening".
- **Local Network permission.** If you tapped Don't Allow, enable it in iOS Settings > Meeting Recorder > Local Network.
- **Firewall.** macOS asks the first time the Mac app listens; if you declined, allow Meeting Recorder in System Settings >
  Network > Firewall.
- **The Mac's name does not resolve.** Set the address by hand in Settings > Server address. Away from home, **Tailscale**
  on both devices works: use the Mac's Tailscale name or `100.x` address and the port from the Mac's settings.
- **"Blocked for a moment".** Too many failed attempts from this address; wait two minutes.
- **Pairing fails.** The code or address was mistyped, or the five minutes ran out: open Pair a device again.
- **Chat is unavailable.** Apple Intelligence is off on the Mac.

# iPhone access: contract

This is everything an iPhone app needs to read the data of the Mac app over the local network. The Mac is the only
server; the phone has no data of its own and nothing goes through a cloud. The DTOs live in
`Sources/Shared/PhoneAPI.swift` (pure Foundation) and the TLS parameters in `Sources/Shared/PhoneTransport.swift`
(Network.framework, available on iOS 13+); an iOS target compiles both files as they are.

- [Security model](#security-model)
- [Transport](#transport)
- [Pairing](#pairing)
- [Requests](#requests)
- [Endpoints](#endpoints)
- [Errors](#errors)
- [Versioning](#versioning)
- [Notes for the iOS client](#notes-for-the-ios-client)

## Security model

The channel is **TLS 1.2 with a pre-shared key and ECDHE** (`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`, `0xCCAC`).
Both ends prove in the handshake that they hold a 32-byte key; there is no certificate. A peer without a valid key gets
a handshake failure and nothing else: no HTTP is ever spoken to it.

Why this over a self-signed certificate with a pinned fingerprint and a bearer token:

- Nothing to generate, store or renew on the Mac: no certificate code, no expiry, no trust prompts, no `SecIdentity` in
  the Keychain. A device key is 32 random bytes.
- Mutual authentication in one step. With a pinned certificate the phone authenticates the Mac but the Mac only learns
  who calls from a bearer token inside the encrypted request, so an unauthenticated peer can still complete a TLS
  handshake and reach the HTTP parser. With PSK the unauthenticated peer never gets past the handshake.
- The ECDHE part gives forward secrecy: recorded traffic stays unreadable if a key leaks later.
- It was checked on macOS 26 with Network.framework on both ends: unknown identities, wrong keys and revoked keys are all
  refused in the handshake (see error codes below), and each device has its own key.

Limits to know about:

- `URLSession` and `AVPlayer` cannot do TLS-PSK. The iOS app talks to the Mac with `NWConnection` and a small HTTP/1.1
  client of its own (see [Notes for the iOS client](#notes-for-the-ios-client)).
- Network.framework does not tell a server which PSK identity a connection used. The Mac therefore trusts the
  `X-Device-Id` header for *which* paired device is calling (last-seen time, revoked-device checks); the security
  boundary is the key. Every paired device can read everything, so a device naming another one gains nothing.
- The key is the credential. Keep it in the iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).

What the server enforces:

- Off by default; a master toggle in Settings > iPhone. Turning it off stops both listeners.
- Per-device keys in the Mac's Keychain (service `com.niklasinde.MeetingRecorder.pairing`), the record
  (id, name, created, last seen) in the `paired_devices` table. Revoking deletes both and restarts the listener without
  the key, then drops every open connection.
- Failed handshakes and unauthenticated requests are counted per peer address; 8 within a minute block that address for
  two minutes. Only the fact (connect, auth failure, pairing opened, device paired or revoked) is logged to os_log,
  category `phone`; never a path, a query or a body.
- Requests are read-only. The only things a request can change are the GitHub refresh (re-fetches through the `gh` CLI
  and updates the cache) and, for pairing, the device list. Chats are answered by the Mac's on-device model and are not
  stored.
- At most 24 connections, 60 s idle timeout, 16 KiB of headers, 256 KiB of body.
- Privacy rules of the app carry over: a redacted activity block stays stripped, stored Claude prompts are sent only
  while "Store last prompt" is on, and GitHub is empty while it is off in the Mac app.

## Transport

The Mac advertises `_meetingrecorder._tcp` with Bonjour on the port set in Settings (default 47821). The pairing
information also carries a host name (`<name>.local`) and port, so Bonjour browsing is optional.

TLS parameters, identical on both ends (`PhoneTransport.parameters`):

```swift
let tls = NWProtocolTLS.Options()
let options = tls.securityProtocolOptions
sec_protocol_options_add_pre_shared_key(options, keyBytes as __DispatchData, Data(deviceId.utf8) as __DispatchData)   // identity = the hex id as UTF-8
sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
```

A client gives exactly one credential. Connect with `NWConnection(host: .init(host), port: .init(rawValue: port)!, using: parameters)`.

## Pairing

Settings > iPhone > **Pair a device…** opens a pairing for five minutes and one device and shows a QR code. A pairing
uses a second listener on a random port that exists only while the pairing is open and answers only `POST /v1/pair`.

The QR code holds

```
meetingrecorder://pair?host=<name>.local&port=<pairing port>&id=<8 hex>&key=<base64url, 16 bytes>
```

`id` is the PSK identity and `key` the pairing key (URL-safe base64 without padding; standard base64 is accepted too).
`PhonePairing(url:)` parses it and rejects anything malformed. Without a camera the user types the **code**: the id and
key as 32 letters and digits (RFC 4648 base32) in groups of four, e.g. `QKXJ-TZW5-QCN3-DYDE-2CLI-G3C4-543Q-ANHM`, with the
host and port shown beside it; `PhonePairing(manualCode:host:port:)` decodes it, ignoring case, spaces and dashes.

The phone then:

1. Connects to `host:port` with the pairing credential (identity `id`, key `key`).
2. Sends `POST /v1/pair` with `{"deviceName": "Niklas’s iPhone"}` (at most 64 characters, shown in the Mac's device list).
3. Receives the device's own credential and stores it in the Keychain, then forgets the pairing key:

```json
{"apiVersion":1,"deviceId":"6edabb92","host":"macbook-pro-2.local","key":"OVC7WO/m7dCYKLP7B7e/qJ1so/kYOHnBjYVYjpGxC2I=","port":47821,"serverName":"macbook-pro-2.local"}
```

   `key` is standard base64 of 32 bytes; `host` and `port` are where everything else is served.
4. From now on connects to that `host:port` with the credential (identity `deviceId`, key `key`) and sends
   `X-Device-Id: <deviceId>` on every request.

The pairing key is spent by the first device that completes step 2; the pairing listener is closed at once. A second
attempt, or one after five minutes, finds the port closed (connection refused) or gets `403 pairing_closed`. Because the
phone swaps the QR key for its own key, a photo of the QR code is worthless once used. If the answer to step 2 is lost
the pairing is spent and the device appears in the Mac's list; revoke it and pair again.

## Requests

HTTP/1.1 over the channel, `Connection: keep-alive` supported (requests are answered one at a time per connection).
Methods: `GET`, and `POST` on `/v1/pair`, `/v1/github/refresh` and `/v1/chat`. Bodies are `application/json`
(`Content-Length` required, no chunked request bodies). Every response has `Cache-Control: no-store`.

JSON is UTF-8. Dates are ISO 8601 in UTC without fractional seconds (`2026-10-16T08:02:00Z`); durations and offsets are
seconds as numbers; `YYYY-MM-DD` day strings are in the Mac's time zone. Absent optional fields are omitted, never `null`.
Ids are integers. Unknown fields must be ignored by clients so that the API can grow within `/v1`.

Every request except the pairing one carries `X-Device-Id`. A missing or unknown id is `401` (and counts as a failed
attempt). A handshake that fails means the key is wrong, unknown or revoked, which the client should treat as "this
device is no longer paired": ask the user to pair again.

## Endpoints

All paths are under `/v1`. Field names are those of the Swift types in `PhoneAPI.swift`.

### `GET /v1/status`

`PhoneStatus`: `appVersion`, `apiVersion` (1), `schemaVersion` (of the Mac's database), `serverTime`, `serverName`,
`features` = `{githubEnabled, activityEnabled, chatAvailable}`. `chatAvailable` is false while Apple Intelligence is
unavailable on the Mac. Use it to decide what to show, and as the connection check.

```json
{"apiVersion":1,"appVersion":"0.2.0","features":{"activityEnabled":true,"chatAvailable":true,"githubEnabled":true},"schemaVersion":12,"serverName":"macbook-pro-2.local","serverTime":"2026-10-19T15:50:32Z"}
```

### `GET /v1/meetings?query=&limit=&before=`

`PhoneMeetingList`: `meetings` of `PhoneMeetingSummary` (`id`, `title`, `date`, `duration`, `language` (`sv`/`en`),
`hasSummary`, `speakers` (names, or the labels in the meeting's language), `chatCount` (chats held on the Mac), and with a
search `snippet`) and `nextBefore`.

- Without `query`: newest first. `limit` is 1 to 200 (default 50). When more remain, `nextBefore` is the date of the last
  meeting; pass it as `before` for the next page (meetings strictly older, compared to the second). It is absent on the
  last page.
- With `query`: full-text search over title, transcript, summary and notes (every word, as a word prefix), best match
  first, at most `limit` results, no paging. `snippet` is the text around the match with each match wrapped in `**`.

```json
{"meetings":[{"chatCount":0,"date":"2026-10-16T08:02:00Z","duration":1964.223,"hasSummary":true,"id":7,"language":"sv","speakers":["Du","Övriga"],"title":"Daily standup – e-mail templates, release, automation, billing, Dashboard"}],"nextBefore":"2026-10-15T14:46:00Z"}
```

### `GET /v1/meetings/{id}`

`PhoneMeetingDetail`: `id`, `title`, `date`, `duration`, `languages` (codes), `languageDetected`,
`engines` = `{transcript?, summary?}` (`summary` is `apple-intelligence` when there is one), `summaryTitle?`,
`summaryUnavailable?` (why there is no summary), `topics` (`{title, points[]}`), `actionItems`
(`{id, owner?, text, done}`), `notes`, `transcript` and `audio`.

- `transcript` is a list of `{start, end, speaker?, speakerName?, text}`. `speaker` is `you`, `others` or `speaker-N`;
  `speakerName` is the name the user gave it, else the label in the meeting's language (`Du`, `Övriga`, `Talare 2`).
  `end` is where the next segment starts, at most 15 seconds after `start`.
- `audio` is `{available, duration?, bytes?, contentType?}`; `available` is false when the file is not on the Mac.

`404 not_found` for an unknown id.

### `GET /v1/meetings/{id}/audio`

The recording, `Content-Type: audio/mp4` for `.m4a` (other containers: `audio/mpeg`, `audio/wav`, `audio/aiff`,
`audio/x-caf`, `audio/aac`), `Accept-Ranges: bytes`. A `Range: bytes=a-b`, `bytes=a-` or `bytes=-n` request is answered
`206` with `Content-Range: bytes a-b/size`; a range outside the file is `416` with `Content-Range: bytes */size`; a
malformed or multi-part range is ignored and the whole file is sent with `200`. `404` when there is no file.

### `GET /v1/activity/day?date=YYYY-MM-DD` and `GET /v1/activity/week?start=YYYY-MM-DD`

`PhoneActivity`: `from`, `to` (the range, in the Mac's time zone, as UTC instants), `totals`, `days` (`{date, activeSeconds}`;
one for a day, seven for a week, from the Mac's first weekday of the week containing `start`) and `blocks`.

- `totals`: `activeSeconds`, and lists of `{name, seconds}` for `projects` ("Unassigned" last), `categories` and `apps`
  ("Other" for apps hidden by the tracking rules), `branches` (`{name, repo?, ticket?, project?, projectGuessed, seconds}`)
  and `tickets` (`{ticket, title?, url?, branches, project?, projectGuessed, seconds}`). Idle time is not counted.
- `blocks`: `{id, start, end, app?, title?, url?, repo?, branch?, ticket?, category?, project?, projectGuessed, summary?,
  excerpt?, redaction?}` in time order, idle blocks left out, neighbouring "other" blocks merged, at most 5000.
  `projectGuessed` means the project is only Apple Intelligence's guess. `summary` is its one-line description.
- **Privacy:** a block the tracking rules redacted has `redaction` set and nothing else but what the rule leaves:
  `private` keeps `app`, times, `category`; `other` keeps times only (and no `app`); `other site` keeps `app`, times,
  `category`. `project` may still be present as a label. `excerpt` is the last Claude prompt, and only while "Store last
  prompt" is on in the Mac app, else the text typed around the cursor when that capture is on; otherwise it is absent.

`400 bad_request` for a missing or malformed date.

### `GET /v1/github`

`PhoneGitHub`: `enabled`, `refreshedAt?`, `prs` (always the four keys `created`, `review_requested`, `assigned`,
`mentioned`, each a list of `PhonePR`) and `error?`. A `PhonePR` is `{url, number, title, repo, isDraft, state
(open|merged|closed), updated, review? (approved|changes_requested|required), checks (passed|failed|running|none), author?,
additions, deletions, comments, labels[], ticket?}`. This is the cache the Mac app shows. While GitHub is off in the Mac
app, `enabled` is false and the lists are empty.

### `POST /v1/github/refresh`

No body. Fetches through the Mac's `gh` CLI (this can take several seconds), updates the cache and answers like
`GET /v1/github`; `error` says why a fetch failed (rate limit, offline, not signed in) while the cache is kept.
`409 github_disabled` while GitHub is off in the Mac app.

### `POST /v1/chat`

Asks the Mac's on-device model, grounded in its meetings and activity, using the same engine and tools as the Mac's chat.
Nothing is stored on the Mac.

Request (`PhoneChatRequest`):

```json
{"scope":{"kind":"meeting","meetingId":7},"messages":[{"role":"user","text":"List the action items that are mine."}]}
```

- `scope.kind`: `general`; `meeting` and `notes` (need `meetingId`); `activity_block` (needs `blockId`, `from`, `to`);
  `day` and `week` (need `date`, any day in it).
- `messages`: up to 40 of `user`/`assistant`, at most 8000 characters each, the last one the question from the user.
  Send the earlier turns to continue a conversation; the Mac rebuilds its context from them.

The response is `200`, `Content-Type: application/x-ndjson`, `Transfer-Encoding: chunked`, `Connection: close`: one JSON
object (`PhoneChatEvent`) per line, in this order of appearance:

| `type` | fields | meaning |
| --- | --- | --- |
| `tool` | `note` | A lookup the answer uses. First line is a summary ("Searched meetings for “standup”"), the following lines what it returned. |
| `token` | `text` | Text added to the answer since the last token. Append. |
| `citations` | `citations` = `[{meetingId, title}]` | The meetings the lookups returned (not sent in a meeting chat). |
| `done` | `text` | The whole answer. Replace what was streamed with it. |
| `error` | `message` | No answer (cancelled, model declined, context too small). The stream ends. |

```
{"note":"Searched meetings for “standup”\n- id 7 · 2026-10-16 10:02 · Daily standup … · 33 min","type":"tool"}
{"text":"- Test e-","type":"token"}
{"text":"mail templates","type":"token"}
{"citations":[{"meetingId":7,"title":"Daily standup …"}],"type":"citations"}
{"text":"- Test e-mail templates from Post …","type":"done"}
```

In a meeting chat the answer contains times as `mm:ss`, which the phone can turn into seeks in the recording. Closing the
connection cancels the generation. One generation runs at a time: a second request gets `429 chat_busy` with
`Retry-After: 3`. `503 chat_unavailable` when Apple Intelligence is unavailable (the message says why).

### `POST /v1/pair`

Only on the pairing port, with the pairing credential. See [Pairing](#pairing). `403 pairing_closed` when the pairing is
spent or expired, `400 bad_request` for a missing `deviceName`.

## Errors

Non-2xx responses have the body `{"error": "<code>", "message": "<text for people>"}` (`PhoneError`).

| Status | `error` | When |
| --- | --- | --- |
| 400 | `bad_request` | Malformed request line, header, date, cursor, scope or chat body. |
| 401 | `missing_device`, `unknown_device` | No `X-Device-Id`, or one that is not paired. The connection is closed. |
| 403 | `pairing_closed` | The pairing was used or has expired. |
| 404 | `not_found` | Unknown path, meeting without that id, no audio file. |
| 405 | `method_not_allowed` | `Allow` says which method the path takes. |
| 409 | `github_disabled` | GitHub is off in the Mac app. |
| 413, 414, 431 | `bad_request` | Body, target or headers too large. |
| 416 | `range_not_satisfiable` | Range outside the file. |
| 429 | `chat_busy` | Another chat is being answered. |
| 500 | `internal` | The Mac could not read its data. |
| 501, 505 | `bad_request` | Chunked request body, HTTP version other than 1.0/1.1. |
| 503 | `chat_unavailable`, `unavailable` | No on-device model; iPhone access stopped meanwhile. |

Connection-level failures (no HTTP response), as `NWError` codes of the TLS handshake:

| Code | Meaning | What to do |
| --- | --- | --- |
| `-9820` bad MAC | The key does not match the identity (wrong or mistyped key). | Pairing: ask for the code again. Later: re-pair. |
| `-9864` unknown PSK identity | The Mac has no such identity. | Re-pair. |
| `-9824` handshake failure | The Mac has no key at all that fits, e.g. the device was revoked. | Re-pair. |
| `-9816` closed without notification | The Mac closed the connection, e.g. this address is blocked after too many failures. | Wait two minutes, then retry. |
| POSIX 61 `ECONNREFUSED` | Nothing listens: iPhone access is off, the port changed, or the pairing has ended. | Show "Mac not reachable" and retry later. |

## Versioning

The path prefix `/v1` is the major version. Within it the server only adds fields and endpoints and clients ignore what
they do not know. A breaking change would be served under `/v2` next to `/v1`. `GET /v1/status` returns `apiVersion` and
the pairing answer repeats it, so a client can refuse a Mac that is newer than it understands. `schemaVersion` is the Mac's
database schema, for diagnostics only.

## Notes for the iOS client

- Use `NWConnection` with `PhoneTransport.parameters([PhoneCredential(id:key:)])` and write the HTTP/1.1 requests by hand
  (`Host`, `X-Device-Id`, `Content-Length` for POSTs); parse `Content-Length` and `Transfer-Encoding: chunked` responses.
  Reach the Mac by the `.local` name from pairing, or find it by browsing `_meetingrecorder._tcp`.
- iOS asks for the Local Network permission the first time the app connects to the Mac; add
  `NSLocalNetworkUsageDescription` and `NSBonjourServices` = `["_meetingrecorder._tcp"]` to the app's Info.plist.
- `AVPlayer` cannot speak PSK. Either feed it through `AVAssetResourceLoaderDelegate` with a custom URL scheme and fulfil
  its data requests with ranged `GET`s on `/v1/meetings/{id}/audio`, or listen on `127.0.0.1` with an `NWListener` and
  hand `AVPlayer` a plain `http://127.0.0.1:<port>/…` URL that forwards to the Mac.
- Keep one connection open while the app is in the foreground and open another for a chat, which holds its connection until
  the answer is done. The Mac allows 24 at once.
- A sleeping Mac does not answer; there is no push. Show the time of the last successful `status` call.

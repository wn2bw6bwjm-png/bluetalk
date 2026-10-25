# BlueTalk

Offline mesh messenger for Android and iPhone.

**NO ACCOUNT · NO SERVER · NO CLOUD · NO REQUIRED INTERNET**

A Flutter messenger for Android and iPhone where nearby phones talk directly to
each other, or hop through other phones that cannot read the messages. A
cryptographic identity is created locally on first launch: no registration, no
phone number, no backend, no telemetry, no analytics, no ads, no internet
requests.

> **Read [docs/STATUS.md](docs/STATUS.md) first.** It states exactly what was
> verified by running code, what was only compiled/analysed, and what was
> never run on real radios. The radio layer has **not** been tested on
> physical devices yet; that is your next step
> ([docs/TESTING_PHYSICAL.md](docs/TESTING_PHYSICAL.md)).

## Repository layout

| Path | Role | Verification done here |
|---|---|---|
| `packages/mesh_core` | Pure Dart: identity, crypto, protocol, routing, rooms domain, invites, themes, transport abstraction | **164 tests**, analyzer clean |
| `packages/mesh_engine` | Pure Dart + SQLite: storage/migrations, outbox, chats, rooms, search, block/mute | **93 tests** (real SQLite + multi-node mesh), analyzer clean |
| `packages/mesh_ble_android` | Kotlin BLE GATT server+client transport + foreground service | Compiles against Android API 34; **never run on hardware** |
| `packages/mesh_multipeer_ios` | Swift: Multipeer (iPhone-iPhone) + CoreBluetooth central (iPhone-Android) | **Not compiled, not run** |
| `app` | Flutter UI (Riverpod) | **Static analysis clean** against Flutter 3.47.7 sources and the pinned plugin versions; **never run** |

Required modules map to code as: `core/ identity/ crypto/ networking/ rooms/
channels/ themes/` = `mesh_core/lib/src/*` (channels live with rooms);
`storage/ messaging/ users/` = `mesh_engine/lib/src/*`; `notifications/ ui/` =
`app/lib/platform`, `app/lib/ui`. The UI never touches SQLite, Bluetooth or
native APIs: it calls `MeshEngine` only.

## Setup

Requirements: Flutter stable >= 3.27 (Dart >= 3.3), Android SDK 34 / JDK 17,
Xcode 15+ for iOS, **two or three physical phones** (emulators have no usable
BLE/Multipeer).

```bash
# 1. Core + engine tests (any machine with Dart; engine needs libsqlite3 with FTS5)
(cd packages/mesh_core   && dart pub get && dart test)
(cd packages/mesh_engine && dart pub get && dart test)

# 2. Generate android/ ios/ and apply permissions / build settings (once)
bash tool/bootstrap_app.sh

# 3. Run on a connected device
cd app && flutter run -d <device-id>
```

Plugin versions (`app/pubspec.yaml`) were pinned and *analysed* but could not
be resolved from pub.dev in the build sandbox; run `flutter pub get` and
`flutter pub outdated`, and re-run the tests after any upgrade.

### Permissions (applied by `bootstrap_app.sh`)

* Android 12+: `BLUETOOTH_SCAN` (`neverForLocation`), `BLUETOOTH_ADVERTISE`,
  `BLUETOOTH_CONNECT`. Android 6-11: `ACCESS_FINE_LOCATION` (the OS requires it
  for BLE scans; the app never reads a position). `CAMERA` (QR scanner),
  `POST_NOTIFICATIONS` (Android 13+). minSdk 23; core-library desugaring on.
* iOS: `NSLocalNetworkUsageDescription`, `NSBonjourServices`
  (`_bluetalk._tcp`, `_bluetalk._udp`), `NSBluetoothAlwaysUsageDescription`,
  `NSCameraUsageDescription`.

## Architecture

```
UI (Flutter, Riverpod)                       app/lib/ui, app/lib/application
  -> MeshEngine (facade)                     mesh_engine/services
       chats - rooms - outbox - search - block/mute - invites
       -> SQLite stores + migrations         mesh_engine/storage
       -> MeshNode (decode, dispatch, relay) mesh_core/networking
            SessionService (seal/open, replay, acks, announce)   crypto/
              IdentityService  KeyExchangeService  EncryptionService
              PacketSigner/Verifier  ReplayGuard  PacketCodec     protocol/
            MeshRouter (dedupe, TTL, loops, route cache, rate limit)
            PeerTransport -> NativeTransport (fragmentation, MTU, ordered sends)
                 -> NativeBridge -> MethodChannel -> Kotlin BLE | Swift Multipeer
```
Native code is a dumb byte pipe (no protocol logic); everything else is Dart
and unit-tested. Platform channels are used instead of Pigeon (the interface is
five calls and five event types, documented in `native_transport.dart`).

## Protocol (v1)

Binary CBOR map with integer keys: version, type, messageId(16), senderId(16),
destinationId?, roomId?, timestamp, ttl, hopCount, payload, signature(64),
senderKeys?(64). Types: announce, directMessage, ack. Decoding is strict (size
limits, unknown keys, wrong types/lengths, trailing bytes, non-canonical
encodings, TTL range). Rooms, groups, reactions, edits, deletes, read receipts,
sync and join requests are all *content kinds* inside encrypted direct
messages, so relays never learn about them.

* **Signature (Ed25519)** covers a fixed canonical layout (domain label,
  version, type, ids, flags, timestamp, payload). `ttl`/`hopCount` are **not
  signed** because relays must change them: a malicious relay can shorten a
  packet's life (denial of delivery) but cannot alter content or sender.
* **Peer ID** = SHA-256(domain || signPub || agreePub)[0..16]; derived from the
  keys, so it cannot be claimed for other keys. Fingerprint = full hash,
  compared out of band to verify contacts.

## Encryption

Per message: fresh X25519 ephemeral key -> ECDH with the recipient's static
key -> HKDF-SHA256 (salt = ephemeralPub||recipientPub, info =
label||sender||recipient) -> ChaCha20-Poly1305 with the packet header as AAD.
Libraries: `cryptography` (no custom primitives). Ed25519/X25519 checked against
RFC 8032 / RFC 7748 test vectors. Private keys live only in the platform secure
store (Android Keystore-backed / iOS Keychain).

Provided: relays cannot read content; sender and recipient authenticated;
header/ciphertext binding; replay protection (persistent across restarts).
**Not provided:** forward secrecy against later compromise of the recipient's
long-term key (needed for offline store-and-forward without a handshake);
metadata hiding (relays see sender/recipient IDs and timestamps); deniability.
Contacts are trust-on-first-use; verify fingerprints.

Groups and rooms use **pairwise fan-out**: one separately encrypted copy per
member (cost grows with member count; rooms are capped at 256 members).
"Public room" means *joinable without an invitation by nearby people*; its
content is still end-to-end encrypted to members, never broadcast in clear.

## Routing

Signed controlled flooding with a route cache (`mesh_router.dart`): a relay
verifies the signature before forwarding, forwards each (sender, messageId,
attempt) once, never back on the arrival link, consumes one TTL per hop (max
8), unicasts on a learned route else floods other links, and rate-limits per
neighbour. Announces are relayed once (2-hop visibility) and shared with late
joiners. The route table is intentionally in memory only: radio link IDs do not
survive restarts, so a persisted table would be wrong.

## Rooms, channels, roles

A room is the deterministic replay of a set of **signed events** ordered by
(lamport, eventId): create/update/delete room, channels, add/remove member,
set role. Every device computes the same state regardless of arrival order
(concurrent edits: last event in that order wins). Permissions are checked *at
the event's position*, so backdating cannot bypass them. Roles: Owner (all),
Admin (room settings, channels, members, delete any message), Member (post).
Devices reconcile with an offer/want exchange whenever two members connect.
The room ID commits to the owner's ID, so nobody else can create it.

## Offline queue and statuses

Every outgoing message is written to SQLite and an outbox row per recipient
*before* any send. Rows survive restarts, retry with back-off, wake when a new
link appears, expire after 7 days (-> *failed*), and stop at a verified signed
ack. Retries reuse the message ID; recipients re-acknowledge duplicates.
Statuses shown: **queued, sent** (handed to a link - not proof), **delivered**
(verified ack from every recipient), **read** (verified receipt; DMs only,
switchable), **failed**. *Relayed* is intentionally absent: the protocol has no
relay acknowledgements, so showing it would be a guess.

## Local storage and privacy

SQLite tables: settings, peers (users), rooms, channels, members, room_events,
messages, reactions, outbox, seen_packets, used_invites + FTS5 index.
Migrations v1->v3 run transactionally and refuse databases from newer app
versions. Search (people, rooms, channels, message text) is local only.
No telemetry/ads/analytics, no network requests to any server. Notifications
are local only (no push service).

## Cross-platform, background and "Relayed"

**Android <-> iPhone.** Both speak the same GATT service. The iPhone is always
the BLE *central* towards Android phones (iPhones cannot advertise the
manufacturer tag Android uses for its own tie-break, and iOS can scan in the
background), Android never initiates towards an untagged device, so duplicate
links cannot form. iPhone <-> iPhone uses Multipeer (foreground only).
Written against the CoreBluetooth API but **never compiled or run**.

**Background: improved, not guaranteed.** This is not something software can
guarantee without a server, because the OS decides whether an app runs.
* Android: a foreground service (permanent notification, type
  `connectedDevice`) raises process priority; the app can ask to be exempt from
  battery optimisation. Vendor "battery savers" can still kill it, swiping the
  app away from recents ends it, and the Dart engine lives only as long as the
  Flutter engine does.
* iOS: `bluetooth-central` background mode plus state restoration let iOS wake
  the app for BLE events with an Android phone. iOS throttles background
  scanning, never restarts an app you force-quit, and suspends Multipeer.
  Two iPhones have **no** background path. A backgrounded iPhone's
  advertisement is invisible to Android scanners, so the iPhone must find the
  Android phone, not the other way round.
* Without push (there is no server) nothing can wake a suspended or
  force-quit app. Queued messages wait in the outbox and go out when the app
  next runs.

**Relayed.** A relay that verified and forwarded your packet returns a signed
*relay receipt* (hop-by-hop, never forwarded). The status shows **relayed**
when a direct neighbour's signature attests this. It is an attestation by that
neighbour: not proof that later hops forwarded it and not delivery; only the
recipient's signed ack means **delivered**.

## Platform limits - read before testing

**BLE (both OS):** a link layer, not a mesh; multi-hop is done in software.
Throughput is a few KB/s (packets are fragmented to the negotiated MTU), range
~10-30 m, Android typically allows ~7 simultaneous GATT links; Android
scanning is throttled (5 starts / 30 s); some chipsets cannot advertise.

**iOS:** Multipeer connects Apple to Apple only and is suspended in the
background. Local Network permission prompt appears on first use.

**Background delivery is not guaranteed on either OS and is not promised.**
Local notifications appear only while the OS lets the app run.

## Testing

```bash
(cd packages/mesh_core   && dart test)   # 164 tests
(cd packages/mesh_engine && dart test)   #  93 tests
```
Covered: identity + RFC vectors; packet serialization/validation; signatures,
replay (incl. persisted); TTL, duplicates, loops, relay; rooms/permissions/
conflict resolution; invites; themes (WCAG contrast of presets); migrations
(v1->v2->v3 with data); outbox (restart, retries, expiry); end-to-end
scenarios on real SQLite: A->C through B, duplicate resend, A->B->A loop,
offline queue then delivery, room metadata sync across 3 devices incl.
partition-and-heal, relay cannot decrypt. In-memory transports exist **only
under `test/`**. Physical procedure: [docs/TESTING_PHYSICAL.md](docs/TESTING_PHYSICAL.md).

## Building with GitHub Actions

`.github/workflows/build.yml` runs the tests, builds an Android APK (debug-key
signed: fine for your own phones) and an **unsigned** iOS app. Start it from
the Actions tab ("Run workflow"). Artifacts appear on the run page.

**iOS signing.** A CI machine has no Apple account, so the `.ipa` is unsigned
and cannot be installed as-is. Options: (1) re-sign and install it yourself
with a free Apple ID through a sideloading tool (the certificate then lasts
only 7 days); (2) build locally in Xcode with your team; (3) with a paid Apple
Developer account ($99/year) add your certificate and provisioning profile as
repository secrets and extend the workflow to sign and upload to TestFlight.
The workflow has never been run; the first run may expose build errors.

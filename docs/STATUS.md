# Status

Last verified in the build sandbox. "Verified" means executed or analysed by a
real tool here, not that it works on phones.

## Verified by running code
* **mesh_core - 163 tests, analyzer clean.** Identity (create/persist/wipe,
  RFC 8032 + RFC 7748 vectors), CBOR codec with strict rejection, signatures
  (tamper detection on every signed field), replay (duplicate/old/future/
  bounded/no cache poisoning/persisted), E2E encryption (relay cannot decrypt
  or re-address), announce (+status/bio), signed acks, fragmentation incl.
  20-byte MTU, NativeTransport against a fake bridge, routing (A-B-C relay,
  duplicates, loops, TTL, route cache, rate limit, late join, retry through a
  relay), content kinds, rooms/roles/permissions/conflict resolution
  (shuffled-order convergence, backdating, forged creates), invites, themes.
* **mesh_engine - 90 tests on real SQLite, analyzer clean.** Migrations v1->v4
  with data, search (FTS5, Cyrillic, hostile input), outbox (retries, expiry,
  restart on a file DB, lost ack -> re-ack), block-before-ack, mute, edits/
  deletes/reactions/read receipts and their authorization, rooms over a 3-node
  mesh (create, sync, partition-and-heal, concurrent renames, moderation,
  group delivery needs all acks), invites (single use, expiry, forged,
  revoked issuer), public rooms, restart recovery, **relay receipts**
  (signed, hop-by-hop, forged/replayed/non-neighbour rejected, status
  queued<sent<relayed<delivered<read never moves backwards).
* **app - static analysis clean** (`dart analyze`) against Flutter 3.47.7
  framework sources and the exact plugin versions pinned in `pubspec.yaml`.
  The analysis caught real errors (missing imports, wrong plugin APIs).
* **Kotlin BLE plugin + foreground service** compile against Android API 34 (Flutter classes
  stubbed).

## Written but NOT verified
* **Any behaviour on real radios**: BLE GATT roles, MTU negotiation,
  reconnects, write queues, tie-break against duplicate links, flooding in a
  real network, battery behaviour.
* **Swift plugin (Multipeer + CoreBluetooth central)**: never compiled (no
  Swift toolchain here). The Android<->iPhone interop rests on it and on the
  Kotlin side agreeing on the GATT protocol; nobody has seen them talk.
* **Foreground service / battery-optimisation request** on real Android
  versions (API 31-35 differ in what they allow).
* **The Flutter app has never been run**: no widget tests, no screenshots; the
  analyzer cannot catch layout or runtime errors. Expect UI bugs.
* **Plugin API behaviour** (secure storage, QR scanner, notifications,
  permissions) is type-checked only.
* `bootstrap_app.sh` patching of generated Gradle/Manifest/Plist files was
  tested only on sample text; check its output.

## Field report (first real test)
Two devices did not find each other. A probable cause was fixed (the Android
recognition tag moved from the scan response, which some phones never deliver,
into the main advertisement) and a **Radio log** was added to diagnose the next
attempt. Second report: with an iPhone and an Android phone neither saw the
other. By design Android cannot see an iPhone (the iPhone never advertises);
the iPhone must find the Android phone. The iPhone side no longer relies on the
manufacturer tag (iOS may report a device before the scan response arrives);
it connects to every device advertising the BlueTalk service. Both fixes are
unverified until tested on phones.

## Visibility before connecting
Nearby now lists unidentified devices ("BlueTalk device", signal strength) as
soon as the radio sees them. The iPhone advertises the service (local name
`BTK`, no GATT service) so Android sees it at once; iPhones skip each other and
any peripheral that lacks the mesh service. Names and identities still arrive
only after the connection (signed announce), so the entry turns into the named
contact. Unverified on phones.

## Deliberate deviations from the brief (and why)
* Platform channels instead of Pigeon (tiny interface, documented).
* Routing cache is in memory only (link IDs do not survive restarts).
* "Relayed" is an attestation by a direct neighbour (signed receipt), not
  proof of onward forwarding; "Sending" is shown as "queued".
* Letter avatars only; avatar images are not implemented.
* Group/room crypto is pairwise fan-out, not a shared group key.
* Room anti-entropy offers cover the newest 600 events per room.

## Known limitations (also in README)
* **Background delivery cannot be guaranteed** (no server, so nothing can wake
  a suspended/force-quit app). Android foreground service and iOS Bluetooth
  background mode are mitigations only. Swiping the app away on Android ends
  it (the Dart engine is tied to the Flutter engine, not to the service).
* iPhone <-> iPhone has no background path (Multipeer is suspended; BLE
  between two iPhones is not implemented). A backgrounded iPhone is invisible
  to Android scanners, so the iPhone has to be the one that initiates.
* Relays see metadata; no forward secrecy for the recipient key; room size
  <= 256, 5000 events/room; read receipts are DM-only; a lying direct neighbour
  can claim "relayed".

## Not implemented
Avatar images, message attachments, in-chat search, running the Dart engine
inside the Android service (true headless background), iPhone <-> iPhone BLE.

## Sandbox note
pub.dev was unreachable, so Dart/Flutter sources and packages were assembled
from GitHub; `package:hex` was replaced by a tiny shim and SQLite was built from
source under musl. None of that applies on a normal machine.

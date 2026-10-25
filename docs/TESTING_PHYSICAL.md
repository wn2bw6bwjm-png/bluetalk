# Physical device test procedure

Emulators cannot do BLE/Multipeer. Use real phones. Record device models, OS
versions, timings and every failure. Test pairs separately: Android-Android
(BLE), iPhone-iPhone (Multipeer), **Android-iPhone (BLE, new and unverified)**.

Setup on each phone: install the build, Bluetooth on, grant all prompts
(iOS: allow Local Network and Camera), Welcome -> Continue (name optional).

## Stage 1: two devices (must pass first)
1. Open **Nearby** on both. Within ~30 s each lists the other as "Connected".
2. Compare fingerprints (Settings -> Security vs chat shield menu) and tap
   "They match".
3. A sends "test 1": B receives it; A's ticks go queued -> sent -> **delivered**.
4. Reverse direction. Send a ~5000-character message (fragmentation).
5. Edit, react, reply, delete a message: both sides update. Open the chat on B:
   A's message shows **read** (turn receipts off in Privacy: it must not).
6. Block B on A: B's messages never show "delivered". Unblock: they arrive.
7. Move out of range / disable Bluetooth on B: A shows B offline. Send from A:
   status stays **queued**. Re-enable B: the message is delivered.
8. Force-stop A while a message is queued, relaunch: it is still queued and is
   delivered once B is back. Same Peer ID after relaunch.
9. Airplane mode + Bluetooth on: still works.

## Stage 1b: Android <-> iPhone
1. Both apps open and in the foreground: the iPhone lists the Android phone as
   "Connected · Bluetooth LE" within ~30 s (the iPhone initiates). If the
   Android phone does not appear, check that it advertises (Nearby banner).
2. Send both ways, including the 5000-character message.
3. Put the Android app in the background with the foreground service on (the
   permanent notification must be visible): the iPhone should stay connected
   while its app is open.
4. Put the iPhone app in the background: note whether messages still arrive,
   and for how long. **Record the result: this is best effort.**
5. Force-quit the iPhone app: it must NOT receive anything (expected).
6. Check the Android battery page: grant "unrestricted"; compare how long the
   radio survives with the screen off, with and without it.

## Stage 2: three devices A - B - C (relay)
Place A and C out of each other's range with B between (different rooms), and
confirm A and C never show each other as "Connected" (they may show "Reachable
via relay").
1. A sends to C: the tick shows **relayed** (B's signed receipt), then
   **delivered**. A direct A->B message must never show *relayed*.
2. Turn B off, send A -> C: **queued**; turn B on: delivered.
3. Move C next to A: delivery now direct.
4. B's Chats list must show nothing from A<->C.

## Stage 3: rooms (3 devices)
1. A creates a private room, adds B (as admin) and C. All three show it with
   the same name/colour/channels.
2. A renames the room, B adds a channel, A promotes/demotes C: all converge.
3. Take C out of range; A and B rename/add a channel; bring C back: C catches up.
4. Members post in a channel; senders reach **delivered** only after every
   member acked. A non-admin cannot rename or add channels (error shown).
5. Admin deletes a member's message (everyone sees the tombstone); a member
   cannot delete an admin's message.
6. Mute a channel: no notification, message still arrives.
7. Invite: A shows a room-invite QR; D (fourth phone or reset C) scans it and is
   added once A is reachable. Scanning the same QR on another phone must fail.
8. Public room: A makes a public room; B sees it under Nearby -> Join.
9. Remove C: C's room shows "no longer a member" and stops receiving.

## Stage 4: appearance and misc
Switch System/Light/Dark/AMOLED/Custom and all seven presets (applies at once,
persists after restart); change a room colour for everyone and for this device
only; search for a word, a contact and a room.

## If devices do not find each other
1. Settings -> Network -> **Radio log**: it lists what the radio did (permissions,
   advertising started/failed, devices found and why it did or did not connect,
   GATT status codes). Use **Copy** and keep it with your notes.
2. Both phones: Bluetooth on, "Nearby devices" permission granted (Android
   <= 11: Location permission AND location switched on), apps open on screen,
   phones within ~2 m. After changing a permission tap **Restart radio**.
3. Typical log lines: `advertising FAILED code=...` (phone cannot advertise),
   `scan FAILED code=6` (scanning too often: wait 30 s), `found ... WITHOUT tag`
   (looks like an iPhone), `client: ... status=133` (generic GATT error; it
   retries), `link UP` (success).

## Troubleshooting
* Android: location services ON for Android <= 11; exempt the app from battery
  optimisation; some phones cannot advertise (banner in Nearby).
* iOS: Settings -> Privacy -> Local Network -> enable the app.
* Radio errors appear in Nearby and Settings -> Network.

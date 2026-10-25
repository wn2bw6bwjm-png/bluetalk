import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';
import 'package:test/test.dart';

import 'support/harness.dart';
import 'support/linked_transport.dart';
import 'support/sqlite_init.dart';

void main() {
  setUpAll(initSqliteForTests);

  test('a scanned device shows up at once, strongest signal first', () async {
    final net = Net()
      ..link('A', 'B')
      ..link('A', 'C');
    await net.build();
    net['A'].transports[0].discover(rssi: -80);
    net['A'].transports[1].discover(rssi: -50);
    await eventually(() => net['A'].engine.nearbyDevices.length == 2,
        what: 'two devices listed');
    final list = net['A'].engine.nearbyDevices;
    expect(list.first.rssi, -50);
    expect(list.last.rssi, -80);
    expect(net['A'].of<NearbyDevicesChanged>(), isNotEmpty);
    await net.stop();
  });

  test('the entry disappears once the device is connected and identified',
      () async {
    final net = Net()..link('A', 'B');
    await net.build();
    net['A'].transports.first.discover(rssi: -60);
    await eventually(() => net['A'].engine.nearbyDevices.isNotEmpty);
    await net.connect('A', 'B'); // same link id as the discovery
    await eventually(() => net['A'].engine.peers.get(net['B'].id) != null,
        what: 'B identified');
    expect(net['A'].engine.nearbyDevices, isEmpty);
    await net.stop();
  });

  test('stale entries expire after 30 seconds', () async {
    initSqliteForTests();
    var now = 1000000;
    final id = await LocalIdentity.fromSeeds(randomBytes(32), randomBytes(32));
    final (ta, _) = LinkedTransport.pair('a>b', 'b>a');
    final db = MeshDatabase.openInMemory();
    final engine = MeshEngine(
      identity: id,
      database: db,
      transports: [ta],
      clock: () => now,
      announceInterval: null,
      outboxInterval: const Duration(hours: 1),
    );
    await engine.start();
    ta.discover(rssi: -70);
    await eventually(() => engine.nearbyDevices.length == 1);
    now += 29000;
    expect(engine.nearbyDevices.length, 1);
    now += 2000;
    expect(engine.nearbyDevices, isEmpty);
    await engine.stop();
    db.close();
  });
}

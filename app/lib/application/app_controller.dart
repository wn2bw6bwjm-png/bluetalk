import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Platform;
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_core/mesh_core.dart';
import 'package:mesh_engine/mesh_engine.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/background.dart';
import '../platform/local_notifications.dart';
import '../platform/method_channel_bridge.dart';
import '../platform/permissions.dart';
import '../platform/secure_secret_store.dart';

enum Phase { loading, welcome, ready, failed }

class AppState {
  const AppState({
    this.phase = Phase.loading,
    this.error,
    this.name,
    this.status,
    this.bio,
    this.self,
    this.fingerprint = '',
    this.theme = const AppThemeSettings(),
    this.engine,
    this.networkRunning = false,
    this.networkError,
  });

  final Phase phase;
  final String? error;
  final String? name;
  final String? status;
  final String? bio;
  final PeerIdentity? self;
  final String fingerprint;
  final AppThemeSettings theme;
  final MeshEngine? engine;
  final bool networkRunning;
  final String? networkError;

  AppState copyWith({
    Phase? phase,
    String? error,
    String? name,
    String? status,
    String? bio,
    PeerIdentity? self,
    String? fingerprint,
    AppThemeSettings? theme,
    MeshEngine? engine,
    bool clearEngine = false,
    bool? networkRunning,
    String? networkError,
    bool clearNetworkError = false,
  }) =>
      AppState(
        phase: phase ?? this.phase,
        error: error ?? this.error,
        name: name ?? this.name,
        status: status ?? this.status,
        bio: bio ?? this.bio,
        self: self ?? this.self,
        fingerprint: fingerprint ?? this.fingerprint,
        theme: theme ?? this.theme,
        engine: clearEngine ? null : (engine ?? this.engine),
        networkRunning: networkRunning ?? this.networkRunning,
        networkError:
            clearNetworkError ? null : (networkError ?? this.networkError),
      );
}

final appControllerProvider =
    NotifierProvider<AppController, AppState>(AppController.new);

/// The running engine (null until the radio was started once).
final engineProvider = Provider<MeshEngine?>(
  (ref) => ref.watch(appControllerProvider.select((s) => s.engine)),
);

/// Bumped (debounced) whenever the engine reports any change. Widgets watch
/// it and re-read the synchronous SQLite stores; no data is cached in UI
/// state, so the screen can never show something the database does not hold.
class RevisionNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// Last radio diagnostics (native BLE/Multipeer lines plus app-level steps),
/// shown in Settings -> Network so a failed test can be understood.
class RadioLog extends Notifier<List<String>> {
  static const int maxLines = 200;

  @override
  List<String> build() => const [];

  void add(String line) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamped = '${two(t.hour)}:${two(t.minute)}:${two(t.second)} $line';
    final next = [...state, stamped];
    state = next.length > maxLines ? next.sublist(next.length - maxLines) : next;
  }

  void clear() => state = const [];
}

final radioLogProvider = NotifierProvider<RadioLog, List<String>>(RadioLog.new);

final revisionProvider =
    NotifierProvider<RevisionNotifier, int>(RevisionNotifier.new);

/// Application layer: owns identity, database and engine lifecycle. The UI
/// never touches SQLite, Bluetooth or native APIs directly.
class AppController extends Notifier<AppState> {
  static const _nameKey = 'profile.name';
  static const _onboardedKey = 'profile.onboarded';
  static const _statusKey = 'profile.status';
  static const _bioKey = 'profile.bio';

  final SecretStore _secrets = SecureSecretStore();
  late final IdentityService _identityService = IdentityService(_secrets);
  final LocalNotifier _notifier = LocalNotifier();
  final BackgroundKeepAlive keepAlive = BackgroundKeepAlive();
  static const backgroundServiceKey = 'background_service';

  MeshDatabase? _db;
  SettingsStore? _settings;
  StreamSubscription<EngineEvent>? _sub;
  Timer? _debounce;
  String? _dbPath;

  @override
  AppState build() {
    ref.onDispose(() {
      _debounce?.cancel();
      unawaited(_sub?.cancel());
      unawaited(state.engine?.stop());
    });
    unawaited(_init());
    return const AppState();
  }

  Future<void> _init() async {
    try {
      final identity = await _identityService.loadOrCreate();
      final dir = await getApplicationSupportDirectory();
      _dbPath = '${dir.path}/mesh.db';
      _db = MeshDatabase.openFile(_dbPath!);
      _settings = SettingsStore(_db!);
      final onboarded = _settings!.getBool(_onboardedKey);
      state = state.copyWith(
        self: identity.public,
        fingerprint: await identity.public.fingerprint(),
        name: _settings!.get(_nameKey),
        status: _settings!.get(_statusKey),
        bio: _settings!.get(_bioKey),
        theme: _settings!.theme,
      );
      await _notifier.init();
      await _buildEngine();
      state = state.copyWith(phase: onboarded ? Phase.ready : Phase.welcome);
      if (onboarded) await startNetwork();
    } catch (e) {
      state = state.copyWith(phase: Phase.failed, error: '$e');
    }
  }

  /// The engine (database access, chats, rooms) always exists once storage is
  /// open, so stored data stays readable even if the radio cannot start
  /// (permission denied, Bluetooth off). Only [startNetwork] turns the radio on.
  Future<void> _buildEngine() async {
    await _sub?.cancel();
    final identity = await _identityService.loadOrCreate();
    // iPhone: Multipeer for iPhone<->iPhone and CoreBluetooth (always the
    // central) for iPhone<->Android. Android: BLE for everyone.
    final transports = <PeerTransport>[
      if (Platform.isIOS)
        NativeTransport(
          kind: TransportKind.multipeer,
          bridge: MethodChannelBridge('mesh/multipeer'),
        ),
      NativeTransport(
        kind: TransportKind.ble,
        bridge: MethodChannelBridge('mesh/ble'),
      ),
    ];
    final log = ref.read(radioLogProvider.notifier);
    for (final t in transports) {
      if (t is NativeTransport) t.logs.listen(log.add);
    }
    final engine = MeshEngine(
      identity: identity,
      database: _db!,
      transports: transports,
      displayName: state.name,
      status: state.status,
      bio: state.bio,
    );
    _sub = engine.events.listen(_onEngineEvent);
    state = state.copyWith(engine: engine, networkRunning: false);
  }

  /// Welcome screen result. [name] is optional.
  Future<void> completeOnboarding(String? name) async {
    final trimmed = name?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      _settings!.set(_nameKey, trimmed);
      state = state.copyWith(name: trimmed);
      await state.engine?.stop();
      await _buildEngine(); // announce the chosen name
    }
    _settings!.setBool(_onboardedKey, true);
    state = state.copyWith(phase: Phase.ready);
    await startNetwork();
  }

  Future<void> startNetwork() async {
    final engine = state.engine;
    if (engine == null || state.networkRunning) return;
    final log = ref.read(radioLogProvider.notifier);
    final denied = await ensureRadioPermissions();
    if (denied != null) {
      log.add('[app] permissions: $denied');
      state = state.copyWith(networkError: denied);
      return;
    }
    log.add('[app] permissions OK, starting radio');
    try {
      await engine.start();
      log.add('[app] radio started');
      if (_settings!.getBool(backgroundServiceKey, fallback: true)) {
        await keepAlive.start();
      }
      state = state.copyWith(networkRunning: true, clearNetworkError: true);
    } catch (e) {
      log.add('[app] start FAILED: $e');
      state = state.copyWith(networkError: 'Could not start radio: $e');
    }
  }

  /// Turns the Android foreground service on/off (persisted).
  Future<void> setBackgroundService(bool on) async {
    _settings!.setBool(backgroundServiceKey, on);
    if (on && state.networkRunning) {
      await keepAlive.start();
    } else if (!on) {
      await keepAlive.stop();
    }
    ref.read(revisionProvider.notifier).bump();
  }

  Future<void> stopNetwork() async {
    await keepAlive.stop();
    await state.engine?.stop();
    state = state.copyWith(networkRunning: false);
  }

  /// A stopped engine cannot be restarted, so build a fresh one on the same
  /// database (queued messages, rooms and keys are all reloaded from disk).
  Future<void> restartNetwork() async {
    await stopNetwork();
    await _buildEngine();
    await startNetwork();
  }

  Future<void> updateName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _settings!.remove(_nameKey);
      state = AppState(
        phase: state.phase,
        status: state.status,
        bio: state.bio,
        self: state.self,
        fingerprint: state.fingerprint,
        theme: state.theme,
        engine: state.engine,
        networkRunning: state.networkRunning,
      );
    } else {
      _settings!.set(_nameKey, trimmed);
      state = state.copyWith(name: trimmed);
    }
    // The name is announced to neighbours when the radio starts.
    await restartNetwork();
  }

  /// Updates the optional status line and bio shown to nearby peers.
  Future<void> updateProfileText({String? status, String? bio}) async {
    if (status != null) {
      final v = status.trim();
      v.isEmpty ? _settings!.remove(_statusKey) : _settings!.set(_statusKey, v);
    }
    if (bio != null) {
      final v = bio.trim();
      v.isEmpty ? _settings!.remove(_bioKey) : _settings!.set(_bioKey, v);
    }
    state = AppState(
      phase: state.phase,
      error: state.error,
      name: state.name,
      status: _settings!.get(_statusKey),
      bio: _settings!.get(_bioKey),
      self: state.self,
      fingerprint: state.fingerprint,
      theme: state.theme,
      engine: state.engine,
      networkRunning: state.networkRunning,
      networkError: state.networkError,
    );
    await restartNetwork(); // announces the new profile
  }

  void setTheme(AppThemeSettings theme) {
    _settings!.theme = theme;
    state = state.copyWith(theme: theme);
  }

  /// Settings store usable before the radio runs (privacy toggles etc.).
  SettingsStore get settings => _settings!;

  /// Erases keys and ALL local data. A new identity is created afterwards.
  Future<void> wipeEverything() async {
    await _sub?.cancel();
    await state.engine?.stop();
    _db?.close();
    _db = null;
    for (final suffix in ['', '-wal', '-shm']) {
      final f = File('$_dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    await _identityService.wipe();
    ref.invalidateSelf();
  }

  // ───────────────────────────── events ─────────────────────────────

  void _onEngineEvent(EngineEvent e) {
    if (e is IncomingNotification) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != AppLifecycleState.resumed) {
        unawaited(_notifier.show(e.title, e.body));
      }
    }
    _debounce ??= Timer(const Duration(milliseconds: 60), () {
      _debounce = null;
      ref.read(revisionProvider.notifier).bump();
    });
  }
}

/// Small helpers shared by widgets.
String hex(Uint8List b) => toHex(b);

String utf8Preview(String s, [int max = 60]) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

Uint8List fromUtf8(String s) => Uint8List.fromList(utf8.encode(s));

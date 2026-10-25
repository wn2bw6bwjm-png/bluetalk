import 'package:sqlite3/sqlite3.dart';

import 'migrations.dart';

/// Owns the SQLite connection and brings the schema up to date.
///
/// Opening is synchronous (sqlite3 FFI). For file databases WAL journaling is
/// enabled so readers never block the writer and a crash cannot corrupt data.
class MeshDatabase {
  MeshDatabase._(this.db);

  final Database db;

  static int get latestVersion => migrations.last.version;

  /// Opens (creating if needed) the database file and migrates it.
  static MeshDatabase openFile(String path) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL');
    return _prepare(db);
  }

  static MeshDatabase openInMemory() => _prepare(sqlite3.openInMemory());

  /// Opens an existing handle, optionally stopping at [upTo] (used by the
  /// migration tests to build an old-version database first).
  static MeshDatabase wrap(Database db, {int? upTo}) =>
      _prepare(db, upTo: upTo);

  static MeshDatabase _prepare(Database db, {int? upTo}) {
    db.execute('PRAGMA foreign_keys = ON');
    final d = MeshDatabase._(db);
    d._migrate(upTo ?? latestVersion);
    return d;
  }

  int get schemaVersion =>
      db.select('PRAGMA user_version').first.values.first as int;

  void _migrate(int target) {
    final current = schemaVersion;
    if (current > latestVersion) {
      throw StateError(
        'Database schema v$current is newer than this app (v$latestVersion). '
        'Refusing to open it to avoid data loss.',
      );
    }
    for (final m in migrations) {
      if (m.version <= current || m.version > target) continue;
      db.execute('BEGIN IMMEDIATE');
      try {
        for (final s in m.statements) {
          db.execute(s);
        }
        db.execute('PRAGMA user_version = ${m.version}');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  /// Runs [action] atomically.
  T transaction<T>(T Function() action) {
    db.execute('BEGIN IMMEDIATE');
    try {
      final r = action();
      db.execute('COMMIT');
      return r;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => db.dispose();
}

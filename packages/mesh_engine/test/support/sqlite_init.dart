import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';

/// TEST ENV ONLY: the sandbox Dart runtime is musl-linked, so it needs a
/// musl-built libsqlite3 (with FTS5). On a normal machine nothing is needed:
/// set MESH_SQLITE_LIB only if the system library has no FTS5.
void initSqliteForTests() {
  final override = Platform.environment['MESH_SQLITE_LIB'];
  final sandbox = File('/home/claude/sdk/libsqlite3_musl.so');
  final path = override ?? (sandbox.existsSync() ? sandbox.path : null);
  if (path != null) {
    open.overrideFor(OperatingSystem.linux, () => DynamicLibrary.open(path));
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mesh_engine/mesh_engine.dart';

import '../../application/app_controller.dart';

/// The engine, re-evaluated whenever anything in it changed. Widgets that call
/// this rebuild on every engine event and re-read the SQLite stores.
MeshEngine? engineOf(WidgetRef ref) {
  ref.watch(revisionProvider);
  return ref.watch(engineProvider);
}

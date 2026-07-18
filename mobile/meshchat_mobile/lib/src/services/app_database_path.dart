import 'package:path/path.dart' as p;

import 'app_database_path_stub.dart'
    if (dart.library.io) 'app_database_path_io.dart';

String? appDatabaseDirectoryOverrideForTesting;

Future<String> appDatabasePath(String filename) async {
  final override = appDatabaseDirectoryOverrideForTesting;
  if (override != null) return p.join(override, filename);
  return resolveAppDatabasePath(filename);
}

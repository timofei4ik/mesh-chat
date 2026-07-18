import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<String> resolveAppDatabasePath(String filename) async {
  final supportDirectory = await getApplicationSupportDirectory();
  final databaseDirectory = Directory(
    p.join(supportDirectory.path, 'databases'),
  );
  await databaseDirectory.create(recursive: true);
  return p.join(databaseDirectory.path, filename);
}

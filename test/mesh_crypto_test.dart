import 'package:flutter_test/flutter_test.dart';
import 'package:meshchat_mobile/src/services/mesh_crypto.dart';

void main() {
  test('decrypts a packet created by the Python client', () async {
    const pythonPacket =
        'MCENC1:eyJ2IjoxLCJ0byI6eyJlIjoidEszcXNhWG02SW5mc2NUVFNPNk1JcWhjUkUyZVdfSW5JM0JJZ29oU0RWST0iLCJuIjoiNl9zWFRXRkluUGlsc1hfUCIsImMiOiIzMUw0OWdBNk1kenYwb2Z4WE11U1ZrS0ZmaDFwZ0tHRWdwV2xKbXBhN050NTQ2YkVxa1lRaEE9PSJ9LCJmcm9tIjp7ImUiOiJ4N1FabUpMN1BudDd4VHdLamFVN0NCWU9SY05rMzZZRDlPTWQwSkJGaHpzPSIsIm4iOiJtNlNnSnNCVlE5c3R4SmQzIiwiYyI6ImJxcGs4ckV1NHZ1Vi1jZEh5by1OeFlfUEhIam93MWFOV0ZvcmppUldLWWNEeFB2ZWY1ZGc1QT09In19';

    final crypto = MeshCrypto();
    await crypto.initialize('mobile-user', 'mobile-secret');

    expect(crypto.publicKey, 'UHVSms_yH31Fh15Q932nKgRwauLIAB45FmV2To-bYSM=');
    expect(await crypto.decryptText(pythonPacket), 'Привет из Python');
  });

  test('reads its own encrypted sender copy', () async {
    final crypto = MeshCrypto();
    await crypto.initialize('mobile-user', 'mobile-secret');

    final encrypted = await crypto.encryptText(
      'UHVSms_yH31Fh15Q932nKgRwauLIAB45FmV2To-bYSM=',
      'Проверка',
    );

    expect(await crypto.decryptText(encrypted), 'Проверка');
  });
  test('wraps group keys and encrypts group content', () async {
    final crypto = MeshCrypto();
    await crypto.initialize('mobile-user', 'mobile-secret');

    final key = crypto.generateGroupKey();
    final envelope = await crypto.wrapGroupKey(crypto.publicKey, key);
    final restoredKey = await crypto.unwrapGroupKey(envelope);

    expect(restoredKey, key);

    final text = await crypto.encryptGroupText(key, 'group hello');
    expect(await crypto.decryptGroupText(restoredKey, text), 'group hello');

    final bytes = await crypto.encryptGroupBytes(key, [1, 2, 3, 4]);
    expect(await crypto.decryptGroupBytes(restoredKey, bytes), [1, 2, 3, 4]);
  });
}

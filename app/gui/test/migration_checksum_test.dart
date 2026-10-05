import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magnetic115hub/core/db/hub_database.dart';

void main() {
  const sql = 'CREATE TABLE demo(id INTEGER PRIMARY KEY);';
  final checksum = sha256.convert(utf8.encode(sql)).toString();

  test('迁移指纹一致时通过', () async {
    await HubDatabase.verifyMigrationChecksums(const <int, String>{
      1: sql,
    }, manifestText: jsonEncode(<String, String>{'v1': checksum}));
  });

  test('迁移指纹不一致时阻断', () async {
    await expectLater(
      HubDatabase.verifyMigrationChecksums(const <int, String>{
        1: sql,
      }, manifestText: jsonEncode(<String, String>{'v1': 'bad'})),
      throwsA(
        isA<HubDbException>()
            .having((e) => e.code, 'code', HubDbError.migrationFailed)
            .having((e) => e.message, 'message', contains('指纹不匹配')),
      ),
    );
  });

  test('迁移缺少指纹时阻断', () async {
    await expectLater(
      HubDatabase.verifyMigrationChecksums(const <int, String>{
        1: sql,
      }, manifestText: '{}'),
      throwsA(
        isA<HubDbException>()
            .having((e) => e.code, 'code', HubDbError.migrationFailed)
            .having((e) => e.message, 'message', contains('缺少指纹')),
      ),
    );
  });
}

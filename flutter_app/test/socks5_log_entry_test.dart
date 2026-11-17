import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/models/frp_config.dart';
import 'package:frp_app/models/socks5_config.dart';
import 'package:frp_app/services/socks5_log_entry.dart';

Socks5Connection _connection({String name = 'Media'}) => Socks5Connection(
  id: 'connection-stable-id',
  name: name,
  tcpPorts: [5513],
  udpPorts: [5513, 5514],
);

Map<String, Object?> _record() => {
  'v': 1,
  'configKey': 'SERVER01/group/8',
  'configName': 'Media group',
  'connectionId': 'connection-stable-id',
  'connectionName': 'Media',
  'protocol': 'udp',
  'listenPort': 5513,
  'event': 'traffic',
  'message': 'Received 3 packets (3600 bytes)',
};

String _line(Map<String, Object?> record) => '[SOCKS5] ${jsonEncode(record)}';

void main() {
  test('control-only display names keep structured logs filterable', () {
    const config = FrpConfig(
      id: 15,
      serverId: 'SERVER01',
      groupId: 8,
      groupName: '\u0080\u009f',
      name: '\u0000',
    );
    final row = _connection(name: '\u0080');
    expect(row.validationError(), isNull);
    final context = Socks5LogContext.fromConfig(config, row);
    expect(context.configName, 'Configuration');
    expect(context.connectionName, 'Ports');
    expect(
      Socks5LogEntry.tryParse(_line({..._record(), ...context.toJson()}))
          ?.context,
      context,
    );
    expect(
      Socks5LogContext.fromConfig(config.copyWith(groupId: 0), row).configName,
      'Configuration',
    );
  });

  test('saved group identity survives renaming and separates servers', () {
    const config = FrpConfig(
      id: 1,
      name: 'visitor-tcp',
      serverId: 'SERVER01',
      groupId: 8,
      groupName: 'Media group',
    );
    final first = Socks5LogContext.fromConfig(config, _connection());
    final renamed = Socks5LogContext.fromConfig(
      config.copyWith(name: 'renamed-tcp', groupName: 'Renamed group'),
      _connection(name: 'Renamed connection'),
    );
    expect(first.configKey, 'SERVER01/group/8');
    expect(renamed.configKey, first.configKey);
    expect(renamed.connectionId, first.connectionId);
    expect(renamed.configName, 'Renamed group');
    expect(renamed.connectionName, 'Renamed connection');
    final udp = Socks5LogContext.fromConfig(
      config.copyWith(id: 2, name: 'visitor-udp'),
      _connection(),
    );
    expect(udp, first);
    expect(udp.hashCode, first.hashCode);
    final otherServer = Socks5LogContext.fromConfig(
      config.copyWith(serverId: 'SERVER02'),
      _connection(),
    );
    expect(otherServer.configKey, isNot(first.configKey));
  });

  test(
    'standalone saved IDs are stable and drafts use bounded distinct keys',
    () {
      const config = FrpConfig(id: 15, name: 'Visitor', serverId: 'SERVER01');
      final first = Socks5LogContext.fromConfig(config, _connection());
      final renamed = Socks5LogContext.fromConfig(
        config.copyWith(name: 'Renamed visitor'),
        _connection(),
      );
      expect(first.configKey, 'SERVER01/config/15');
      expect(renamed.configKey, first.configKey);
      expect(renamed.configName, 'Renamed visitor');
      final draft = config.copyWith(id: 0, name: 'Draft / ["name"] ' * 50);
      final draftContext = Socks5LogContext.fromConfig(draft, _connection());
      expect(draftContext.configKey.length, lessThanOrEqualTo(128));
      expect(draftContext, Socks5LogContext.fromConfig(draft, _connection()));
      expect(
        Socks5LogContext.fromConfig(
          draft.copyWith(name: '${draft.name}2'),
          _connection(),
        ).configKey,
        isNot(draftContext.configKey),
      );
    },
  );

  test(
    'display names fall back and respect native length without broken Unicode',
    () {
      const grouped = FrpConfig(
        id: 1,
        serverId: 'SERVER01',
        groupId: 8,
        name: 'Fallback visitor',
      );
      expect(
        Socks5LogContext.fromConfig(grouped, _connection()).configName,
        'Fallback visitor',
      );
      expect(
        Socks5LogContext.fromConfig(
          grouped.copyWith(name: ''),
          _connection(),
        ).configName,
        'Configuration',
      );
      final longName = '${'a' * 159}😀 remaining';
      final context = Socks5LogContext.fromConfig(
        grouped.copyWith(groupName: longName),
        _connection(name: longName),
      );
      expect(context.configName, 'a' * 159);
      expect(context.connectionName, 'a' * 159);
      expect(utf8.decode(utf8.encode(context.configName)), context.configName);
    },
  );

  test(
    'C1 characters in otherwise valid names cannot reject native metadata',
    () {
      const config = FrpConfig(
        id: 15,
        serverId: 'SERVER01',
        groupId: 8,
        groupName: 'Living\u0085room\u009fTV',
      );
      final row = _connection(name: 'Video\u0080audio');
      expect(row.validationError(), isNull);
      final context = Socks5LogContext.fromConfig(config, row);
      expect(context.configName, 'Living room TV');
      expect(context.connectionName, 'Video audio');
      expect(context.connectionId, row.id);
      expect(context.configKey, 'SERVER01/group/8');
    },
  );

  test(
    'imported sensitive-looking IDs use stable metadata-only identities',
    () {
      const config = FrpConfig(id: 15, name: 'Visitor', serverId: 'SERVER01');
      final keys = <String>{};
      for (final id in [
        'password=alpha',
        'password=beta',
        'password:alpha',
        'sk:alpha',
        'id\u0080tail',
        '连接标识',
        'encoded/example',
      ]) {
        final row = _connection().copyWith(id: id);
        expect(row.validationError(), isNull);
        final context = Socks5LogContext.fromConfig(config, row);
        expect(context.connectionId, startsWith('encoded/'));
        expect(context.connectionId.length, lessThanOrEqualTo(128));
        expect(context.connectionId, isNot(contains(id)));
        expect(keys.add(context.connectionId), isTrue);
        expect(row.toJson()['id'], id);
        expect(
          Socks5LogContext.fromConfig(
            config.copyWith(name: 'Renamed visitor'),
            row.copyWith(name: 'Renamed connection'),
          ).connectionId,
          context.connectionId,
        );
      }
      for (final id in [
        'default',
        'row-a',
        'row_1',
        'row.2',
        Socks5Connection.generateId(),
      ]) {
        expect(
          Socks5LogContext.fromConfig(
            config,
            _connection().copyWith(id: id),
          ).connectionId,
          id,
        );
      }
    },
  );

  test('legacy configuration control characters are safe in log metadata', () {
    const config = FrpConfig(
      id: 15,
      serverId: 'SERVER01',
      groupId: 8,
      groupName: 'Living\nroom\tTV\u007f',
      name: 'visitor\r\nname\u0000',
    );
    final context = Socks5LogContext.fromConfig(config, _connection());
    expect(context.configName, 'Living room TV ');
    expect(context.configKey, 'SERVER01/group/8');
    final renamed = Socks5LogContext.fromConfig(
      config.copyWith(groupName: 'Living room TV'),
      _connection(),
    );
    expect(renamed.configKey, context.configKey);
    final standalone = Socks5LogContext.fromConfig(
      config.copyWith(groupId: 0),
      _connection(),
    );
    expect(standalone.configName, 'visitor  name ');
    expect(standalone.configKey, 'SERVER01/config/15');
    expect(
      Socks5LogContext.fromConfig(
        config.copyWith(groupId: 0, name: 'Clean name'),
        _connection(),
      ).configKey,
      standalone.configKey,
    );
  });

  test(
    'structured records preserve quoted labels without exposing JSON or IDs',
    () {
      final record = {
        ..._record(),
        'configName': '设备 [A] "main"',
        'connectionName': 'Video / "HD" [1]',
        'bytesReceived': 3600,
        'packetsReceived': 3,
        'futureMetric': {'value': 10},
      };
      final line = _line(record);
      final entry = Socks5LogEntry.tryParse(line)!;
      expect(entry.rawLine, line);
      expect(entry.raw, line);
      expect(entry.context.configKey, record['configKey']);
      expect(entry.context.connectionId, record['connectionId']);
      expect(entry.protocol, 'udp');
      expect(entry.listenPort, 5513);
      expect(entry.event, 'traffic');
      expect(entry.message, record['message']);
      expect(
        entry.displayLine,
        '[SOCKS5] 设备 [A] "main" / Video / "HD" [1] · UDP :5513 · Received 3 packets (3600 bytes)',
      );
      expect(entry.displayLine, isNot(contains('configKey')));
      expect(entry.displayLine, isNot(contains('connection-stable-id')));
      expect(entry.displayLine, isNot(contains('SERVER01')));
    },
  );

  test('optional epoch timestamp renders local time and invalid extras are ignored', () {
    final time = DateTime(2026, 11, 17, 10, 20, 30);
    final entry = Socks5LogEntry.tryParse(
      _line({..._record(), 'timestampMs': time.millisecondsSinceEpoch}),
    )!;
    expect(entry.timestampMs, time.millisecondsSinceEpoch);
    expect(entry.displayLine, startsWith('10:20:30 [SOCKS5]'));
    for (final invalid in ['later', {}, 8640000000000001]) {
      final parsed = Socks5LogEntry.tryParse(
        _line({..._record(), 'timestampMs': invalid}),
      )!;
      expect(parsed.timestampMs, isNull);
      expect(parsed.displayLine, startsWith('[SOCKS5]'));
    }
  });

  test(
    'legacy, future, incomplete and malformed records fall back to plain text',
    () {
      for (final line in [
        '[SOCKS5] UDP 5513: channel ready',
        '[SOCKS5] {broken json',
        '[STUN] ${jsonEncode(_record())}',
        'frpc output ${_line(_record())}',
        '[SOCKS5] [1, 2, 3]',
        _line({..._record(), 'v': 2}),
        _line({..._record(), 'v': 1.0}),
        _line({..._record(), 'configKey': null}),
        _line({..._record(), 'connectionId': ''}),
        _line({..._record(), 'connectionName': []}),
        _line({..._record(), 'protocol': 'sudp'}),
        _line({..._record(), 'listenPort': 0}),
        _line({..._record(), 'listenPort': 65536}),
        _line({..._record(), 'listenPort': '5513'}),
        _line({..._record(), 'message': []}),
        '[SOCKS5] ${jsonEncode(_record())} trailing junk',
      ]) {
        expect(Socks5LogEntry.tryParse(line), isNull, reason: line);
      }
      final value = _record()
        ..remove('configKey')
        ..remove('connectionId');
      expect(Socks5LogEntry.tryParse(_line(value)), isNull);
    },
  );

  test('control characters in labels and messages cannot create extra display rows', () {
    final entry = Socks5LogEntry.tryParse(
      _line({
        ..._record(),
        'configName': 'Group\nline',
        'message': 'Sent\r\n3\tpackets',
      }),
    )!;
    expect(entry.displayLine, isNot(contains('\n')));
    expect(entry.displayLine, isNot(contains('\r')));
    expect(entry.displayLine, contains('Group line'));
  });
}

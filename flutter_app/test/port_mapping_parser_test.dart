import 'package:flutter_test/flutter_test.dart';
import 'package:frp_app/services/port_mapping_parser.dart';

void main() {
  test('port lists and ranges expand and pair in order', () {
    final result = PortMappingParser.parse('22，8000-8002', '10022,9000—9002');

    expect(result.error, isNull);
    expect(
      result.mappings.map((mapping) => [mapping.localPort, mapping.remotePort]),
      [
        [22, 10022],
        [8000, 9000],
        [8001, 9001],
        [8002, 9002],
      ],
    );
  });

  test('port mapping validation rejects ambiguous input', () {
    expect(
      PortMappingParser.parse('22,23', '10022').error,
      'Local and remote port counts must match (2 vs 1)',
    );
    expect(
      PortMappingParser.parse('22,22', '10022,10023').error,
      'Local ports must not contain duplicates',
    );
    expect(
      PortMappingParser.parse('23-22', '10022-10023').error,
      'Local port range must be ascending: "23-22"',
    );
    expect(
      PortMappingParser.parse('1-129', '1000-1128').error,
      'At most 128 port mappings are allowed',
    );
  });

  test('port lists compact consecutive values without reordering', () {
    expect(
      PortMappingParser.formatPorts([22, 8000, 8001, 8002, 443]),
      '22,8000-8002,443',
    );
  });

  test('single bind-port input expands ranges and rejects duplicates', () {
    final result = PortMappingParser.parsePorts(
      '39001，39003-39005',
      label: 'XTCP bind',
    );
    expect(result.error, isNull);
    expect(result.ports, [39001, 39003, 39004, 39005]);

    expect(
      PortMappingParser.parsePorts('39001,39001', label: 'XTCP bind').error,
      'XTCP bind ports must not contain duplicates',
    );
    expect(
      PortMappingParser.parsePorts('-1', label: 'XTCP bind').error,
      'XTCP bind port must be between 1 and 65535',
    );
    expect(
      PortMappingParser.parsePorts(
        '-1',
        label: 'XTCP bind',
        allowDisabledPort: true,
      ).ports,
      [-1],
    );
    expect(
      PortMappingParser.parsePorts(
        '-1,39001',
        label: 'XTCP bind',
        allowDisabledPort: true,
      ).error,
      'XTCP bind disabled port -1 cannot be combined with other ports',
    );
  });
}

// Writes PricingTable.builtIn as a JSON price list that apps can fetch and
// layer over their own built-in table with PricingTable.fromJson and
// withOverrides:
//
//   dart run tool/export_pricing.dart [output path]
//
// Default output: build/pricing.json. Publish it with each release (and
// whenever a provider changes prices) so apps on older versions pick up
// the new prices without an update.
import 'dart:convert';
import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';

void main(List<String> args) {
  final out = File(args.isEmpty ? 'build/pricing.json' : args.first);
  final json = {
    'asOf': PricingTable.builtInAsOf.toIso8601String().substring(0, 10),
    ...PricingTable.builtIn.toJson(),
  };
  // Must load back unchanged, or apps would ignore it.
  PricingTable.fromJson(json);
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(json)}\n',
  );
  stdout.writeln(
    'Wrote ${PricingTable.builtIn.models.length} model prices to ${out.path}',
  );
}

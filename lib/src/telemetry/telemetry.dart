import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/cancellation.dart';
import 'pricing.dart';

// ── Tracing ────────────────────────────────────────────────────────────────

/// What a span measures.
enum SpanKind { run, model, tool }

/// Identifies a span, for parenting child spans.
final class SpanContext {
  final String traceId;
  final String spanId;
  const SpanContext(this.traceId, this.spanId);
}

/// One finished unit of work: a run, a model call or a tool call.
///
/// Attributes follow the OpenTelemetry GenAI conventions where one exists
/// (`gen_ai.*`), plus `agentic_harness.*` ones. Prompt and answer text are
/// never recorded.
final class TraceSpan {
  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final String name;
  final SpanKind kind;
  final DateTime start;
  final DateTime end;
  final Map<String, Object?> attributes;

  /// The error message when the work failed.
  final String? error;

  const TraceSpan({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    required this.name,
    required this.kind,
    required this.start,
    required this.end,
    this.attributes = const {},
    this.error,
  });

  Duration get duration => end.difference(start);

  SpanContext get context => SpanContext(traceId, spanId);

  Map<String, Object?> toJson() => {
    'traceId': traceId,
    'spanId': spanId,
    if (parentSpanId != null) 'parentSpanId': parentSpanId,
    'name': name,
    'kind': kind.name,
    'start': start.toUtc().toIso8601String(),
    'end': end.toUtc().toIso8601String(),
    'attributes': attributes,
    if (error != null) 'error': error,
  };
}

/// Receives each span as it ends (`RunConfig.tracer`). Called on the run's
/// path: keep it fast and never throw (errors are logged and ignored).
abstract interface class SpanExporter {
  void export(TraceSpan span);
}

/// Keeps spans in memory, for tests and in-app trace views.
class InMemorySpanExporter implements SpanExporter {
  final List<TraceSpan> spans = [];

  /// Most spans kept; the oldest are dropped first.
  final int maxSpans;
  InMemorySpanExporter({this.maxSpans = 10000});

  @override
  void export(TraceSpan span) {
    spans.add(span);
    // Trim in chunks so a full buffer doesn't shift the list per span.
    if (spans.length > maxSpans + maxSpans ~/ 10) {
      spans.removeRange(0, spans.length - maxSpans);
    }
  }
}

/// Sends spans to an OpenTelemetry collector over OTLP/HTTP with JSON
/// (`POST <endpoint>`, usually `http://localhost:4318/v1/traces`).
///
/// Spans are batched and sent every [interval] or when [batchSize] are
/// waiting, one request at a time; call [flush] before exit and [close]
/// when done. Failed sends are logged and dropped, and at most [maxQueued]
/// spans wait. The endpoint must be https unless it is loopback or
/// [allowInsecureHttp] is set, and redirects are not followed (they would
/// re-send [headers]).
class OtlpHttpExporter implements SpanExporter {
  final Uri endpoint;
  final Map<String, String> headers;
  final String serviceName;
  final int batchSize;
  final int maxQueued;
  final Duration interval;
  final http.Client _client;
  final bool _ownsClient;
  final ListQueue<TraceSpan> _queue = ListQueue();
  Timer? _timer;
  Future<void>? _draining;
  bool _closed = false;

  OtlpHttpExporter(
    this.endpoint, {
    this.headers = const {},
    this.serviceName = 'agentic_harness',
    int batchSize = 100,
    int maxQueued = 5000,
    this.interval = const Duration(seconds: 5),
    bool allowInsecureHttp = false,
    http.Client? client,
  }) : batchSize = batchSize.clamp(1, 10000),
       maxQueued = maxQueued.clamp(1, 100000),
       _client = client ?? http.Client(),
       _ownsClient = client == null {
    final loopback = const {
      'localhost',
      '127.0.0.1',
      '::1',
      '[::1]',
    }.contains(endpoint.host);
    if (endpoint.scheme != 'https' && !loopback && !allowInsecureHttp) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Use https for a remote collector (or set allowInsecureHttp)',
      );
    }
  }

  @override
  void export(TraceSpan span) {
    if (_closed) return;
    if (_queue.length >= maxQueued) _queue.removeFirst();
    _queue.add(span);
    if (_queue.length >= batchSize) {
      unawaited(flush());
    } else {
      _timer ??= Timer(interval, () => unawaited(flush()));
    }
  }

  /// Sends everything queued.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    // One drain at a time; it keeps going until the queue is empty.
    return _draining ??= _drain().whenComplete(() => _draining = null);
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final batch = <TraceSpan>[];
      while (batch.length < batchSize && _queue.isNotEmpty) {
        batch.add(_queue.removeFirst());
      }
      await _send(batch);
    }
  }

  Future<void> _send(List<TraceSpan> batch) async {
    try {
      final request =
          http.Request('POST', endpoint)
            ..followRedirects = false
            ..headers.addAll({'content-type': 'application/json', ...headers})
            ..body = jsonEncode(toOtlpJson(batch, serviceName: serviceName));
      final response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      // Drain the body without keeping it.
      await response.stream.drain<void>().timeout(const Duration(seconds: 30));
      if (response.statusCode >= 300) {
        developer.log(
          'trace export failed (HTTP ${response.statusCode})',
          name: 'agentic_harness.telemetry',
          level: 900,
        );
      }
    } catch (e) {
      developer.log(
        'trace export failed (${e.runtimeType})',
        name: 'agentic_harness.telemetry',
        level: 900,
      );
    }
  }

  Future<void> close() async {
    await flush();
    _closed = true;
    _timer?.cancel();
    if (_ownsClient) _client.close();
  }
}

/// [spans] as an OTLP/JSON `ExportTraceServiceRequest`.
Map<String, Object?> toOtlpJson(
  List<TraceSpan> spans, {
  String serviceName = 'agentic_harness',
}) {
  String nanos(DateTime t) => '${t.microsecondsSinceEpoch * 1000}';
  return {
    'resourceSpans': [
      {
        'resource': {
          'attributes': _otlpAttributes({'service.name': serviceName}),
        },
        'scopeSpans': [
          {
            'scope': {'name': 'agentic_harness'},
            'spans': [
              for (final s in spans)
                {
                  'traceId': s.traceId,
                  'spanId': s.spanId,
                  if (s.parentSpanId != null) 'parentSpanId': s.parentSpanId,
                  'name': s.name,
                  // INTERNAL for runs and tools, CLIENT for model calls.
                  'kind': s.kind == SpanKind.model ? 3 : 1,
                  'startTimeUnixNano': nanos(s.start),
                  'endTimeUnixNano': nanos(s.end),
                  'attributes': _otlpAttributes(s.attributes),
                  'status':
                      s.error == null
                          ? {'code': 1}
                          : {'code': 2, 'message': s.error},
                },
            ],
          },
        ],
      },
    ],
  };
}

List<Map<String, Object?>> _otlpAttributes(Map<String, Object?> attributes) {
  Map<String, Object?> value(Object? v) => switch (v) {
    final bool b => {'boolValue': b},
    final int i => {'intValue': '$i'},
    final double d => {'doubleValue': d},
    final List<Object?> l => {
      'arrayValue': {
        'values': [for (final e in l) value(e)],
      },
    },
    _ => {'stringValue': '$v'},
  };
  return [
    for (final e in attributes.entries)
      if (e.value != null) {'key': e.key, 'value': value(e.value)},
  ];
}

final _random = Random.secure();

String _hex(int bytes) =>
    [
      for (var i = 0; i < bytes; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();

/// A new random trace id (32 hex characters).
String newTraceId() => _hex(16);

/// A new random span id (16 hex characters).
String newSpanId() => _hex(8);

/// Telemetry a run hands to tools that start runs of their own
/// (`HarnessTool.startsRuns`), so a subagent's spans nest under the call
/// and its cost counts toward the parent run.
final class RunTelemetry {
  final SpanExporter? tracer;
  final PricingTable? pricing;

  /// The tool call's span.
  final SpanContext? parent;

  /// Adds a child run's cost to the parent's reported cost.
  final void Function(double cost)? addCost;

  /// Opens a child run's ledger under the calling run's, so concurrent
  /// children share one budget (the parent ledger itself isn't exposed).
  final BudgetLedger Function({double? limit, double spent})? openLedger;

  /// How deeply the calling run is nested (0 for a top-level run).
  final int depth;

  /// The deepest nesting allowed (`RunConfig.maxSubagentDepth` of the
  /// top-level run).
  final int maxDepth;

  /// Starts [work] in the background of the calling run and returns a task
  /// id; the text it completes with reaches the run as a message later.
  /// Throws [StateError] when too many tasks are running. Null when the
  /// run can't take background work.
  final String Function(
    String label,
    Future<String> Function(CancelToken cancel) work,
  )?
  startBackground;

  const RunTelemetry({
    this.tracer,
    this.pricing,
    this.parent,
    this.addCost,
    this.openLedger,
    this.depth = 0,
    this.maxDepth = 3,
    this.startBackground,
  });
}

/// Money a run (and the runs it starts) may spend, shared down the run
/// tree. Each model call reserves its worst-case cost before it starts and
/// releases the reservation when it ends; spending is recorded at every
/// level, so runs working at the same time can't jointly overshoot. While
/// several child runs are open, each may use an equal share of what the
/// parent has left, so one can't take it all.
final class BudgetLedger {
  /// This level's limit in US dollars; null means only the parents'.
  final double? limit;
  final BudgetLedger? _parent;
  double _spent;
  double _reserved = 0;
  int _openChildren = 0;
  bool _closed = false;
  Completer<void>? _released;

  /// A top-level ledger. [spent] is spending carried over from before a
  /// resume.
  BudgetLedger({this.limit, double spent = 0}) : _parent = null, _spent = spent;

  BudgetLedger._child(BudgetLedger parent, {this.limit, double spent = 0})
    : _parent = parent,
      _spent = spent {
    parent._openChildren++;
  }

  /// A ledger for a child run under this one. Its [spent] (from before a
  /// resume) counts against the child only: the parent already counted it.
  BudgetLedger child({double? limit, double spent = 0}) =>
      BudgetLedger._child(this, limit: limit, spent: spent);

  /// Whether this level or any above it has a limit.
  bool get hasLimit => limit != null || (_parent?.hasLimit ?? false);

  double get spent => _spent;

  /// What may still be spent or reserved, or null without a limit.
  double? get available {
    double? left = limit == null ? null : limit! - _spent - _reserved;
    final p = _parent;
    final above = p?.available;
    if (p != null && above != null) {
      final share = above / max(1, p._openChildren);
      left = left == null ? share : min(left, share);
    }
    return left;
  }

  /// Reserves [amount] at every level, or returns null (reserving nothing)
  /// when it doesn't fit.
  BudgetReservation? reserve(double amount) {
    if (_closed || !amount.isFinite || amount < 0) return null;
    final left = available;
    if (left != null && amount > left) return null;
    _adjust(amount);
    return BudgetReservation._(this, amount);
  }

  /// Records spending at every level.
  void spend(double amount) {
    if (!amount.isFinite || amount <= 0) return;
    _spent += amount;
    _parent?.spend(amount);
  }

  /// Ends this ledger's share of its parent (when its run ends).
  void close() {
    if (_closed) return;
    _closed = true;
    final p = _parent;
    if (p != null) p._openChildren--;
  }

  BudgetLedger get _root => _parent?._root ?? this;

  /// Whether calls anywhere in the run tree hold reservations (so waiting
  /// for [nextRelease] can free money).
  bool get othersReserving => _root._reserved > 0;

  /// Completes the next time a reservation anywhere in the tree is
  /// released.
  Future<void> get nextRelease => (_root._released ??= Completer()).future;

  void _adjust(double amount) {
    _reserved = max(0, _reserved + amount);
    final p = _parent;
    if (p != null) {
      p._adjust(amount);
    } else if (amount < 0) {
      final waiting = _released;
      _released = null;
      waiting?.complete();
    }
  }
}

/// Money held for one call; release it once the call ends.
final class BudgetReservation {
  final BudgetLedger _ledger;
  final double amount;
  bool _released = false;
  BudgetReservation._(this._ledger, this.amount);

  /// Returns the money to the ledger (once; later calls do nothing).
  void release() {
    if (_released) return;
    _released = true;
    _ledger._adjust(-amount);
  }
}

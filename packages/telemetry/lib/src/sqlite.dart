import 'package:sqlite3/sqlite3.dart';

import 'tracing.dart';

/// The application uses this small SQL surface for history and desktop state.
/// Each execution is timed, including prepared statements and cursor steps.
class TracedDatabase {
  TracedDatabase(this.raw, this.name) {
    // Native commit hooks include implicit writes and exclude savepoint release.
    // Traces can therefore diagnose actual transaction amplification, not just
    // count application-level append calls or explicit COMMIT statements.
    raw.commitFilter = () {
      traceInstant('sqlite.commit', category: 'sqlite', attributes: {'db.name': name});
      return true;
    };
  }
  final Database raw;
  final String name;
  int get lastInsertRowId => raw.lastInsertRowId;
  void close() => traceSync('sqlite.close', raw.close, category: 'sqlite', attributes: {'db.name': name});

  T _run<T>(String operation, String sql, T Function() action) =>
    traceSync('sqlite.$operation', action, category: 'sqlite',
      attributes: {'db.name': name, 'db.query.text': sql});

  void execute(String sql, [List<Object?> parameters = const []]) =>
    _run('execute', sql, () => raw.execute(sql, parameters));
  ResultSet select(String sql, [List<Object?> parameters = const []]) =>
    _run('select', sql, () => raw.select(sql, parameters));
  TracedStatement prepare(String sql) =>
    TracedStatement(_run('prepare', sql, () => raw.prepare(sql)), name, sql);
}

TracedDatabase openTracedDatabase(String path, {OpenMode mode = OpenMode.readWriteCreate}) =>
  traceSync('sqlite.open', () => TracedDatabase(sqlite3.open(path, mode: mode), path),
    category: 'sqlite', attributes: {'db.name': path});

class TracedStatement {
  TracedStatement(this.raw, this.database, this.sql);
  final PreparedStatement raw;
  final String database, sql;
  _TracedCursor? _cursor;
  T _run<T>(String operation, T Function() action) =>
    traceSync('sqlite.$operation', action, category: 'sqlite',
      attributes: {'db.name': database, 'db.query.text': sql});
  void execute([List<Object?> parameters = const []]) => _run('execute', () => raw.execute(parameters));
  ResultSet select([List<Object?> parameters = const []]) => _run('select', () => raw.select(parameters));
  IteratingCursor selectCursor([List<Object?> parameters = const []]) {
    _cursor?.finish();
    final span = startTraceSpan('sqlite.cursor', category: 'sqlite',
      attributes: {'db.name': database, 'db.query.text': sql});
    try { return _cursor = _TracedCursor(raw.selectCursor(parameters), span); }
    catch (error) { span?.end(error: error); rethrow; }
  }
  void close() {
    _cursor?.finish();
    _run('finalize', raw.close);
  }
}

class _TracedCursor extends IteratingCursor {
  _TracedCursor(this.inner, this.span) : super(inner.columnNames, inner.tableNames);
  final IteratingCursor inner;
  final TraceSpan? span;
  final _watch = Stopwatch();
  int _rows = 0;
  @override
  Row get current => inner.current;
  @override
  bool moveNext() {
    _watch.start();
    try {
      final next = inner.moveNext();
      _watch.stop();
      if (next) { _rows++; } else { finish(); }
      return next;
    } catch (error) {
      _watch.stop();
      span?.end(error: error, attributes: {'db.execution_us': _watch.elapsedMicroseconds});
      rethrow;
    }
  }
  void finish() => span?.end(attributes: {'db.rows': _rows, 'db.execution_us': _watch.elapsedMicroseconds});
}

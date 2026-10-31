import 'dart:convert';

// Codex's text output budgets and UTF-8 head/tail truncation; see decisions.md.
int cellOutputTokens(String source) {
  final newline = source.indexOf('\n');
  final first = (newline < 0 ? source : source.substring(0, newline)).trimLeft();
  const prefix = '// @exec:';
  if (!first.startsWith(prefix)) return 10000;
  if (newline < 0 || source.substring(newline + 1).trim().isEmpty) {
    throw const FormatException('exec pragma must be followed by JavaScript source');
  }
  final directive = jsonDecode(first.substring(prefix.length));
  if (directive is! Map<String, dynamic>) {
    throw const FormatException('exec pragma must be a JSON object');
  }
  for (final entry in directive.entries) {
    if (entry.key != 'max_output_tokens' && entry.key != 'yield_time_ms') {
      throw const FormatException(
        'exec pragma only supports yield_time_ms and max_output_tokens',
      );
    }
    final value = entry.value;
    if (value != null &&
        (value is! int || value < 0 || value > 9007199254740991)) {
      throw FormatException('${entry.key} must be a non-negative safe integer');
    }
  }
  // Yielding is not implemented. Preserve the existing treatment of that field
  // as a comment, while honoring the independently supported output budget.
  return directive['max_output_tokens'] as int? ?? 10000;
}

/// Applies the same presentation budget to direct tool output as printed cells.
String truncateTextOutput(String text, {int maxTokens = 10000}) =>
    renderCellOutput({
      'head': [text],
      'tail': <String>[],
      'omittedBytes': 0,
      'omittedItems': 0,
    }, maxTokens).single;

List<String> renderCellOutput(Map<String, dynamic> collected, int maxTokens) {
  final head = (collected['head'] as List).cast<String>();
  final tail = (collected['tail'] as List).cast<String>();
  final omittedBytes = collected['omittedBytes'] as int;
  final omittedItems = collected['omittedItems'] as int;
  final notice = omittedBytes == 0 && omittedItems == 0 ? null
      : '[Code Mode session output limit reached: omitted $omittedBytes text bytes; '
          'discarded $omittedItems text segments, 0 images, 0 audio items]';
  final combined = StringBuffer();
  void append(String text) {
    if (combined.isNotEmpty) combined.write('\n');
    combined.write(text);
  }
  head.forEach(append);
  final gap = combined.length;
  for (var i = 0; i < tail.length; i++) {
    if (i == 0 && collected['continuesHead'] == true) {
      combined.write(tail[i]);
    } else {
      append(tail[i]);
    }
  }
  final text = combined.toString();
  final bytes = utf8.encode(text);
  final budget = maxTokens * 4;
  if (bytes.length <= budget) {
    return [...head, ?notice, ...tail];
  }
  var left = budget ~/ 2, right = bytes.length - (budget - budget ~/ 2);
  while (left > 0 && bytes[left] & 0xc0 == 0x80) {
    left--;
  }
  while (right < bytes.length && bytes[right] & 0xc0 == 0x80) {
    right++;
  }
  final prefix = utf8.decode(bytes.sublist(0, left));
  final suffix = utf8.decode(bytes.sublist(right));
  final lines = '\n'.allMatches(text).length + (text.endsWith('\n') ? 0 : 1);
  final header = 'Warning: truncated output (original token count: ${(bytes.length + 3) ~/ 4})\n'
      'Total output lines: $lines\n\n';
  final marker = '…${(bytes.length - budget + 3) ~/ 4} tokens truncated…';
  final rendered = '$header$prefix$marker$suffix';
  if (notice == null) return [rendered];
  // Keep the retention notice at the lost middle, even when the token budget
  // removes that position from the rendered text.
  final gapBytes = utf8.encode(text.substring(0, gap)).length;
  final offset = header.length + (gapBytes <= left ? gap
      : prefix.length + marker.length + (gapBytes >= right
          ? utf8.decode(bytes.sublist(right, gapBytes)).length : 0));
  return [
    rendered.substring(0, offset),
    notice,
    if (offset < rendered.length) rendered.substring(offset),
  ];
}

// Retain text in the runtime, before serializing it across FFI. The fixed head
// and rolling tail share Codex's 1 MiB / 32 Ki item limits. Cursors avoid copying
// the entire retained suffix for every subsequent text() call.
const outputBootstrap = r'''
function __createOutput() {
  const maxBytes = 1024 * 1024, maxItems = 32 * 1024;
  const head = [];
  let tail = [], first = 0, bytes = 0, headBytes = 0, bounded = false;
  let omittedBytes = 0, omittedItems = 0;
  function entry(text) {
    let bytes = text.length;
    if (/[^\x00-\x7f]/.test(text)) {
      bytes = 0;
      for (let i = 0; i < text.length;) {
        const code = text.codePointAt(i);
        bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
        i += code > 0xffff ? 2 : 1;
      }
    }
    return {text, bytes, start: 0};
  }
  function boundary(item, budget, roundUp = false) {
    if (item.bytes === item.text.length - item.start) {
      const bytes = Math.min(budget, item.bytes);
      return {end: item.start + bytes, bytes};
    }
    let end = item.start, bytes = 0;
    while (end < item.text.length && bytes < budget) {
      const code = item.text.codePointAt(end);
      const width = code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
      if (!roundUp && bytes + width > budget) break;
      bytes += width;
      end += code > 0xffff ? 2 : 1;
    }
    return {end, bytes};
  }
  function advance(item, cut) {
    item.start = cut.end;
    item.bytes -= cut.bytes;
    if (item.start >= 4096 && item.start * 2 >= item.text.length) {
      item.text = item.text.slice(item.start);
      item.start = 0;
    }
  }
  function shift() {
    const item = tail[first];
    tail[first++] = null;
    return item;
  }
  function splitHead() {
    const item = tail[first];
    const cut = boundary(item, maxBytes / 2 - headBytes);
    if (cut.bytes === 0) return;
    head.push({text: item.text.slice(item.start, cut.end), bytes: cut.bytes, start: 0});
    headBytes += cut.bytes;
    advance(item, cut);
    item.continuesHead = true;
  }
  function discard() {
    const item = shift();
    bytes -= item.bytes;
    omittedBytes += item.bytes;
    omittedItems++;
  }
  return {
    push(text) {
      const item = entry(text);
      tail.push(item);
      bytes += item.bytes;
      if (!bounded) {
        if (bytes <= maxBytes && tail.length <= maxItems) return;
        bounded = true;
        while (head.length < maxItems / 2 && first < tail.length) {
          const item = tail[first];
          if (item.bytes <= maxBytes / 2 - headBytes || bytes <= maxBytes) {
            head.push(shift());
            headBytes += item.bytes;
            if (headBytes > maxBytes / 2) break;
          } else {
            splitHead();
            break;
          }
        }
      }
      if (bytes > maxBytes && headBytes > maxBytes / 2) {
        const item = head.pop();
        headBytes -= item.bytes;
        if (first > 0) tail[--first] = item;
        else tail.unshift(item);
        splitHead();
      }
      while (bytes > maxBytes) {
        const item = tail[first];
        if (item.bytes <= bytes - maxBytes) {
          discard();
        } else {
          const cut = boundary(item, bytes - maxBytes, true);
          if (cut.bytes === item.bytes) {
            discard();
          } else {
            advance(item, cut);
            bytes -= cut.bytes;
            omittedBytes += cut.bytes;
          }
        }
      }
      function itemCount() {
        const continuation = first < tail.length && tail[first].continuesHead;
        return head.length + tail.length - first - Number(!!continuation)
          + Number(!continuation && (omittedBytes > 0 || omittedItems > 0));
      }
      while (itemCount() > maxItems) {
        discard();
      }
      if (first >= 4096 && first * 2 >= tail.length) {
        tail = tail.slice(first);
        first = 0;
      }
    },
    collect() {
      return {
        head: head.map(item => item.text.slice(item.start)),
        tail: tail.slice(first).map(item => item.text.slice(item.start)),
        continuesHead: first < tail.length && !!tail[first].continuesHead,
        omittedBytes, omittedItems
      };
    }
  };
}
''';

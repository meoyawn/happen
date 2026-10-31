import 'dart:math';
import 'dart:typed_data';

import 'package:stemmer/stemmer.dart';

import 'stop_words.dart';
import 'unicode.dart';

final _stopWords = englishStopWords.map(normalizeSearchText).toSet();

/// bm25 2.3.2's fixed English tokenizer, after ASCII transliteration. Keeping
/// identifier underscores and internal word punctuation follows Unicode words;
/// camel-case splitting and exact-name boosts are not part of Codex search.
List<String> searchTokens(String source) {
  final text = normalizeSearchText(source).toLowerCase(), result = <String>[];
  bool letter(int index) => index >= 0 && index < text.length &&
    text.codeUnitAt(index) >= 97 && text.codeUnitAt(index) <= 122;
  bool number(int index) => index >= 0 && index < text.length &&
    text.codeUnitAt(index) >= 48 && text.codeUnitAt(index) <= 57;
  bool word(int index) => index < text.length && (letter(index) || number(index) || text[index] == '_');
  for (var index = 0; index < text.length;) {
    if (!word(index)) { index++; continue; }
    final start = index++;
    var alphanumeric = letter(start) || number(start);
    while (index < text.length) {
      if (word(index)) { alphanumeric |= letter(index) || number(index); index++; continue; }
      if ((letter(index - 1) && letter(index + 1) && "'.:".contains(text[index])) ||
        (number(index - 1) && number(index + 1) && "'.,;".contains(text[index]))) { index++; continue; }
      break;
    }
    final token = text.substring(start, index);
    if (alphanumeric && !_stopWords.contains(token)) result.add(SnowballStemmer().stem(token));
  }
  return result;
}

// bm25's default embedding space uses fxhash::hash32 over the Rust string hash.
int _hash(String token) {
  var hash = 0;
  void add(int word) { hash = ((((hash << 5) | (hash >> 27)) & 0xffffffff) ^ word) * 0x27220a95 & 0xffffffff; }
  var offset = 0;
  while (offset + 4 <= token.length) {
    add(token.codeUnitAt(offset) | token.codeUnitAt(offset + 1) << 8 |
      token.codeUnitAt(offset + 2) << 16 | token.codeUnitAt(offset + 3) << 24);
    offset += 4;
  }
  while (offset < token.length) { add(token.codeUnitAt(offset++)); }
  add(255);
  return hash;
}

class BM25Index {
  BM25Index(List<String> documents) {
    final corpus = documents.map(searchTokens).toList();
    final average = _f32(corpus.isEmpty ? 256 : corpus.fold<int>(0, (sum, doc) => sum + doc.length) / corpus.length);
    final avgdl = average <= 0 ? 256.0 : average, k1 = _f32(1.2), b = _f32(0.75);
    for (final tokens in corpus) {
      final counts = <int, int>{};
      for (final token in tokens) { counts.update(_hash(token), (count) => count + 1, ifAbsent: () => 1); }
      final weights = <int, double>{};
      for (final entry in counts.entries) {
        final frequency = _f32(entry.value.toDouble());
        final numerator = _f32(frequency * _f32(k1 + 1));
        final denominator = _f32(frequency + _f32(k1 * _f32(_f32(1 - b) + _f32(b * _f32(tokens.length / avgdl)))));
        weights[entry.key] = _f32(numerator / denominator);
        _frequencies.update(entry.key, (count) => count + 1, ifAbsent: () => 1);
      }
      _documents.add(weights);
    }
  }
  final _documents = <Map<int, double>>[];
  final _frequencies = <int, int>{};
  final _float = Float32List(1);
  double _f32(double value) { _float[0] = value; return _float[0]; }

  List<({int index, double score})> search(String query, int limit) {
    final tokens = searchTokens(query).map(_hash).toList();
    final scores = <({int index, double score})>[];
    for (var index = 0; index < _documents.length; index++) {
      var score = 0.0;
      for (final token in tokens) {
        final frequency = _frequencies[token] ?? 0;
        final idf = _f32(log(_f32(1 + _f32(_f32(_documents.length - frequency + 0.5) / _f32(frequency + 0.5)))));
        score = _f32(score + _f32(idf * (_documents[index][token] ?? 0)));
      }
      if (score > 0) scores.add((index: index, score: score));
    }
    // Upstream has unspecified ordering for equal scores. Registration order
    // makes those ties reproducible without changing the ranking weights.
    scores.sort((a, b) => a.score != b.score ? b.score.compareTo(a.score) : a.index.compareTo(b.index));
    return scores.take(limit).toList();
  }
}

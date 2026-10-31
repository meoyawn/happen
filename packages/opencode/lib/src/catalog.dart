import 'dart:convert';

import 'package:protocol/protocol.dart';

import 'catalog_data.dart';
import 'instructions.dart';

const deepseekCatalogRevision = 'ce7073d51254c26cd63b22a60835b8f948deb447';
const supportedDeepSeekModel = 'deepseek-flash';
const openCodeDeepSeekModel = 'deepseek-v4.1-flash-free';
const openCodeCatalogRevision = 'fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e';

final _catalog = {
  for (final value
      in (jsonObject(jsonDecode(modelCatalogJson))['models'] as List))
    (value as Map)['id'] as String: jsonObject(value),
};

Json deepseekModel(String model) {
  // OpenCode's pinned models-dev snapshot has separate gateway limits.
  if (model == openCodeDeepSeekModel) {
    return const {
      'id': openCodeDeepSeekModel,
      'name': 'DeepSeek V4.1 Flash Free',
      'contextWindow': 200000,
      'maxOutputTokens': 32000,
    };
  }
  if (model != supportedDeepSeekModel) {
    throw ArgumentError('Supported DeepSeek model: $supportedDeepSeekModel');
  }
  return Map.unmodifiable(_catalog[model]!);
}

String deepseekInstructions(String model) {
  deepseekModel(model);
  return openCodeInstructions;
}

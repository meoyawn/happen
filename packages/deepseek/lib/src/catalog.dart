import 'dart:convert';

import 'package:protocol/protocol.dart';

import 'catalog_data.dart';

const deepseekCatalogRevision = 'ce7073d51254c26cd63b22a60835b8f948deb447';
const supportedDeepSeekModel = 'deepseek-flash';

final _catalog = {
  for (final value
      in (jsonObject(jsonDecode(modelCatalogJson))['models'] as List))
    (value as Map)['id'] as String: jsonObject(value),
};

Json deepseekModel(String model) {
  if (model != supportedDeepSeekModel) {
    throw ArgumentError('Supported DeepSeek model: $supportedDeepSeekModel');
  }
  return Map.unmodifiable(_catalog[model]!);
}

String deepseekInstructions(String model) {
  deepseekModel(model);
  return 'You are a coding agent powered by the $model model.';
}

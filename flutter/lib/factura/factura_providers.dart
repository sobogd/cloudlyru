import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'factura_api.dart';

/// Клиент фактурного API, собранный поверх текущего облачного клиента.
///
/// Зависит от `appStateProvider` намеренно: при смене сервера или выходе из аккаунта облачный
/// клиент пересоздаётся, и раздел фактур обязан ходить новым адресом с новой сессией. `watch`
/// здесь — реакция на эти события, а не на каждый кадр: `AppState` уведомляет слушателей только
/// при входе, выходе и смене адреса.
///
/// Отдельный файл, а не провайдер в экране списка: раздел фактур — это несколько экранов
/// (фактуры, расходы, декларации, справочники), и клиент нужен им всем.
final facturaApiProvider = Provider<FacturaApi>((ref) {
  final state = ref.watch(appStateProvider);
  return FacturaApi(state.api);
});

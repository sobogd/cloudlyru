import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'app_state.dart';
import 'storage/settings.dart';

final settingsProvider = Provider<Settings>((ref) => throw UnimplementedError());

final appStateProvider = ChangeNotifierProvider<AppState>(
  (ref) => AppState(ref.read(settingsProvider)),
);

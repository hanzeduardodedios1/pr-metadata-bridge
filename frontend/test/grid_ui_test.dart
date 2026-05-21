import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Mock photo paths for an 8-item grid (no disk I/O).
final List<String> _mockPhotoPaths = List.generate(
  8,
  (i) => p.normalize('/mock/session/photo_${i.toString().padLeft(2, '0')}.jpg'),
);

Future<void> simulateKeyDownEvent(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(key);
}

Future<void> simulateKeyUpEvent(
  WidgetTester tester,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyUpEvent(key);
}

HomePageState _homeState(WidgetTester tester) {
  return tester.state<HomePageState>(find.byType(HomePage));
}

Future<void> _pumpPhotoGrid(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final backendHost = BackendHostController();

  await tester.pumpWidget(
    MaterialApp(
      home: HomePage(
        backendHost: backendHost,
        initialPhotoPaths: _mockPhotoPaths,
        initialLicenseValid: true,
      ),
    ),
  );

  await tester.pump();
}

Future<void> _tapPhotoAtIndex(WidgetTester tester, int index) async {
  final fileName = p.basename(_mockPhotoPaths[index]);
  await tester.tap(find.text(fileName));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('V1.1 grid selection (selectedPhotos)', () {
    testWidgets('plain tap sets anchor and clears selectedPhotos', (
      tester,
    ) async {
      await _pumpPhotoGrid(tester);

      await _tapPhotoAtIndex(tester, 0);

      final state = _homeState(tester);
      expect(state.anchorPath, _mockPhotoPaths[0]);
      expect(state.selectedPhotos, isEmpty);
    });

    testWidgets('ctrl-click adds photo to selectedPhotos', (tester) async {
      await _pumpPhotoGrid(tester);

      await _tapPhotoAtIndex(tester, 0);

      await simulateKeyDownEvent(tester, LogicalKeyboardKey.controlLeft);
      await _tapPhotoAtIndex(tester, 2);
      await simulateKeyUpEvent(tester, LogicalKeyboardKey.controlLeft);

      final selectedPhotos = _homeState(tester).selectedPhotos;
      expect(selectedPhotos, contains(_mockPhotoPaths[2]));
      expect(selectedPhotos.length, 1);
    });

    testWidgets('shift-click selects range from anchor index', (tester) async {
      await _pumpPhotoGrid(tester);

      await _tapPhotoAtIndex(tester, 0);

      await simulateKeyDownEvent(tester, LogicalKeyboardKey.shiftLeft);
      await _tapPhotoAtIndex(tester, 5);
      await simulateKeyUpEvent(tester, LogicalKeyboardKey.shiftLeft);

      final selectedPhotos = _homeState(tester).selectedPhotos;
      expect(selectedPhotos.length, 6);
      for (var i = 0; i <= 5; i++) {
        expect(selectedPhotos, contains(_mockPhotoPaths[i]));
      }
      expect(selectedPhotos, isNot(contains(_mockPhotoPaths[6])));
      expect(selectedPhotos, isNot(contains(_mockPhotoPaths[7])));
    });
  });
}

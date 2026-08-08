import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicat/app.dart';

void main() {
  testWidgets('renders the Phase 0 placeholder home screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: MusicatApp()));

    expect(find.text('Musicat'), findsOneWidget);
    expect(find.text('Phase 0 — scaffold running.'), findsOneWidget);
  });
}

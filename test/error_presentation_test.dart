import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:obtainium/components/ui_widgets.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/settings_provider.dart';
import 'package:provider/provider.dart';

void main() {
  test('repeated errors retain every app in the aggregate', () {
    final errors = MultiAppMultiError();
    errors.add('one', StateError('offline'));
    errors.add('two', StateError('offline'));
    expect(errors.idsByErrorString.values.single, ['one', 'two']);
    expect(errors.toString(), contains('offline'));
  });

  testWidgets(
    'unexpected errors leave controls usable; details can be closed',
    (tester) async {
      var presses = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () =>
                          showMessage(StateError('test failure'), context),
                      child: const Text('Fail'),
                    ),
                    TextButton(
                      onPressed: () => presses++,
                      child: const Text('Action'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Fail'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Action'));
      expect(presses, 1);
      await tester.tap(find.text('errorDetails'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('ok'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mms_project/main.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

void main() {
  const ttsChannel = MethodChannel('flutter_tts');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (_) async => 1);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
  });

  testWidgets('lists recipes and opens the dedicated cooking page', (
    tester,
  ) async {
    late KitchenController kitchen;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) =>
            kitchen = KitchenController(sounds: FakeSoundEffects())
              ..loadRecipes(),
        child: const KitchenApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Küchenstimme'), findsOneWidget);
    expect(find.text('Was kochen wir?'), findsOneWidget);
    expect(find.text('Cremige Tomatenpasta'), findsOneWidget);
    expect(find.text('Buntes Ofengemüse'), findsOneWidget);
    expect(find.text('Apfelpfannkuchen'), findsOneWidget);
    expect(find.byTooltip('Rezept per Sprache auswählen'), findsOneWidget);
    expect(find.byTooltip('Hilfe und Sprachbefehle'), findsOneWidget);

    await tester.tap(find.byTooltip('Hilfe und Sprachbefehle'));
    await tester.pumpAndSettle();
    expect(find.text('Hilfe und Sprachbefehle'), findsOneWidget);
    expect(find.text('Rezept auswählen'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Timer fünf Minuten'),
      250,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Timer fünf Minuten'), findsOneWidget);
    await tester.tap(find.byTooltip('Zurück'));
    await tester.pumpAndSettle();
    expect(find.text('Was kochen wir?'), findsOneWidget);

    expect(await kitchen.selectRecipeFromSpeech('Rezept zwei', 0.9), isTrue);
    expect(kitchen.recipe?.name, 'Buntes Ofengemüse');
    expect(kitchen.isPaused, isTrue);
    expect(
      await kitchen.selectRecipeFromSpeech('Cremige Tomatenpasta', 0.9),
      isTrue,
    );

    await tester.tap(find.text('Cremige Tomatenpasta'));
    await tester.pumpAndSettle();

    expect(find.text('SCHRITT 1'), findsOneWidget);
    expect(
      find.text('Sag „Weiter“ oder tippe auf Start, wenn du bereit bist.'),
      findsOneWidget,
    );
    expect(find.text('Mikrofon aus'), findsOneWidget);
    expect(find.byTooltip('Zur Rezeptliste'), findsOneWidget);
    expect(find.byTooltip('Vorheriger Schritt'), findsOneWidget);
    expect(find.byTooltip('Anleitung starten'), findsOneWidget);
    expect(find.byTooltip('Nächster Schritt'), findsOneWidget);
    expect(find.byTooltip('Schritt wiederholen'), findsOneWidget);
    expect(find.byTooltip('Timer einstellen'), findsOneWidget);
    expect(find.byTooltip('Zutaten anzeigen'), findsOneWidget);
    expect(find.byTooltip('Sprachbefehl geben'), findsOneWidget);

    await tester.tap(find.byTooltip('Timer einstellen'));
    await tester.pumpAndSettle();
    expect(find.text('Timer einstellen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Abbrechen'));
    await tester.pumpAndSettle();
    expect(kitchen.timerSeconds, 0);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Timer einstellen'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '5');
    await tester.tap(find.byTooltip('Timer starten'));
    await tester.pump();
    expect(kitchen.timerSeconds, 300);
    expect(find.text('05:00'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Zur Rezeptliste'));
    await tester.pumpAndSettle();
    expect(find.text('Was kochen wir?'), findsOneWidget);
    expect(find.text(KitchenController.homeHint), findsOneWidget);
    expect(find.text('Küchentimer'), findsOneWidget);
  });
}

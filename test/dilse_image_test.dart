import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/widgets/dilse_image.dart';

void main() {
  group('DilSeImage Widget Tests', () {
    testWidgets('renders fallback placeholder icon when imageUrl is empty', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: DilSeImage(imageUrl: '', width: 60, height: 60)),
        ),
      );

      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });

    testWidgets(
      'renders custom error widget when provided and imageUrl is empty',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: DilSeImage(
                imageUrl: '',
                width: 60,
                height: 60,
                errorWidget: Text('CUSTOM_ERROR'),
              ),
            ),
          ),
        );

        expect(find.text('CUSTOM_ERROR'), findsOneWidget);
      },
    );

    testWidgets('applies borderRadius with ClipRRect when specified', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DilSeImage(
              imageUrl: '',
              width: 80,
              height: 80,
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
          ),
        ),
      );

      final clipRRect = tester.widget<ClipRRect>(find.byType(ClipRRect));
      expect(
        clipRRect.borderRadius,
        equals(const BorderRadius.all(Radius.circular(16))),
      );
    });
  });
}

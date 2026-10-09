import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_app/screens/artist_profile_screen.dart';
import 'package:music_app/screens/library_screen.dart';
import 'package:music_app/services/dynamic_artist_service.dart';
import 'package:music_app/services/preferences_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService().init();
  });

  const testArtist = ArtistItem(
    name: 'Devi Sri Prasad',
    genre: 'Tollywood • High Energy Dance & Melodies',
    imageUrl: 'https://example.com/dsp.jpg',
    language: 'Telugu',
    badge: 'TOP ARTIST',
  );

  testWidgets(
    'ArtistProfileScreen renders header, buttons, search bar, and filter chips',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: ArtistProfileScreen(
            artist: testArtist,
            artistName: 'Devi Sri Prasad',
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      // Hero Header
      expect(find.text('Devi Sri Prasad'), findsWidgets);
      expect(find.text('TOP ARTIST'), findsOneWidget);
      expect(
        find.text('Tollywood • High Energy Dance & Melodies'),
        findsWidgets,
      );

      // Actions
      expect(find.textContaining('Play All'), findsOneWidget);
      expect(find.text('Shuffle'), findsOneWidget);

      // Search Bar
      expect(
        find.text("Search within Devi Sri Prasad's tracks..."),
        findsOneWidget,
      );

      // Language Chips Header & Chips
      expect(find.text('LANGUAGE'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Telugu'), findsOneWidget);

      // Movie & Era Chips Header & Chips
      expect(find.text('MOVIE & ERA RANGE'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'All Eras'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, '2020–2025'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'All Movies'), findsOneWidget);
      expect(find.text('Pushpa The Rise'), findsOneWidget);
    },
  );

  testWidgets(
    'ArtistProfileScreen selects language and movie chips interactively',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: ArtistProfileScreen(
            artist: testArtist,
            artistName: 'Devi Sri Prasad',
          ),
        ),
      );
      await tester.pump();

      // Tap Tamil chip
      final tamilChip = find.widgetWithText(ChoiceChip, 'Tamil');
      if (tamilChip.evaluate().isNotEmpty) {
        await tester.tap(tamilChip);
        await tester.pump();
        final chip = tester.widget<ChoiceChip>(tamilChip);
        expect(chip.selected, isTrue);
      }

      // Tap Pushpa movie chip
      final pushpaChip = find.text('Pushpa The Rise');
      expect(pushpaChip, findsOneWidget);
      await tester.tap(pushpaChip);
      await tester.pump();

      // 'Clear Movie' should appear in header
      expect(find.text('Clear Movie'), findsOneWidget);

      // Tap Clear Movie
      await tester.tap(find.text('Clear Movie'));
      await tester.pump();
      expect(find.text('Clear Movie'), findsNothing);
    },
  );

  testWidgets('ArtistProfileScreen live search input updates search text', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(
      const MaterialApp(
        home: ArtistProfileScreen(
          artist: testArtist,
          artistName: 'Devi Sri Prasad',
        ),
      ),
    );
    await tester.pump();

    final searchField = find.byType(TextField);
    expect(searchField, findsOneWidget);

    await tester.enterText(searchField, 'Pushpa Pushpa');
    await tester.pump();

    expect(find.text('Pushpa Pushpa'), findsOneWidget);
    expect(find.byIcon(Icons.clear_rounded), findsOneWidget);

    // Clear search
    await tester.tap(find.byIcon(Icons.clear_rounded));
    await tester.pump();
    expect(find.text('Pushpa Pushpa'), findsNothing);
  });

  testWidgets(
    'ArtistProfileScreen renders smoothly on mobile portrait (390x844)',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: ArtistProfileScreen(
            artist: testArtist,
            artistName: 'Devi Sri Prasad',
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Devi Sri Prasad'), findsWidgets);
    },
  );

  test(
    'DynamicArtistService returns rich 6-7 line curated bio and dynamic fallback',
    () {
      final service = DynamicArtistService();
      final dspBio = service.getArtistBio('Devi Sri Prasad');
      expect(dspBio, contains('National Award-winning'));
      expect(dspBio, contains('Pushpa'));
      expect(dspBio.length, greaterThan(300));

      final thamanBio = service.getArtistBio('Thaman S');
      expect(thamanBio, contains('Ala Vaikunthapurramuloo'));

      final fallbackBio = service.getArtistBio('Unknown Indie Artist');
      expect(fallbackBio, contains('Unknown Indie Artist'));
      expect(fallbackBio, contains('DilSe'));
      expect(fallbackBio.length, greaterThan(200));
    },
  );

  testWidgets(
    'ArtistProfileScreen renders About Artist section with verified badge, 6-7 line bio, and tags',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      await tester.pumpWidget(
        const MaterialApp(
          home: ArtistProfileScreen(
            artist: testArtist,
            artistName: 'Devi Sri Prasad',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Scroll down to reveal About Artist section
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pump();

      expect(find.text('ABOUT THE ARTIST'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(
        find.textContaining('National Award-winning Indian composer'),
        findsOneWidget,
      );
      expect(find.textContaining('Telugu Repertoire'), findsOneWidget);
    },
  );

  testWidgets(
    'ArtistProfileScreen follow button toggles between Follow and Followed with smooth animation and updates PreferencesService without polluting daily mixes',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final prefs = PreferencesService();
      expect(prefs.isArtistFollowed('Devi Sri Prasad'), isFalse);
      expect(prefs.followedArtists, isEmpty);

      final initialDailyMixes = prefs.getDailyMixConfigs();

      await tester.pumpWidget(
        const MaterialApp(
          home: ArtistProfileScreen(
            artist: testArtist,
            artistName: 'Devi Sri Prasad',
          ),
        ),
      );
      await tester.pump();

      // Find the squircle follow button
      final followBtn = find.byKey(
        const ValueKey('artist_profile_follow_button'),
      );
      expect(followBtn, findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Followed'), findsNothing);

      // Tap Follow
      await tester.tap(followBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300)); // Finish animation

      expect(find.text('Followed'), findsOneWidget);
      expect(find.text('Follow'), findsNothing);
      expect(prefs.isArtistFollowed('Devi Sri Prasad'), isTrue);
      expect(prefs.followedArtists, contains('Devi Sri Prasad'));

      // Strict Guardrail: Followed artist must NOT affect daily mixes
      final dailyMixesAfterFollow = prefs.getDailyMixConfigs();
      expect(dailyMixesAfterFollow.length, equals(initialDailyMixes.length));
      for (int i = 0; i < initialDailyMixes.length; i++) {
        expect(
          dailyMixesAfterFollow[i].title,
          equals(initialDailyMixes[i].title),
        );
        expect(
          dailyMixesAfterFollow[i].query,
          equals(initialDailyMixes[i].query),
        );
      }

      // Tap again to Unfollow
      await tester.tap(followBtn);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('Followed'), findsNothing);
      expect(prefs.isArtistFollowed('Devi Sri Prasad'), isFalse);
      expect(prefs.followedArtists, isEmpty);
    },
  );

  testWidgets(
    'LibraryScreen renders Artists tab and displays followed artists',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final prefs = PreferencesService();
      await prefs.toggleFollowArtist('Devi Sri Prasad');

      await tester.pumpWidget(const MaterialApp(home: LibraryScreen()));
      await tester.pump();

      // Verify Artists tab is present
      expect(find.text('Artists'), findsOneWidget);

      // Tap on Artists tab
      await tester.tap(find.text('Artists'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('1 Followed Artist'), findsOneWidget);
      expect(find.text('Devi Sri Prasad'), findsOneWidget);
      expect(find.text('Following'), findsOneWidget);
    },
  );
}

// FavoritesStore persistence and pruning tests.

import 'package:clouddock/src/features/favorites/favorites_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<bool> add(
  FavoritesStore store, {
  String accountId = 'acc-1',
  String bucket = 'b',
  String key = 'photos/a.jpg',
}) => store.toggle(
  accountId: accountId,
  accountName: 'My account',
  bucket: bucket,
  key: key,
  name: key.split('/').last,
  size: 123,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('toggle adds then removes', () async {
    final store = FavoritesStore();
    expect(await add(store), isTrue);
    expect(store.state, hasLength(1));
    expect(
      store.contains(FavoritesStore.idFor('acc-1', 'b', 'photos/a.jpg')),
      isTrue,
    );
    expect(await add(store), isFalse);
    expect(store.state, isEmpty);
  });

  test('persists and reloads from prefs', () async {
    final store = FavoritesStore();
    await add(store);
    await add(store, key: 'photos/b.jpg');

    final reloaded = FavoritesStore();
    await Future<void>.delayed(Duration.zero);
    expect(reloaded.state, hasLength(2));
    expect(reloaded.state.first.key, isNotNull);
  });

  test('prune drops entries for deleted accounts', () async {
    final store = FavoritesStore();
    await add(store, accountId: 'keep');
    await add(store, accountId: 'gone', key: 'x.txt');
    expect(store.state, hasLength(2));

    store.prune({'keep'});
    await Future<void>.delayed(Duration.zero);
    expect(store.state, hasLength(1));
    expect(store.state.single.accountId, 'keep');
  });

  test('clear empties and persists the empty list', () async {
    final store = FavoritesStore();
    await add(store);
    await store.clear();
    expect(store.state, isEmpty);

    final reloaded = FavoritesStore();
    await Future<void>.delayed(Duration.zero);
    expect(reloaded.state, isEmpty);
  });

  test('ids are account + bucket + key scoped', () {
    expect(
      FavoritesStore.idFor('a', 'b', 'c/d.txt'),
      isNot(FavoritesStore.idFor('a', 'b', 'other/d.txt')),
    );
    expect(
      FavoritesStore.idFor('a', 'b', 'c/d.txt'),
      isNot(FavoritesStore.idFor('a', 'b2', 'c/d.txt')),
    );
  });
}

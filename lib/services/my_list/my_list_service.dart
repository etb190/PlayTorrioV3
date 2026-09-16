import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/my_list/my_list_item.dart';
import '../continue_watching/continue_watching_service.dart';
import '../trakt/trakt_service.dart';
import '../simkl/simkl_service.dart';

class LastWatchedEpisode {
  final int season;
  final int episode;
  final String? episodeTitle;

  const LastWatchedEpisode({
    required this.season,
    required this.episode,
    this.episodeTitle,
  });

  String get label => 'S${season.toString().padLeft(2, '0')}:E${episode.toString().padLeft(2, '0')}';
}

abstract final class MyListService {
  static const _storageKey = 'my_list_v1';
  static const int maxItems = 500;

  static final ValueNotifier<List<MyListItem>> items = ValueNotifier<List<MyListItem>>([]);
  static final ValueNotifier<bool> isSyncing = ValueNotifier<bool>(false);
  static SharedPreferences? _prefs;

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final stored = prefs.getString(_storageKey);
    if (stored != null) {
      try {
        final list = (jsonDecode(stored) as List)
            .map((e) => MyListItem.fromJson(e as Map<String, dynamic>))
            .toList();
        items.value = list;
      } catch (_) {
        items.value = [];
      }
    }
    syncAll();
  }

  static Future<void> syncAll() async {
    if (isSyncing.value) return;
    isSyncing.value = true;
    try {
      await Future.wait([
        syncWithTrakt(),
        syncWithSimkl(),
      ]);
    } finally {
      isSyncing.value = false;
    }
  }

  static Future<void> syncWithTrakt() async {
    try {
      if (!await TraktService.instance.isAuthenticated()) return;
      final movieItems = await TraktService.instance.fetchList('watchlist', 'movies');
      final showItems = await TraktService.instance.fetchList('watchlist', 'shows');

      final combined = [...movieItems, ...showItems];
      if (combined.isEmpty) return;

      final current = List<MyListItem>.from(items.value);
      for (final raw in combined) {
        if (raw is! Map<String, dynamic>) continue;
        final item = MyListItem.fromTraktJson(raw);
        final idx = current.indexWhere((i) => i.uniqueKey == item.uniqueKey || i.matches(item));
        if (idx == -1) {
          current.insert(0, item);
        } else {
          current[idx] = current[idx].mergeWith(item);
        }
      }
      current.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      items.value = current.take(maxItems).toList();
      await _persist();
    } catch (e) {
      debugPrint('MyListService: Trakt sync error: $e');
    }
  }

  static Future<void> syncWithSimkl() async {
    try {
      if (!await SimklService.instance.isAuthenticated()) return;
      final lib = await SimklService.instance.fetchLibrarySnapshotOrNull();
      if (lib == null) return;

      final current = List<MyListItem>.from(items.value);
      for (final bucket in ['movies', 'shows', 'anime']) {
        final list = lib[bucket];
        if (list is! List) continue;
        for (final raw in list) {
          if (raw is! Map<String, dynamic>) continue;
          final status = raw['status'];
          if (status == 'plantowatch' || status == 'watching') {
            final item = MyListItem.fromSimklJson(raw);
            final idx = current.indexWhere((i) => i.uniqueKey == item.uniqueKey || i.matches(item));
            if (idx == -1) {
              current.insert(0, item);
            } else {
              current[idx] = current[idx].mergeWith(item);
            }
          }
        }
      }
      current.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      items.value = current.take(maxItems).toList();
      await _persist();
    } catch (e) {
      debugPrint('MyListService: Simkl sync error: $e');
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(items.value.map((e) => e.toJson()).toList());
    await prefs.setString(_storageKey, data);
  }

  static bool isInList(MyListItem item) {
    return items.value.any((i) => i.uniqueKey == item.uniqueKey || i.matches(item));
  }

  static void add(MyListItem item) {
    if (isInList(item)) return;

    final newList = <MyListItem>[...items.value, item];
    newList.sort((a, b) => b.addedAt.compareTo(a.addedAt));

    if (newList.length > maxItems) {
      newList.removeRange(maxItems, newList.length);
    }

    items.value = newList;
    _persist();

    // Push to cloud services if logged in
    _syncCloudAdd(item);
  }

  static void _syncCloudAdd(MyListItem item) async {
    final imdb = item.imdbId;
    final tmdb = item.tmdbId;
    final trakt = item.traktId;
    final simkl = item.simklId;

    if (await TraktService.instance.isAuthenticated()) {
      TraktService.instance.addToWatchlist(
        imdb ?? '',
        item.type,
        tmdbId: tmdb,
        traktId: trakt,
      );
    }
    if (await SimklService.instance.isAuthenticated()) {
      SimklService.instance.addToList(
        imdb ?? '',
        item.type,
        'plantowatch',
        tmdbId: tmdb,
        simklId: simkl,
      );
    }
  }

  static void remove(MyListItem item) {
    items.value = items.value.where((i) => i.uniqueKey != item.uniqueKey && !i.matches(item)).toList();
    _persist();

    _syncCloudRemove(item);
  }

  static void _syncCloudRemove(MyListItem item) async {
    final imdb = item.imdbId;
    final tmdb = item.tmdbId;
    final trakt = item.traktId;
    final simkl = item.simklId;

    if (await TraktService.instance.isAuthenticated()) {
      TraktService.instance.removeFromWatchlist(
        imdb ?? '',
        item.type,
        tmdbId: tmdb,
        traktId: trakt,
      );
    }
    if (await SimklService.instance.isAuthenticated()) {
      SimklService.instance.addToList(
        imdb ?? '',
        item.type,
        'dropped',
        tmdbId: tmdb,
        simklId: simkl,
      );
    }
  }

  static void toggle(MyListItem item) {
    if (isInList(item)) {
      remove(item);
    } else {
      add(item);
    }
  }

  /// Retrieves the last watched season and episode for a TV show item in My List.
  static LastWatchedEpisode? getLastWatchedEpisode(MyListItem item) {
    if (item.type != 'series' && item.type != 'anime' && item.type != 'tv') {
      return null;
    }

    final cleanItemTitle = item.title.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();

    // 1. Check in-memory active Continue Watching sessions
    for (final cw in ContinueWatchingService.activeItems.value) {
      if (cw.type == 'movie') continue;
      final cleanCwTitle = cw.title.toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '').trim();

      final matchesId = (item.imdbId != null && item.imdbId!.isNotEmpty && cw.id == item.imdbId) ||
          (item.tmdbId != null && (cw.id == 'tmdb:${item.tmdbId}' || cw.id == '${item.tmdbId}')) ||
          (item.traktId != null && cw.id == '${item.traktId}') ||
          (item.simklId != null && cw.id == '${item.simklId}');

      final matchesTitle = cleanItemTitle.isNotEmpty && cleanCwTitle.isNotEmpty && cleanItemTitle == cleanCwTitle;

      if ((matchesId || matchesTitle) && cw.season != null && cw.episode != null) {
        return LastWatchedEpisode(
          season: cw.season!,
          episode: cw.episode!,
          episodeTitle: cw.episodeTitle,
        );
      }
    }

    // 2. Fall back to persisted SharedPreferences keys
    if (_prefs == null) {
      SharedPreferences.getInstance().then((p) => _prefs = p);
    }

    if (_prefs != null) {
      final candidateKeys = <String>{
        if (item.imdbId != null && item.imdbId!.isNotEmpty) item.imdbId!,
        if (item.tmdbId != null) ...['tmdb:${item.tmdbId}', '${item.tmdbId}'],
        if (item.traktId != null) '${item.traktId}',
        if (item.simklId != null) '${item.simklId}',
        if (cleanItemTitle.isNotEmpty) cleanItemTitle,
      };

      for (final key in candidateKeys) {
        final s = _prefs!.getInt('last_watched_season_$key');
        final e = _prefs!.getInt('last_watched_episode_$key');
        if (s != null && e != null) {
          final epId = _prefs!.getString('last_watched_episode_id_$key');
          return LastWatchedEpisode(season: s, episode: e, episodeTitle: epId);
        }
      }
    }

    return null;
  }
}

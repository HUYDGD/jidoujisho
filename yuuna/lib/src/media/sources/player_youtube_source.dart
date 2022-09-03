import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:infinite_scroll_pagination/infinite_scroll_pagination.dart';
import 'package:material_floating_search_bar/material_floating_search_bar.dart';
import 'package:subtitle/subtitle.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:yuuna/language.dart';
import 'package:yuuna/media.dart';
import 'package:yuuna/models.dart';
import 'package:yuuna/pages.dart';
import 'package:yuuna/utils.dart';

/// A media source that allows the user to stream a selected video from YouTube.
class PlayerYoutubeSource extends PlayerMediaSource {
  /// Define this media source.
  PlayerYoutubeSource._privateConstructor()
      : super(
          uniqueKey: 'player_youtube',
          sourceName: 'YouTube',
          description: 'Select and watch videos from YouTube.',
          icon: Icons.smart_display,
          implementsSearch: true,
          implementsHistory: true,
        );

  /// Get the singleton instance of this media type.
  static PlayerYoutubeSource get instance => _instance;

  static final PlayerYoutubeSource _instance =
      PlayerYoutubeSource._privateConstructor();

  /// HTTP client for search queries.
  final YoutubeHttpClient _client = YoutubeHttpClient();

  late final SearchClient _searchClient;
  late final VideoClient _videoClient;
  late final PlaylistClient _playlistClient;

  final Map<String, Video> _videoCache = <String, Video>{};
  final Map<String, StreamManifest> _streamManifestCache =
      <String, StreamManifest>{};
  final Map<String, Map<int, VideoSearchList>> _searchListCache =
      <String, Map<int, VideoSearchList>>{};
  final Map<String, ClosedCaptionManifest> _closedCaptionManifestCache =
      <String, ClosedCaptionManifest>{};

  @override
  Future<void> prepareResources() async {
    _searchClient = SearchClient(_client);
    _videoClient = VideoClient(_client);
    _playlistClient = PlaylistClient(_client);
  }

  @override
  BaseMediaSearchBar? buildBar() {
    return const YoutubeMediaSearchBar();
  }

  @override
  BaseSourcePage buildLaunchPage({MediaItem? item}) {
    return PlayerSourcePage(
      item: item,
      source: this,
      useHistory: true,
    );
  }

  @override
  List<Widget> getActions({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    return [
      buildTrendingButton(
        context: context,
        ref: ref,
        appModel: appModel,
      ),
      buildCaptionFilterButton(
        context: context,
        ref: ref,
        appModel: appModel,
      ),
    ];
  }

  /// Allows user to launch trending playlists page.
  Widget buildTrendingButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    String trendingLabel = appModel.translate('trending');

    return FloatingSearchBarAction(
      child: JidoujishoIconButton(
        size: Theme.of(context).textTheme.titleLarge?.fontSize,
        tooltip: trendingLabel,
        icon: Icons.whatshot,
        onTap: () => showTrendingVideos(
          context: context,
          appModel: appModel,
        ),
      ),
    );
  }

  /// Allows user to toggle whether or not to filter for videos with
  /// closed captions.
  Widget buildCaptionFilterButton({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
  }) {
    String trendingLabel = appModel.translate('caption_filter');

    ValueNotifier<bool> notifier = ValueNotifier<bool>(isCaptionFilterOn);

    return FloatingSearchBarAction(
      showIfOpened: true,
      showIfClosed: false,
      child: ValueListenableBuilder<bool>(
        valueListenable: notifier,
        builder: (context, value, child) {
          return JidoujishoIconButton(
            size: Theme.of(context).textTheme.titleLarge?.fontSize,
            tooltip: trendingLabel,
            enabledColor: value ? Colors.red : null,
            icon: Icons.closed_caption,
            onTap: () {
              toggleCaptionFilter();
              notifier.value = !value;
            },
          );
        },
      ),
    );
  }

  @override
  Future<List<MediaItem>?> searchMediaItems({
    required BuildContext context,
    required String searchTerm,
    required int pageKey,
  }) async {
    late VideoSearchList? searchList;

    searchTerm = searchTerm.trim();

    String storeKey = searchTerm;
    if (isCaptionFilterOn) {
      storeKey = '$searchTerm [filter:cc]';
    }

    Map<int, VideoSearchList>? store = _searchListCache[storeKey];
    store ??= {};

    if (pageKey == 1) {
      if (store[1] == null) {
        searchList = await _searchClient.search(searchTerm,
            filter: isCaptionFilterOn
                ? FeatureFilters.subTitles
                : TypeFilters.video);
      } else {
        searchList = store[1];
      }
    } else {
      VideoSearchList lastList = store[pageKey - 1]!;
      searchList = await lastList.nextPage();
    }

    if (searchList == null) {
      return null;
    } else {
      store[pageKey] = searchList;
    }

    List<MediaItem> items = [];
    List<Video> videos = [];

    for (Video video in searchList) {
      if (video.duration == null || video.duration == Duration.zero) {
        continue;
      }

      videos.add(video);
      _videoCache[video.url] = video;
      items.add(getMediaItem(video));
    }

    return items;
  }

  @override
  Future<List<String>> generateSearchSuggestions(String searchTerm) async {
    return _searchClient.getQuerySuggestions(searchTerm);
  }

  /// Creates a media item from a YouTube [Video] entity.
  MediaItem getMediaItem(Video video) {
    return MediaItem(
      title: video.title,
      mediaIdentifier: video.url,
      mediaSourceIdentifier: uniqueKey,
      mediaTypeIdentifier: mediaType.uniqueKey,
      position: 0,
      duration: video.duration?.inSeconds ?? 0,
      canDelete: true,
      canEdit: false,
      imageUrl: video.thumbnails.mediumResUrl,
      author: video.author,
      authorIdentifier: video.channelId.value,
    );
  }

  @override
  Future<VlcPlayerController> preparePlayerController({
    required AppModel appModel,
    required WidgetRef ref,
    required MediaItem item,
  }) async {
    String dataSource = await getDataSource(item);
    String audioUrl = await getAudioUrl(item);

    int startTime = item.position;

    List<String> advancedParams = ['--start-time=$startTime'];
    List<String> audioParams = [
      '--input-slave=$audioUrl',
      '--sub-track=99999',
    ];

    return VlcPlayerController.network(
      dataSource,
      options: VlcPlayerOptions(
        advanced: VlcAdvancedOptions(advancedParams),
        audio: VlcAudioOptions(audioParams),
      ),
    );
  }

  /// Gets the [StreamManifest] if in cache and fetches it
  /// and stores it if otherwise.
  Future<StreamManifest> getStreamManifest(MediaItem item) async {
    String videoId = VideoId(item.mediaIdentifier).value;
    StreamManifest? manifest = _streamManifestCache[videoId];
    if (manifest == null) {
      manifest = await _videoClient.streams.getManifest(videoId);
      _streamManifestCache[videoId] ??= manifest;
    }

    return manifest;
  }

  /// Gets the [ClosedCaptionManifest] if in cache and fetches it
  /// and stores it if otherwise.
  Future<ClosedCaptionManifest> getClosedCaptionManifest(MediaItem item) async {
    String videoId = VideoId(item.mediaIdentifier).value;
    ClosedCaptionManifest? manifest = _closedCaptionManifestCache[videoId];
    if (manifest == null) {
      manifest = await _videoClient.closedCaptions.getManifest(
        videoId,
        formats: [ClosedCaptionFormat.vtt],
      );
      _closedCaptionManifestCache[videoId] ??= manifest;
    }

    return manifest;
  }

  @override
  Future<List<SubtitleItem>> prepareSubtitles({
    required AppModel appModel,
    required WidgetRef ref,
    required MediaItem item,
  }) async {
    ClosedCaptionManifest manifest = await getClosedCaptionManifest(item);

    List<String> languageCodes = [];
    List<SubtitleItem> items = [];

    for (ClosedCaptionTrackInfo trackInfo in manifest.tracks) {
      String languageCode = trackInfo.language.code;
      if (languageCodes.contains(languageCode) || trackInfo.isAutoGenerated) {
        // lol
        continue;
      }

      String vtt = await _videoClient.closedCaptions.getSubTitles(trackInfo);
      languageCodes.add(languageCode);
      items.add(
        SubtitleItem(
          controller: SubtitleController(
            provider: SubtitleProvider.fromString(
              data: vtt,
              type: SubtitleType.vtt,
            ),
          ),
          metadata: 'YouTube - [$languageCode]',
          type: SubtitleItemType.webSubtitle,
        ),
      );
    }

    SubtitleItem priorityItem;
    int priorityIndex =
        languageCodes.indexOf(appModel.targetLanguage.languageCode);

    if (priorityIndex != -1) {
      priorityItem = items[priorityIndex];
      items.remove(priorityItem);
      List<SubtitleItem> newItems = [];
      newItems.add(priorityItem);
      newItems.addAll(items);
      items = newItems;
    }

    return items;
  }

  /// Gets the network URL for a certain video quality.
  String getVideoUrlForQuality({
    required StreamManifest manifest,
    required VideoQuality preferredQuality,
  }) {
    for (VideoStreamInfo streamInfo in manifest.video) {
      if (!streamInfo.videoCodec.contains('avc1')) {
        continue;
      }

      VideoQuality? quality = streamInfo.videoQuality;

      if (quality == preferredQuality) {
        return streamInfo.url.toString();
      }
    }

    throw Exception('Preferred quality not found');
  }

  /// Used to get the data source to use as the video URL.
  Future<String> getDataSource(MediaItem item) async {
    StreamManifest manifest = await getStreamManifest(item);

    List<VideoQuality> qualities = getVideoQualities(manifest);
    VideoQuality currentQuality = preferredQuality;
    while (!qualities.contains(currentQuality)) {
      if (currentQuality.index == 0) {
        return manifest.video.first.url.toString();
      }
      VideoQuality fallbackQuality =
          VideoQuality.values[currentQuality.index - 1];
      currentQuality = fallbackQuality;
    }

    return getVideoUrlForQuality(
      manifest: manifest,
      preferredQuality: currentQuality,
    );
  }

  /// Used to get the audio source for a video.
  Future<String> getAudioUrl(MediaItem item) async {
    StreamManifest manifest = await getStreamManifest(item);

    AudioStreamInfo streamAudioInfo = manifest.audioOnly
        .sortByBitrate()
        .lastWhere((info) => info.audioCodec.contains('mp4a'));
    return streamAudioInfo.url.toString();
  }

  /// Gets the video qualities available for a [StreamManifest].
  List<VideoQuality> getVideoQualities(StreamManifest manifest) {
    List<VideoQuality> qualities = [];

    for (VideoStreamInfo streamInfo in manifest.video) {
      if (!streamInfo.videoCodec.contains('avc1')) {
        continue;
      }

      qualities.add(streamInfo.videoQuality);
    }

    qualities = qualities.toSet().toList();
    qualities.sort((a, b) => a.index.compareTo(b.index));
    return qualities;
  }

  /// Add your target language country under this Trending 20 playlist support.
  String? getTrendingPlaylistId(Language language) {
    switch ('${language.languageCode}-${language.countryCode}') {
      case 'ja-JP': // Japanese (Japan)
        return 'PLuXL6NS58Dyx-wTr5o7NiC7CZRbMA91DC';
      default:
        return null;
    }
  }

  /// Get the preferred quality.
  VideoQuality get preferredQuality {
    int index = getPreference<int>(
        key: 'preferred_quality', defaultValue: VideoQuality.medium480.index);
    return VideoQuality.values[index];
  }

  /// Set the preferred quality.
  void setPreferredQuality(VideoQuality quality) async {
    setPreference<int>(key: 'preferred_quality', value: quality.index);
  }

  /// Get the caption filter on the history page.
  bool get isCaptionFilterOn {
    return getPreference<bool>(key: 'caption_filter', defaultValue: false);
  }

  /// Toggle the caption filter on the history page.
  void toggleCaptionFilter() async {
    setPreference<bool>(key: 'caption_filter', value: !isCaptionFilterOn);
  }

  @override
  String getDisplaySubtitleFromMediaItem(MediaItem item) {
    return item.author ?? '';
  }

  /// Launch a trending videos page.
  Future<void> showTrendingVideos({
    required AppModel appModel,
    required BuildContext context,
  }) async {
    String playlistId = getTrendingPlaylistId(appModel.targetLanguage)!;
    Playlist trendingPlaylist = await _playlistClient.get(playlistId);

    PagingController<int, MediaItem> pagingController =
        PagingController(firstPageKey: 1);

    pagingController.addPageRequestListener((pageKey) async {
      List<MediaItem> items = [];
      List<Video> videos = [];

      try {
        videos = await _playlistClient.getVideos(playlistId).toList();
        for (Video video in videos) {
          items.add(getMediaItem(video));
        }
      } finally {
        pagingController.appendLastPage(items);
      }
    });

    // Prevent recursion
    Navigator.of(context).popUntil((route) => route.isFirst);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => VideoResultsPage(
          showAppBar: true,
          title: trendingPlaylist.title,
          pagingController: pagingController,
        ),
      ),
    );
  }
}

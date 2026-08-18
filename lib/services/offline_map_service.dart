import 'dart:async';
import 'dart:math';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'location_fallback_service.dart';

class OfflineMapService extends GetxController {
  static OfflineMapService instanceOrCreate() {
    if (Get.isRegistered<OfflineMapService>()) {
      return Get.find<OfflineMapService>();
    }
    return Get.put(OfflineMapService(), permanent: true);
  }

  static const String storeName = 'safe_route_offline_store';
  static const String _lastAutoDownloadPrefsKey = 'last_auto_download_timestamp';
  static const String _allowMobileDataPrefsKey = 'allow_mobile_data_auto_download';
  static const double maxStorageCapMB = 300.0; // 300MB storage cap for auto downloads

  final RxBool isOffline = false.obs;
  final RxBool isAutoDownloading = false.obs;
  final RxBool isManualDownloading = false.obs;
  final RxDouble downloadProgress = 0.0.obs;
  final RxInt downloadedTilesCount = 0.obs;
  final RxInt totalTilesToDownload = 0.obs;
  final RxBool allowMobileDataAutoDownload = false.obs;
  final Rxn<LatLng> lastCachedRegionCentroid = Rxn<LatLng>();
  final RxString offlineLocationLabel = ''.obs;

  late final FMTCStore store;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  @override
  void onInit() {
    super.onInit();
    store = FMTCStore(storeName);
    _loadSettings();
    _initConnectivityListener();
  }

  @override
  void onClose() {
    _connectivitySub?.cancel();
    super.onClose();
  }

  /// Task 1: Initializes SQLite ObjectBox store persistently across app restarts
  static Future<void> initializeStore() async {
    try {
      await FMTCObjectBoxBackend().initialise();
      final store = FMTCStore(storeName);
      final isReady = await store.manage.ready;
      if (!isReady) {
        await store.manage.create();
      }
      debugPrint('[OfflineMapService] FMTC Tile Store initialized successfully.');
    } catch (e) {
      debugPrint('[OfflineMapService] Store initialization error / already initialized: $e');
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    allowMobileDataAutoDownload.value = prefs.getBool(_allowMobileDataPrefsKey) ?? false;
    final cachedLat = prefs.getDouble('last_cached_centroid_lat');
    final cachedLng = prefs.getDouble('last_cached_centroid_lng');
    if (cachedLat != null && cachedLng != null) {
      lastCachedRegionCentroid.value = LatLng(cachedLat, cachedLng);
    }
  }

  Future<void> toggleMobileDataAutoDownload(bool value) async {
    allowMobileDataAutoDownload.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowMobileDataPrefsKey, value);
  }

  /// Task 4: Listens to network connectivity state changes via connectivity_plus
  void _initConnectivityListener() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final hasWifi = results.contains(ConnectivityResult.wifi);
      final hasMobile = results.contains(ConnectivityResult.mobile);
      final hasEthernet = results.contains(ConnectivityResult.ethernet);
      final isConnected = hasWifi || hasMobile || hasEthernet;

      final previousOffline = isOffline.value;
      isOffline.value = !isConnected;

      debugPrint('[OfflineMapService] Connectivity changed: ${results.map((r) => r.name).join(", ")}; isOffline: ${isOffline.value}');

      if (previousOffline && !isOffline.value) {
        // Reconnected! Auto-resume live network tiles
        offlineLocationLabel.value = '';
        Get.snackbar(
          'Online',
          'Connection restored. Live map tiles resumed.',
          snackPosition: SnackPosition.TOP,
          duration: const Duration(seconds: 3),
        );
      } else if (isOffline.value) {
        _handleOfflinePositionFallback();
      }
    });

    // Initial status check
    Connectivity().checkConnectivity().then((results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      isOffline.value = !isConnected;
      if (isOffline.value) {
        _handleOfflinePositionFallback();
      }
    });
  }

  /// Task 4a & 4b: Resolves offline position using LocationFallbackService (Tier 4 last known first)
  Future<LatLng?> _handleOfflinePositionFallback() async {
    try {
      final locResult = await LocationFallbackService.resolveLocationForEmergency();
      if (locResult.position != null) {
        offlineLocationLabel.value = 'Offline — showing cached map (${locResult.statusLabel}).';
        return LatLng(locResult.position!.latitude, locResult.position!.longitude);
      }
    } catch (e) {
      debugPrint('[OfflineMapService] LocationFallbackService resolution failed offline: $e');
    }

    // Fallback to last-downloaded region centroid if position unavailable
    if (lastCachedRegionCentroid.value != null) {
      offlineLocationLabel.value = 'Approximate area — exact position unavailable';
      return lastCachedRegionCentroid.value;
    }

    offlineLocationLabel.value = 'Offline — showing cached map. Some areas may be unavailable.';
    return null;
  }

  /// Task 1 & 4c: Gets TileProvider for TileLayer with Network-First (Online) or Cache-Only (Offline)
  TileProvider getTileProvider({required bool forceOffline}) {
    final strategy = (forceOffline || isOffline.value)
        ? BrowseStoreStrategy.read
        : BrowseStoreStrategy.readUpdateCreate;

    return FMTCTileProvider(
      stores: {
        storeName: strategy,
      },
    );
  }

  /// Task 2: Checks if Wi-Fi is connected
  Future<bool> isWifiConnected() async {
    final results = await Connectivity().checkConnectivity();
    return results.contains(ConnectivityResult.wifi);
  }

  /// Task 2: Checks storage volume against 300MB cap
  Future<double> getStoreSizeInMB() async {
    try {
      final sizeInBytes = await store.stats.size;
      return sizeInBytes / (1024 * 1024);
    } catch (_) {
      return 0.0;
    }
  }

  /// Task 2: Auto-download tile area around user's current location (Wi-Fi only, ≤300MB cap, 5km radius, zoom 12-16)
  Future<void> triggerAutoDownloadIfEligible({required LatLng centerLocation}) async {
    if (isAutoDownloading.value || isManualDownloading.value) return;

    final onWifi = await isWifiConnected();
    if (!onWifi && !allowMobileDataAutoDownload.value) {
      debugPrint('[OfflineMapService] Skipping auto-download: Device is on Mobile Data (Wi-Fi required).');
      return;
    }

    // Check frequency: Once per session if >24h since last update
    final prefs = await SharedPreferences.getInstance();
    final lastRun = prefs.getInt(_lastAutoDownloadPrefsKey) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - lastRun < 24 * 60 * 60 * 1000) {
      debugPrint('[OfflineMapService] Skipping auto-download: Updated within last 24h.');
      return;
    }

    // Storage Cap Check (300MB)
    final currentMB = await getStoreSizeInMB();
    if (currentMB >= maxStorageCapMB) {
      debugPrint('[OfflineMapService] Storage cap (300MB) reached (${currentMB.toStringAsFixed(1)}MB). Stopping auto-download.');
      Get.snackbar(
        'Offline Map Cap Reached',
        'Auto-download paused (300MB limit reached). Manage map storage in Settings.',
        snackPosition: SnackPosition.BOTTOM,
      );
      return;
    }

    debugPrint('[OfflineMapService] Triggering auto-download on Wi-Fi (Radius: 5km, Zoom 12-16) at ${centerLocation.latitude}, ${centerLocation.longitude}...');
    await prefs.setInt(_lastAutoDownloadPrefsKey, nowMs);
    await _saveCachedCentroid(centerLocation);

    unawaited(_performTileDownload(
      centerLocation: centerLocation,
      radiusKm: 5.0,
      minZoom: 12,
      maxZoom: 16,
      isAuto: true,
    ));
  }

  /// Task 3: Manual download trigger for selected area / bounds
  Future<bool> triggerManualDownload({
    required LatLng centerLocation,
    required double radiusKm,
    required int minZoom,
    required int maxZoom,
    required BuildContext context,
  }) async {
    if (isAutoDownloading.value || isManualDownloading.value) {
      Get.snackbar('Download in Progress', 'A map tile download is already running.');
      return false;
    }

    final onWifi = await isWifiConnected();
    final estimatedTiles = estimateTileCount(centerLocation, radiusKm, minZoom, maxZoom);
    final estimatedSizeMB = (estimatedTiles * 20.0) / 1024.0; // ~20KB per tile

    // Task 3: Mobile Data confirmation dialog if not on Wi-Fi
    if (!onWifi) {
      if (!context.mounted) return false;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Download on Mobile Data?'),
          content: Text(
            'You are connected to Cellular Data.\n\n'
            'Estimated tiles: $estimatedTiles\n'
            'Estimated size: ~${estimatedSizeMB.toStringAsFixed(1)} MB\n\n'
            'Do you wish to proceed with the download?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );

      if (proceed != true) return false;
    }

    await _saveCachedCentroid(centerLocation);
    _performTileDownload(
      centerLocation: centerLocation,
      radiusKm: radiusKm,
      minZoom: minZoom,
      maxZoom: maxZoom,
      isAuto: false,
    );
    return true;
  }

  int estimateTileCount(LatLng center, double radiusKm, int minZoom, int maxZoom) {
    int total = 0;
    for (int z = minZoom; z <= maxZoom; z++) {
      final n = pow(2, z).toDouble();
      final latDegPerTile = 360.0 / n;
      final radiusDeg = radiusKm / 111.0;
      final tilesAcross = ((radiusDeg * 2) / latDegPerTile).ceil().clamp(1, 20);
      total += (tilesAcross * tilesAcross);
    }
    return total;
  }

  Future<void> _performTileDownload({
    required LatLng centerLocation,
    required double radiusKm,
    required int minZoom,
    required int maxZoom,
    required bool isAuto,
  }) async {
    if (isAuto) {
      isAutoDownloading.value = true;
    } else {
      isManualDownloading.value = true;
    }

    downloadProgress.value = 0.0;
    downloadedTilesCount.value = 0;
    totalTilesToDownload.value = estimateTileCount(centerLocation, radiusKm, minZoom, maxZoom);

    try {
      final isReady = await store.manage.ready;
      if (!isReady) {
        await store.manage.create();
      }

      final region = CircleRegion(
        centerLocation,
        radiusKm,
      );

      final downloadableRegion = region.toDownloadable(
        minZoom: minZoom,
        maxZoom: maxZoom,
        options: TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.safe_route',
          additionalOptions: const {
            'User-Agent': 'VIGIL_Emergency_App/1.0.0 (safe_route_app)',
          },
        ),
      );

      final downloadSession = store.download.startForeground(
        region: downloadableRegion,
      );

      final completer = Completer<void>();
      StreamSubscription? sub;

      sub = downloadSession.downloadProgress.listen(
        (progress) async {
          dynamic p = progress;
          try {
            if (p.percentage != null) {
              downloadProgress.value = (p.percentage as num).toDouble() / 100.0;
            }
            if (p.successfulTiles != null) {
              downloadedTilesCount.value = (p.successfulTiles as num).toInt();
            } else if (p.downloadedTiles != null) {
              downloadedTilesCount.value = (p.downloadedTiles as num).toInt();
            }
            if (p.estTotalTiles != null) {
              totalTilesToDownload.value = (p.estTotalTiles as num).toInt();
            }
          } catch (_) {}

          // Check storage cap mid-download
          final currentMB = await getStoreSizeInMB();
          if (currentMB >= maxStorageCapMB) {
            debugPrint('[OfflineMapService] Storage cap reached mid-download (${currentMB.toStringAsFixed(1)}MB). Partial tiles preserved.');
            store.download.cancel();
            Get.snackbar(
              'Storage Limit Hit',
              'Download stopped at 300MB limit. Partial area remains available offline.',
              snackPosition: SnackPosition.BOTTOM,
            );
            if (!completer.isCompleted) completer.complete();
          }
        },
        onError: (err) {
          debugPrint('[OfflineMapService] Stream error during tile download: $err');
          if (!completer.isCompleted) completer.completeError(err);
        },
        onDone: () {
          debugPrint('[OfflineMapService] Tile download stream completed successfully.');
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: false,
      );

      await completer.future.timeout(
        const Duration(minutes: 6),
        onTimeout: () {
          debugPrint('[OfflineMapService] Tile download timed out after 6 minutes.');
        },
      );
      await sub.cancel();

      final count = downloadedTilesCount.value;
      Get.snackbar(
        'Offline Map Downloaded',
        'Successfully cached $count map tiles for offline emergency use.',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: const Color(0xFF22C55E),
        colorText: Colors.white,
        duration: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('[OfflineMapService] Tile download error: $e');
      Get.snackbar(
        'Download Error',
        'Could not complete offline tile download: ${e.toString().split("\n").first}',
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Colors.redAccent,
        colorText: Colors.white,
      );
    } finally {
      isAutoDownloading.value = false;
      isManualDownloading.value = false;
      downloadProgress.value = 1.0;
    }
  }

  void cancelCurrentDownload() {
    try {
      store.download.cancel();
      isAutoDownloading.value = false;
      isManualDownloading.value = false;
      Get.snackbar('Download Cancelled', 'Tile download was cancelled by user.');
    } catch (e) {
      debugPrint('[OfflineMapService] Error cancelling download: $e');
    }
  }

  Future<void> _saveCachedCentroid(LatLng centroid) async {
    lastCachedRegionCentroid.value = centroid;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('last_cached_centroid_lat', centroid.latitude);
    await prefs.setDouble('last_cached_centroid_lng', centroid.longitude);
  }

  /// Task 3: Clears cached tiles to free up device storage
  Future<void> clearTileCache() async {
    try {
      await store.manage.reset();
      lastCachedRegionCentroid.value = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_cached_centroid_lat');
      await prefs.remove('last_cached_centroid_lng');
      await prefs.remove(_lastAutoDownloadPrefsKey);
      Get.snackbar('Cache Cleared', 'All downloaded offline map tiles removed.');
    } catch (e) {
      debugPrint('[OfflineMapService] Error clearing cache: $e');
    }
  }
}

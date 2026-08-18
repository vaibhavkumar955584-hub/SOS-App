import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class JourneyDestination {
  const JourneyDestination({
    required this.placeId,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.category,
    this.distanceMeters,
  });

  final String placeId;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final String? category;
  final double? distanceMeters;

  String get formattedDistance {
    if (distanceMeters == null) return '';
    if (distanceMeters! < 1000) {
      return '${distanceMeters!.toStringAsFixed(0)} m';
    }
    return '${(distanceMeters! / 1000).toStringAsFixed(1)} km';
  }

  Map<String, dynamic> toJson() => {
        'placeId': placeId,
        'name': name,
        'address': address,
        'latitude': latitude,
        'longitude': longitude,
        'category': category,
        'distanceMeters': distanceMeters,
      };

  factory JourneyDestination.fromJson(Map<String, dynamic> json) =>
      JourneyDestination(
        placeId: json['placeId'] ?? '',
        name: json['name'] ?? '',
        address: json['address'] ?? '',
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        category: json['category'],
        distanceMeters: (json['distanceMeters'] as num?)?.toDouble(),
      );
}

class PlaceCategoryItem {
  const PlaceCategoryItem({
    required this.key,
    required this.label,
    required this.iconName,
    required this.query,
  });

  final String key;
  final String label;
  final String iconName;
  final String query;
}

class _CacheEntry {
  final List<JourneyDestination> results;
  final DateTime timestamp;
  _CacheEntry(this.results) : timestamp = DateTime.now();

  bool get isExpired => DateTime.now().difference(timestamp) > const Duration(minutes: 15);
}

class PlaceSearchService {
  static int _currentSearchSeq = 0;
  static Timer? _debounceTimer;
  static const String _recentSearchesKey = 'safe_route_recent_searches_v2';

  // In-memory LRU-style cache for 0ms repeated search responses
  static final Map<String, _CacheEntry> _searchCache = {};

  // Default Greater Noida / Delhi NCR Center
  static const LatLng defaultNcrCenter = LatLng(28.4744, 77.5040);

  static const List<PlaceCategoryItem> categories = [
    PlaceCategoryItem(key: 'hospital', label: 'Hospitals', iconName: 'hospital', query: 'hospital emergency'),
    PlaceCategoryItem(key: 'police', label: 'Police', iconName: 'police', query: 'police station'),
    PlaceCategoryItem(key: 'pharmacy', label: 'Pharmacy', iconName: 'pharmacy', query: 'pharmacy chemist'),
    PlaceCategoryItem(key: 'fuel', label: 'Petrol', iconName: 'fuel', query: 'petrol pump CNG'),
    PlaceCategoryItem(key: 'metro', label: 'Metro', iconName: 'metro', query: 'metro station transit'),
    PlaceCategoryItem(key: 'atm', label: 'ATM', iconName: 'atm', query: 'ATM bank cash'),
    PlaceCategoryItem(key: 'hotel', label: 'Hotels', iconName: 'hotel', query: 'hotel lodge'),
    PlaceCategoryItem(key: 'shelter', label: 'Safe Place', iconName: 'shield', query: 'police help desk hospital shelter'),
  ];

  /// Comprehensive preset dictionary of Indian transit hubs, hospitals, and landmarks for 0ms instant autocomplete
  static final List<JourneyDestination> _popularPresets = [
    // Greater Noida & Noida
    const JourneyDestination(
      placeId: 'ncr_pari_chowk',
      name: 'Pari Chowk',
      address: 'Pari Chowk, Greater Noida, Uttar Pradesh 201310',
      latitude: 28.4682,
      longitude: 77.5109,
      category: 'landmark',
    ),
    const JourneyDestination(
      placeId: 'ncr_knowledge_park_2',
      name: 'Knowledge Park II',
      address: 'Knowledge Park II, Greater Noida, UP 201310',
      latitude: 28.4614,
      longitude: 77.4975,
      category: 'education',
    ),
    const JourneyDestination(
      placeId: 'ncr_knowledge_park_3',
      name: 'Knowledge Park III',
      address: 'Knowledge Park III, Greater Noida, UP 201308',
      latitude: 28.4665,
      longitude: 77.4912,
      category: 'education',
    ),
    const JourneyDestination(
      placeId: 'ncr_sharda_univ',
      name: 'Sharda University & Hospital',
      address: 'Plot No. 32, 34, Knowledge Park III, Greater Noida, UP 201310',
      latitude: 28.4735,
      longitude: 77.4820,
      category: 'university',
    ),
    const JourneyDestination(
      placeId: 'ncr_galgotias_univ',
      name: 'Galgotias University',
      address: 'Plot No.2, Sector 17A, Yamuna Expressway, Greater Noida, UP 203201',
      latitude: 28.3644,
      longitude: 77.5401,
      category: 'university',
    ),
    const JourneyDestination(
      placeId: 'ncr_bennett_univ',
      name: 'Bennett University',
      address: 'Plot No 8-11, TechZone 2, Greater Noida, UP 201310',
      latitude: 28.4485,
      longitude: 77.5855,
      category: 'university',
    ),
    const JourneyDestination(
      placeId: 'ncr_gaur_city_mall',
      name: 'Gaur City Mall & Extension',
      address: 'Gaur City 1, Sector 4, Greater Noida West (Noida Ext), UP 201009',
      latitude: 28.6086,
      longitude: 77.4264,
      category: 'commercial',
    ),
    const JourneyDestination(
      placeId: 'ncr_yatharth_hosp',
      name: 'Yatharth Super Specialty Hospital',
      address: 'Plot No. 32, Omega 1, Greater Noida, UP 201308',
      latitude: 28.4705,
      longitude: 77.5170,
      category: 'hospital',
    ),
    const JourneyDestination(
      placeId: 'ncr_kailash_hosp',
      name: 'Kailash Hospital Greater Noida',
      address: 'Knowledge Park I, Greater Noida, UP 201310',
      latitude: 28.4770,
      longitude: 77.5085,
      category: 'hospital',
    ),
    const JourneyDestination(
      placeId: 'ncr_fortis_sec62',
      name: 'Fortis Hospital Sector 62',
      address: 'B-22, Sector 62, Noida, UP 201301',
      latitude: 28.6186,
      longitude: 77.3732,
      category: 'hospital',
    ),
    const JourneyDestination(
      placeId: 'ncr_police_kp',
      name: 'Knowledge Park Police Station',
      address: 'Knowledge Park II, Greater Noida, UP 201310',
      latitude: 28.4600,
      longitude: 77.4950,
      category: 'police',
    ),
    const JourneyDestination(
      placeId: 'ncr_police_surajpur',
      name: 'Surajpur Police Station & Commissionerate',
      address: 'Surajpur, Greater Noida, UP 201306',
      latitude: 28.5284,
      longitude: 77.4890,
      category: 'police',
    ),
    const JourneyDestination(
      placeId: 'ncr_aqua_line_depot',
      name: 'Depot Metro Station (Aqua Line)',
      address: 'Sector Depot, Greater Noida, UP 201310',
      latitude: 28.4410,
      longitude: 77.5210,
      category: 'metro',
    ),
    const JourneyDestination(
      placeId: 'ncr_aqua_line_delta1',
      name: 'Delta 1 Metro Station (Aqua Line)',
      address: 'Sector Delta 1, Greater Noida, UP 201310',
      latitude: 28.4812,
      longitude: 77.5147,
      category: 'metro',
    ),
    const JourneyDestination(
      placeId: 'ncr_sec62_noida',
      name: 'Sector 62 Noida Hub',
      address: 'Sector 62, Noida, Uttar Pradesh 201301',
      latitude: 28.6280,
      longitude: 77.3649,
      category: 'commercial',
    ),
    const JourneyDestination(
      placeId: 'ncr_sec18_noida',
      name: 'Sector 18 Noida (Atta Market / DLF Mall)',
      address: 'Sector 18, Noida, UP 201301',
      latitude: 28.5708,
      longitude: 77.3261,
      category: 'commercial',
    ),
    const JourneyDestination(
      placeId: 'ncr_yamuna_exp',
      name: 'Yamuna Expressway Toll Plaza',
      address: 'Yamuna Expressway, Greater Noida, UP 201310',
      latitude: 28.4200,
      longitude: 77.5300,
      category: 'highway',
    ),
    const JourneyDestination(
      placeId: 'ncr_jewar_airport',
      name: 'Noida International Airport (Jewar)',
      address: 'Jewar, Greater Noida, Uttar Pradesh 203135',
      latitude: 28.1500,
      longitude: 77.5800,
      category: 'airport',
    ),
    // Delhi Hubs
    const JourneyDestination(
      placeId: 'delhi_aiims',
      name: 'AIIMS Hospital New Delhi',
      address: 'Sri Aurobindo Marg, Ansari Nagar East, New Delhi 110029',
      latitude: 28.5672,
      longitude: 77.2100,
      category: 'hospital',
    ),
    const JourneyDestination(
      placeId: 'delhi_connaught_place',
      name: 'Connaught Place (CP)',
      address: 'Connaught Place, Central Delhi, New Delhi 110001',
      latitude: 28.6315,
      longitude: 77.2167,
      category: 'commercial',
    ),
    const JourneyDestination(
      placeId: 'delhi_igi_airport',
      name: 'Indira Gandhi International Airport (IGI T3)',
      address: 'Palam, New Delhi 110037',
      latitude: 28.5562,
      longitude: 77.1000,
      category: 'airport',
    ),
    const JourneyDestination(
      placeId: 'delhi_ndls',
      name: 'New Delhi Railway Station (NDLS)',
      address: 'Bhavbhuti Marg, Ratan Lal Market, Kamla Market, Ajmeri Gate, New Delhi 110006',
      latitude: 28.6430,
      longitude: 77.2195,
      category: 'transit',
    ),
    const JourneyDestination(
      placeId: 'delhi_anand_vihar',
      name: 'Anand Vihar ISBT & Railway Station',
      address: 'Anand Vihar, East Delhi, Delhi 110092',
      latitude: 28.6475,
      longitude: 77.3150,
      category: 'transit',
    ),
  ];

  static const Map<String, List<String>> _keywordDictionary = {
    'par': ['Pari Chowk, Greater Noida', 'Pari Chowk Metro Station', 'Pari Chowk Bus Stand'],
    'kno': ['Knowledge Park II, Greater Noida', 'Knowledge Park III, Greater Noida', 'Knowledge Park Metro Station'],
    'sha': ['Sharda University, Greater Noida', 'Sharda Hospital, Knowledge Park III'],
    'gal': ['Galgotias University, Greater Noida', 'Galgotias College of Engg & Tech'],
    'ben': ['Bennett University, Greater Noida', 'Bennett TechZone 2'],
    'gau': ['Gaur City Mall, Greater Noida West', 'Gaur City 1 & 2 Noida Extension'],
    'sec': ['Sector 62 Noida', 'Sector 18 Noida', 'Sector 142 Noida', 'Sector Alpha 1 Greater Noida'],
    'yat': ['Yatharth Hospital Omega 1 Greater Noida', 'Yatharth Hospital Sector 110 Noida'],
    'kai': ['Kailash Hospital Greater Noida', 'Kailash Hospital Sector 27 Noida'],
    'exp': ['Yamuna Expressway Greater Noida', 'Noida-Greater Noida Expressway'],
    'jew': ['Noida International Airport (Jewar)', 'Jewar Expressway Hub'],
    'aqu': ['Aqua Line Metro Station Greater Noida', 'Depot Metro Station', 'Delta 1 Metro Station'],
    'hos': ['Hospital', 'AIIMS Hospital New Delhi', 'Yatharth Hospital Greater Noida', 'Kailash Hospital Greater Noida'],
    'pol': ['Knowledge Park Police Station', 'Surajpur Police Station', 'Police Control Room Greater Noida'],
    'pha': ['Pharmacy', '24/7 Medical Store Greater Noida', 'Apollo Pharmacy Sector 18'],
    'pet': ['Petrol Pump Pari Chowk', 'EV Charging Station Knowledge Park', 'CNG Station Sector 62'],
    'met': ['Aqua Line Metro Station', 'Botanical Garden Metro', 'Sector 52 Metro Station'],
    'atm': ['ATM Pari Chowk', 'SBI ATM Knowledge Park', 'HDFC Bank ATM Sector 18'],
    'saf': ['Safe Place Greater Noida', 'Police Station Knowledge Park', 'Kailash Hospital Emergency'],
    'emer': ['Emergency Hospital Greater Noida', 'Police Station Surajpur', 'Ambulance Service NCR'],
  };

  /// Smart keyword suggestions based on partial input
  static List<String> getKeywordSuggestions(String input) {
    final clean = input.trim().toLowerCase();
    if (clean.isEmpty) return const [];

    final suggestions = <String>{};

    _keywordDictionary.forEach((key, list) {
      if (clean.startsWith(key) || key.startsWith(clean)) {
        suggestions.addAll(list);
      }
    });

    if (suggestions.isEmpty) {
      suggestions.add('Search "$input"');
      suggestions.add('$input near me');
    }

    return suggestions.toList();
  }

  /// Debounced place search with 200ms debounce and instant cache retrieval
  static Future<List<JourneyDestination>> searchPlacesDebounced(
    String query,
    LatLng? userLocation, {
    Duration debounceDuration = const Duration(milliseconds: 200),
  }) {
    final clean = query.trim().toLowerCase();
    final cacheKey = '$clean|${userLocation?.latitude.toStringAsFixed(3)}|${userLocation?.longitude.toStringAsFixed(3)}';

    // 0ms Cache Hit: return immediately if fresh in memory
    if (_searchCache.containsKey(cacheKey)) {
      final entry = _searchCache[cacheKey]!;
      if (!entry.isExpired) {
        return Future.value(entry.results);
      }
    }

    final completer = Completer<List<JourneyDestination>>();

    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounceDuration, () async {
      final results = await searchPlaces(query, userLocation);
      if (!completer.isCompleted) {
        completer.complete(results);
      }
    });

    return completer.future;
  }

  /// High-performance multi-tier place search (Cache -> Local Presets -> OSM Nominatim -> Native Device Geocoder Fallback)
  static Future<List<JourneyDestination>> searchPlaces(
    String query,
    LatLng? userLocation,
  ) async {
    final searchSeq = ++_currentSearchSeq;
    final trimmed = query.trim();
    final effectiveLocation = userLocation ?? defaultNcrCenter;

    if (trimmed.isEmpty) {
      final recent = await getRecentSearches();
      if (recent.isNotEmpty) {
        return _formatWithDistances(recent, effectiveLocation);
      }
      return _getPopularPresetsWithDistance(effectiveLocation);
    }

    final queryLower = trimmed.toLowerCase();
    final cacheKey = '$queryLower|${effectiveLocation.latitude.toStringAsFixed(3)}|${effectiveLocation.longitude.toStringAsFixed(3)}';

    if (_searchCache.containsKey(cacheKey) && !_searchCache[cacheKey]!.isExpired) {
      return _searchCache[cacheKey]!.results;
    }

    final presetMatches = <JourneyDestination>[];

    // 1. Instant Preset Matching (0ms latency, multi-token fuzzy matching)
    final queryTokens = queryLower.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    for (final preset in _popularPresets) {
      final nameLower = preset.name.toLowerCase();
      final addressLower = preset.address.toLowerCase();

      bool isMatch = false;
      if (queryTokens.isEmpty) {
        isMatch = nameLower.contains(queryLower) || addressLower.contains(queryLower);
      } else {
        isMatch = queryTokens.every((token) => nameLower.contains(token) || addressLower.contains(token));
      }

      if (isMatch) {
        final dist = Geolocator.distanceBetween(
          effectiveLocation.latitude,
          effectiveLocation.longitude,
          preset.latitude,
          preset.longitude,
        );
        presetMatches.add(
          JourneyDestination(
            placeId: preset.placeId,
            name: preset.name,
            address: preset.address,
            latitude: preset.latitude,
            longitude: preset.longitude,
            category: preset.category,
            distanceMeters: dist,
          ),
        );
      }
    }

    final results = <JourneyDestination>[...presetMatches];
    final seenCoordinates = <String>{
      ...presetMatches.map((p) => '${p.latitude.toStringAsFixed(4)}_${p.longitude.toStringAsFixed(4)}'),
    };

    // 2. Primary Online API: OpenStreetMap Nominatim with dynamic region viewbox
    try {
      final minLat = effectiveLocation.latitude - 0.75;
      final maxLat = effectiveLocation.latitude + 0.75;
      final minLon = effectiveLocation.longitude - 0.75;
      final maxLon = effectiveLocation.longitude + 0.75;
      final locationBias = '&viewbox=$minLon,$maxLat,$maxLon,$minLat&bounded=0&countrycodes=in';

      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(trimmed)}&addressdetails=1&limit=15$locationBias',
      );

      final response = await http.get(url, headers: {
        'User-Agent': 'VIGIL-SafeRoute-App/3.0',
        'Accept-Language': 'en-IN,en;q=0.9,hi;q=0.8',
      }).timeout(const Duration(seconds: 4));

      if (searchSeq != _currentSearchSeq) {
        return presetMatches;
      }

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);

        for (var item in data) {
          final lat = double.tryParse(item['lat']?.toString() ?? '');
          final lon = double.tryParse(item['lon']?.toString() ?? '');
          if (lat == null || lon == null) continue;

          final coordKey = '${lat.toStringAsFixed(4)}_${lon.toStringAsFixed(4)}';
          if (seenCoordinates.contains(coordKey)) continue;
          seenCoordinates.add(coordKey);

          final displayName = item['display_name']?.toString() ?? '';
          final parts = displayName.split(',');
          final mainName = parts.isNotEmpty ? parts[0].trim() : 'Location';
          final subAddress = parts.length > 1
              ? parts.sublist(1, parts.length > 4 ? 4 : parts.length).join(',').trim()
              : displayName;

          final distMeters = Geolocator.distanceBetween(
            effectiveLocation.latitude,
            effectiveLocation.longitude,
            lat,
            lon,
          );

          results.add(
            JourneyDestination(
              placeId: item['place_id']?.toString() ?? '${lat}_$lon',
              name: mainName,
              address: subAddress,
              latitude: lat,
              longitude: lon,
              category: item['type']?.toString() ?? item['class']?.toString(),
              distanceMeters: distMeters,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[PlaceSearchService] Nominatim search error: $e');

      // 3. Fallback: Native Device Geocoding if Nominatim fails or times out
      try {
        final locations = await geo.locationFromAddress('$trimmed, India').timeout(const Duration(seconds: 3));
        for (var loc in locations.take(5)) {
          final coordKey = '${loc.latitude.toStringAsFixed(4)}_${loc.longitude.toStringAsFixed(4)}';
          if (seenCoordinates.contains(coordKey)) continue;
          seenCoordinates.add(coordKey);

          final distMeters = Geolocator.distanceBetween(
            effectiveLocation.latitude,
            effectiveLocation.longitude,
            loc.latitude,
            loc.longitude,
          );

          results.add(
            JourneyDestination(
              placeId: 'native_geo_${loc.latitude}_${loc.longitude}',
              name: trimmed,
              address: 'Coordinates: ${loc.latitude.toStringAsFixed(4)}, ${loc.longitude.toStringAsFixed(4)}',
              latitude: loc.latitude,
              longitude: loc.longitude,
              category: 'geocoded',
              distanceMeters: distMeters,
            ),
          );
        }
      } catch (_) {}
    }

    // 4. Smart Ranking: Exact prefix matches first, then distance proximity
    results.sort((a, b) {
      final aMatchesPrefix = a.name.toLowerCase().startsWith(queryLower);
      final bMatchesPrefix = b.name.toLowerCase().startsWith(queryLower);
      if (aMatchesPrefix && !bMatchesPrefix) return -1;
      if (!aMatchesPrefix && bMatchesPrefix) return 1;
      return (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0);
    });

    // Store in memory cache (cap cache size at 50 items)
    if (_searchCache.length > 50) {
      _searchCache.remove(_searchCache.keys.first);
    }
    _searchCache[cacheKey] = _CacheEntry(results);

    return results;
  }

  /// Search nearby places for category chips with category-specific keywords
  static Future<List<JourneyDestination>> searchNearbyCategory(
    String categoryKey,
    LatLng? userLocation,
  ) async {
    final effectiveLocation = userLocation ?? defaultNcrCenter;
    final catItem = categories.firstWhere(
      (c) => c.key == categoryKey,
      orElse: () => categories.first,
    );

    return searchPlaces(catItem.query, effectiveLocation);
  }

  /// Save recently chosen destination to persistent storage
  static Future<void> saveRecentSearch(JourneyDestination dest) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingRaw = prefs.getStringList(_recentSearchesKey) ?? [];
      final existing = existingRaw
          .map((item) {
            try {
              return JourneyDestination.fromJson(jsonDecode(item));
            } catch (_) {
              return null;
            }
          })
          .whereType<JourneyDestination>()
          .where((d) => d.placeId != dest.placeId && (d.name != dest.name || d.address != dest.address))
          .toList();

      existing.insert(0, dest);
      final capped = existing.take(8).map((d) => jsonEncode(d.toJson())).toList();
      await prefs.setStringList(_recentSearchesKey, capped);
    } catch (e) {
      debugPrint('[PlaceSearchService] Error saving recent search: $e');
    }
  }

  /// Retrieve list of recent searches
  static Future<List<JourneyDestination>> getRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final existingRaw = prefs.getStringList(_recentSearchesKey) ?? [];
      return existingRaw
          .map((item) {
            try {
              return JourneyDestination.fromJson(jsonDecode(item));
            } catch (_) {
              return null;
            }
          })
          .whereType<JourneyDestination>()
          .toList();
    } catch (e) {
      debugPrint('[PlaceSearchService] Error getting recent searches: $e');
      return [];
    }
  }

  /// Clear all recent searches
  static Future<void> clearRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_recentSearchesKey);
    } catch (_) {}
  }

  static List<JourneyDestination> _getPopularPresetsWithDistance(LatLng location) {
    return _formatWithDistances(_popularPresets, location);
  }

  static List<JourneyDestination> _formatWithDistances(List<JourneyDestination> list, LatLng location) {
    final formatted = <JourneyDestination>[];
    for (final preset in list) {
      final dist = Geolocator.distanceBetween(
        location.latitude,
        location.longitude,
        preset.latitude,
        preset.longitude,
      );
      formatted.add(
        JourneyDestination(
          placeId: preset.placeId,
          name: preset.name,
          address: preset.address,
          latitude: preset.latitude,
          longitude: preset.longitude,
          category: preset.category,
          distanceMeters: dist,
        ),
      );
    }
    formatted.sort((a, b) => (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0));
    return formatted;
  }
}

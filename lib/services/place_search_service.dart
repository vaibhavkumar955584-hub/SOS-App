import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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

class PlaceSearchService {
  static int _currentSearchSeq = 0;
  static Timer? _debounceTimer;

  static const List<PlaceCategoryItem> categories = [
    PlaceCategoryItem(key: 'hospital', label: 'Hospitals', iconName: 'hospital', query: 'hospital'),
    PlaceCategoryItem(key: 'police', label: 'Police', iconName: 'police', query: 'police station'),
    PlaceCategoryItem(key: 'pharmacy', label: 'Pharmacy', iconName: 'pharmacy', query: 'pharmacy'),
    PlaceCategoryItem(key: 'fuel', label: 'Petrol', iconName: 'fuel', query: 'petrol pump'),
    PlaceCategoryItem(key: 'metro', label: 'Metro', iconName: 'metro', query: 'metro station'),
    PlaceCategoryItem(key: 'atm', label: 'ATM', iconName: 'atm', query: 'ATM'),
    PlaceCategoryItem(key: 'hotel', label: 'Hotels', iconName: 'hotel', query: 'hotel'),
    PlaceCategoryItem(key: 'shelter', label: 'Safe Place', iconName: 'shield', query: 'emergency shelter'),
  ];

  static const Map<String, List<String>> _keywordDictionary = {
    'hos': ['Hospital', 'Emergency Hospital', 'Nearby Hospital', 'Hospital with Emergency'],
    'pol': ['Police Station', 'Nearby Police Station', 'Police Control Room', 'Outpost'],
    'pha': ['Pharmacy', '24/7 Medical Store', 'Chemist Shop'],
    'pet': ['Petrol Pump', 'EV Charging Station', 'Fuel Station'],
    'met': ['Metro Station', 'Subway Station', 'Bus Stop'],
    'atm': ['ATM', 'Bank Branch', 'Cash Point'],
    'saf': ['Safe Place', 'Police Station', 'Hospital', 'Public Shelter'],
    'emer': ['Emergency Hospital', 'Police Station', 'Fire Station', 'Ambulance Service'],
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
      suggestions.add('Search "$input" nearby');
      suggestions.add('$input near me');
    }

    return suggestions.toList();
  }

  /// Debounced place search querying Nominatim API with cancellation protection
  static Future<List<JourneyDestination>> searchPlacesDebounced(
    String query,
    LatLng? userLocation, {
    Duration debounceDuration = const Duration(milliseconds: 350),
  }) {
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

  /// Direct API Search querying Nominatim
  static Future<List<JourneyDestination>> searchPlaces(
    String query,
    LatLng? userLocation,
  ) async {
    final searchSeq = ++_currentSearchSeq;
    final trimmed = query.trim();

    if (trimmed.isEmpty) {
      if (userLocation != null) {
        return searchNearbyCategory('hospital', userLocation);
      }
      return const [];
    }

    try {
      String locationBias = '';
      if (userLocation != null) {
        // Bias search towards user's current bounding box (~20km)
        final minLat = userLocation.latitude - 0.2;
        final maxLat = userLocation.latitude + 0.2;
        final minLon = userLocation.longitude - 0.2;
        final maxLon = userLocation.longitude + 0.2;
        locationBias = '&viewbox=$minLon,$maxLat,$maxLon,$minLat';
      }

      final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent(trimmed)}&addressdetails=1&limit=10$locationBias',
      );

      final response = await http.get(url, headers: {
        'User-Agent': 'SafeRoute-FlutterApp/1.0',
        'Accept-Language': 'en-US,en;q=0.9',
      }).timeout(const Duration(seconds: 8));

      // Cancel stale out-of-order request
      if (searchSeq != _currentSearchSeq) {
        debugPrint('[PlaceSearchService] Cancelled stale search request seq: $searchSeq');
        return const [];
      }

      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        final results = <JourneyDestination>[];

        for (var item in data) {
          final lat = double.tryParse(item['lat']?.toString() ?? '');
          final lon = double.tryParse(item['lon']?.toString() ?? '');
          if (lat == null || lon == null) continue;

          final displayName = item['display_name']?.toString() ?? '';
          final parts = displayName.split(',');
          final mainName = parts.isNotEmpty ? parts[0].trim() : 'Location';
          final subAddress = parts.length > 1 ? parts.sublist(1, parts.length > 4 ? 4 : parts.length).join(',').trim() : displayName;

          double? distMeters;
          if (userLocation != null) {
            distMeters = Geolocator.distanceBetween(
              userLocation.latitude,
              userLocation.longitude,
              lat,
              lon,
            );
          }

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

        // Rank by proximity & exact match
        if (userLocation != null) {
          results.sort((a, b) => (a.distanceMeters ?? 0).compareTo(b.distanceMeters ?? 0));
        }

        return results;
      }
    } catch (e) {
      debugPrint('[PlaceSearchService] Search error: $e');
    }

    return const [];
  }

  /// Search nearby places for category chips (Hospitals, Police, etc.)
  static Future<List<JourneyDestination>> searchNearbyCategory(
    String categoryKey,
    LatLng userLocation,
  ) async {
    final catItem = categories.firstWhere(
      (c) => c.key == categoryKey,
      orElse: () => categories.first,
    );

    return searchPlaces('${catItem.query}', userLocation);
  }
}

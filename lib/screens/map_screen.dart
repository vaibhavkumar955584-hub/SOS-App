import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/location_service.dart';
import '../controllers/sos_controller.dart';
import '../controllers/heatmap_controller.dart';
import '../controllers/history_controller.dart';
import '../controllers/rescue_invite_controller.dart';
import '../controllers/rescue_stats_controller.dart';
import '../services/journey_safety_service.dart';
import '../services/routing_service.dart';
import '../controllers/sos_listener_controller.dart';
import '../screens/safe_route_menu_screens.dart';
import '../controllers/risk_controller.dart';
import '../controllers/sos_heatmap_controller.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  static const double _unsafeZoneRadiusMeters = 150;
  static const double _unsafeRouteBufferMeters = 70;
  static const double _responderRouteCacheDistanceMeters = 25;
  static const double _routeTapThresholdMeters = 40;
  static const double _publishDistanceThresholdMeters = 10;
  static const double _journeyDeviationThresholdMeters = 50;
  static const double _journeyArrivalThresholdMeters = 30;
  static const double _journeyAutoSosRiskThreshold = 45;
  static const Duration _journeyRouteRefreshCooldown = Duration(seconds: 15);
  static const String _journeyGuardEnabledPrefsKey = 'journey_guard_enabled';
  static const String _journeyGuardActivePrefsKey = 'journey_guard_active';
  static const String _journeyGuardSelectingPrefsKey =
      'journey_guard_selecting_destination';
  static const String _journeyDestinationLatPrefsKey =
      'journey_guard_destination_lat';
  static const String _journeyDestinationLngPrefsKey =
      'journey_guard_destination_lng';
  final MapController _mapController = MapController();
  final SosController _sosController = SosController.instanceOrCreate();
  final HeatmapController _heatmapController =
      Get.isRegistered<HeatmapController>()
      ? Get.find<HeatmapController>()
      : Get.put(HeatmapController(), permanent: true);
  final SosHeatmapController _sosHeatmapController =
      Get.isRegistered<SosHeatmapController>()
      ? Get.find<SosHeatmapController>()
      : Get.put(SosHeatmapController());
  late final RiskController _riskController = RiskController.instance;

  Position? _currentPosition;
  String? _errorMessage;
  bool _isLoading = true;

  List<LatLng> _sosRouteLocations = [];
  RouteSummary? _activeRouteSummary;
  RouteSummary? _journeyRouteSummary;
  JourneyRiskResult? _journeyRiskResult;
  String? _journeyWarningMessage;
  String? _selectedUnsafeZoneId;
  String? _lastRouteHistoryKey;
  String? _selectedResponderUid;
  LatLng? _victimLocation;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _sessionSubscription;
  Worker? _broadcastWorker;
  Worker? _rescueWorker;
  Worker? _unsafeZonesWorker;
  final Map<String, _ResponderRouteInfo> _responderRoutes = {};
  final Map<String, _CachedResponderRoute> _routeCache = {};
  Worker? _sosWorker;
  StreamSubscription<Position>? _positionStreamSubscription;
  LatLng? _lastPublishedVictimLocation;
  LatLng? _lastPublishedResponderLocation;
  bool _isJourneyGuardEnabled = false;
  bool _isSelectingJourneyDestination = false;
  bool _isJourneyActive = false;
  bool _hasAutoSosTriggered = false;
  LatLng? _journeyDestination;
  List<LatLng> _journeyRouteLocations = [];
  double? _journeyDeviationMeters;
  double? _lastJourneyRiskScore;
  DateTime? _lastJourneyRouteRefreshAt;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreJourneyGuardState());
    _fetchCurrentLocation();
    _startLocationTracking(); // Real-time continuous stream
    _bindActiveSessionTracking();
    _broadcastWorker = ever(_sosController.isActiveBroadcast, (_) {
      _bindActiveSessionTracking();
    });
    _rescueWorker = ever(SosListenerController.instance.activeSosUid, (_) {
      _bindActiveSessionTracking();
    });
    _unsafeZonesWorker = ever<List<UnsafeZone>>(
      _heatmapController.unsafeZones,
      (zones) {
        if (_isJourneyGuardEnabled &&
            _journeyDestination != null &&
            _currentPosition != null) {
          unawaited(
            _setJourneyDestination(
              _journeyDestination!,
              preserveJourneyState: _isJourneyActive,
              logHistory: false,
            ),
          );
        }
      },
    );

    _sosWorker = ever(SosListenerController.instance.activeSosTarget, (
      LatLng? target,
    ) {
      if (target != null && _currentPosition != null) {
        _drawRouteTo(target);
      } else if (target == null) {
        RescueInviteController.instance.clearInviteJoinBadge();
        if (!mounted) return;
        setState(() {
          _sosRouteLocations.clear();
          _activeRouteSummary = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _sosWorker?.dispose();
    _broadcastWorker?.dispose();
    _rescueWorker?.dispose();
    _unsafeZonesWorker?.dispose();
    _sessionSubscription?.cancel();
    _positionStreamSubscription?.cancel();
    super.dispose();
  }

  void _startLocationTracking() {
    final locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _positionStreamSubscription =
        Geolocator.getPositionStream(
          locationSettings: locationSettings,
        ).listen((Position position) async {
          if (mounted) {
            setState(() {
              _currentPosition = position;
            });

            final currentLatLng = LatLng(position.latitude, position.longitude);
            if (_isJourneyGuardEnabled) {
              unawaited(_riskController.updateRisk(currentLatLng));
              _evaluateJourneyProgress(currentLatLng);
            }

            if (_sosController.isActiveBroadcast.value &&
                _shouldPublishLocation(
                  previous: _lastPublishedVictimLocation,
                  current: currentLatLng,
                )) {
              _lastPublishedVictimLocation = currentLatLng;
              await _sosController.updateVictimLocation(position);
            }

            if (SosListenerController.instance.activeSosTarget.value != null) {
              _drawRouteTo(
                SosListenerController.instance.activeSosTarget.value!,
              );

              if (_shouldPublishLocation(
                previous: _lastPublishedResponderLocation,
                current: currentLatLng,
              )) {
                _lastPublishedResponderLocation = currentLatLng;
                await SosListenerController.instance.updateResponderLocation(
                  position,
                  target: SosListenerController.instance.activeSosTarget.value,
                );
              }
            }
          }
        });
  }

  Future<void> _drawRouteTo(LatLng target) async {
    if (_currentPosition == null) return;
    try {
      final route = await RoutingService.getRoute(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        target,
      );
      if (mounted) {
        setState(() {
          _sosRouteLocations = route.points;
          _activeRouteSummary = route.points.isEmpty ? null : route;
        });
      }
      if (route.points.isNotEmpty &&
          SosListenerController.instance.activeSosTarget.value != null) {
        final destinationName =
            SosListenerController.instance.activeDestinationName.value;
        final historyKey =
            '${target.latitude.toStringAsFixed(5)},${target.longitude.toStringAsFixed(5)}';
        if (_lastRouteHistoryKey != historyKey) {
          _lastRouteHistoryKey = historyKey;
          await HistoryController.instanceOrCreate().recordRoute(
            destinationName: destinationName,
            distanceLabel: _formatDistance(route.distanceMeters),
            durationLabel: _formatDuration(route.durationSeconds),
          );
        }
      }
    } catch (e) {
      debugPrint("Error drawing route: \$e");
    }
  }

  Future<void> _fetchCurrentLocation() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final position = await LocationService.getCurrentPosition();
      if (!mounted) return;
      bool isFirstLoad = _currentPosition == null;
      setState(() {
        _currentPosition = position;
        _isLoading = false;
      });

      if (_isJourneyGuardEnabled) {
        _riskController.startPolling(position);
        unawaited(_restoreJourneyRouteIfNeeded());
      } else {
        _riskController.stopPolling();
        _riskController.currentRiskScore.value = null;
      }

      if (!isFirstLoad) {
        _moveCameraTo(position);
      }

      if (SosListenerController.instance.activeSosTarget.value != null) {
        _drawRouteTo(SosListenerController.instance.activeSosTarget.value!);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
      _showErrorSnackBar(_errorMessage!);
    }
  }

  void _moveCameraTo(Position position) {
    _mapController.move(LatLng(position.latitude, position.longitude), 15.0);
  }

  void _showErrorSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Retry',
          onPressed: _fetchCurrentLocation,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showAddUnsafeZoneDialog(LatLng point) {
    var selectedReason = 'Poor lighting'.obs;
    final selectedStartTime = Rxn<TimeOfDay>();
    final selectedEndTime = Rxn<TimeOfDay>();

    String formatTime(TimeOfDay time) {
      final hour = time.hour.toString().padLeft(2, '0');
      final minute = time.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    }

    Get.defaultDialog(
      title: "Mark Unsafe Area",
      titleStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
      content: Obx(
        () => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Do you want to mark this area as unsafe?",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Select Reason (Optional):",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8.0,
              runSpacing: -4.0,
              children: [
                ChoiceChip(
                  label: const Text("Poor lighting"),
                  selected: selectedReason.value == 'Poor lighting',
                  onSelected: (bool selected) {
                    if (selected) selectedReason.value = 'Poor lighting';
                  },
                  selectedColor: Colors.redAccent.withOpacity(0.3),
                ),
                ChoiceChip(
                  label: const Text("Harassment"),
                  selected: selectedReason.value == 'Harassment',
                  onSelected: (bool selected) {
                    if (selected) selectedReason.value = 'Harassment';
                  },
                  selectedColor: Colors.redAccent.withOpacity(0.3),
                ),
                ChoiceChip(
                  label: const Text("Isolated area"),
                  selected: selectedReason.value == 'Isolated area',
                  onSelected: (bool selected) {
                    if (selected) selectedReason.value = 'Isolated area';
                  },
                  selectedColor: Colors.redAccent.withOpacity(0.3),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Unsafe Time (Optional):",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: selectedStartTime.value ?? TimeOfDay.now(),
                      );
                      if (picked != null) {
                        selectedStartTime.value = picked;
                      }
                    },
                    icon: const Icon(Icons.access_time),
                    label: Text(
                      selectedStartTime.value == null
                          ? "From"
                          : "From ${formatTime(selectedStartTime.value!)}",
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: selectedEndTime.value ?? TimeOfDay.now(),
                      );
                      if (picked != null) {
                        selectedEndTime.value = picked;
                      }
                    },
                    icon: const Icon(Icons.schedule),
                    label: Text(
                      selectedEndTime.value == null
                          ? "To"
                          : "To ${formatTime(selectedEndTime.value!)}",
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      textConfirm: "Confirm",
      textCancel: "Cancel",
      confirmTextColor: Colors.white,
      buttonColor: Colors.redAccent,
      onConfirm: () {
        Get.back(); // Dismiss dialog
        _heatmapController.addUnsafeZone(
          point,
          reason: selectedReason.value,
          timeStart: selectedStartTime.value == null
              ? null
              : formatTime(selectedStartTime.value!),
          timeEnd: selectedEndTime.value == null
              ? null
              : formatTime(selectedEndTime.value!),
        );
      },
    );
  }

  void _enableJourneyDestinationSelection() {
    if (!_isJourneyGuardEnabled) {
      _showInfoSnackBar('Turn on Journey Guard first.');
      return;
    }
    setState(() {
      _isSelectingJourneyDestination = true;
    });
    unawaited(_persistJourneyGuardState());
    _showInfoSnackBar('Tap on map to choose destination');
  }

  Future<void> _setJourneyDestination(
    LatLng destination, {
    bool preserveJourneyState = false,
    bool logHistory = true,
  }) async {
    if (!_isJourneyGuardEnabled) {
      return;
    }
    if (_currentPosition == null) {
      _showErrorSnackBar('Current location unavailable.');
      return;
    }

    try {
      final journeyDecision = await _buildSafeJourneyRoute(
        LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        destination,
      );
      final route = journeyDecision.route;
      if (!mounted) return;
      if (route.points.isEmpty) {
        _showErrorSnackBar('Unable to build route for selected destination.');
        return;
      }

      setState(() {
        _journeyDestination = destination;
        _journeyRouteLocations = route.points;
        _journeyRouteSummary = route;
        _journeyRiskResult = JourneySafetyService.calculateRouteRisk(
          route.points,
          _heatmapController.unsafeZones,
          userLocation: LatLng(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          dangerBufferMeters:
              _unsafeZoneRadiusMeters + _unsafeRouteBufferMeters,
        );
        _lastJourneyRiskScore = _journeyRiskResult?.score;
        _journeyWarningMessage = journeyDecision.warningMessage;
        _journeyDeviationMeters = null;
        _isJourneyActive = preserveJourneyState;
        _hasAutoSosTriggered = false;
        _lastJourneyRouteRefreshAt = DateTime.now();
      });
      await _persistJourneyGuardState();
      if (logHistory) {
        unawaited(
          HistoryController.instanceOrCreate().recordJourneyEvent(
            title: 'Journey Route Ready',
            subtitle:
                'Distance ${_formatDistance(route.distanceMeters)} - ${_formatDuration(route.durationSeconds)}',
            metadata: {
              'destinationLat': destination.latitude,
              'destinationLng': destination.longitude,
            },
          ),
        );
      }
    } catch (_) {
      _showErrorSnackBar('Failed to fetch safer route.');
    }
  }

  void _startJourney() {
    if (!_isJourneyGuardEnabled) {
      _showInfoSnackBar('Turn on Journey Guard first.');
      return;
    }
    if (_journeyRouteLocations.length < 2) {
      _showErrorSnackBar('Select a destination and route first.');
      return;
    }
    setState(() {
      _isJourneyActive = true;
      _hasAutoSosTriggered = false;
    });
    if (_currentPosition != null) {
      _riskController.startPolling(_currentPosition!);
    }
    unawaited(_persistJourneyGuardState());
    unawaited(
      HistoryController.instanceOrCreate().recordJourneyEvent(
        title: 'Journey Started',
        subtitle: 'Live route monitoring enabled',
      ),
    );
    _showInfoSnackBar(
      'Journey started. SOS auto-triggers if you go off-route.',
    );
  }

  void _endJourney({bool showMessage = true}) {
    if (!mounted) return;
    final wasActive = _isJourneyActive;
    setState(() {
      _isJourneyActive = false;
      _isSelectingJourneyDestination = false;
      _hasAutoSosTriggered = false;
      _journeyDestination = null;
      _journeyRouteLocations.clear();
      _journeyRouteSummary = null;
      _journeyRiskResult = null;
      _journeyWarningMessage = null;
      _lastJourneyRiskScore = null;
      _journeyDeviationMeters = null;
      _lastJourneyRouteRefreshAt = null;
    });
    unawaited(_persistJourneyGuardState());
    if (wasActive) {
      unawaited(
        HistoryController.instanceOrCreate().recordJourneyEvent(
          title: 'Journey Ended',
          subtitle: 'Route monitoring stopped',
        ),
      );
    }
    if (showMessage) {
      _showInfoSnackBar('Journey ended.');
    }
  }

  void _evaluateJourneyProgress(LatLng current) {
    if (!_isJourneyGuardEnabled ||
        !_isJourneyActive ||
        _journeyRouteLocations.length < 2) {
      return;
    }

    final deviation = _distanceToPolylineMeters(
      current,
      _journeyRouteLocations,
    );
    if (mounted) {
      setState(() {
        _journeyDeviationMeters = deviation;
      });
    }

    final destination = _journeyDestination;
    if (destination != null) {
      final distanceToDestination = Geolocator.distanceBetween(
        current.latitude,
        current.longitude,
        destination.latitude,
        destination.longitude,
      );
      if (distanceToDestination <= _journeyArrivalThresholdMeters) {
        _endJourney(showMessage: true);
        _showInfoSnackBar('Destination reached safely.');
        return;
      }
    }

    final updatedRisk = JourneySafetyService.calculateRouteRisk(
      _journeyRouteLocations,
      _heatmapController.unsafeZones,
      userLocation: current,
      dangerBufferMeters: _unsafeZoneRadiusMeters + _unsafeRouteBufferMeters,
    );
    if (mounted) {
      setState(() {
        _journeyRiskResult = updatedRisk;
        if (updatedRisk.intersectsDangerZone) {
          _journeyWarningMessage =
              'No fully safe route available. Showing lowest-risk route.';
        }
      });
    }

    if (_lastJourneyRiskScore != null &&
        (updatedRisk.score - _lastJourneyRiskScore!).abs() >= 12 &&
        _journeyDestination != null) {
      _lastJourneyRiskScore = updatedRisk.score;
      _lastJourneyRouteRefreshAt = DateTime.now();
      unawaited(
        _setJourneyDestination(
          _journeyDestination!,
          preserveJourneyState: true,
          logHistory: false,
        ),
      );
      return;
    }
    _lastJourneyRiskScore = updatedRisk.score;

    final shouldRefreshRouteForDeviation =
        deviation > (_journeyDeviationThresholdMeters * 0.6) &&
        _journeyDestination != null &&
        (_lastJourneyRouteRefreshAt == null ||
            DateTime.now().difference(_lastJourneyRouteRefreshAt!) >=
                _journeyRouteRefreshCooldown);

    if (shouldRefreshRouteForDeviation) {
      _lastJourneyRouteRefreshAt = DateTime.now();
      unawaited(
        _setJourneyDestination(
          _journeyDestination!,
          preserveJourneyState: true,
          logHistory: false,
        ),
      );
    }

    final shouldAutoTrigger =
        deviation > _journeyDeviationThresholdMeters &&
        (updatedRisk.score >= _journeyAutoSosRiskThreshold ||
            updatedRisk.intersectsDangerZone ||
            updatedRisk.nearbyDangerCount > 0);

    if (shouldAutoTrigger && !_hasAutoSosTriggered) {
      _hasAutoSosTriggered = true;
      _endJourney(showMessage: false);
      unawaited(() async {
        final didTrigger = await _sosController.triggerAutoRouteDeviationSOS(
          deviationMeters: deviation,
        );
        if (!mounted) return;
        if (didTrigger) {
          _showErrorSnackBar(
            'Route deviation detected (> ${_journeyDeviationThresholdMeters.toInt()}m). SOS triggered.',
          );
        } else {
          _showInfoSnackBar(
            'Route deviation detected, but SOS is already active.',
          );
        }
      }());
    }
  }

  double _distanceToPolylineMeters(LatLng point, List<LatLng> polyline) {
    if (polyline.length < 2) return double.infinity;
    var nearestDistance = double.infinity;
    for (var i = 0; i < polyline.length - 1; i++) {
      final distance = JourneySafetyService.distanceToSegmentMeters(
        point,
        polyline[i],
        polyline[i + 1],
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
      }
    }
    return nearestDistance;
  }

  void _showInfoSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _restoreJourneyGuardState() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_journeyGuardEnabledPrefsKey) ?? false;
    final active = prefs.getBool(_journeyGuardActivePrefsKey) ?? false;
    final selecting = prefs.getBool(_journeyGuardSelectingPrefsKey) ?? false;
    final destinationLat = prefs.getDouble(_journeyDestinationLatPrefsKey);
    final destinationLng = prefs.getDouble(_journeyDestinationLngPrefsKey);

    if (!mounted) {
      return;
    }

    setState(() {
      _isJourneyGuardEnabled = enabled;
      _isJourneyActive = enabled && active;
      _isSelectingJourneyDestination =
          enabled &&
          selecting &&
          destinationLat == null &&
          destinationLng == null;
      _journeyDestination =
          enabled && destinationLat != null && destinationLng != null
          ? LatLng(destinationLat, destinationLng)
          : null;
    });

    if (_isJourneyGuardEnabled) {
      if (_currentPosition != null) {
        _riskController.startPolling(_currentPosition!);
      }
      await _restoreJourneyRouteIfNeeded();
    } else {
      _riskController.stopPolling();
      _riskController.currentRiskScore.value = null;
    }
  }

  Future<void> _persistJourneyGuardState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_journeyGuardEnabledPrefsKey, _isJourneyGuardEnabled);
    await prefs.setBool(
      _journeyGuardActivePrefsKey,
      _isJourneyGuardEnabled && _isJourneyActive,
    );
    await prefs.setBool(
      _journeyGuardSelectingPrefsKey,
      _isJourneyGuardEnabled && _isSelectingJourneyDestination,
    );

    if (_isJourneyGuardEnabled && _journeyDestination != null) {
      await prefs.setDouble(
        _journeyDestinationLatPrefsKey,
        _journeyDestination!.latitude,
      );
      await prefs.setDouble(
        _journeyDestinationLngPrefsKey,
        _journeyDestination!.longitude,
      );
    } else {
      await prefs.remove(_journeyDestinationLatPrefsKey);
      await prefs.remove(_journeyDestinationLngPrefsKey);
    }
  }

  Future<void> _restoreJourneyRouteIfNeeded() async {
    if (!_isJourneyGuardEnabled ||
        _currentPosition == null ||
        _journeyDestination == null) {
      return;
    }

    if (_journeyRouteLocations.isNotEmpty) {
      return;
    }

    await _setJourneyDestination(
      _journeyDestination!,
      preserveJourneyState: _isJourneyActive,
      logHistory: false,
    );
  }

  Future<void> _handleJourneyGuardToggle(bool enabled) async {
    if (_isJourneyGuardEnabled == enabled) {
      return;
    }

    if (!enabled) {
      setState(() {
        _isJourneyGuardEnabled = false;
      });
      _riskController.stopPolling();
      _riskController.currentRiskScore.value = null;
      _endJourney(showMessage: false);
      await _persistJourneyGuardState();
      _showInfoSnackBar('Journey Guard turned off.');
      return;
    }

    setState(() {
      _isJourneyGuardEnabled = true;
      _isSelectingJourneyDestination = false;
      _isJourneyActive = false;
      _hasAutoSosTriggered = false;
    });
    if (_currentPosition == null) {
      await _fetchCurrentLocation();
      if (_currentPosition == null) {
        if (!mounted) return;
        setState(() {
          _isJourneyGuardEnabled = false;
        });
        await _persistJourneyGuardState();
        _showErrorSnackBar(
          'Location permission is required to enable Journey Guard.',
        );
        return;
      }
    }
    if (_currentPosition != null) {
      _riskController.startPolling(_currentPosition!);
      unawaited(
        _riskController.updateRisk(
          LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
        ),
      );
    }
    await _persistJourneyGuardState();
    _showInfoSnackBar(
      'Journey Guard enabled. Choose a destination, then press Start Journey.',
    );
  }

  Future<void> _showSafetyControlsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Obx(
              () => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Theme.of(context).dividerColor,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Safety Controls',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Manage safety tools without crowding the map.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  _ControlToggleTile(
                    icon: Icons.shield_outlined,
                    iconColor: Colors.amber.shade700,
                    title: 'Journey Guard',
                    subtitle:
                        'Monitors deviation and nearby danger once you start a journey.',
                    value: _isJourneyGuardEnabled,
                    onChanged: _handleJourneyGuardToggle,
                  ),
                  const SizedBox(height: 10),
                  _ControlToggleTile(
                    icon: Icons.vibration,
                    iconColor: Colors.deepPurpleAccent,
                    title: 'Shake SOS',
                    subtitle: 'Emergency shake trigger for hands-free SOS.',
                    value: _sosController.isShakeSOSActive.value,
                    onChanged: _sosController.toggleShakeSOS,
                  ),
                  const SizedBox(height: 10),
                  _ControlToggleTile(
                    icon: Icons.mic_none_rounded,
                    iconColor: Colors.teal,
                    title: 'Voice SOS',
                    subtitle:
                        'Listens for help me, save me, SOS, or emergency and triggers SOS automatically.',
                    value: _sosController.isVoiceSOSActive.value,
                    onChanged: _sosController.toggleVoiceSOS,
                  ),
                  const SizedBox(height: 10),
                  _ControlToggleTile(
                    icon: Icons.local_fire_department,
                    iconColor: Colors.redAccent,
                    title: 'Unsafe Zones',
                    subtitle: 'Shows community-reported danger areas on map.',
                    value: _heatmapController.isHeatmapVisible.value,
                    onChanged: (_) => _heatmapController.toggleHeatmap(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final floatingOffsets = JourneySafetyService.getFloatingButtonOffsets(
      isTripActive:
          _isJourneyGuardEnabled &&
          (_isJourneyActive || _journeyRouteLocations.isNotEmpty),
      hasResponderCard: _selectedResponderUid != null,
      screenHeight: mediaQuery.size.height,
      safeBottomPadding:
          max(mediaQuery.viewPadding.bottom, mediaQuery.padding.bottom) + 8,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'SafeRoute',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        actions: [
          Row(
            children: [
              Tooltip(
                message: 'Open Safety Controls',
                child: IconButton(
                  onPressed: _showSafetyControlsSheet,
                  icon: const Icon(Icons.tune_rounded),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Tooltip(
                message:
                    'Automatically monitors your journey and can trigger SOS if high-risk deviation is detected.',
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: _TopBarStatusChip(
                    label: _isJourneyActive
                        ? 'Guard Active'
                        : _isJourneyGuardEnabled
                        ? 'Guard Ready'
                        : 'Guard Off',
                    icon: _isJourneyActive
                        ? Icons.shield
                        : Icons.shield_outlined,
                    accentColor: _isJourneyActive
                        ? Colors.greenAccent
                        : _isJourneyGuardEnabled
                        ? Colors.amber
                        : Colors.white70,
                    isEnabled: _isJourneyGuardEnabled,
                    onTap: () =>
                        _handleJourneyGuardToggle(!_isJourneyGuardEnabled),
                  ),
                ),
              ),
              PopupMenuButton<_AppMenuAction>(
                icon: const Icon(Icons.more_vert),
                onSelected: _handleMenuAction,
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: _AppMenuAction.emergencyContacts,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.contact_phone_outlined),
                      title: Text('Emergency Contacts'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _AppMenuAction.sosTimer,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.timer_outlined),
                      title: Text('SOS Timer'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _AppMenuAction.editProfile,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.person_outline),
                      title: Text('Edit Profile'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _AppMenuAction.history,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.history),
                      title: Text('History'),
                    ),
                  ),
                  PopupMenuItem(
                    value: _AppMenuAction.logout,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.logout),
                      title: Text('Logout'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          _currentPosition == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.location_off,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _errorMessage ?? "Location not available",
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _fetchCurrentLocation,
                          icon: const Icon(Icons.refresh),
                          label: const Text("Retry"),
                        ),
                      ],
                    ),
                  ),
                )
              : FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: LatLng(
                      _currentPosition!.latitude,
                      _currentPosition!.longitude,
                    ),
                    initialZoom: 15.0,
                    onTap: _handleMapTap,
                    onLongPress: (tapPosition, point) =>
                        _showAddUnsafeZoneDialog(point),
                    onPositionChanged: (position, hasGesture) {
                      final bounds = position.visibleBounds;
                      final zoom = position.zoom;
                      _sosHeatmapController.refreshForViewport(
                        bounds: bounds,
                        zoom: zoom,
                      );
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.safe_route',
                    ),
                    PolylineLayer(
                      polylines: [
                        if (_sosRouteLocations.isNotEmpty)
                          Polyline(
                            points: _sosRouteLocations,
                            color: Colors.blueAccent,
                            strokeWidth: 5.0,
                          ),
                        if (_isJourneyGuardEnabled &&
                            _journeyRouteLocations.isNotEmpty)
                          Polyline(
                            points: _journeyRouteLocations,
                            color: Colors.deepPurpleAccent,
                            strokeWidth: 5.0,
                          ),
                      ],
                    ),
                    if (_responderRoutes.isNotEmpty)
                      PolylineLayer(
                        polylines: _responderRoutes.values.map((route) {
                          final hasSelection = _selectedResponderUid != null;
                          final isSelected = route.uid == _selectedResponderUid;
                          final routeColor = _routeColorForUid(route.uid);
                          return Polyline(
                            points: route.route.points,
                            color: routeColor.withOpacity(
                              isSelected
                                  ? 0.95
                                  : hasSelection
                                  ? 0.25
                                  : 0.68,
                            ),
                            strokeWidth: isSelected ? 6 : 4,
                          );
                        }).toList(),
                      ),
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: LatLng(
                            _currentPosition!.latitude,
                            _currentPosition!.longitude,
                          ),
                          width: 72,
                          height: 72,
                          child: const Icon(
                            Icons.person_pin_circle,
                            size: 36,
                            color: Colors.blueAccent,
                          ),
                        ),
                        if (_victimLocation != null)
                          Marker(
                            point: _victimLocation!,
                            width: 84,
                            height: 84,
                            child: const Icon(
                              Icons.location_pin,
                              size: 44,
                              color: Colors.red,
                            ),
                          ),
                        if (SosListenerController
                                .instance
                                .activeSosTarget
                                .value !=
                            null)
                          Marker(
                            point: SosListenerController
                                .instance
                                .activeSosTarget
                                .value!,
                            width: 80,
                            height: 80,
                            child: const Icon(
                              Icons.warning,
                              size: 40,
                              color: Colors.redAccent,
                            ),
                          ),
                        if (_isJourneyGuardEnabled &&
                            _journeyDestination != null)
                          Marker(
                            point: _journeyDestination!,
                            width: 80,
                            height: 80,
                            child: const Icon(
                              Icons.flag_circle,
                              size: 38,
                              color: Colors.deepPurple,
                            ),
                          ),
                        ..._responderRoutes.values.map(
                          (route) => Marker(
                            point: route.currentLocation,
                            width: route.uid == _selectedResponderUid ? 92 : 72,
                            height: route.uid == _selectedResponderUid
                                ? 92
                                : 72,
                            child: GestureDetector(
                              onTap: () => _selectResponderRoute(route.uid),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    route.uid == _selectedResponderUid
                                        ? Icons.shield
                                        : Icons.shield_outlined,
                                    size: route.uid == _selectedResponderUid
                                        ? 34
                                        : 28,
                                    color: _routeColorForUid(route.uid),
                                  ),
                                  if (route.uid == _selectedResponderUid)
                                    Container(
                                      margin: const EdgeInsets.only(top: 2),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Text(
                                        route.displayName,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    Obx(() {
                      if (_sosHeatmapController.isVisible.value) {
                        return CircleLayer(
                          circles: _sosHeatmapController.buildCircleMarkers(),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                    Obx(() {
                      if (_heatmapController.isHeatmapVisible.value) {
                        return CircleLayer(
                          circles: _heatmapController.unsafeZones.map((zone) {
                            final isSelected = zone.id == _selectedUnsafeZoneId;
                            
                            Color baseColor;
                            switch (zone.confidence) {
                              case ZoneConfidence.high:
                                baseColor = Colors.red;
                                break;
                              case ZoneConfidence.medium:
                                baseColor = Colors.orange;
                                break;
                              case ZoneConfidence.low:
                                baseColor = Colors.orangeAccent;
                                break;
                            }
                            
                            final fillColor = baseColor.withOpacity(
                                isSelected ? 0.34 : (zone.confidence == ZoneConfidence.low ? 0.15 : 0.24)
                            );
                            
                            return CircleMarker(
                              point: zone.point,
                              color: fillColor,
                              borderColor: baseColor,
                              borderStrokeWidth: isSelected ? 2.2 : 1.2,
                              useRadiusInMeter: true,
                              radius: isSelected
                                  ? _unsafeZoneRadiusMeters + 20
                                  : _unsafeZoneRadiusMeters,
                            );
                          }).toList(),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],
                ),
          Obx(() {
            final activeTarget =
                SosListenerController.instance.activeSosTarget.value;
            final destinationName =
                SosListenerController.instance.activeDestinationName.value;
            final routeSummary = _activeRouteSummary;
            final joinedViaInvite =
                RescueInviteController.instance.joinedViaInvite.value;
            final isRescueHelper =
                SosListenerController.instance.isInRescueMode.value &&
                !_sosController.isActiveBroadcast.value;

            if (activeTarget == null ||
                routeSummary == null ||
                routeSummary.points.isEmpty) {
              return const SizedBox.shrink();
            }

            return Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: _RouteSummaryCard(
                distanceLabel: _formatDistance(routeSummary.distanceMeters),
                durationLabel: _formatDuration(routeSummary.durationSeconds),
                destinationName: destinationName,
                onLeaveRescue: _confirmLeaveRescue,
                onShareInvite: isRescueHelper
                    ? RescueInviteController.instance.shareActiveRescueInvite
                    : null,
                joinedViaInvite: joinedViaInvite,
              ),
            );
          }),
          Positioned(
            top: _activeRouteSummary == null ? 16 : 178,
            left: 16,
            right: 16,
            child: Obx(() {
              final stats = RescueStatsController.instance;
              final totalCount = stats.totalRescues.value;
              final personalCount = stats.personalHelpedRescues.value;
              return _RescueStatsBanner(
                totalLabel: totalCount >= 100
                    ? 'Trusted by $totalCount+ successful rescues'
                    : '$totalCount+ Rescues Completed',
                personalLabel: personalCount > 0
                    ? 'You helped in $personalCount rescues'
                    : null,
              );
            }),
          ),
          Obx(() {
            final isRescueHelper =
                SosListenerController.instance.isInRescueMode.value &&
                !_sosController.isActiveBroadcast.value;
            final joinedViaInvite =
                RescueInviteController.instance.joinedViaInvite.value;

            if (!isRescueHelper) {
              return const SizedBox.shrink();
            }

            return Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: _SaviorBottomControlCard(
                onShareInvite: () => RescueInviteController.instance
                    .shareActiveRescueInvite(),
                onLeaveRescue: _confirmLeaveRescue,
                joinedViaInvite: joinedViaInvite,
              ),
            );
          }),
          if (_selectedResponderUid != null &&
              _responderRoutes[_selectedResponderUid] != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: _ResponderRouteCard(
                route: _responderRoutes[_selectedResponderUid]!,
                isSelected: true,
                onClose: () {
                  setState(() {
                    _selectedResponderUid = null;
                  });
                },
              ),
            ),
          if (_currentPosition != null && _isJourneyGuardEnabled)
            Positioned(
              left: 16,
              right: 16,
              bottom: floatingOffsets.journeyPanelBottom,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _isJourneyActive
                            ? 'Journey active'
                            : _isSelectingJourneyDestination
                            ? 'Tap map to pick destination'
                            : 'Journey Guard',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isJourneyActive
                            ? 'Journey Guard Active'
                            : 'Auto Trip Safety monitors deviation and nearby danger zones after you start the journey.',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          if (_journeyRouteSummary != null)
                            Text(
                              'ETA ${_formatDuration(_journeyRouteSummary!.durationSeconds)}',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          if (_journeyRouteSummary != null)
                            Text(
                              'Distance ${_formatDistance(_journeyRouteSummary!.distanceMeters)}',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          if (_journeyDeviationMeters != null &&
                              _isJourneyActive)
                            Text(
                              'Deviation ${_journeyDeviationMeters!.toStringAsFixed(0)}m',
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                        ],
                      ),
                      if (_journeyWarningMessage != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _journeyWarningMessage!,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          if (!_isJourneyActive)
                            TextButton(
                              onPressed: _enableJourneyDestinationSelection,
                              child: const Text('Choose'),
                            ),
                          if (!_isJourneyActive &&
                              _journeyRouteLocations.isNotEmpty)
                            FilledButton(
                              onPressed: _startJourney,
                              child: const Text('Start'),
                            ),
                          if (_isJourneyActive)
                            FilledButton(
                              onPressed: _endJourney,
                              child: const Text('End Trip'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_isJourneyGuardEnabled)
            Positioned(
              bottom: floatingOffsets.riskBottom,
              right: 16,
              child: Obx(() {
                final score =
                    _journeyRiskResult?.score ??
                    _riskController.currentRiskScore.value;
                if (score == null) return const SizedBox.shrink();
                return _RiskLevelIndicator(
                  score: score,
                  intersectsDangerZone:
                      _journeyRiskResult?.intersectsDangerZone == true,
                );
              }),
            ),

          if (_isLoading)
            Container(
              color: Colors.white.withOpacity(0.7),
              child: const Center(child: CircularProgressIndicator()),
            ),

          // GetX Reactive Full-Screen Overlays
          Obx(() {
            if (_sosController.isCountdown.value) {
              return Container(
                color: Colors.black87, // Dramatic Dark Overlay
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.red,
                        size: 100,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        "Sending alert in ${_sosController.countdownSeconds.value}...",
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 60),
                      SizedBox(
                        height: 50,
                        width: 200,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                          ),
                          onPressed: () => _sosController.cancelSOS(),
                          icon: const Icon(Icons.cancel, size: 28),
                          label: const Text(
                            "CANCEL",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 20,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }

            if (_sosController.isSent.value) {
              return Container(
                color: Colors.black87,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    margin: const EdgeInsets.symmetric(horizontal: 24),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.redAccent, width: 2),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          "🚨 SOS ALERT SENT",
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Obx(
                          () => Text(
                            _sosController.isSendingEmergencyAlerts.value
                                ? _sosController.smsStatusMessage.value
                                : "Your emergency alert is active and contacts have been processed.",
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 16,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        Obx(() {
                          final messages = <String>[];
                          if (_sosController.isEmergencyRecording.value ||
                              _sosController
                                  .recordingStatusMessage
                                  .value
                                  .isNotEmpty) {
                            messages.add(
                              _sosController.recordingStatusMessage.value,
                            );
                          }
                          if (_sosController.isVoiceSOSActive.value &&
                              _sosController
                                  .voiceStatusMessage
                                  .value
                                  .isNotEmpty) {
                            messages.add(
                              _sosController.voiceStatusMessage.value,
                            );
                          }
                          if (messages.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Text(
                              messages.join('\n'),
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 13,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          );
                        }),
                        const SizedBox(height: 14),
                        Obx(
                          () => Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.22),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.08),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Sent: ${_sosController.smsSentCount.value}/${_sosController.smsTotalCount.value}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Failed: ${_sosController.smsFailedCount.value}',
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                if (_sosController
                                    .smsRetryStatus
                                    .value
                                    .isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Text(
                                      _sosController.smsRetryStatus.value,
                                      style: const TextStyle(
                                        color: Colors.orangeAccent,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Obx(
                          () =>
                              _sosController.availableSmsSubscriptions.length >
                                  1
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: SizedBox(
                                    width: double.infinity,
                                    height: 46,
                                    child: OutlinedButton.icon(
                                      onPressed: _sosController
                                          .showSmsSubscriptionPicker,
                                      icon: const Icon(Icons.sim_card_outlined),
                                      label: const Text('Choose SMS SIM'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white,
                                        side: const BorderSide(
                                          color: Colors.white24,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 36),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: _sosController.copyMessage,
                            icon: const Icon(Icons.copy),
                            label: const Text(
                              "Copy Message",
                              style: TextStyle(fontSize: 16),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey[800],
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: _sosController.shareSOS,
                            icon: const Icon(Icons.share),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                            ),
                            label: const Text(
                              "Share to Apps",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: OutlinedButton.icon(
                            onPressed: () => RescueInviteController.instance
                                .shareActiveRescueInvite(),
                            icon: const Icon(Icons.group_add, color: Colors.white),
                            label: const Text(
                              "Share Rescue Invite Link",
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: Colors.white.withOpacity(0.5),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: Obx(
                            () => ElevatedButton.icon(
                              onPressed: _sosController.isCompletingRescue.value
                                  ? null
                                  : _sosController.stopActiveSOS,
                              icon: _sosController.isCompletingRescue.value
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.verified_user),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              label: Text(
                                _sosController.isCompletingRescue.value
                                    ? "COMPLETING RESCUE..."
                                    : "MARK AS SAFE (STOP SOS)",
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: _sosController.closeAlert,
                            child: const Text(
                              "Keep Running & Close Menu",
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            if (_sosController.isLoading.value) {
              return Container(
                color: Colors.black54,
                child: Center(
                  child: Obx(
                    () => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.red),
                        const SizedBox(height: 16),
                        Text(
                          _sosController.isSendingEmergencyAlerts.value
                              ? _sosController.smsStatusMessage.value
                              : "Fetching GPS...",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        if (_sosController.isSendingEmergencyAlerts.value) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Sent ${_sosController.smsSentCount.value}/${_sosController.smsTotalCount.value} • Failed ${_sosController.smsFailedCount.value}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          if (_sosController.smsRetryStatus.value.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: Text(
                                _sosController.smsRetryStatus.value,
                                style: const TextStyle(
                                  color: Colors.orangeAccent,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            }
            return const SizedBox.shrink();
          }),
        ],
      ),
      floatingActionButton: Obx(
        () => (_sosController.isCountdown.value || _sosController.isSent.value)
            ? const SizedBox.shrink() // Hide buttons during overlays
            : SizedBox(
                width: 170,
                height:
                    max(
                      floatingOffsets.locationBottom,
                      floatingOffsets.sosBottom,
                    ) +
                    100,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (_currentPosition != null &&
                        !_isLoading &&
                        !_sosController.isLoading.value)
                      Positioned(
                        right: 0,
                        bottom: floatingOffsets.locationBottom,
                        child: FloatingActionButton(
                          heroTag: 'locationBtn',
                          onPressed: () {
                            if (_currentPosition != null) {
                              _moveCameraTo(_currentPosition!);
                            }
                          },
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onPrimary,
                          child: const Icon(Icons.my_location),
                        ),
                      ),
                    Positioned(
                      right: 0,
                      bottom: floatingOffsets.sosBottom,
                      child: _sosController.isActiveBroadcast.value
                          ? Obx(
                              () => FloatingActionButton.extended(
                                heroTag: 'stopSosBtn',
                                onPressed:
                                    _sosController.isCompletingRescue.value
                                    ? null
                                    : () => _sosController.stopActiveSOS(),
                                backgroundColor: Colors.black,
                                foregroundColor: Colors.greenAccent,
                                icon: _sosController.isCompletingRescue.value
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.greenAccent,
                                        ),
                                      )
                                    : const Icon(Icons.verified_user, size: 28),
                                label: Text(
                                  _sosController.isCompletingRescue.value
                                      ? "COMPLETING..."
                                      : "I'M SAFE",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                            )
                          : _PulsingSosButton(
                              onPressed: () =>
                                  _sosController.initiateSOSWorkflow(),
                            ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Future<_JourneyRouteBuildResult> _buildSafeJourneyRoute(
    LatLng start,
    LatLng destination,
  ) async {
    final visibleUnsafeZones = _heatmapController.unsafeZones;
    final candidateRoutes = <JourneySafetyCandidate>[];
    final uniqueCandidateKeys = <String>{};
    final baseRoutes = await RoutingService.getAlternativeRoutes(
      start,
      destination,
      maxAlternatives: 3,
    );
    final baseRoute = baseRoutes.isNotEmpty
        ? baseRoutes.first
        : await RoutingService.getRoute(start, destination);
    if (baseRoute.points.isEmpty) {
      return const _JourneyRouteBuildResult(
        route: RouteSummary(points: [], distanceMeters: 0, durationSeconds: 0),
      );
    }

    _addJourneyCandidates(
      candidateRoutes: candidateRoutes,
      uniqueCandidateKeys: uniqueCandidateKeys,
      routes: baseRoutes.isNotEmpty ? baseRoutes : [baseRoute],
      visibleUnsafeZones: visibleUnsafeZones,
      userLocation: start,
      viaPoints: const [],
    );

    if (visibleUnsafeZones.isNotEmpty) {
      final seedRoutes = baseRoutes.isNotEmpty ? baseRoutes : [baseRoute];
      for (final seedRoute in seedRoutes) {
        if (seedRoute.points.isEmpty) {
          continue;
        }

        for (final zone in visibleUnsafeZones) {
          final routeIntersectsZone =
              JourneySafetyService.doesRouteIntersectDangerZone(
                seedRoute.points,
                [zone],
                actualZoneRadiusMeters: _unsafeZoneRadiusMeters,
              );
          final routeZoneDistance = _distanceToPolylineMeters(
            zone.point,
            seedRoute.points,
          );
          final zoneInfluenceDistance =
              _unsafeZoneRadiusMeters +
              JourneySafetyService.getAdaptiveDangerBufferForZone(zone) +
              120;
          if (!routeIntersectsZone &&
              routeZoneDistance > zoneInfluenceDistance) {
            continue;
          }

          final detourWaypointSets = _buildDetourWaypointSetsForZone(
            seedRoute.points,
            zone,
          );
          for (final viaPoints in detourWaypointSets) {
            final reroutedRoutes = await RoutingService.getAlternativeRoutes(
              start,
              destination,
              viaPoints: viaPoints,
              maxAlternatives: 2,
            );
            if (reroutedRoutes.isEmpty) {
              continue;
            }

            _addJourneyCandidates(
              candidateRoutes: candidateRoutes,
              uniqueCandidateKeys: uniqueCandidateKeys,
              routes: reroutedRoutes,
              visibleUnsafeZones: visibleUnsafeZones,
              userLocation: start,
              viaPoints: viaPoints,
            );
          }
        }
      }
    }

    final decision = JourneySafetyService.selectBalancedSafeRoute(
      candidateRoutes,
      visibleUnsafeZones,
      actualZoneRadiusMeters: _unsafeZoneRadiusMeters,
      maxDetourRatio: 1.32,
    );
    if (decision == null) {
      return _JourneyRouteBuildResult(route: baseRoute);
    }

    return _JourneyRouteBuildResult(
      route: decision.candidate.route,
      warningMessage: decision.warningMessage,
    );
  }

  List<List<LatLng>> _buildDetourWaypointSetsForZone(
    List<LatLng> routePoints,
    UnsafeZone zone,
  ) {
    if (routePoints.length < 2) {
      return const <List<LatLng>>[];
    }

    final zoneCenter = zone.point;
    var bestStart = routePoints.first;
    var bestEnd = routePoints[1];
    var nearestDistance = double.infinity;

    for (var i = 0; i < routePoints.length - 1; i++) {
      final distance = JourneySafetyService.distanceToSegmentMeters(
        zoneCenter,
        routePoints[i],
        routePoints[i + 1],
      );
      if (distance < nearestDistance) {
        nearestDistance = distance;
        bestStart = routePoints[i];
        bestEnd = routePoints[i + 1];
      }
    }

    final dx = bestEnd.longitude - bestStart.longitude;
    final dy = bestEnd.latitude - bestStart.latitude;
    final length = sqrt(dx * dx + dy * dy);
    if (length == 0) {
      return const <List<LatLng>>[];
    }

    final tangentX = dx / length;
    final tangentY = dy / length;
    final perpendicularX = -tangentY;
    final perpendicularY = tangentX;
    final adaptiveBuffer =
        JourneySafetyService.getAdaptiveDangerBufferForZone(zone);
    final lateralOffsetMeters =
        _unsafeZoneRadiusMeters + max(35.0, min(110.0, adaptiveBuffer * 0.45));
    final longitudinalSweepMeters =
        lateralOffsetMeters + max(45.0, _unsafeZoneRadiusMeters * 0.35);
    final waypointSets = <List<LatLng>>[];
    final uniqueKeys = <String>{};

    LatLng offsetPoint({
      required double lateralMeters,
      required double longitudinalMeters,
    }) {
      final avgLat = zoneCenter.latitude * pi / 180;
      final metersPerLng = 111320.0 * cos(avgLat).clamp(0.2, double.infinity);
      final latOffset =
          ((perpendicularY * lateralMeters) + (tangentY * longitudinalMeters)) /
          111320.0;
      final lngOffset =
          ((perpendicularX * lateralMeters) + (tangentX * longitudinalMeters)) /
          metersPerLng;
      return LatLng(
        zoneCenter.latitude + latOffset,
        zoneCenter.longitude + lngOffset,
      );
    }

    for (final side in [-1.0, 1.0]) {
      final midpoint = offsetPoint(
        lateralMeters: lateralOffsetMeters * side,
        longitudinalMeters: 0,
      );
      final entry = offsetPoint(
        lateralMeters: lateralOffsetMeters * side,
        longitudinalMeters: -longitudinalSweepMeters,
      );
      final exit = offsetPoint(
        lateralMeters: lateralOffsetMeters * side,
        longitudinalMeters: longitudinalSweepMeters,
      );

      for (final candidate in [
        <LatLng>[midpoint],
        <LatLng>[entry, exit],
        <LatLng>[entry, midpoint, exit],
      ]) {
        final key = candidate
            .map(
              (point) =>
                  '${point.latitude.toStringAsFixed(5)},${point.longitude.toStringAsFixed(5)}',
            )
            .join('|');
        if (uniqueKeys.add(key)) {
          waypointSets.add(candidate);
        }
      }
    }

    return waypointSets;
  }

  void _addJourneyCandidates({
    required List<JourneySafetyCandidate> candidateRoutes,
    required Set<String> uniqueCandidateKeys,
    required List<RouteSummary> routes,
    required List<UnsafeZone> visibleUnsafeZones,
    required LatLng userLocation,
    required List<LatLng> viaPoints,
  }) {
    for (final route in routes) {
      if (route.points.isEmpty) {
        continue;
      }

      final routeKey = [
        route.distanceMeters.toStringAsFixed(0),
        route.durationSeconds.toStringAsFixed(0),
        route.points.length,
        if (route.points.isNotEmpty)
          '${route.points.first.latitude.toStringAsFixed(4)},${route.points.first.longitude.toStringAsFixed(4)}',
        if (route.points.length > 2)
          '${route.points[route.points.length ~/ 2].latitude.toStringAsFixed(4)},${route.points[route.points.length ~/ 2].longitude.toStringAsFixed(4)}',
        if (route.points.isNotEmpty)
          '${route.points.last.latitude.toStringAsFixed(4)},${route.points.last.longitude.toStringAsFixed(4)}',
      ].join('|');

      if (!uniqueCandidateKeys.add(routeKey)) {
        continue;
      }

      candidateRoutes.add(
        JourneySafetyCandidate(
          route: route,
          viaPoints: viaPoints,
          risk: JourneySafetyService.calculateRouteRisk(
            route.points,
            visibleUnsafeZones,
            userLocation: userLocation,
            dangerBufferMeters:
                _unsafeZoneRadiusMeters + _unsafeRouteBufferMeters,
            actualZoneRadiusMeters: _unsafeZoneRadiusMeters,
          ),
        ),
      );
    }
  }

  String _formatDistance(double distanceMeters) {
    if (distanceMeters >= 1000) {
      final kilometers = distanceMeters / 1000;
      final decimals = kilometers >= 10 ? 0 : 1;
      return '${kilometers.toStringAsFixed(decimals)} km';
    }
    return '${distanceMeters.round()} m';
  }

  String _formatDuration(double durationSeconds) {
    final minutes = (durationSeconds / 60).ceil();
    return minutes <= 1 ? '1 min' : '$minutes mins';
  }

  void _bindActiveSessionTracking() {
    _sessionSubscription?.cancel();
    _sessionSubscription = null;

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      _clearSharedSessionUi();
      return;
    }

    final sessionId = _sosController.isActiveBroadcast.value
        ? currentUser.uid
        : SosListenerController.instance.activeSosUid.value;

    if (sessionId == null || sessionId.isEmpty) {
      _clearSharedSessionUi();
      return;
    }

    _sessionSubscription = FirebaseFirestore.instance
        .collection('active_sos')
        .doc(sessionId)
        .snapshots()
        .listen((doc) async {
          final data = doc.data();
          if (data == null || data['active'] != true) {
            if (!_sosController.isActiveBroadcast.value) {
              SosListenerController.instance.clearActiveNavigation();
            }
            _clearSharedSessionUi();
            return;
          }

          final victim = _extractVictimLocation(data);
          if (victim == null) {
            return;
          }

          final responderMeta = Map<String, dynamic>.from(
            data['respondersMeta'] as Map? ?? {},
          );
          final responders = await _parseResponderRoutesAsync(
            responderMeta,
            victim,
          );

          if (!_sosController.isActiveBroadcast.value) {
            SosListenerController.instance.activeSosTarget.value = victim;
          }

          if (!mounted) return;
          setState(() {
            _victimLocation = victim;
            _responderRoutes
              ..clear()
              ..addEntries(responders.entries);
            if (_selectedResponderUid != null &&
                !_responderRoutes.containsKey(_selectedResponderUid)) {
              _selectedResponderUid = null;
            }
          });
        });
  }

  Future<Map<String, _ResponderRouteInfo>> _parseResponderRoutesAsync(
    Map<String, dynamic> responderMeta,
    LatLng victim,
  ) async {
    final results = <String, _ResponderRouteInfo>{};
    for (final entry in responderMeta.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final data = Map<String, dynamic>.from(raw);
      final uid = data['uid']?.toString() ?? entry.key;
      final lat = (data['latitude'] as num?)?.toDouble();
      final lng = (data['longitude'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      results[uid] = _ResponderRouteInfo(
        uid: uid,
        displayName: data['name']?.toString().trim().isNotEmpty == true
            ? data['name'].toString()
            : uid,
        currentLocation: LatLng(lat, lng),
        victimLocation: victim,
        route: await _getResponderRoute(LatLng(lat, lng), victim),
        status: data['status']?.toString() ?? 'Approaching',
      );
    }
    return results;
  }

  Future<_ResponderRouteData> _getResponderRoute(
    LatLng start,
    LatLng victim,
  ) async {
    final key = _routeCacheKey(start, victim);
    final cached = _routeCache[key];
    if (cached != null) {
      final drift = Geolocator.distanceBetween(
        cached.start.latitude,
        cached.start.longitude,
        start.latitude,
        start.longitude,
      );
      if (drift <= _responderRouteCacheDistanceMeters) {
        return cached.data;
      }
    }

    final route = await RoutingService.getRoute(start, victim);
    final data = _ResponderRouteData(
      points: route.points,
      distanceMeters: route.distanceMeters,
      durationSeconds: route.durationSeconds,
    );
    _routeCache[key] = _CachedResponderRoute(
      start: start,
      victim: victim,
      data: data,
    );
    return data;
  }

  LatLng? _extractVictimLocation(Map<String, dynamic> data) {
    final victimData = data['victim'];
    if (victimData is Map) {
      final normalized = Map<String, dynamic>.from(victimData);
      final lat = (normalized['lat'] as num?)?.toDouble();
      final lng = (normalized['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        return LatLng(lat, lng);
      }
    }

    final lat = (data['latitude'] as num?)?.toDouble();
    final lng = (data['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) {
      return null;
    }
    return LatLng(lat, lng);
  }

  void _clearSharedSessionUi() {
    if (!mounted) return;
    setState(() {
      _victimLocation = null;
      _responderRoutes.clear();
      _selectedResponderUid = null;
      _lastPublishedResponderLocation = null;
    });
  }

  bool _shouldPublishLocation({
    required LatLng? previous,
    required LatLng current,
  }) {
    if (previous == null) {
      return true;
    }

    final movedMeters = Geolocator.distanceBetween(
      previous.latitude,
      previous.longitude,
      current.latitude,
      current.longitude,
    );
    return movedMeters >= _publishDistanceThresholdMeters;
  }

  String _routeCacheKey(LatLng start, LatLng victim) {
    return '${start.latitude.toStringAsFixed(4)},${start.longitude.toStringAsFixed(4)}->'
        '${victim.latitude.toStringAsFixed(4)},${victim.longitude.toStringAsFixed(4)}';
  }

  void _handleMenuAction(_AppMenuAction action) {
    switch (action) {
      case _AppMenuAction.emergencyContacts:
        Get.to(
          () => const EmergencyContactsScreen(),
          transition: Transition.rightToLeftWithFade,
          duration: const Duration(milliseconds: 250),
        );
        break;
      case _AppMenuAction.sosTimer:
        Get.to(
          () => SosTimerScreen(),
          transition: Transition.rightToLeftWithFade,
          duration: const Duration(milliseconds: 250),
        );
        break;
      case _AppMenuAction.editProfile:
        Get.to(
          () => const EditProfileScreen(),
          transition: Transition.rightToLeftWithFade,
          duration: const Duration(milliseconds: 250),
        );
        break;
      case _AppMenuAction.history:
        Get.to(
          () => HistoryScreen(),
          transition: Transition.rightToLeftWithFade,
          duration: const Duration(milliseconds: 250),
        );
        break;
      case _AppMenuAction.logout:
        showLogoutConfirmation();
        break;
    }
  }

  void _handleMapTap(TapPosition tapPosition, LatLng point) {
    if (_isJourneyGuardEnabled && _isSelectingJourneyDestination) {
      setState(() {
        _isSelectingJourneyDestination = false;
      });
      unawaited(_persistJourneyGuardState());
      _setJourneyDestination(point);
      return;
    }

    final tappedRouteUid = _findTappedResponderRoute(point);
    if (tappedRouteUid != null) {
      _selectResponderRoute(tappedRouteUid);
      return;
    }

    final visibleZones = _heatmapController.unsafeZones;
    if (!_heatmapController.isHeatmapVisible.value || visibleZones.isEmpty) {
      if (_selectedUnsafeZoneId != null || _selectedResponderUid != null) {
        setState(() {
          _selectedUnsafeZoneId = null;
          _selectedResponderUid = null;
        });
      }
      return;
    }

    UnsafeZone? nearestZone;
    double nearestDistance = double.infinity;

    for (final zone in visibleZones) {
      final distance = Geolocator.distanceBetween(
        point.latitude,
        point.longitude,
        zone.point.latitude,
        zone.point.longitude,
      );
      if (distance <= _unsafeZoneRadiusMeters && distance < nearestDistance) {
        nearestZone = zone;
        nearestDistance = distance;
      }
    }

    if (nearestZone == null) {
      if (_selectedUnsafeZoneId != null || _selectedResponderUid != null) {
        setState(() {
          _selectedUnsafeZoneId = null;
          _selectedResponderUid = null;
        });
      }
      return;
    }

    final selectedZone = nearestZone;
    setState(() {
      _selectedUnsafeZoneId = selectedZone.id;
    });
    _showUnsafeZoneDetails(selectedZone);
  }

  String? _findTappedResponderRoute(LatLng tapPoint) {
    String? nearestUid;
    var nearestDistance = double.infinity;

    for (final route in _responderRoutes.values) {
      final points = route.route.points;
      if (points.length < 2) continue;

      for (var i = 0; i < points.length - 1; i++) {
        final distance = JourneySafetyService.distanceToSegmentMeters(
          tapPoint,
          points[i],
          points[i + 1],
        );
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearestUid = route.uid;
        }
      }
    }

    if (nearestDistance <= _routeTapThresholdMeters) {
      return nearestUid;
    }
    return null;
  }

  void _showUnsafeZoneDetails(UnsafeZone zone) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isUnsafeNow = _isCurrentlyUnsafe(zone.timeStart, zone.timeEnd);
        final isNightRange = _isNightRange(zone.timeStart, zone.timeEnd);
        final reasonLabel = _formatReason(zone.reason);
        final subtitle =
            'Unsafe from '
            '${_formatZoneTime(zone.timeStart)} to ${_formatZoneTime(zone.timeEnd)}';

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                  bottom: Radius.circular(28),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 24,
                    offset: Offset(0, 12),
                  ),
                ],
                border: Border.all(color: Colors.red.withOpacity(0.14)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.warning_amber_rounded,
                          color: Colors.redAccent,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Unsafe Area',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              zone.areaName ?? 'Community reported zone',
                              style: TextStyle(
                                fontSize: 13,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (reasonLabel != null) ...[
                    Text(
                      reasonLabel,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (isUnsafeNow)
                        _UnsafeInfoChip(
                          label: 'Currently Unsafe Now',
                          foregroundColor: Colors.red.shade800,
                          backgroundColor: Colors.red.shade50,
                        ),
                      if (isNightRange)
                        _UnsafeInfoChip(
                          label: 'Usually unsafe at night',
                          foregroundColor: Colors.deepPurple.shade700,
                          backgroundColor: Colors.deepPurple.shade50,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _selectedUnsafeZoneId = null;
        });
      }
    });
  }

  String? _formatReason(String? reason) {
    if (reason == null || reason.trim().isEmpty) {
      return null;
    }

    switch (reason) {
      case 'poor_lighting':
      case 'Poor lighting':
        return 'Poor lighting';
      case 'harassment':
      case 'Harassment':
        return 'Harassment';
      case 'isolated_area':
      case 'Isolated area':
        return 'Isolated area';
      default:
        return reason
            .replaceAll('_', ' ')
            .split(' ')
            .where((word) => word.isNotEmpty)
            .map(
              (word) =>
                  '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}',
            )
            .join(' ');
    }
  }

  String _formatZoneTime(String value) {
    final parsed = TimeOfDayFormatUtil.tryParse(value);
    if (parsed == null) {
      return value;
    }
    return parsed.format(context);
  }

  bool _isCurrentlyUnsafe(String start, String end) {
    final startTime = TimeOfDayFormatUtil.tryParse(start);
    final endTime = TimeOfDayFormatUtil.tryParse(end);
    if (startTime == null || endTime == null) {
      return false;
    }

    final now = TimeOfDay.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = startTime.hour * 60 + startTime.minute;
    final endMinutes = endTime.hour * 60 + endTime.minute;

    if (startMinutes <= endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes <= endMinutes;
    }

    return nowMinutes >= startMinutes || nowMinutes <= endMinutes;
  }

  bool _isNightRange(String start, String end) {
    final startTime = TimeOfDayFormatUtil.tryParse(start);
    final endTime = TimeOfDayFormatUtil.tryParse(end);
    if (startTime == null || endTime == null) {
      return false;
    }

    final startMinutes = startTime.hour * 60 + startTime.minute;
    final endMinutes = endTime.hour * 60 + endTime.minute;
    return startMinutes >= 18 * 60 ||
        endMinutes <= 6 * 60 ||
        startMinutes > endMinutes;
  }

  void _selectResponderRoute(String uid) {
    setState(() {
      _selectedResponderUid = uid;
    });
  }

  Future<void> _confirmLeaveRescue() async {
    final shouldLeave = await Get.dialog<bool>(
      AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Leave Rescue?'),
        content: const Text(
          'You will stop assisting this SOS and stop sharing your live location.',
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Get.back(result: true),
            child: const Text('Leave Rescue'),
          ),
        ],
      ),
    );

    if (shouldLeave != true) return;

    final success = await SosListenerController.instance.leaveRescueSession();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'You left the rescue session'
              : 'Unable to leave rescue. Please try again.',
        ),
        backgroundColor: success ? null : Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// Dedicated Widget handling local repetitive animation states cleanly
class _PulsingSosButton extends StatefulWidget {
  final VoidCallback onPressed;

  const _PulsingSosButton({required this.onPressed});

  @override
  _PulsingSosButtonState createState() => _PulsingSosButtonState();
}

class _PulsingSosButtonState extends State<_PulsingSosButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    // 1-second pulse bounding looping infinitely
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _animation = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _animation,
      child: FloatingActionButton(
        heroTag: 'sosBtnAnimated',
        onPressed: widget.onPressed,
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        elevation: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        child: const Icon(Icons.sos, size: 28, weight: 800),
      ),
    );
  }
}

class _RouteSummaryCard extends StatelessWidget {
  const _RouteSummaryCard({
    required this.distanceLabel,
    required this.durationLabel,
    required this.destinationName,
    required this.onLeaveRescue,
    required this.onShareInvite,
    required this.joinedViaInvite,
  });

  final String distanceLabel;
  final String durationLabel;
  final String destinationName;
  final VoidCallback onLeaveRescue;
  final Future<void> Function()? onShareInvite;
  final bool joinedViaInvite;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            colors: [
              colorScheme.primaryContainer.withOpacity(0.96),
              const Color(0xFFD14B7A).withOpacity(0.94),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 18,
              offset: Offset(0, 10),
            ),
          ],
          border: Border.all(color: Colors.white.withOpacity(0.2), width: 1),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.shield_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Safe Route Active',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _RouteMetricChip(
                  icon: Icons.route_rounded,
                  label: distanceLabel,
                ),
                _RouteMetricChip(
                  icon: Icons.schedule_rounded,
                  label: durationLabel,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              destinationName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            if (joinedViaInvite) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  'Joined via Rescue Invite',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (onShareInvite != null)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => onShareInvite?.call(),
                      icon: const Icon(Icons.group_add, color: Colors.white),
                      label: const Text(
                        'Invite Helper',
                        style: TextStyle(color: Colors.white),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.white.withOpacity(0.4)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                if (onShareInvite != null) const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onLeaveRescue,
                    icon: const Icon(Icons.exit_to_app, color: Colors.white),
                    label: const Text(
                      'Leave Rescue',
                      style: TextStyle(color: Colors.white),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.white.withOpacity(0.55)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteMetricChip extends StatelessWidget {
  const _RouteMetricChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBarStatusChip extends StatelessWidget {
  const _TopBarStatusChip({
    required this.label,
    required this.icon,
    required this.accentColor,
    required this.isEnabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color accentColor;
  final bool isEnabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(isEnabled ? 0.18 : 0.1),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: accentColor.withOpacity(isEnabled ? 0.55 : 0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: accentColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ControlToggleTile extends StatelessWidget {
  const _ControlToggleTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest.withOpacity(0.4),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _UnsafeInfoChip extends StatelessWidget {
  const _UnsafeInfoChip({
    required this.label,
    required this.foregroundColor,
    required this.backgroundColor,
  });

  final String label;
  final Color foregroundColor;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: foregroundColor,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _RescueStatsBanner extends StatelessWidget {
  const _RescueStatsBanner({required this.totalLabel, this.personalLabel});

  final String totalLabel;
  final String? personalLabel;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: true,
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.72),
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [
              BoxShadow(
                color: Color(0x22000000),
                blurRadius: 16,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                totalLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (personalLabel != null) ...[
                const SizedBox(height: 4),
                Text(
                  personalLabel!,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ResponderRouteInfo {
  const _ResponderRouteInfo({
    required this.uid,
    required this.displayName,
    required this.currentLocation,
    required this.victimLocation,
    required this.route,
    required this.status,
  });

  final String uid;
  final String displayName;
  final LatLng currentLocation;
  final LatLng victimLocation;
  final _ResponderRouteData route;
  final String status;
}

class _ResponderRouteData {
  const _ResponderRouteData({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
}

class _CachedResponderRoute {
  const _CachedResponderRoute({
    required this.start,
    required this.victim,
    required this.data,
  });

  final LatLng start;
  final LatLng victim;
  final _ResponderRouteData data;
}

class _JourneyRouteBuildResult {
  const _JourneyRouteBuildResult({required this.route, this.warningMessage});

  final RouteSummary route;
  final String? warningMessage;
}

class _ResponderRouteCard extends StatelessWidget {
  const _ResponderRouteCard({
    required this.route,
    required this.isSelected,
    required this.onClose,
  });

  final _ResponderRouteInfo route;
  final bool isSelected;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final routeColor = _routeColorForUid(route.uid);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: [
              Colors.grey.shade900.withOpacity(0.96),
              routeColor.withOpacity(0.92),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33000000),
              blurRadius: 18,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isSelected ? Icons.shield : Icons.shield_outlined,
                  color: Colors.white,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Savior ${route.displayName}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'ETA: ${_formatMinutes(route.route.durationSeconds)}',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            Text(
              'Distance: ${_formatDistanceMeters(route.route.distanceMeters)}',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            Text(
              'Status: ${route.status}',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatMinutes(double durationSeconds) {
  final minutes = (durationSeconds / 60).ceil();
  return minutes <= 1 ? '1 min' : '$minutes min';
}

String _formatDistanceMeters(double distanceMeters) {
  if (distanceMeters >= 1000) {
    return '${(distanceMeters / 1000).toStringAsFixed(distanceMeters >= 10000 ? 0 : 1)} km';
  }
  return '${distanceMeters.round()} m';
}

Color _routeColorForUid(String uid) {
  final palette = [
    Colors.blue,
    Colors.green,
    Colors.teal,
    Colors.indigo,
    Colors.blueAccent,
    Colors.lightBlue,
  ];
  return palette[uid.hashCode.abs() % palette.length];
}

enum _AppMenuAction {
  emergencyContacts,
  sosTimer,
  editProfile,
  history,
  logout,
}

class _RiskLevelIndicator extends StatelessWidget {
  final double score;
  final bool intersectsDangerZone;

  const _RiskLevelIndicator({
    required this.score,
    this.intersectsDangerZone = false,
  });

  @override
  Widget build(BuildContext context) {
    Color riskColor;
    if (score <= 30) {
      riskColor = Colors.green;
    } else if (score <= 60) {
      riskColor = Colors.orange;
    } else {
      riskColor = Colors.redAccent;
    }

    final label = score <= 30
        ? 'Low'
        : score <= 60
        ? 'Moderate'
        : 'High';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor.withOpacity(0.95),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
        border: Border.all(color: riskColor.withOpacity(0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: riskColor,
                  boxShadow: [
                    BoxShadow(
                      color: riskColor.withOpacity(0.4),
                      blurRadius: 4,
                      spreadRadius: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                "Risk: ${score.toInt()}",
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              intersectsDangerZone
                  ? '$label • Route intersects unsafe area'
                  : label,
              style: TextStyle(
                color: riskColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (score > 60 && !intersectsDangerZone)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                "High Risk Area",
                style: TextStyle(
                  color: Colors.redAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SaviorBottomControlCard extends StatelessWidget {
  const _SaviorBottomControlCard({
    required this.onShareInvite,
    required this.onLeaveRescue,
    required this.joinedViaInvite,
  });

  final VoidCallback onShareInvite;
  final VoidCallback onLeaveRescue;
  final bool joinedViaInvite;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      color: const Color(0xFF1E1E2C),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.shield_moon_rounded,
                    color: Colors.redAccent,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Savior Interface Active',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        joinedViaInvite
                            ? 'Joined via Rescue Dynamic Link'
                            : 'Assisting active SOS session',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onShareInvite,
                    icon: const Icon(Icons.group_add, color: Colors.white),
                    label: const Text(
                      'Share Session',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFD14B7A),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: onLeaveRescue,
                  icon: const Icon(Icons.exit_to_app, color: Colors.white),
                  label: const Text(
                    'Leave',
                    style: TextStyle(color: Colors.white),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.white.withOpacity(0.4)),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 14,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

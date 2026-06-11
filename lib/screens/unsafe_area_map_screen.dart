import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:get/get.dart';
import 'package:latlong2/latlong.dart';

import '../controllers/sos_heatmap_controller.dart';

class UnsafeAreaMapScreen extends StatefulWidget {
  const UnsafeAreaMapScreen({super.key});

  @override
  State<UnsafeAreaMapScreen> createState() => _UnsafeAreaMapScreenState();
}

class _UnsafeAreaMapScreenState extends State<UnsafeAreaMapScreen> {
  final SosHeatmapController _heatmapController =
      Get.isRegistered<SosHeatmapController>()
      ? Get.find<SosHeatmapController>()
      : Get.put(SosHeatmapController());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS Safety Heatmap')),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(
              initialCenter: const LatLng(28.6139, 77.2090),
              initialZoom: 13.5,
              onPositionChanged: (position, hasGesture) {
                final bounds = position.visibleBounds;
                final zoom = position.zoom;
                _heatmapController.refreshForViewport(bounds: bounds, zoom: zoom);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'safe_route',
              ),
              Obx(
                () => CircleLayer(circles: _heatmapController.buildCircleMarkers()),
              ),
            ],
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Obx(
              () => Card(
                child: SwitchListTile(
                  title: const Text('Show Safety Heatmap'),
                  subtitle: Text(
                    _heatmapController.isLoading.value
                        ? 'Loading visible SOS events...'
                        : 'Red: high density • Yellow: medium • Green: low',
                  ),
                  value: _heatmapController.isVisible.value,
                  onChanged: _heatmapController.toggleVisibility,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

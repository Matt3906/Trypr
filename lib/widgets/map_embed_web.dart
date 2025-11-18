// Web implementation: injects Leaflet (CDN) and registers an HtmlElementView
// that contains a Leaflet map with markers for the provided points.
// This file is only imported on web via conditional imports in `map_embed.dart`.

import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui'
    as ui; // platformViewRegistry available at runtime for registering HtmlElementView

import 'package:flutter/widgets.dart';

class MapEmbed extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  const MapEmbed({super.key, required this.points});

  @override
  Widget build(BuildContext context) {
    final viewId = 'leaflet-map-${DateTime.now().microsecondsSinceEpoch}';

    // Register the view factory that will create the DOM element.
    // ignore: undefined_prefixed_name
    ui.platformViewRegistry.registerViewFactory(viewId, (int viewId) {
      final container = html.DivElement();
      container.style.width = '100%';
      container.style.height = '100%';

      // Inject Leaflet CSS if not present
      if (html.document.getElementById('leaflet-css') == null) {
        final link =
            html.LinkElement()
              ..id = 'leaflet-css'
              ..rel = 'stylesheet'
              ..href = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css';
        html.document.head!.append(link);
      }

      // Ensure container has an id for the initialization script
      if (container.id.isEmpty)
        container.id =
            'leaflet-container-${DateTime.now().microsecondsSinceEpoch}';

      // Inject Leaflet JS if not present, then initialize map
      void initLeaflet() {
        try {
          final ptsJson = jsonEncode(points);
          final script = html.ScriptElement();
          script.type = 'text/javascript';
          script.text = '''(function(elId, points){
            var el = document.getElementById(elId);
            el.style.height = '100%';
            try {
              var map = L.map(el).setView([0,0], 2);
              L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {maxZoom: 19, attribution: '© OpenStreetMap'}).addTo(map);
              var markers = [];
              for (var i=0;i<points.length;i++){
                var p = points[i];
                var marker = L.marker([p.lat, p.lon]).addTo(map).bindPopup(p.name || '');
                markers.push(marker);
              }
              if (markers.length>0){
                var group = new L.featureGroup(markers);
                map.fitBounds(group.getBounds().pad(0.2));
              }
            } catch(e) { console.log('leaflet init err', e); }
          })("${container.id}", $ptsJson);''';
          html.document.body!.append(script);
        } catch (e) {
          // ignore
        }
      }

      // Always append Leaflet JS and initialize on load.
      final s =
          html.ScriptElement()
            ..src = 'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js'
            ..async = true;
      s.onLoad.listen((_) => initLeaflet());
      html.document.body!.append(s);

      return container;
    });

    return HtmlElementView(viewType: viewId);
  }
}

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

class EarthSrcdoc {
  static const String _earthIndexAssetPath = 'web/earth/index.html';

  static Future<String> build({required String mapsApiKey}) async {
    final indexHtml = await rootBundle.loadString(_earthIndexAssetPath);

    final jsFile = _extractFirstGroup(indexHtml, [
      RegExp(r'src="/earth/assets/([^"]+\\.js)"'),
      RegExp(r'src="./assets/([^"]+\\.js)"'),
      RegExp(r"src='\.\/assets\/([^']+\.js)'"),
    ]);
    final cssFile = _extractFirstGroup(indexHtml, [
      RegExp(r'href="/earth/assets/([^"]+\\.css)"'),
      RegExp(r'href="./assets/([^"]+\\.css)"'),
      RegExp(r"href='\.\/assets\/([^']+\.css)'"),
    ]);

    final js = await rootBundle.loadString('web/earth/assets/$jsFile');
    final css = await rootBundle.loadString('web/earth/assets/$cssFile');

    final escapedKey = const HtmlEscape().convert(mapsApiKey);

    return _buildHtml(
      mapsApiKey: escapedKey,
      css: _sanitizeForTag(css, closingTag: '</style>'),
      js: _sanitizeForTag(js, closingTag: '</script>'),
    );
  }

  static String _extractFirstGroup(String input, List<RegExp> patterns) {
    for (final pattern in patterns) {
      final match = pattern.firstMatch(input);
      if (match != null && match.groupCount >= 1 && match.group(1) != null) {
        return match.group(1)!;
      }
    }
    throw StateError('Failed to locate Earth asset reference in index.html');
  }

  static String _sanitizeForTag(String content, {required String closingTag}) {
    // Prevent accidental early-termination of the surrounding tag.
    return content.replaceAll(closingTag, closingTag.replaceFirst('/', r'\\/'));
  }

  static String _buildHtml({
    required String mapsApiKey,
    required String css,
    required String js,
  }) {
    // Keep this minimal: the Vite output expects a #root div.
    // Google Maps JS API is loaded via the importLibrary bootstrap snippet.
    const googleMapsLoader = r'''
      (g=>{var h,a,k,p="The Google Maps JavaScript API",c="google",l="importLibrary",q="__ib__",m=document,b=window;b=b[c]||(b[c]={}); var d=b.maps||(b.maps={}),r=new Set,e=new URLSearchParams,u=()=>h||(h=new Promise(async(f,n)=>{await (a=m.createElement("script"));e.set("libraries",[...r]+"");for(k in g)e.set(k.replace(/[A-Z]/g,t=>"_"+t[0].toLowerCase()),g[k]);e.set("callback",c+".maps."+q);a.src=`https://maps.${c}apis.com/maps/api/js?`+e;d[q]=f;a.onerror=()=>h=n(Error(p+" could not load."));a.nonce=m.querySelector("script[nonce]")?.nonce||"";m.head.append(a)}));d[l]?console.warn(p+" only loads once. Ignoring:",g):d[l]=(f,...n)=>r.add(f)&&u().then(()=>d[l](f,...n))})
        ({key: (document.querySelector('meta[name="google-maps-api-key"]')?.getAttribute('content') || ''), v: "weekly"});
    ''';

    return '''<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="google-maps-api-key" content="$mapsApiKey" />
    <title>Trypr Earth</title>
    <script>
      // The Earth bundle checks window.location.search for embed=true.
      // When using iframe srcdoc there's no real URL, so we synthesize one.
      try { history.replaceState(null, '', '/?embed=true'); } catch (_) {}
    </script>
    <style>
$css
    </style>
    <script>
      $googleMapsLoader
    </script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module">
$js
    </script>
  </body>
</html>
''';
  }
}

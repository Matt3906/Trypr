class LocationDisplay {
  final String title;
  final String subtitle;

  const LocationDisplay({required this.title, required this.subtitle});
}

final RegExp _caPostal = RegExp(
  r'\b[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTVXY][ -]?\d[ABCEGHJ-NPRSTVXY]\d\b',
  caseSensitive: false,
);
final RegExp _usZip = RegExp(r'\b\d{5}(-\d{4})?\b');
final RegExp _looksNumeric = RegExp(r'^\d+[A-Za-z]?$');

const Map<String, String> _provinceToAbbr = {
  // Canada
  'alberta': 'AB',
  'british columbia': 'BC',
  'manitoba': 'MB',
  'new brunswick': 'NB',
  'newfoundland and labrador': 'NL',
  'newfoundland': 'NL',
  'labrador': 'NL',
  'northwest territories': 'NT',
  'nova scotia': 'NS',
  'nunavut': 'NU',
  'ontario': 'ON',
  'prince edward island': 'PE',
  'quebec': 'QC',
  'saskatchewan': 'SK',
  'yukon': 'YT',

  // US (common)
  'alabama': 'AL',
  'alaska': 'AK',
  'arizona': 'AZ',
  'arkansas': 'AR',
  'california': 'CA',
  'colorado': 'CO',
  'connecticut': 'CT',
  'delaware': 'DE',
  'district of columbia': 'DC',
  'florida': 'FL',
  'georgia': 'GA',
  'hawaii': 'HI',
  'idaho': 'ID',
  'illinois': 'IL',
  'indiana': 'IN',
  'iowa': 'IA',
  'kansas': 'KS',
  'kentucky': 'KY',
  'louisiana': 'LA',
  'maine': 'ME',
  'maryland': 'MD',
  'massachusetts': 'MA',
  'michigan': 'MI',
  'minnesota': 'MN',
  'mississippi': 'MS',
  'missouri': 'MO',
  'montana': 'MT',
  'nebraska': 'NE',
  'nevada': 'NV',
  'new hampshire': 'NH',
  'new jersey': 'NJ',
  'new mexico': 'NM',
  'new york': 'NY',
  'north carolina': 'NC',
  'north dakota': 'ND',
  'ohio': 'OH',
  'oklahoma': 'OK',
  'oregon': 'OR',
  'pennsylvania': 'PA',
  'rhode island': 'RI',
  'south carolina': 'SC',
  'south dakota': 'SD',
  'tennessee': 'TN',
  'texas': 'TX',
  'utah': 'UT',
  'vermont': 'VT',
  'virginia': 'VA',
  'washington': 'WA',
  'west virginia': 'WV',
  'wisconsin': 'WI',
  'wyoming': 'WY',
};

String _normalizeToken(String s) => s.trim().replaceAll(RegExp(r'\s+'), ' ');

bool _isPostal(String token) {
  final t = token.trim();
  return _caPostal.hasMatch(t) || _usZip.hasMatch(t);
}

bool _isNoiseAdmin(String token) {
  final t = token.toLowerCase();
  // Explicitly strip these.
  if (RegExp(r'\b(district|county|region)\b', caseSensitive: false)
      .hasMatch(t)) {
    return true;
  }

  // Common "clutter" admin/area descriptors that often appear between city and
  // province/state in geocoder strings.
  return RegExp(
    r'\b(horseshoe|metropolitan|metro|greater|area|census division)\b',
    caseSensitive: false,
  ).hasMatch(t);
}

bool _isCountry(String token) {
  final t = token.toLowerCase();
  return t == 'canada' || t == 'united states' || t == 'usa' || t == 'us';
}

String _abbrProvince(String token) {
  final norm = token.trim();
  final lower = norm.toLowerCase();
  if (_provinceToAbbr.containsKey(lower)) return _provinceToAbbr[lower]!;

  // Already abbreviated.
  final stripped = norm.replaceAll('.', '').trim();
  if (stripped.length == 2 && RegExp(r'^[A-Za-z]{2}$').hasMatch(stripped)) {
    return stripped.toUpperCase();
  }
  return norm;
}

String _abbrStreetSuffix(String street) {
  // Abbreviate last word only.
  final s = street.trim();
  final parts = s.split(RegExp(r'\s+'));
  if (parts.isEmpty) return s;

  final last = parts.last.toLowerCase();
  const suffix = {
    'boulevard': 'Blvd',
    'avenue': 'Ave',
    'street': 'St',
    'road': 'Rd',
    'drive': 'Dr',
    'lane': 'Ln',
    'court': 'Ct',
    'place': 'Pl',
    'terrace': 'Ter',
    'highway': 'Hwy',
    'trail': 'Trl',
    'circle': 'Cir',
  };

  final ab = suffix[last];
  if (ab == null) return s;

  parts[parts.length - 1] = ab;
  return parts.join(' ');
}

/// "Clean but Verified" formatter.
///
/// - Title: Place name (preferred). If none, street address.
/// - Subtitle: [Street Address] (if not used in title), [City], [Prov/State]
/// - Strips: District/County/Region and postal codes.
LocationDisplay formatLocationDisplay({String? placeName, String? raw}) {
  final rawText = (raw ?? '').trim();
  final pn = (placeName ?? '').trim();

  if (rawText.isEmpty && pn.isEmpty) {
    return const LocationDisplay(title: '', subtitle: '');
  }

  // Split by comma (Nominatim / many formatted addresses).
  final tokens = rawText
      .split(',')
      .map(_normalizeToken)
      .where((t) => t.isNotEmpty)
      .where((t) => !_isCountry(t))
      .where((t) => !_isNoiseAdmin(t))
      .where((t) => !_isPostal(t))
      .toList();

  // Deduplicate sequential repeats.
  final cleaned = <String>[];
  for (final t in tokens) {
    if (cleaned.isNotEmpty && cleaned.last.toLowerCase() == t.toLowerCase()) {
      continue;
    }
    cleaned.add(t);
  }

  // Heuristic: place name candidate.
  String place = '';
  if (pn.isNotEmpty && !pn.contains(',')) {
    place = pn;
  } else if (cleaned.length >= 3 && !_looksNumeric.hasMatch(cleaned.first)) {
    // If the next token looks like a civic number, treat the first token as place.
    if (_looksNumeric.hasMatch(cleaned[1])) {
      place = cleaned.first;
    }
  }

  // Find province/state from the end.
  String prov = '';
  int provIndex = -1;
  for (var i = cleaned.length - 1; i >= 0; i--) {
    final ab = _abbrProvince(cleaned[i]);
    if (ab.length == 2 && RegExp(r'^[A-Z]{2}$').hasMatch(ab)) {
      prov = ab;
      provIndex = i;
      break;
    }
    // If token is a known full province/state name.
    if (_provinceToAbbr.containsKey(cleaned[i].toLowerCase())) {
      prov = _abbrProvince(cleaned[i]);
      provIndex = i;
      break;
    }
  }

  String city = '';
  if (provIndex > 0) {
    for (var i = provIndex - 1; i >= 0; i--) {
      final t = cleaned[i];
      if (_isNoiseAdmin(t) || _isPostal(t) || _isCountry(t)) continue;
      city = t;
      break;
    }
  } else if (cleaned.length >= 2) {
    // Fallback: assume last is province-like and previous is city.
    city = cleaned.last;
  }

  // Street address: prefer civic number + road name.
  String street = '';
  if (cleaned.length >= 2) {
    if (place.isNotEmpty) {
      // Use tokens after place.
      final after = cleaned.skip(1).toList();
      if (after.isNotEmpty && _looksNumeric.hasMatch(after.first)) {
        final num = after.first;
        final road = after.length >= 2 ? after[1] : '';
        street = _normalizeToken([num, road].where((s) => s.isNotEmpty).join(' '));
      } else {
        street = after.first;
      }
    } else {
      if (_looksNumeric.hasMatch(cleaned.first)) {
        final num = cleaned.first;
        final road = cleaned.length >= 2 ? cleaned[1] : '';
        street = _normalizeToken([num, road].where((s) => s.isNotEmpty).join(' '));
      }
    }
  }
  if (street.isNotEmpty) street = _abbrStreetSuffix(street);

  // Title selection.
  final title = (place.isNotEmpty ? place : (street.isNotEmpty ? street : (cleaned.isNotEmpty ? cleaned.first : pn))).trim();

  // Subtitle assembly.
  final subParts = <String>[];
  if (street.isNotEmpty && title.toLowerCase() != street.toLowerCase()) {
    subParts.add(street);
  }
  if (city.isNotEmpty && city.toLowerCase() != title.toLowerCase()) {
    subParts.add(city);
  }
  if (prov.isNotEmpty) {
    subParts.add(prov);
  }

  return LocationDisplay(title: title, subtitle: subParts.join(', '));
}

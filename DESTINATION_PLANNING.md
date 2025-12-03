# Trip Planning Features - Destination Detail System

## Overview

The new destination planning system enables users to create rigorous, detailed itineraries for each destination in their trips. Users can plan accommodations, create daily schedules, track activities, and leverage AI assistance for recommendations.

## Key Features

### 1. **Destination Detail Screen** (`destination_detail_screen.dart`)
A comprehensive multi-tab interface for planning a single destination with four main sections:

#### Tab 1: Accommodations
- **Add/Edit Hotels**: Store accommodation details including:
  - Hotel/accommodation name
  - Address
  - Price per night
  - Check-in date
  - Notes (booking reference, amenities, etc.)
- **View All Stays**: Quick overview of all accommodations planned for the destination
- **Budget Tracking**: See total accommodation costs at a glance

#### Tab 2: Daily Itinerary
- **Day-by-Day Planning**: Create a structured itinerary with one entry per day
- **Each Day Includes**:
  - Day title (e.g., "Day 1: Exploration")
  - Overview/notes
  - Time-based activities with:
    - Activity name
    - Time slot (e.g., "09:00 AM - 01:00 PM")
    - Description
- **Timeline View**: Visual timeline of all planned activities
- **Edit/Delete**: Modify or remove days and activities as needed

#### Tab 3: Activities & Things to Do
- **Add Custom Activities**: Build a "bucket list" of things to experience
- **Activity Details**:
  - Activity name
  - Description
  - Category (Museum, Park, Restaurant, etc.)
  - Rating (user input or AI-generated)
- **Browse & Organize**: Quick reference of all local attractions and activities

#### Tab 4: AI Trip Planner Assistant
- **AI-Powered Recommendations**: Get suggestions for:
  - **Accommodations**: Hotels, hostels, boutique stays with ratings
  - **Restaurants**: Dining options and cuisine recommendations
  - **Attractions**: Must-see places and activities
  - **Itineraries**: AI-generated daily schedules
  - **Custom Questions**: Ask anything specific about the destination
- **One-Click Integration**: Select recommendations to automatically add them to the plan
- **Backend Integration Ready**: Placeholder for connecting to OpenAI, Google Gemini, or custom backend

### 2. **Trip Detail Integration**
- **Clickable Destinations**: In the trip detail screen, each waypoint is now an interactive card showing:
  - Destination name
  - Coordinates
  - Quick stats: number of accommodations, days planned
- **Direct Navigation**: Click any destination to open its planning interface
- **Live Updates**: Changes in the destination planner automatically sync to the trip

### 3. **Planning Widgets** (`destination_planning_widgets.dart`)
Reusable UI components for dashboard and summary views:

- **DestinationStatsCard**: Quick metrics display (accommodations, activities, days)
- **BudgetTrackerWidget**: Real-time budget monitoring with progress bars
- **DailyChecklistWidget**: Track completed activities and tasks
- **LocationPreviewCard**: Show destination with image and coordinates
- **TimelineActivityWidget**: Visual timeline of daily activities

## Data Structure

### Destination Object Schema
```dart
{
  'name': 'Paris',
  'lat': 48.8566,
  'lon': 2.3522,
  'accommodations': [
    {
      'name': 'Hotel Name',
      'address': '123 Main St',
      'price': 150.0,
      'checkIn': '2024-03-15',
      'notes': 'Booking ref: ABC123'
    }
  ],
  'itinerary': [
    {
      'title': 'Day 1: City Exploration',
      'notes': 'General overview of the day',
      'activities': [
        {
          'title': 'Eiffel Tower',
          'time': '09:00 AM - 12:00 PM',
          'description': 'Visit and climb the Eiffel Tower'
        }
      ]
    }
  ],
  'things_to_do': [
    {
      'name': 'Louvre Museum',
      'description': 'World-famous art museum',
      'category': 'Museum',
      'rating': 4.8
    }
  ]
}
```

## User Workflows

### Planning a New Destination
1. Open trip detail → Click on a destination card
2. Go to **Accommodations** tab → Add hotels/stays
3. Go to **Itinerary** tab → Create daily plans with activities
4. Go to **Activities** tab → Add bucket list items
5. (Optional) Use **AI Assist** tab for recommendations
6. Click **Save** to persist all changes

### Using AI Assistant
1. Open destination → Click **AI Assist** tab
2. Choose a recommendation type (Hotels, Restaurants, etc.)
3. Optionally customize the query
4. Review AI suggestions
5. Click **Add** on recommended items to integrate into your plan
6. Save changes

### Editing Existing Plans
1. Destination detail is always editable
2. Modify text fields directly
3. Use **Delete** icons to remove items
4. Changes auto-save when you click the top-right **Save** button

## AI Integration Notes

### Current Implementation
- **Mock Data**: Placeholder recommendations with 1-second delay
- **Backend Endpoint**: Ready for connection to:
  - OpenAI GPT-4 API
  - Google Gemini API
  - Custom Node.js/Python backend
  - Llama/Local LLM service

### To Integrate Real AI:
1. Update `_generateRecommendations()` in `AIAssistantSheet`
2. Replace mock data with actual API calls:
```dart
final response = await http.post(
  Uri.parse('https://your-backend.com/api/recommendations'),
  headers: {'Content-Type': 'application/json'},
  body: jsonEncode({
    'destination': widget.destination,
    'type': widget.mode,
    'query': _queryCtrl.text,
  }),
);
```
3. Parse and display results from your backend

## Features & Benefits

✅ **Comprehensive Planning**: All destination details in one place  
✅ **Daily Granularity**: Plan activities hour-by-hour per location  
✅ **Budget Awareness**: Track accommodation costs automatically  
✅ **AI-Enhanced**: Get intelligent recommendations for stays, food, and attractions  
✅ **Reusable Widgets**: Dashboard components for quick summaries  
✅ **Firestore Integration**: All data persists to your trip document  
✅ **Collaborative**: Shared trips support multi-user editing  
✅ **Flexible**: Users can edit at any time; local changes sync to cloud  

## Future Enhancements

- 📍 Map integration for visual itinerary planning
- 💳 Restaurant/booking reservation links
- 📱 Mobile-optimized AI chat interface
- 🎨 Itinerary export to PDF/images
- 🌐 Multi-language AI recommendations
- ⭐ User ratings/reviews of accommodations
- 🔗 Integration with booking platforms (Airbnb, Hotels.com, etc.)

## File Reference

| File | Purpose |
|------|---------|
| `lib/screens/destination_detail_screen.dart` | Main destination planning UI |
| `lib/widgets/destination_planning_widgets.dart` | Reusable planning components |
| `lib/screens/trip_detail_screen.dart` | Updated to show clickable destinations |
| `lib/widgets/modern_widgets.dart` | GradientButton, GlassCard, AvatarRing |

## Usage Example

```dart
// Open destination planning from trip detail
await Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => DestinationDetailScreen(
      tripId: tripId,
      destinationIndex: 0,
      destination: waypoints[0],
      tripRef: tripRefPath,
    ),
  ),
);
```

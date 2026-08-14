# Anemos - Flutter App

The Flutter web/mobile front end for Anemos: an AI travel
planner that turns a conversation into a day-by-day itinerary with routes,
places, bookings, and a live trip view. Route optimization (Nearest
Neighbor + 2-Opt) is baked into itinerary creation server-side rather than
exposed as a separate tool.

## Screenshots

> Note: This is a functional demo app. In a production version, you would add screenshots here showing the beautiful UI.

## Getting Started

### Prerequisites

- Flutter SDK (latest stable version)
- Go API server running (see `../api/README.md`)
- iOS Simulator / Android Emulator or physical device

### Installation

1. **Navigate to the Flutter app directory**:
   ```bash
   cd src/packages/flutter-app
   ```

2. **Install dependencies**:
   ```bash
   flutter pub get
   ```

3. **Start the Go API server** (in another terminal):
   ```bash
   cd ../api
   go run .
   ```

4. **Run the app**:
   ```bash
   flutter run
   ```

### API Configuration

With Docker (`make docker-dev` or `make docker-deploy`), the app uses `/api/v1` via the gateway at `http://localhost:3000`. For local `flutter run` without Docker, the default is `http://localhost:8080/api/v1`. To change this:

1. Edit `lib/services/api_client.dart`
2. Update the `_baseUrl` constant to your API server address

## Architecture

### State Management
- **Riverpod**: Modern, type-safe state management with excellent developer experience
- **Provider Pattern**: Clean separation of business logic and UI components

### Project Structure
```
lib/
├── main.dart                    # App entry point
├── models/                      # Data models (matching Go API structs)
│   ├── location.dart           # Location and operating hours models
│   └── route_request.dart      # Travel-times request/response models
├── services/
│   └── api_client.dart         # HTTP client for API communication
├── providers/                  # Riverpod state providers (one per feature)
├── screens/                    # Main app screens (home, plan chat, trips,
│   └── ...                     #   trip detail, flight search, guides, …)
└── widgets/                    # Reusable UI components
```

### Key Features
- **Type-Safe Models**: Auto-generated JSON serialization matching Go API structs
- **Error Handling**: Comprehensive error handling with user-friendly messages
- **Loading States**: Beautiful loading indicators and smooth UX
- **Form Validation**: Input validation with helpful error messages
- **Material Design 3**: Modern, accessible UI following Material Design guidelines

## API Integration

The app integrates with the following Go API endpoints:

### Route Optimization (travel times)
```
POST /api/v1/optimize-route
```
Powers the trip detail's between-stop travel times (preserve-order mode).
**Request**: List of locations with coordinates, categories, operating hours
**Response**: Route timing details and distance metrics

### Health Check
```
GET /api/v1/health
```
**Response**: API health status

## Development

### Code Generation
When you modify models, regenerate JSON serialization:
```bash
dart run build_runner build
```

### Testing
Run tests:
```bash
flutter test
```

### Analysis
Check code quality:
```bash
flutter analyze
```

## Example Usage

### Country Planning Example  
1. Add countries with capitals and coordinates
2. Set ideal travel seasons and months to avoid
3. Configure minimum stay durations
4. Set trip start date and total duration
5. Choose optimization strategy (distance/season/balanced)
6. Tap "Optimize Trip" to get optimized itinerary

## Built With

- **Flutter**: Google's UI toolkit for beautiful, natively compiled mobile apps
- **Riverpod**: Modern state management for Flutter
- **Material Design 3**: Latest design system for intuitive user interfaces
- **HTTP Package**: For seamless API communication
- **JSON Serialization**: Type-safe model generation and API integration

## Contributing

This is a demo application showcasing Flutter + Go API integration. In a production environment, you would:

1. Add comprehensive unit and integration tests
2. Implement proper error logging and analytics
3. Add offline support and caching
4. Implement user authentication
5. Add more detailed location and country data sources
6. Implement maps integration for visual route display
7. Add push notifications for trip reminders
8. Implement data persistence with local database

## License

This project is for demonstration purposes.
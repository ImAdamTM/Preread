# Preread

An iOS/iPadOS RSS reader app built with SwiftUI that caches articles for offline reading.

## Features

- **RSS/Atom Feed Support** - Add and manage multiple feed sources
- **Offline Reading** - Articles are cached locally with configurable fidelity
- **Reader Mode** - Clean, distraction-free reading with customizable fonts and text size
- **Dark Mode** - Full support for light, dark, and system appearance
- **Background Refresh** - Keeps feeds up to date automatically
- **Deep Links** - Open articles and sources via `preread://` URL scheme
- **Home Screen Shortcuts** - Quick access to your favourite sources
- **iPad Support** - Adaptive layout with NavigationSplitView on iPad

## Requirements

- iOS 17.0+
- Xcode 16+

## Getting Started

1. Clone the repository
2. Open `Preread.xcodeproj` in Xcode
3. Build and run on a simulator or device

## Project Structure

```
Preread/
├── Models/            # Article, Source, CachedPage data models
├── Services/          # Feed fetching, page caching, database, background tasks
├── Views/
│   ├── Components/    # Reusable UI components
│   ├── Reader/        # Reader mode views
│   └── Settings/      # App settings
├── Utilities/         # Theme, haptics, formatting, deep linking
└── Resources/         # Reader template, dark reader JS
```

## License

All rights reserved.

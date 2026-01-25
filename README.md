# ndi_flow

**Intelligent File Organization for macOS**

ndi_flow is a native macOS application that uses on-device machine learning to automatically organize your files based on their semantic content. Instead of relying on filenames or manual sorting, ndi_flow analyzes the actual content of your documents and images to group related files together.

![macOS](https://img.shields.io/badge/macOS-15.0+-blue?logo=apple)
![Swift](https://img.shields.io/badge/Swift-6-orange?logo=swift)
![License](https://img.shields.io/badge/License-MIT-green)

## Features

- **Semantic File Clustering** — Automatically groups related files based on content analysis, not just filenames
- **On-Device ML Processing** — All analysis happens locally using Apple's NaturalLanguage and Vision frameworks
- **Real-Time Folder Monitoring** — Watches your folders via FSEvents and indexes new files automatically
- **Dynamic Workspaces** — Create workspaces that aggregate files from multiple folders
- **Privacy-First Design** — No cloud uploads, no external APIs — everything stays on your Mac
- **Native macOS Experience** — Built with SwiftUI 6 and SwiftData for a premium, fluid interface

## How It Works

1. **Add Monitored Folders** — Select folders (Downloads, Documents, project directories) to watch
2. **Automatic Indexing** — ndi_flow extracts text from documents and analyzes images using on-device ML
3. **Semantic Clustering** — Files are grouped by content similarity using agglomerative clustering
4. **Browse & Discover** — View clusters in a three-column layout, discover related files you forgot about

## Screenshots

```
┌─────────────┬──────────────────┬─────────────────┐
│  Workspaces │     Clusters     │   File Detail   │
│  (Sidebar)  │    (Content)     │    (Preview)    │
└─────────────┴──────────────────┴─────────────────┘
```

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon or Intel Mac
- Xcode 16+ (for building from source)

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/nodaysidle/nodaysidle-ndiflow.git
   cd nodaysidle-ndiflow
   ```

2. Install XcodeGen (if not already installed):
   ```bash
   brew install xcodegen
   ```

3. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```

4. Build and run:
   ```bash
   xcodebuild -project ndi_flow.xcodeproj -scheme ndi_flow -configuration Release build
   ```

5. Copy to Applications:
   ```bash
   cp -R ~/Library/Developer/Xcode/DerivedData/ndi_flow-*/Build/Products/Release/ndi_flow.app /Applications/
   ```

## Architecture

### Core Components

| Component | Description |
|-----------|-------------|
| `FolderMonitoringService` | FSEvents-based real-time file system monitoring |
| `DocumentEmbeddingGenerator` | NLEmbedding-based semantic vector generation |
| `ClusteringEngine` | Agglomerative single-link clustering algorithm |
| `WorkspaceAggregationService` | Coordinates indexing, clustering, and persistence |
| `SemanticAnalysisService` | Unified interface for document and image analysis |

### Supported File Types

**Documents:** TXT, PDF, RTF, DOCX, Markdown, HTML, JSON, XML, source code files

**Images:** JPEG, PNG, HEIC, TIFF, GIF, WebP (analyzed using Vision framework)

### Tech Stack

- **UI:** SwiftUI 6 with NavigationSplitView
- **Persistence:** SwiftData with automatic migrations
- **ML:** NaturalLanguage (NLEmbedding) + Vision (VNFeaturePrint)
- **File Monitoring:** FSEvents API
- **Concurrency:** Swift 6 structured concurrency with actors
- **Build:** XcodeGen for project generation

## Project Structure

```
ndi_flow/
├── Models/                 # SwiftData @Model entities
│   ├── FileEntity.swift
│   ├── EmbeddingEntity.swift
│   ├── WorkspaceEntity.swift
│   └── MonitoredFolderEntity.swift
├── Views/                  # SwiftUI views
│   ├── ContentView.swift
│   ├── SettingsView.swift
│   └── WorkspaceViews.swift
├── Services/               # Business logic
│   ├── FolderMonitoringService.swift
│   ├── DocumentEmbeddingGenerator.swift
│   ├── ClusteringEngine.swift
│   └── WorkspaceAggregationService.swift
├── Persistence/            # SwiftData configuration
│   └── PersistenceController.swift
└── Utilities/              # Helpers and extensions
    └── Logger+Extensions.swift
```

## Configuration

### Entitlements

The app requires the following sandbox entitlements:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.files.downloads.read-write</key>
<true/>
<key>com.apple.security.files.bookmarks.app-scope</key>
<true/>
```

### Clustering Threshold

Each workspace has an adjustable clustering threshold (0.0 - 1.0):
- **Lower values** = More files grouped together (looser clusters)
- **Higher values** = Fewer, more specific clusters

## Usage

### Getting Started

1. Launch **ndi_flow** from Applications
2. Open **Settings** (gear icon or Cmd+,)
3. Click **Add Folder** and select a folder to monitor (e.g., Downloads)
4. The app will scan and index all files in the folder
5. Files are automatically grouped into semantic clusters

### Workspaces

- Create multiple workspaces for different projects
- Each workspace can monitor multiple folders
- Adjust the clustering threshold to control cluster granularity

### Real-Time Monitoring

- The app runs in the background with an active green indicator
- New files are automatically detected and indexed
- Clusters update in real-time as files are added

## Development

### Building

```bash
# Generate Xcode project
xcodegen generate

# Build debug
xcodebuild -scheme ndi_flow -configuration Debug build

# Build release
xcodebuild -scheme ndi_flow -configuration Release build
```

### Opening in Xcode

```bash
open ndi_flow.xcodeproj
# Press Cmd+R to run
```

## Troubleshooting

**App shows "Stopped" instead of "Monitoring":**
- Go to Settings and click "Start Monitoring"
- Ensure at least one folder is enabled with a valid workspace

**Files not being indexed:**
- Check that the folder is in the monitored list
- Click the refresh button (↻) on the folder to rescan
- Some file types may not contain extractable text

**Clustering produces too many/few clusters:**
- Adjust the clustering threshold slider in the workspace settings

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Built with Apple's [NaturalLanguage](https://developer.apple.com/documentation/naturallanguage) and [Vision](https://developer.apple.com/documentation/vision) frameworks
- Uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) for project generation
- Inspired by the need for smarter file organization beyond rule-based systems

---

**ndi_flow** — *NODAYSIDLE*

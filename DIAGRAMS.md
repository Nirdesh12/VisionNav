# VisionNav – Activity Diagram & Entity-Relation Diagram

## 1. Activity Diagram

The diagram below covers the four main user flows in VisionNav: **Object Detection**, **Route Navigation**, **Settings**, and **Help**.

```mermaid
flowchart TD
    %% ── Entry ──────────────────────────────────────────────────────────
    A([App Launch]) --> B[Show Home Dashboard\nContentView]

    %% ── Top-level choices ───────────────────────────────────────────────
    B --> C{User Action}
    C -->|Tap Object Detection| OD1
    C -->|Tap Navigation| NV1
    C -->|Tap Settings| ST1
    C -->|Tap Help| HL1

    %% ════════════════════════════════════════════════════════════════════
    %% OBJECT DETECTION FLOW
    %% ════════════════════════════════════════════════════════════════════
    OD1[Open ObjectDetectionView]
    OD1 --> OD2[Request Camera Permission]
    OD2 --> OD3{Permission\nGranted?}
    OD3 -->|No| OD_ERR[Show Error Alert\nReturn to Home]
    OD3 -->|Yes| OD4[Start ARKit Session\nEnable LiDAR Depth]
    OD4 --> OD5[Capture Camera Frame\n@ 25 fps]
    OD5 --> OD6[Crop to Focus Box\nAdjustable FOV slider]
    OD6 --> OD7[Run YOLO v8 Inference\nObjectDetectionModel]
    OD7 --> OD8[Compute Depth\nfrom ARDepthData or Estimate]
    OD8 --> OD9{Object\nDetected?}
    OD9 -->|No| OD5
    OD9 -->|Yes| OD10[Create DetectedObject\nlabel · confidence · bbox · timestamp]
    OD10 --> OD11[Create DepthResult\ndistance · isLiDAR · timestamp]
    OD11 --> OD12[Determine Depth Zone\nRed <0.3 m · Orange · Yellow · Green · Cyan >1.5 m]
    OD12 --> OD13[Audio Feedback\nSpeak object + distance]
    OD12 --> OD14[Haptic Feedback\nIntensity ∝ 1/distance]
    OD12 --> OD15[Visual Overlay\nColour-coded focus box]
    OD13 & OD14 & OD15 --> OD16{User\nStops?}
    OD16 -->|No| OD5
    OD16 -->|Yes| OD17[Stop ARKit Session]
    OD17 --> B

    %% ════════════════════════════════════════════════════════════════════
    %% NAVIGATION FLOW
    %% ════════════════════════════════════════════════════════════════════
    NV1[Open RouteNavigationView]
    NV1 --> NV2[Request Location &\nMicrophone Permissions]
    NV2 --> NV3{Permissions\nGranted?}
    NV3 -->|No| NV_ERR[Show Error Alert\nReturn to Home]
    NV3 -->|Yes| NV4{Input\nMode?}

    NV4 -->|Voice| NV5[Prompt: Speak Destination]
    NV5 --> NV6[Speech Recognition\nSpeech Framework]
    NV6 --> NV7[Search via MapKit\nLocalSearch]
    NV7 --> NV8[Confirm Destination\nAudio Readback]
    NV8 --> NV9[Create SearchResult\nname · address · distance]

    NV4 -->|Manual Text| NV10[User Types Destination]
    NV10 --> NV7

    NV9 --> NV11[Request Route\nOSRM API first]
    NV11 --> NV12{OSRM\nAvailable?}
    NV12 -->|Yes| NV13[Parse OSRM Steps\ninto NavigationSteps]
    NV12 -->|No| NV14[Run Custom A* Engine\nCustomRouteEngine]
    NV14 --> NV15[Create CustomRouteResult\ncoordinates · distance · steps · smoothed]
    NV15 --> NV16[Convert to NavigationSteps]
    NV13 --> NV16

    NV16 --> NV17[Start Navigation Loop]
    NV17 --> NV18[Update MapKit Overlay\nTop half of screen]
    NV17 --> NV19[Start ARKit Session\nCamera + LiDAR Depth]
    NV19 --> NV20[Run NavigationModel\nYOLO + Segmentation Inference]
    NV20 --> NV21[Run DepthProcessor\nBilateral Filter + Outlier Removal\n+ Temporal Fusion]
    NV21 --> NV22[Create NavigationDetection\nlabel · isObstacle · isGuidance · distance]

    NV22 --> NV23{Alert\nType?}
    NV23 -->|Danger/Obstacle| NV24[Danger Alert\nHaptics + Voice Warning]
    NV23 -->|Stairs Detected| NV25[Stairs Alert\nVoice: Stairs Ahead]
    NV23 -->|Tactile Paving| NV26[Guidance Alert\nVoice: Path Guidance]
    NV23 -->|Path Clear| NV27[No Alert]

    NV24 & NV25 & NV26 & NV27 --> NV28[Check GPS Location\nNavigationLocationManager]
    NV28 --> NV29{Reached Next\nWaypoint?}
    NV29 -->|No| NV30{Off Route\n>40 m?}
    NV30 -->|No| NV17
    NV30 -->|Yes| NV31[Offer Reroute\nRecalculate Route]
    NV31 --> NV11
    NV29 -->|Yes| NV32[Speak Next Instruction\nNavigationStep.instruction]
    NV32 --> NV33{Arrived at\nDestination?}
    NV33 -->|No| NV17
    NV33 -->|Yes| NV34[Speak: You have arrived\nStop ARKit Session]
    NV34 --> B

    %% ════════════════════════════════════════════════════════════════════
    %% SETTINGS FLOW
    %% ════════════════════════════════════════════════════════════════════
    ST1[Open SettingsView]
    ST1 --> ST2[Load Preferences\nSettingsManager / UserDefaults]
    ST2 --> ST3{User\nAdjusts}
    ST3 -->|Volume Slider| ST4[Update voiceVolume\nAVAudioSession]
    ST3 -->|Speech Rate Slider| ST5[Update speechRate\nAVSpeechSynthesizer]
    ST3 -->|Feedback Mode| ST6[Update feedbackMode\nvoiceOnly · hapticOnly · hapticWithCriticalVoice]
    ST3 -->|Notifications Toggle| ST7[Update notificationsEnabled]
    ST4 & ST5 & ST6 & ST7 --> ST8[Persist to UserDefaults]
    ST8 --> ST3
    ST3 -->|Done| B

    %% ════════════════════════════════════════════════════════════════════
    %% HELP FLOW
    %% ════════════════════════════════════════════════════════════════════
    HL1[Open HelpView]
    HL1 --> HL2{Select\nSection}
    HL2 -->|Audio Tutorial| HL3[Play Audio\nAVSpeechSynthesizer Walkthrough]
    HL2 -->|Object Detection Guide| HL4[Show 4-Step\nDetection Guide]
    HL2 -->|Navigation Guide| HL5[Show 4-Step\nNavigation Guide]
    HL2 -->|Quick Tips| HL6[Show Tips\nHeadphones · Haptics · Adjustments]
    HL2 -->|Contact Support| HL7[Open Support\nEmail / Link]
    HL3 & HL4 & HL5 & HL6 & HL7 --> HL8{Back?}
    HL8 -->|Yes| B
    HL8 -->|No| HL2
```

---

## 2. Entity-Relation Diagram

The ER diagram covers all core data structures in VisionNav and shows how they relate to each other.

```mermaid
erDiagram

    %% ── Object Detection entities ────────────────────────────────────────
    DetectedObject {
        UUID    id                  PK
        String  label
        Float   confidence
        CGRect  boundingBox
        Date    timestamp
    }

    DepthResult {
        UUID    id                  PK
        Float   distance_meters
        Bool    isLiDAR
        Date    timestamp
    }

    %% ── Navigation Detection entities ────────────────────────────────────
    NavigationDetection {
        UUID     id                 PK
        String   label
        Float    confidence
        CGRect   boundingBox
        Bool     isObstacle
        Bool     isGuidance
        Float    distance_meters
        UIImage  segmentationMask
    }

    AlertType {
        String  type               PK
    }

    %% ── Route / Location entities ────────────────────────────────────────
    NavigationStep {
        UUID     id                PK
        String   instruction
        Double   distance_meters
        String   maneuver          FK
        Double   latitude
        Double   longitude
    }

    ManeuverType {
        String  type               PK
    }

    SearchResult {
        UUID    id                 PK
        String  name
        String  address
        Double  distance_meters
        MKMapItem mapItem
    }

    CustomRouteResult {
        UUID     id                PK
        Double   totalDistance_m
        Bool     success
        Int      stepCount
        Array    coordinates
        Array    smoothedCoordinates
    }

    CustomRouteStep {
        UUID    id                 PK
        String  instruction
        Double  distance_meters
        Double  latitude
        Double  longitude
    }

    %% ── Settings entities ────────────────────────────────────────────────
    UserSettings {
        String  feedbackMode       FK
        Double  voiceVolume
        Double  speechRate
        Bool    notificationsEnabled
        String  appVersion
    }

    FeedbackMode {
        String  mode               PK
    }

    %% ── Session / runtime "container" entities ──────────────────────────
    ObjectDetectionSession {
        UUID    id                 PK
        Date    startedAt
        Bool    isLiDARAvailable
    }

    NavigationSession {
        UUID    id                 PK
        Date    startedAt
        Bool    isVoiceSearch
        String  destinationName
        Bool    offlineMode
    }

    %% ────────────────────────────────────────────────────────────────────
    %% Relationships
    %% ────────────────────────────────────────────────────────────────────

    %% Object detection
    ObjectDetectionSession ||--o{ DetectedObject    : "produces"
    ObjectDetectionSession ||--o{ DepthResult       : "captures"
    DetectedObject         ||--|| DepthResult       : "paired with"

    %% Navigation detection
    NavigationSession      ||--o{ NavigationDetection : "produces"
    NavigationDetection    }o--|| AlertType           : "classified as"

    %% Route
    NavigationSession      ||--o| SearchResult        : "targets"
    NavigationSession      ||--o{ NavigationStep      : "follows"
    NavigationSession      ||--o| CustomRouteResult   : "may use"
    CustomRouteResult      ||--o{ CustomRouteStep     : "contains"
    NavigationStep         }o--|| ManeuverType         : "has maneuver"

    %% Settings
    UserSettings           }o--|| FeedbackMode        : "uses"
    ObjectDetectionSession }o--|| UserSettings        : "configured by"
    NavigationSession      }o--|| UserSettings        : "configured by"
```

---

### Diagram Notes

| Diagram | Scope |
|---------|-------|
| **Activity Diagram** | All four major user flows: Object Detection, Route Navigation, Settings, Help |
| **ER Diagram** | All persistent/runtime data models: DetectedObject, DepthResult, NavigationDetection, NavigationStep, SearchResult, CustomRouteResult, UserSettings, and related enums |

**Technology quick reference**

| Concern | Technology |
|---------|-----------|
| Camera & Depth | ARKit 5 (smoothedSceneDepth) |
| Object Detection | YOLO v8 via CoreML / Vision |
| Audio Feedback | AVSpeechSynthesizer |
| Haptics | CoreHaptics (CHHapticEngine) |
| Routing (online) | OSRM API |
| Routing (offline) | Custom A\* (CustomRouteEngine) |
| Persistence | UserDefaults |
| Maps | MapKit / CoreLocation |
| Voice Input | Speech framework |

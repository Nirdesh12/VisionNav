# VisionNav – Application Flowchart

This diagram shows the overall flow of the **VisionNav** iOS accessibility app for visually impaired users.

```mermaid
flowchart TD
    A([📱 Launch App]) --> B[Home Screen\nContentView]

    B --> C[🔍 Object Detection]
    B --> D[🗺️ Route Navigation]
    B --> E[⚙️ Settings]
    B --> F[❓ Help]

    %% ─── Object Detection ───────────────────────────────────────────
    subgraph OD [Object Detection Module]
        direction TB
        C --> OD1[Start ARKit Camera\n+ LiDAR Session]
        OD1 --> OD2[Capture Frame\nevery 0.1 s]
        OD2 --> OD3[Run YOLOv8 Model\nyolov26s.mlmodel]
        OD3 --> OD4{Object in\nFocus Box?}
        OD4 -- No --> OD2
        OD4 -- Yes --> OD5[Get Depth via LiDAR\nStatistical Filtering]
        OD5 --> OD6[Classify Distance\nRed → Yellow → Green → Cyan]
        OD6 --> OD7{Feedback\nMode?}
        OD7 -- Voice --> OD8[🔊 Speak Object\n+ Distance]
        OD7 -- Haptic --> OD9[📳 Vibrate\nProportional to Distance]
        OD7 -- Combined --> OD8 & OD9
        OD8 & OD9 --> OD2
    end

    %% ─── Route Navigation ────────────────────────────────────────────
    subgraph RN [Route Navigation Module]
        direction TB
        D --> RN1{Set\nDestination}
        RN1 -- Text Search --> RN2[MKLocalSearch\nFind Place]
        RN1 -- 🎤 Voice Input --> RN3[Speech Recognition\nTranscribe & Search]
        RN2 & RN3 --> RN4[Query OSRM\nOpenStreetMap Routing]
        RN4 --> RN5[Parse Route\nWaypoints & Maneuvers]
        RN5 --> RN6[Display Map\n+ Route Polyline]
        RN6 --> RN7[Start Navigation Loop\nevery 0.25 s]
        RN7 --> RN8[Capture Camera Frame\n+ LiDAR Depth]
        RN8 --> RN9[Run YOLOv8 Seg Model\nSegmentation]
        RN9 --> RN10[Divide FOV into 5 Zones\nCenter · Left · Right · Near · Far]
        RN10 --> RN11{Obstacle\nDetected?}
        RN11 -- Yes --> RN12[📳 Directional Haptics\n🔊 Zone Warning]
        RN11 -- Stairs --> RN13[🔊 Stair Alert\nCount Steps]
        RN12 & RN13 --> RN14{Every 12 s:\nNext Turn?}
        RN14 -- Yes --> RN15[🔊 Speak Maneuver\n"Turn left in 20 m"]
        RN14 -- No --> RN16{Arrived\n< 10 m?}
        RN15 --> RN16
        RN16 -- No --> RN7
        RN16 -- Yes --> RN17[🔊 "You have arrived"\nEnd Navigation]
    end

    %% ─── Settings ────────────────────────────────────────────────────
    subgraph ST [Settings Module]
        direction TB
        E --> ST1[Adjust Volume\nSlider]
        E --> ST2[Adjust Speech Rate\nSlider]
        E --> ST3{Select\nFeedback Mode}
        ST3 --> ST4[Voice Only]
        ST3 --> ST5[Haptic Only]
        ST3 --> ST6[Combined]
        ST1 & ST2 & ST4 & ST5 & ST6 --> ST7[Save to\nUserDefaults]
    end

    %% ─── Help ────────────────────────────────────────────────────────
    F --> HV[Display Tutorial\nfor Each Feature]
```

---

## Key Technologies

| Layer | Technology |
|---|---|
| UI | SwiftUI + ARKit |
| Object Detection | YOLOv8 (CoreML / Vision) |
| Depth Sensing | LiDAR (ARKit `smoothedSceneDepth`) |
| Routing | OSRM (OpenStreetMap) |
| Audio Guidance | AVSpeechSynthesizer |
| Haptic Feedback | CoreHaptics |
| Voice Input | Speech framework |
| Persistence | UserDefaults |

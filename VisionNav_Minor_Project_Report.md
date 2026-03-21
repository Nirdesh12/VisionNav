# Cover Page

## VisionNav Minor Project Report

### Submitted by: Nirdesh12

### Date: 2026-03-14

---

# Title Page

## Title: VisionNav – An iOS Application for Navigation

## Submitted to: [Institution Name Here]

---

# Acknowledgement

I would like to express my gratitude to [Names of people who helped] for their support and guidance.

---

# Abstract

This report presents the findings and outcomes of the VisionNav project, a Swift-based iOS application aimed at providing seamless navigational assistance.

---

# Table of Contents

1. Introduction
2. Literature Review
3. Methodology
4. Results and Conclusion
5. Future Enhancements
6. References
7. Appendices

---

# Introduction

The introduction of the VisionNav project outlines the objectives and scope of the application development.

---

# Literature Review

This section reviews the existing literature related to navigation solutions, focusing on mobile applications and technological advancements in iOS development.

---

# Methodology

The methodology outlines the development process, including the tools and frameworks used in the design and development of the VisionNav application.

---

## 3.3 Data Flow Diagrams (DFD)

A Data Flow Diagram (DFD) models how data moves through the VisionNav system — from sensor inputs through processing stages to user feedback outputs. The diagrams below present the system at three levels of detail.

---

### 3.3.1 Context Diagram (Level 0)

The Context Diagram shows VisionNav as a single process interacting with two external entities: the **User** (provides the environment to navigate) and the **Environment** (physical world sensed by LiDAR and Camera).

```
+-------------+    Destination / Voice Input    +-------------------+    LiDAR Depth Data   +-------------+
|             | -----------------------------> |                   | <-------------------- |             |
|    User     |                                |  0.0  VisionNav   |                        | Environment |
|             | <------------------------------ |    System         | <-------------------- |             |
+-------------+    Audio & Haptic Feedback     +-------------------+    Camera Frames       +-------------+
```

---

### 3.3.2 Level 1 DFD

The Level 1 DFD decomposes VisionNav into three main processes, their data flows, and the data stores involved.

```mermaid
flowchart TD
    ENV([Environment]) -->|LiDAR Depth Data| P1
    ENV -->|Camera Frames| P1

    P1["1.0\nSensor Data\nAcquisition"] -->|Raw Sensor Data| DS1[(Sensor Buffer)]
    DS1 -->|Synchronized Sensor Data| P2

    P2["2.0\nData Processing"] -->|Navigation Commands| DS2[(Navigation State)]
    DS2 -->|Instructions| P3

    P3["3.0\nUser Feedback\nGeneration"] -->|Audio Alerts| USR([User])
    P3 -->|Haptic Signals| USR

    USR -->|Voice Input / Destination| P1
```

---

### 3.3.3 Level 2 DFD – Process 1.0: Sensor Data Acquisition

This diagram expands **Process 1.0** into its sub-processes: LiDAR capture, camera capture, and ARKit-based sensor synchronization.

```mermaid
flowchart TD
    ENV([Environment])

    ENV -->|LiDAR Pulses / Depth Measurements| P11
    P11["1.1\nLiDAR Data\nCapture"] -->|Raw Point Cloud| DS11[(Raw LiDAR Buffer)]

    ENV -->|Visual Light / Scene| P12
    P12["1.2\nCamera Image\nCapture"] -->|Raw Camera Frames| DS12[(Raw Camera Buffer)]

    DS11 -->|Raw Point Cloud| P13
    DS12 -->|Raw Camera Frames| P13
    P13["1.3\nARKit Sensor\nSynchronization"] -->|Synchronized Sensor Data| DS1[(Sensor Buffer\n→ to Process 2.0)]
```

**Sub-process descriptions:**

| Sub-Process | Input | Processing | Output |
|---|---|---|---|
| 1.1 LiDAR Data Capture | Environment (physical space) | Emits laser pulses; measures time-of-flight to generate a 3D point cloud | Raw Point Cloud |
| 1.2 Camera Image Capture | Environment (visual scene) | Captures RGB frames at configured resolution and frame rate using AVFoundation | Raw Camera Frames |
| 1.3 ARKit Sensor Synchronization | Raw Point Cloud, Raw Camera Frames | Uses ARKit to temporally align and register depth and image data to a common coordinate frame | Synchronized Sensor Data |

---

### 3.3.4 Level 2 DFD – Process 2.0: Data Processing

This diagram expands **Process 2.0** into its four sub-processes: data preprocessing, sensor fusion, ML inference, and decision & feedback logic.

```mermaid
flowchart TD
    DS1[(Sensor Buffer\nfrom Process 1.0)]

    DS1 -->|Synchronized LiDAR Point Cloud| P21
    DS1 -->|Synchronized Camera Frames| P21

    P21["2.1\nPreprocess\nSensor Data"] -->|Filtered Point Cloud| DS21[(Preprocessed\nLiDAR Store)]
    P21 -->|Normalized Image| DS22[(Preprocessed\nCamera Store)]

    DS21 -->|Filtered Point Cloud| P22
    DS22 -->|Normalized Image| P22
    P22["2.2\nSensor Fusion"] -->|Fused 3D Scene Data| DS23[(Fused Scene\nStore)]

    DS23 -->|Fused 3D Scene Data| P23
    P23["2.3\nML Inference\n(YOLO26 via CoreML)"] -->|Detected Objects\nwith Labels & Distances| DS24[(Detection\nResults Store)]

    DS24 -->|Detected Objects\nwith Labels & Distances| P24
    P24["2.4\nDecision &\nFeedback Logic"] -->|Navigation Commands| DS2[(Navigation State\n→ to Process 3.0)]
```

**Sub-process descriptions:**

| Sub-Process | Input | Processing | Output |
|---|---|---|---|
| 2.1 Preprocess Sensor Data | Raw LiDAR Point Cloud, Raw Camera Frames | **LiDAR:** Voxel-grid downsampling (up to 90% reduction), RoI truncation (Z ≤ 2 m), RANSAC floor-plane removal. **Camera:** Resize to model input dimensions, pixel normalisation, optional augmentation. | Filtered Point Cloud, Normalized Image |
| 2.2 Sensor Fusion | Filtered Point Cloud, Normalized Image | Aligns 3D point cloud coordinates with corresponding camera pixels using ARKit extrinsics; projects depth values onto the image plane to produce a dense, spatially-registered fused 3D scene representation. | Fused 3D Scene Data |
| 2.3 ML Inference (YOLO26 via CoreML) | Fused 3D Scene Data | Runs the YOLO26 model (NMS-free, DFL-removed) on-device via CoreML. Predicts bounding boxes, class labels (door, person, stair, furniture, etc.), and uses associated depth values for distance estimation. | Detected Objects with Labels & Distances |
| 2.4 Decision & Feedback Logic | Detected Objects with Labels & Distances | Ranks obstacles by proximity and relevance; selects the highest-priority hazard; constructs natural-language audio instructions (e.g., "Door ahead at 1.5 m") and corresponding haptic patterns for delivery to Process 3.0. | Navigation Commands (audio text + haptic pattern) |

---

# Results and Conclusion

Results from the project will be discussed here, summarizing the application's performance and potential impact.

---

# Future Enhancements

Suggestions for future enhancements and new features that could be added to the VisionNav application in subsequent releases.

---

# References

[1] Author Name, "Title of the Source". 

[2] Author Name, "Another Title of the Source".

---

# Appendices

Appendix A: Additional Resources

Appendix B: Glossary of Terms
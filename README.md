# SafeRoute 🛡️

**SafeRoute** is a proactive personal safety platform built with Flutter. Unlike traditional navigation apps that prioritize the fastest path, SafeRoute uses a custom geospatial engine to guide users through the safest possible routes, balancing travel time with risk avoidance.

---

## 🌟 Key Features

### 1. Proactive "Journey Guard"
The core of SafeRoute is its **Danger-Zone-Aware Routing**. It analyzes routes against a dataset of reported unsafe zones (high-crime areas, poor lighting, or isolated spots).
*   **Safety Scoring:** Every route is assigned a "Safety Tax" based on proximity to risk.
*   **Practicality Pool:** The algorithm only suggests a safer route if the detour is reasonable (typically within 30% of the fastest time).
*   **Adaptive Buffers:** Danger zones aren't just points; they have dynamic buffers that scale based on the severity of the reports in that area.

### 2. Reactive SOS System
When an emergency occurs, SafeRoute switches into a high-intensity coordination mode:
*   **Shake-to-Trigger:** Background service allows SOS activation via a physical device shake.
*   **Real-time Coordination:** Powered by Firebase, SOS sessions sync location and status instantly between the victim and responders.
*   **Direct SMS Alerts:** Uses a native `MethodChannel` on Android to send enriched, non-blocking SMS alerts to emergency contacts.
*   **Rescue Invite Links:** Generates dynamic links for trusted helpers to join a live tracking session.

### 3. Cross-Platform & Independent
Built to be platform-agnostic, SafeRoute runs seamlessly on:
*   **Android:** Full feature set including direct background SMS.
*   **iOS:** Compliant safety coordination and real-time tracking.
*   **Desktop:** Large-screen dashboard for responders and history management.

---

## 🧠 Core Algorithm: Balanced Route Selection

The app uses a unique three-step logic to determine the best path:
1.  **The Safety Filter:** Identifies all candidate paths that avoid "Red Zones" (critical danger areas).
2.  **The Sanity Check:** Filters the safe paths to find those within a "Practicality Pool" (reasonable distance/time).
3.  **Human Context:** Generates clear UI feedback like *"Adding 4 mins to avoid an isolated area,"* empowering users with the "why" behind a suggestion.

---

## 🛠️ Tech Stack

*   **Frontend:** Flutter & GetX (State Management)
*   **Backend:** Firebase Auth, Firestore (Real-time Sync)
*   **Geospatial:** Custom Cartesian Projection logic for efficient mobile point-to-polyline calculations.
*   **Native:** Kotlin/MethodChannels for Android-specific hardware triggers.

---

## 🚀 Getting Started

### Flutter App Setup
1.  **Install Dependencies:**
    ```bash
    flutter pub get
    ```
2.  **Firebase Config:** Place your `google-services.json` (Android) and `GoogleService-Info.plist` (iOS) in the appropriate directories.
3.  **Run the App:**
    ```bash
    flutter run
    ```

### Optional Backend Setup
The backend (Node.js) is currently used for health monitoring and extended coordination APIs.
1.  **Navigate to backend:** `cd backend`
2.  **Install dependencies:** `npm install`
3.  **Configure `.env`:** Copy `.env.example` to `.env` and fill in your Firebase Service Account details.
4.  **Start:** `npm start`

---

## 🧪 Testing

SafeRoute relies on a "Test-Driven Development" approach, especially for its math-heavy routing logic.

**Run Routing Tests:**
```bash
flutter test test/journey_safety_service_test.dart
```

**Run Backend Tests:**
```bash
cd backend && npm test
```

---

## ⚖️ Safety & Compliance Notes

*   **Direct SMS:** Programmatic SMS sending is restricted to Android. On other platforms, the app uses alternative notification pathways.
*   **Battery Optimization:** The routing engine uses "Bounding Box" pre-filtering to minimize CPU usage and preserve battery during long trips.
*   **Data Privacy:** All location data is scoped to active SOS sessions and journey history, following standard privacy best practices.

---

## 🔮 Future Roadmap & Offline Resilience Architecture

### 1. GPS-Off Fallback & Location Recovery
To maintain maximum emergency reliability when device GPS is toggled OFF:
*   **Fused Location Provider Fallback:** Fallback to Android `FusedLocationProviderClient` for cell-tower and Wi-Fi-based coarse location when GPS hardware is disabled, ensuring approximate area data is included in SMS alerts.
*   **Last Known Location Caching:** Automatically cache the last valid GPS fix locally with a timestamp (`"last seen near X, Y mins ago"`), providing immediate location context if GPS is unavailable during a sudden emergency.
*   **1-Tap Location Resolution Dialog:** Seamlessly launch `SettingsClient.checkLocationSettings()` to prompt users with a 1-tap system dialog to enable location services without navigating away from the app.
*   **OS Privacy Compliance:** Fully compliant with Android/iOS privacy security policies (preventing unconsented silent background GPS toggling).

### 2. Zero-Internet Offline Voice Trigger (On-Device Wake-Word)
*   **On-Device Voice Engine (Picovoice Porcupine / Vosk):** Integrate lightweight on-device keyword spotting to detect custom wake-phrases (e.g., *"Help me now"*) 100% offline without requiring internet connectivity or cloud NLP processing.
*   **Foreground Audio Service:** Run a low-power audio listener service that processes microphone streams locally even when the screen is off or the app is in the background, providing immediate hands-free emergency activation without relying on cloud assistant engines.

### 3. Dual-Channel Emergency Dispatch & SMS Carrier Failure Fallback
To eliminate silent alert delivery failures caused by exhausted cellular SMS packs or carrier balance restrictions:
*   **Dual-Channel Parallel Dispatch:** Simultaneously initiate cellular SMS dispatch (via native Android `SmsManager`) and cloud-based alert broadcasting (via Firebase Cloud Firestore & Push Notifications) upon emergency activation.
*   **SMS Delivery Status Tracking:** Utilize Android native `sentIntent` and `deliveryIntent` PendingIntents to capture real-time SMS transmission statuses (e.g., `RESULT_ERROR_GENERIC_FAILURE`, carrier quota blocks).
*   **Smart Cloud & App Fallback:** If cellular SMS delivery fails due to zero SMS balance, automatically fallback to internet-based alert channels (Firebase Live Sync, WhatsApp deep links `wa.me`, or third-party web SMS gateways).
*   **Pitch Bottom Line:** *"If SMS fails (no SMS balance) and internet is active, the app automatically falls back to cloud alerts. Complete failure occurs only if BOTH cellular SMS and internet data are simultaneously unavailable."*

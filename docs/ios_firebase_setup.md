# iOS Firebase Setup

The iOS app is prepared for Firebase push, but you still need to connect your Apple and Firebase settings.

## 1. Add the Firebase iOS app

In Firebase Console:

- Project: `stockfoliong`
- Bundle ID: `com.stockfoliong.app`

Download `GoogleService-Info.plist` and place it at:

- `flutter_app/ios/Runner/GoogleService-Info.plist`

Then open `flutter_app/ios/Runner.xcworkspace` in Xcode and confirm the file appears under the `Runner` target.

## 2. Enable Apple push capabilities in Xcode

For the `Runner` target, enable:

- `Push Notifications`
- `Background Modes`
  - check `Remote notifications`

## 3. Add APNs to Firebase

In Apple Developer:

- create an APNs Authentication Key

Then in Firebase Console:

- Project settings
- Cloud Messaging
- upload the APNs key

## 4. Build with Firebase iOS dart-defines

Use the Flutter helper script so the version becomes dotted automatically:

```bash
python3 scripts/flutter_build.py ios --debug --no-codesign \
  --dart-define=API_BASE_URL=https://ngx-api.up.railway.app/ \
  --dart-define=FIREBASE_PROJECT_ID=stockfoliong \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=864886127583 \
  --dart-define=FIREBASE_IOS_BUNDLE_ID=com.stockfoliong.app \
  --dart-define=FIREBASE_IOS_APP_ID=YOUR_IOS_APP_ID \
  --dart-define=FIREBASE_IOS_API_KEY=YOUR_IOS_API_KEY
```

## 5. Test on a real iPhone

iOS push does not behave reliably in the simulator. Use a real device for:

- token registration
- foreground notifications
- background/terminated push tests

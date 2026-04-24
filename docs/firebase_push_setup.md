# Firebase Push Setup

Push notifications are now wired in two layers:

1. The Flutter app can register an Android or iOS device token with the backend.
2. The backend can send Firebase Cloud Messaging (FCM) notifications when a held stock moves by the configured threshold.

## 1. Push this build and test the in-app alerts first

Before turning on Firebase, deploy this version and confirm:

- login works
- holdings load normally
- the in-app 5% toast alerts still work
- the Admin screen loads the new Push notifications card

That gives you a stable checkpoint before we add cloud push credentials.

## 2. Create/configure the Firebase project

Follow the official Firebase Flutter setup and FCM setup:

- [Add Firebase to your Flutter app](https://firebase.google.com/docs/flutter/setup)
- [Receive messages using Firebase Cloud Messaging in Flutter](https://firebase.google.com/docs/cloud-messaging/flutter/receive?hl=en)
- [Authorize server-side FCM HTTP v1 sends](https://firebase.google.com/docs/cloud-messaging/auth-server)

For Android and iOS, collect these values from Firebase:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_MESSAGING_SENDER_ID`
- `FIREBASE_ANDROID_APP_ID`
- `FIREBASE_ANDROID_API_KEY`
- `FIREBASE_IOS_APP_ID`
- `FIREBASE_IOS_API_KEY`
- `FIREBASE_IOS_BUNDLE_ID` (defaults to `com.stockfoliong.app`)

## 3. Build the Flutter app with Firebase values

Example:

```bash
flutter build apk --release \
  --dart-define=API_BASE_URL=https://your-backend.up.railway.app \
  --dart-define=FIREBASE_PROJECT_ID=your-project-id \
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=1234567890 \
  --dart-define=FIREBASE_ANDROID_APP_ID=1:1234567890:android:abc123 \
  --dart-define=FIREBASE_ANDROID_API_KEY=AIza... \
  --dart-define=FIREBASE_IOS_APP_ID=1:1234567890:ios:def456 \
  --dart-define=FIREBASE_IOS_API_KEY=AIza... \
  --dart-define=FIREBASE_IOS_BUNDLE_ID=com.stockfoliong.app
```

For iOS, also enable the **Push Notifications** capability and **Background Modes > Remote notifications** in Xcode before release testing.

## 4. Configure Railway backend variables

Set these on the Railway backend service:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_SERVICE_ACCOUNT_JSON`
- `PUSH_ALERT_THRESHOLD_PERCENT=5`

`FIREBASE_SERVICE_ACCOUNT_JSON` can be either:

- the raw JSON content of the service account key, or
- base64-encoded JSON

The backend uses Firebase Cloud Messaging HTTP v1 and removes invalid device tokens automatically when FCM says a token is no longer valid.

## 5. Test it

1. Sign into the Android or iOS app.
2. Open the Account tab and confirm the mobile push status says it is enabled.
3. Open the Admin tab and use **Send test push**.
4. Once that works, normal background syncs will send alerts for portfolio holdings that move by 5% or more since the last alert reference price.

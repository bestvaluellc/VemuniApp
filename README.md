# Vemuni

Vemuni is a SwiftUI iPhone app that makes restaurant menus easier to read and checks restaurant bills for fees and possible double tipping.

## What is included

- Menu and receipt photo capture or photo-library selection
- Automatic language detection and English translation
- Plain-language dish explanations, prices, dietary indicators, and cautious allergen hints
- Receipt subtotal, tax, service-charge, gratuity, and total extraction
- Tip calculations based on the pretax subtotal when visible
- Google, Apple, and email/password authentication through Firebase
- Firebase Analytics events for acquisition and funnel measurement without menu, receipt, image, or email contents
- Ten introductory scans followed by one free scan per UTC day, enforced server-side
- Firebase HTTPS function that keeps the OpenAI API key off the phone
- Per-scan AI usage records and lifetime token totals in Firestore, without menu text or images
- Bundle ID `bestvaluellc.apps.vemuni`

## Open the iPhone app

Open `Vemuni.xcodeproj` in Xcode. Select your Apple development team for the Vemuni target, confirm the Sign in with Apple capability, allow Swift Package Manager to resolve Firebase and Google Sign-In, and run on an iPhone or simulator.

The included `GoogleService-Info.plist` is configured for Firebase project `vemuni-d4f87`. The app's `Info.plist` already contains the matching Google callback URL and deployed-function URL.

## Deploy the scan function

From this folder:

```sh
cd functions
npm install
cd ..
firebase functions:secrets:set OPENAI_API_KEY
firebase deploy --only functions,firestore:rules
```

The endpoint is `analyzeDiningPhoto` in `us-central1`. It verifies a Firebase ID token, sends the image to the OpenAI Responses API using structured output, records scan allowance counters and token-usage metadata in Firestore, and does not save the uploaded image. Usage records contain the response ID, scan type, page count, model, input, cached-input, output, reasoning, and total token counts. They do not contain menu text, receipt values, or images.

## Analytics events

Vemuni records `scan_opened`, `scan_photo_selected`, `scan_started`, `scan_completed`, `scan_failed`, `menu_item_opened`, `auth_attempt`, and Firebase's standard `login` event. Parameters are limited to scan type, photo source, result counts, detected-language label, broad error category, and boolean feature flags. Never add menu text, receipt values, email addresses, image data, or other user-provided content to Analytics.

## Before App Store submission

- Add Terms of Use and Privacy Policy destinations.
- Add in-app account deletion because Vemuni supports account creation.
- Enable and enforce Firebase App Check to reduce unauthorized API use.
- Replace per-install local quota messaging with the server-returned quota state.
- Test Google and Apple authentication on a signed physical device.
- Add accessibility and localization QA.

Menu explanations and allergen indicators are informational. Users should always verify ingredients and allergens with the restaurant.

#!/bin/bash
# Usage: bash build.sh <app_name> "<Label>"
set -e
APP="$1"
LABEL="$2"
flutter create --platforms=android --org com.funludo --project-name "$APP" "build_$APP"
cp "$APP.dart" "build_$APP/lib/main.dart"
cd "build_$APP"
rm -rf test
M=android/app/src/main/AndroidManifest.xml
sed -i 's|<application|<uses-permission android:name="android.permission.INTERNET"/>\n    <application|' "$M"
sed -i "s|android:label=\"[^\"]*\"|android:label=\"$LABEL\"|" "$M"
flutter pub get
flutter build apk --release

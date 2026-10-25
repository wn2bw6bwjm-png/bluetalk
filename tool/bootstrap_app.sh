#!/usr/bin/env bash
# Generates the Android/iOS runner projects for app/ and applies every
# permission / build setting the app and its plugins need. Run ONCE on a
# machine with Flutter (stable >= 3.27) installed. Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/../app"

[ -d android ] || flutter create --platforms=android,ios --org dev.bluetalk --project-name bluetalk .

python3 - <<'PY'
import re, pathlib, sys

# ---------------- Android ----------------
manifest = pathlib.Path("android/app/src/main/AndroidManifest.xml")
m = manifest.read_text()
perms = [
    '<uses-permission android:name="android.permission.CAMERA" />',
    '<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />',
    '<uses-feature android:name="android.hardware.camera" android:required="false" />',
]
for p in perms:
    if p not in m:
        m = m.replace("<application", p + "\n    <application", 1)
# App name shown under the launcher icon
m = re.sub(r'android:label="[^"]*"', 'android:label="BlueTalk"', m, count=1)
manifest.write_text(m)

gradle = pathlib.Path("android/app/build.gradle.kts")
kts = gradle.exists()
if not kts:
    gradle = pathlib.Path("android/app/build.gradle")
g = gradle.read_text()

# minSdk 23 (BLE plugin) -------------------------------------------------
g = re.sub(r"minSdk(Version)?\s*=?\s*(flutter\.minSdkVersion|\d+)",
           "minSdk = 23" if kts else "minSdkVersion 23", g)

# core library desugaring (required by flutter_local_notifications) ------
if "coreLibraryDesugaring" not in g:
    if kts:
        g = g.replace("compileOptions {",
                      "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", 1)
        g += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")\n}\n'
    else:
        g = g.replace("compileOptions {",
                      "compileOptions {\n        coreLibraryDesugaringEnabled true", 1)
        g += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4'\n}\n"
gradle.write_text(g)
print(f"Android patched ({gradle}). Verify minSdk / desugaring / permissions.")

# ---------------- iOS ----------------
plist = pathlib.Path("ios/Runner/Info.plist")
p = plist.read_text()
def add(key, xml):
    global p
    if f"<key>{key}</key>" not in p:
        p = p.replace("</dict>\n</plist>", f"\t<key>{key}</key>\n\t{xml}\n</dict>\n</plist>")
txt = "Used to find and talk to nearby devices without internet."
add("NSLocalNetworkUsageDescription", f"<string>{txt}</string>")
add("NSBluetoothAlwaysUsageDescription", f"<string>{txt}</string>")
add("UIBackgroundModes",
    "<array>\n\t\t<string>bluetooth-central</string>\n\t</array>")
add("NSCameraUsageDescription", "<string>Used to scan invite QR codes.</string>")
add("NSBonjourServices",
    "<array>\n\t\t<string>_bluetalk._tcp</string>\n\t\t<string>_bluetalk._udp</string>\n\t</array>")
# App name shown on the home screen
for key in ("CFBundleDisplayName", "CFBundleName"):
    if f"<key>{key}</key>" in p:
        p = re.sub(rf"(<key>{key}</key>\s*<string>)[^<]*(</string>)", r"\1BlueTalk\2", p)
    else:
        p = p.replace("</dict>\n</plist>", f"\t<key>{key}</key>\n\t<string>BlueTalk</string>\n</dict>\n</plist>")
plist.write_text(p)
print("iOS Info.plist patched.")
PY

flutter pub get
echo
echo "Done. Next:  cd app && flutter run -d <device-id>"
echo "iOS: open ios/Runner.xcworkspace once and set your signing team."

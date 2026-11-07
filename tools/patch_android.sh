#!/usr/bin/env bash
# "flutter create" yeni Flutter sürümlerinde AGP 9 + dahili Kotlin 2.2.10 ile
# geliyor; Flutter ise en az Kotlin 2.2.20 istiyor ve build şu hatayla düşüyordu:
#   "Your project's Kotlin version (2.2.10) is lower than ... 2.2.20"
# Çözüm: kararlı eski ikili kullan: AGP 8.11.1 + Kotlin 2.2.20 + Gradle 8.14.3.
set -euo pipefail

S=android/settings.gradle.kts
A=android/app/build.gradle.kts
W=android/gradle/wrapper/gradle-wrapper.properties

# 1) Android Gradle Plugin sürümü
sed -i -E 's/(id\("com\.android\.application"\) version )"[^"]+"/\1"8.11.1"/' "$S"

# 2) Kotlin eklentisi: sürümü 2.2.20 yap, satır yoksa ekle
if grep -q 'org.jetbrains.kotlin.android' "$S"; then
  sed -i -E 's/(id\("org\.jetbrains\.kotlin\.android"\) version )"[^"]+"/\1"2.2.20"/' "$S"
else
  sed -i '/id("com.android.application")/a\    id("org.jetbrains.kotlin.android") version "2.2.20" apply false' "$S"
fi

# 3) Uygulama modülünde Kotlin eklentisi uygulanmalı (AGP 8'de dahili değil)
if ! grep -Eq 'org\.jetbrains\.kotlin\.android|kotlin-android' "$A"; then
  sed -i '0,/id("com.android.application")/s//id("com.android.application")\n    id("org.jetbrains.kotlin.android")/' "$A"
fi

# 4) Gradle sürümü (AGP 8.11 ile uyumlu)
sed -i -E 's#^distributionUrl=.*#distributionUrl=https\\://services.gradle.org/distributions/gradle-8.14.3-all.zip#' "$W"

# 4b) Yeni şablonun eklediği AGP 9'a özel ayarlar AGP 8'de sorun çıkarmasın
if [ -f android/gradle.properties ]; then
  sed -i '/^android\.newDsl/d;/^android\.builtInKotlin/d' android/gradle.properties || true
fi

# 5) Uygulama adı
sed -i 's/android:label="[^"]*"/android:label="Bono Çeviri"/' android/app/src/main/AndroidManifest.xml

echo "=== settings.gradle.kts ==="; cat "$S"
echo "=== app/build.gradle.kts ==="; cat "$A"
echo "=== gradle-wrapper.properties ==="; cat "$W"

# Doğrulama: yama tutmadıysa burada net bir hata ver
grep -q '"8.11.1"' "$S" || { echo "HATA: AGP sürümü yamalanamadı"; exit 1; }
grep -q '"2.2.20"' "$S" || { echo "HATA: Kotlin sürümü yamalanamadı"; exit 1; }
grep -q 'gradle-8.14.3' "$W" || { echo "HATA: Gradle sürümü yamalanamadı"; exit 1; }
grep -Eq 'org\.jetbrains\.kotlin\.android|kotlin-android' "$A" || { echo "HATA: app'e Kotlin eklentisi eklenemedi"; exit 1; }

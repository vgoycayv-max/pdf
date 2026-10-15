# Bono Çeviri

PDF'i telefonda açar, yazıları **kendi yerinde** Türkçeye çevirir (eski yazının üstüne yeni yazıyı koyar).
Resimli veya yan yana sayfalı PDF'lerde yazılar karışmaz, çünkü sıralama değişmez; her yazı bloğu yerinde çevrilir.

## Neler yapar
- PDF açar, sayfaları **alt alta sürekli kaydırarak** gösterir (DjVu sonra eklenecek)
- **Çeviri simgesi (üstte):** açınca kaydırdıkça görünen sayfa ve sonraki 2 sayfa kendiliğinden çevrilir. Tekrar basınca durur
- Alttaki sayfa numarasına dokun: istediğin sayfaya atlarsın (örn. 1250)
- Menü → "Tüm sayfaları çevir": hepsini sırayla çevirir ("Durdur" düğmesi var)
- Çevrilmiş yazıya **dokun** → düzelt → Kaydet. Düzeltme sözlüğe kalıcı yazılır
- Menü → "Çevrilmiş PDF'i kaydet": çevrilmiş halini yeni PDF yapar
- Menü → "Sözlüğü göster / düzenle": kayıtları uygulama içinde görür, düzenler, silersin
- Sözlüğü .txt olarak içe/dışa aktarabilirsin (toplu öbek eklemek için). Sözlük başta boştur; dışa aktarınca açıklama ve örnek satırlar gelir
- **Mod simgesi (üstte, kitap/telefon/bulut):** çeviri modunu seçersin
  - *Sadece sözlük:* internete çıkmaz, sadece sözlükteki öbekler çevrilir
  - *Sözlük + cihaz modeli:* internetsiz çalışan hazır çeviri modeli (Google ML Kit). İlk seçişte dil modelini bir kez indirir (internet gerekir, ~30 MB), sonra internetsiz çalışır. Kalitesi internet çevirisinden düşüktür
  - *Sözlük + internet:* en iyi kalite (Google)
  - Her modda önce sözlük bakılır, senin düzeltmelerin her zaman önce gelir
- **Yakınlaştırma:** iki parmakla aç/kapa ya da alttaki +/- düğmeleri (3 kata kadar)
- **Menü → PDF'lerde ara (klasör):** bir klasör seç (alt klasörler dahil). Aranan kelimenin geçtiği sayfalar resim olarak `/storage/emulated/0/Cikti` klasörüne kaydedilir. Dosya adı: `pdfadı_sayfa_numara.png`. İki tür arama: *İlk eşleşme* (her PDF'te ilk bulunan sayfa, sonra sonraki PDF'e geçer) ve *Tüm eşleşmeler*. Büyük/küçük harf ve ç ğ ı ö ş ü farkı yok sayılır. İlk kullanımda "tüm dosyalara erişim" izni sorulur, ayarlarda Bono Çeviri için aç. Taranmış (resimden ibaret, yazı katmanı olmayan) PDF'lerde sonuç çıkmaz.
- **Menü → TXT dosyası çevir:** .txt dosyasını satır satır, seçili çeviri moduyla çevirir, `ad_tr.txt` olarak kaydeder
- Menü → Ayarlar: yazı boyu, kutu payı, sütun ayırma (çeviri yazısı büyük/küçükse veya sütunlar karışıyorsa buradan ayarla)
- Çevrilen yazı kendi kutusunun dışına taşmaz (sığana kadar küçülür)
- Formül ve sayfa numarası gibi yazı olmayan parçalar çevrilmez
- Zaten Türkçe olan paragraflar tekrar çevrilmez (dil otomatik bulunur), üstüne yazı konmaz

## Sözlük nasıl çalışır
Satır biçimi (her satıra bir tane):

    good morning => günaydın
    as a result of the => ... sonucunda

Çeviri sırası: önce tüm paragraf sözlükte var mı bakar. Yoksa cümleyi soldan sağa tarar, her yerde **en uzun** eşleşmeyi alır (7 kelime, olmazsa 6, 5, 4, 3, 2, 1). Eşleşmeyen kısımları çeviri servisine sorar, parçaları birleştirir. Büyük/küçük harf ve kenardaki noktalama önemsiz.

## APK nasıl alınır (GitHub)
1. GitHub'da yeni bir depo aç, bu klasörün **içindekileri** yükle (`.github` klasörü de dahil, gizli klasördür, atlama).
2. Depoda **Actions** sekmesi → "Build APK" → **Run workflow**.
3. Bitince çalışmanın sayfasında **Artifacts** altından `bono-ceviri-apk` indir, zip'in içindeki `app-release.apk` dosyasını kur.

## Dosyalar ne işe yarar
- `lib/main.dart`: ekran ve düğmeler
- `lib/pdf_tools.dart`: yazı bloklarını bulur, çeviriyi sayfanın üstüne çizer, PDF üretir
- `lib/translator.dart`: sözlük + çeviri servisi
- `.github/workflows/build.yml`: GitHub'da APK'yı derleyen ayar
- `tools/patch_android.sh`: Android derleme sürümlerini düzelten yama (Bono Reader'dan)
- `pubspec.yaml`: kullanılan hazır paketlerin listesi

## Bilinmesi gerekenler
- Çeviri için internet gerekir. Servis Google'ın anahtarsız kapısıdır, resmi değildir; çok yoğun kullanımda geçici engellenebilir. Çevrilen metin bellekte tutulur, sözlükteki öbekler hiç servise gitmez.
- Kaydedilen PDF'te sayfalar resim olarak durur (yazı seçilemez). Çok sayfalı PDF'te hazırlanması yavaş olabilir.
- Çeviri şu an **sadece internetle** çalışır (sözlük internetsiz çalışır). İnternetsiz çeviri modeli sonraki adım.
- Yakınlaştırma (zoom) henüz yok. Dönük sayfalar ve resmin içindeki yazılar (OCR) da yok.
- **Rusça eklemek için:** `translator.dart` içindeki `langPair` değerini `'en-ru'` yap. Her dil çifti kendi sözlük dosyasını kullanır.
- İlk derlemede hata çıkarsa Actions günlüğündeki kırmızı hata satırını bana yapıştır, düzeltirim.

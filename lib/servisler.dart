import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Servis "bu metin zaten hedef dilde" derse sonuç bu işaretle başlar.
const ayniIsareti = '\u0001';

/// Bir çeviri hizmeti. Üst üste hata alırsa kısa süre dinlendirilir (engellenmesin diye).
abstract class Servis {
  String get kod;
  String get ad;
  String get aciklama;

  /// Tek istekte gönderilecek en çok karakter.
  int get maksKarakter => 1500;

  int ardArdaHata = 0;
  DateTime? kapaliBitis;

  bool get musait => kapaliBitis == null || DateTime.now().isAfter(kapaliBitis!);

  void basari() {
    ardArdaHata = 0;
    kapaliBitis = null;
  }

  void hata() {
    ardArdaHata++;
    if (ardArdaHata >= 3) kapaliBitis = DateTime.now().add(Duration(seconds: min(300, 30 * ardArdaHata)));
  }

  /// [kaynak] 'auto' olabilir. Çok satırlı metin gönderilebilir.
  Future<String> cevir(String metin, String kaynak, String hedef);

  /// Birden çok satırı tek istekte çevirir. Satır sayısı tutmazsa satır satır çevirir.
  Future<List<String>> satirlar(List<String> g, String kaynak, String hedef) async {
    if (g.length > 1) {
      final r = await cevir(g.join('\n'), kaynak, hedef);
      if (r.startsWith(ayniIsareti)) return List<String>.from(g);
      final p = r.split('\n');
      if (p.length == g.length) return p;
    }
    final cikti = <String>[];
    for (final l in g) {
      cikti.add(await tekSatir(l, kaynak, hedef));
    }
    return cikti;
  }

  Future<String> tekSatir(String l, String kaynak, String hedef) async {
    if (l.length <= maksKarakter) {
      final r = await cevir(l, kaynak, hedef);
      return r.startsWith(ayniIsareti) ? l : r;
    }
    // Çok uzun satır: cümle sınırlarından bölerek gönder
    final cikti = <String>[];
    var kalan = l;
    while (kalan.length > maksKarakter) {
      var kes = kalan.lastIndexOf('. ', maksKarakter);
      if (kes < 200) kes = kalan.lastIndexOf(' ', maksKarakter);
      if (kes < 1) kes = maksKarakter;
      cikti.add(await tekSatir(kalan.substring(0, kes + 1), kaynak, hedef));
      kalan = kalan.substring(kes + 1).trimLeft();
    }
    if (kalan.isNotEmpty) cikti.add(await tekSatir(kalan, kaynak, hedef));
    return cikti.join(' ');
  }
}

/// Google'ın anahtarsız (resmi olmayan) kapısı.
class GoogleServis extends Servis {
  @override
  String get kod => 'google';
  @override
  String get ad => 'Google';
  @override
  String get aciklama => 'Anahtarsız, resmi olmayan kapı. Çok istekte geçici engelleyebilir.';

  @override
  Future<String> cevir(String m, String k, String h) async {
    final u = Uri.https('translate.googleapis.com', '/translate_a/single',
        {'client': 'gtx', 'sl': k, 'tl': h, 'dt': 't', 'q': m});
    final r = await http.get(u).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    final s = (j[0] as List).map((e) => (e[0] ?? '').toString()).join();
    if (k == 'auto' && j is List && j.length > 2 && j[2] == h) return ayniIsareti + m;
    return s;
  }
}

/// Microsoft Edge'in çeviri kapısı. Bing Translator ile aynı motor. Anahtar gerekmez.
class MicrosoftServis extends Servis {
  String? _jeton;
  DateTime _bitis = DateTime(2000);

  @override
  String get kod => 'microsoft';
  @override
  String get ad => 'Microsoft / Bing';
  @override
  String get aciklama => 'Bing Translator ile aynı motor. Anahtarsız, resmi olmayan kapı.';
  @override
  int get maksKarakter => 4000;

  Future<String> _jetonAl(bool zorla) async {
    if (!zorla && _jeton != null && DateTime.now().isBefore(_bitis)) return _jeton!;
    final r = await http.get(Uri.parse('https://edge.microsoft.com/translate/auth')).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200 || r.body.trim().isEmpty) throw Exception('jeton alınamadı (HTTP ${r.statusCode})');
    _jeton = r.body.trim();
    _bitis = DateTime.now().add(const Duration(minutes: 8));
    return _jeton!;
  }

  @override
  Future<String> cevir(String m, String k, String h) async {
    for (var deneme = 0; deneme < 2; deneme++) {
      final jeton = await _jetonAl(deneme == 1);
      final q = {'api-version': '3.0', 'to': h, if (k != 'auto') 'from': k};
      final r = await http
          .post(
            Uri.https('api-edge.cognitive.microsofttranslator.com', '/translate', q),
            headers: {'Authorization': 'Bearer $jeton', 'Content-Type': 'application/json'},
            body: jsonEncode([
              {'Text': m}
            ]),
          )
          .timeout(const Duration(seconds: 25));
      if (r.statusCode == 401 && deneme == 0) continue; // jeton süresi dolmuş, yenisini al
      if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (k == 'auto' && j[0]['detectedLanguage']?['language'] == h) return ayniIsareti + m;
      return j[0]['translations'][0]['text'] as String;
    }
    throw Exception('yetkilendirme başarısız');
  }
}

/// Yandex'in mobil uygulama kapısı. Deneysel: sık sık engellenir ya da değişir.
class YandexServis extends Servis {
  final String _ucid = () {
    final r = Random.secure();
    return List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
  }();

  @override
  String get kod => 'yandex';
  @override
  String get ad => 'Yandex (deneysel)';
  @override
  String get aciklama => 'Rusça için iyidir. Anahtarsız kapı, çalışmayabilir.';
  @override
  int get maksKarakter => 3000;

  @override
  Future<String> cevir(String m, String k, String h) async {
    final u = Uri.https('translate.yandex.net', '/api/v1/tr.json/translate',
        {'srv': 'android', 'ucid': _ucid, 'lang': k == 'auto' ? h : '$k-$h', 'format': 'text'});
    final r = await http.post(u, body: {'text': m}).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j['code'] != 200) throw Exception('kod ${j['code']}');
    if (k == 'auto' && j['lang'] == '$h-$h') return ayniIsareti + m;
    return (j['text'] as List).join('');
  }
}

/// Lingva: Google çevirisinin açık aynası. Deneysel, sunucular zaman zaman kapalı olur.
class LingvaServis extends Servis {
  static const sunucular = ['lingva.ml', 'lingva.thedaviddelta.com'];

  @override
  String get kod => 'lingva';
  @override
  String get ad => 'Lingva (deneysel)';
  @override
  String get aciklama => 'Google kalitesi, farklı adresten. Sunucu kapalı olabilir.';
  @override
  int get maksKarakter => 1200;

  @override
  Future<String> cevir(String m, String k, String h) async {
    final hatalar = <String>[];
    for (final s in sunucular) {
      try {
        final u = Uri.parse('https://$s/api/v1/$k/$h/${Uri.encodeComponent(m)}');
        final r = await http.get(u).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          hatalar.add('$s HTTP ${r.statusCode}');
          continue;
        }
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        return (j['translation'] ?? '').toString();
      } catch (e) {
        hatalar.add('$s: bağlantı yok');
      }
    }
    throw Exception(hatalar.join(', '));
  }
}

/// Telefonun içindeki çeviri modeli (Google ML Kit). İnternetsiz çalışır.
class CihazServis extends Servis {
  OnDeviceTranslator? _motor;
  String? _anahtar;

  @override
  String get kod => 'cihaz';
  @override
  String get ad => 'Cihaz modeli (internetsiz)';
  @override
  String get aciklama => 'Telefonda çalışır, internet gerekmez. Kalite orta. Dil modeli bir kez iner.';
  @override
  int get maksKarakter => 3000;

  static TranslateLanguage dilKodu(String kod) {
    switch (kod) {
      case 'tr':
        return TranslateLanguage.turkish;
      case 'ru':
        return TranslateLanguage.russian;
      default:
        return TranslateLanguage.english;
    }
  }

  @override
  Future<String> cevir(String m, String k, String h) async {
    final kk = k == 'auto' ? 'en' : k;
    final a = '$kk-$h';
    if (_anahtar != a) {
      await _motor?.close();
      _motor = OnDeviceTranslator(sourceLanguage: dilKodu(kk), targetLanguage: dilKodu(h));
      _anahtar = a;
    }
    return _motor!.translateText(m);
  }
}

/// Cihaz içi dil modellerini kontrol eder, yoksa indirir (bir kereliğine internet gerekir).
Future<void> cihazModelHazirla(List<String> kodlar, void Function(String) bilgi) async {
  final yonetici = OnDeviceTranslatorModelManager();
  for (final kod in kodlar) {
    final dil = CihazServis.dilKodu(kod);
    if (!await yonetici.isModelDownloaded(dil.bcpCode)) {
      bilgi('Dil modeli indiriliyor: ${dil.bcpCode} (bir kez, ~30 MB)...');
      final ok = await yonetici.downloadModel(dil.bcpCode, isWifiRequired: false);
      if (!ok) throw Exception('Dil modeli indirilemedi. İnternet bağlantısını kontrol et.');
    }
  }
}

final Map<String, Servis> tumServisler = {
  'google': GoogleServis(),
  'microsoft': MicrosoftServis(),
  'yandex': YandexServis(),
  'lingva': LingvaServis(),
  'cihaz': CihazServis(),
};

/// Hangi hizmetlerin kullanılacağı (kalıcı).
class ServisAyar {
  static Set<String> secili = {'google', 'microsoft'};

  /// İnternet hizmetleri (PDF çevirisinde ve çevrimiçi modda kullanılır).
  static List<Servis> online() => [
        for (final k in const ['google', 'microsoft', 'yandex', 'lingva'])
          if (secili.contains(k)) tumServisler[k]!
      ];

  /// Seçili tüm hizmetler (TXT çevirisinde cihaz modeli de dahil).
  static List<Servis> secilenler() => [
        for (final k in tumServisler.keys)
          if (secili.contains(k)) tumServisler[k]!
      ];

  static Future<File> _dosya() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/servis_ayar.json');
  }

  static Future<void> yukle() async {
    try {
      final f = await _dosya();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      final l = (j['secili'] as List).map((e) => e.toString()).where(tumServisler.containsKey).toSet();
      if (l.isNotEmpty) secili = l;
    } catch (_) {}
  }

  static Future<void> kaydet() async {
    try {
      final f = await _dosya();
      await f.writeAsString(jsonEncode({'secili': secili.toList()}));
    } catch (_) {}
  }
}

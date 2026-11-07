import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import 'servisler.dart';

/// Dil çifti. Rusça için ileride 'en-ru' yapılır (ayrı sözlük dosyası kullanır).
const langPair = 'en-tr';

/// Sözlükte aranacak en uzun öbek (kelime sayısı).
const maxPhrase = 7;

/// Karşılaştırma için metni sadeleştirir: küçük harf, kenar noktalama yok, tek boşluk.
String norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(RegExp(r'^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$', unicode: true), '')
    .trim();

/// Düzenlenebilir sözlük. Dosya satırı:  ingilizce öbek => türkçe karşılığı
/// '#' ile başlayan satırlar yorumdur.
class Sozluk {
  final Map<String, String> map = {};
  late File dosya;

  static Future<Sozluk> yukle() async {
    final d = await getApplicationDocumentsDirectory();
    final s = Sozluk()..dosya = File('${d.path}/sozluk_$langPair.txt');
    if (await s.dosya.exists()) s.metinEkle(await s.dosya.readAsString());
    return s;
  }

  int metinEkle(String t) {
    var n = 0;
    for (final satir in t.split('\n')) {
      if (satir.trimLeft().startsWith('#')) continue;
      final i = satir.indexOf('=>');
      if (i < 0) continue;
      final k = norm(satir.substring(0, i));
      final v = satir.substring(i + 2).trim();
      if (k.isEmpty || v.isEmpty) continue;
      map[k] = v;
      n++;
    }
    return n;
  }

  String metin() => map.entries.map((e) => '${e.key} => ${e.value}').join('\n');

  /// Dışa aktarılan dosya: açıklama + (varsa) kayıtlar. Boşsa örnek satırlar da gelir.
  String disaMetin() {
    final b = StringBuffer()
      ..writeln('# Bono Çeviri sözlüğü ($langPair)')
      ..writeln('# Her satır:  ingilizce öbek => türkçe karşılığı')
      ..writeln('# Öbek 1-$maxPhrase kelime olabilir. # ile başlayan satırlar yorumdur.');
    if (map.isEmpty) {
      b
        ..writeln('# Örnek (başındaki # işaretini silince çalışır):')
        ..writeln('# good morning => günaydın')
        ..writeln('# as a result of => ... sonucunda');
    } else {
      b.writeln(metin());
    }
    return b.toString();
  }

  Future<void> kaydet() => dosya.writeAsString(metin());
}

class Cevirici {
  static const _ayni = ayniIsareti; // "bu zaten hedef dilde" işareti
  final Sozluk sozluk;
  final Map<String, String> _onbellek = {};
  int _sira = 0;

  /// 0 = sadece sözlük (internet yok), 1 = sözlük + cihaz içi model (internet yok),
  /// 2 = sözlük + internet (seçili hizmetler aynı anda, sırayla dağıtılır)
  int mod = 2;

  Cevirici(this.sozluk);

  /// Cihaz içi dil modellerini kontrol eder, yoksa indirir (bir kereliğine internet gerekir).
  Future<void> modelHazirla(void Function(String) bilgi) => cihazModelHazirla(langPair.split('-'), bilgi);

  /// Önce sözlük (en uzun öbek önce: 7,6,5...1 kelime), eşleşmeyen kısım seçili moda göre çevrilir.
  /// Metin zaten hedef dildeyse (ve sözlükten de bir şey gelmediyse) null döner: dokunulmaz.
  Future<String?> cevir(String metin) async {
    final tam = sozluk.map[norm(metin)];
    if (tam != null) return tam;

    final kelimeler = metin.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final parcalar = <String>[];
    final bosluk = <String>[];
    var degisti = false;

    Future<void> bosalt() async {
      if (bosluk.isEmpty) return;
      if (mod == 0) {
        parcalar.add(bosluk.join(' '));
        bosluk.clear();
        return;
      }
      final s = await _servis(bosluk.join(' '));
      if (s.startsWith(_ayni)) {
        parcalar.add(s.substring(1));
      } else {
        parcalar.add(s);
        degisti = true;
      }
      bosluk.clear();
    }

    var i = 0;
    while (i < kelimeler.length) {
      var bulundu = false;
      for (var n = min(maxPhrase, kelimeler.length - i); n >= 1; n--) {
        final v = sozluk.map[norm(kelimeler.sublist(i, i + n).join(' '))];
        if (v != null) {
          await bosalt();
          parcalar.add(v);
          degisti = true;
          i += n;
          bulundu = true;
          break;
        }
      }
      if (!bulundu) {
        bosluk.add(kelimeler[i]);
        i++;
      }
    }
    await bosalt();
    return degisti ? parcalar.join(' ') : null;
  }

  // Çok uzun metni cümle sınırlarından bölerek gönderir.
  Future<String> _servis(String m) async {
    if (m.length <= 1500) return _tek(m);
    final cikti = <String>[];
    var kalan = m;
    while (kalan.length > 1500) {
      var kes = kalan.lastIndexOf('. ', 1500);
      if (kes < 300) kes = kalan.lastIndexOf(' ', 1500);
      if (kes < 1) kes = 1500;
      cikti.add(await _tek(kalan.substring(0, kes + 1)));
      kalan = kalan.substring(kes + 1).trimLeft();
    }
    if (kalan.isNotEmpty) cikti.add(await _tek(kalan));
    final temiz = cikti.map((e) => e.startsWith(_ayni) ? e.substring(1) : e).toList();
    return (cikti.every((e) => e.startsWith(_ayni)) ? _ayni : '') + temiz.join(' ');
  }

  /// Seçili hizmetlere sırayla dağıtır; biri hata verirse sıradakine geçer.
  Future<String> _tek(String m) async {
    final anahtar = '$mod|$m';
    final c = _onbellek[anahtar];
    if (c != null) return c;
    if (_turkceGibi(m)) return _ayni + m;

    final dil = langPair.split('-');
    List<Servis> adaylar;
    if (mod == 1) {
      adaylar = [tumServisler['cihaz']!];
    } else {
      adaylar = ServisAyar.online();
      if (adaylar.isEmpty) adaylar = [tumServisler['google']!];
    }
    final hatalar = <String>[];
    final bas = _sira++;
    for (var k = 0; k < adaylar.length; k++) {
      final s = adaylar[(bas + k) % adaylar.length];
      if (!s.musait) continue;
      try {
        final r = await s.cevir(m, s is CihazServis ? dil[0] : 'auto', dil[1]);
        s.basari();
        _onbellek[anahtar] = r;
        return r;
      } catch (e) {
        s.hata();
        hatalar.add('${s.ad}: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
    throw Exception(hatalar.isEmpty
        ? 'Seçili çeviri hizmetleri geçici olarak dinleniyor, biraz sonra tekrar denenecek.'
        : hatalar.join(' | '));
  }

  // Dil algılaması olmayan hizmetler için: metin zaten Türkçe harfler içeriyorsa çevirme.
  bool _turkceGibi(String m) {
    final harf = RegExp(r'\p{L}', unicode: true).allMatches(m).length;
    if (harf < 20) return false;
    final tr = RegExp(r'[ğĞıİşŞ]').allMatches(m).length;
    return tr / harf > 0.015;
  }
}

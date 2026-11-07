import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'servisler.dart';
import 'translator.dart';

/// Hangi hizmetlerin kullanılacağını seçtiren pencere.
Future<void> servisDialogu(BuildContext context) async {
  await showDialog(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: const Text('Çeviri hizmetleri'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Seçtiklerin aynı anda çalışır. Biri durursa iş diğerine geçer.', style: TextStyle(fontSize: 12)),
            for (final s in tumServisler.values)
              CheckboxListTile(
                dense: true,
                value: ServisAyar.secili.contains(s.kod),
                title: Text(s.ad),
                subtitle: Text(s.aciklama, style: const TextStyle(fontSize: 11)),
                onChanged: (v) {
                  setS(() {
                    if (v == true) {
                      ServisAyar.secili.add(s.kod);
                    } else {
                      ServisAyar.secili.remove(s.kod);
                    }
                  });
                  ServisAyar.kaydet();
                },
              ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Tamam'))],
      ),
    ),
  );
}

class _Bolum {
  final int bas, son; // satır aralığı [bas, son)
  int durum = 0; // 0 bekliyor, 1 çevriliyor, 2 bitti, 3 hata
  final Set<String> denenen = {};
  final List<String> hatalar = [];
  _Bolum(this.bas, this.son);
}

class TxtCeviriSayfasi extends StatefulWidget {
  final Sozluk sozluk;
  const TxtCeviriSayfasi({super.key, required this.sozluk});

  @override
  State<TxtCeviriSayfasi> createState() => _TxtCeviriSayfasiState();
}

class _TxtCeviriSayfasiState extends State<TxtCeviriSayfasi> {
  String ad = '';
  List<String> satirlar = [];
  List<String?> ceviri = [];
  List<_Bolum> bolumler = [];
  int bolumBoyu = 30;
  bool calisiyor = false;
  bool durdur = false;
  final List<String> gunluk = [];
  File? ilerlemeDosyasi;

  List<String> get dil => langPair.split('-');

  void mesaj(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void log(String m) {
    if (mounted) setState(() => gunluk.add(m));
  }

  void bolumleriKur() {
    bolumler = [for (var i = 0; i < satirlar.length; i += bolumBoyu) _Bolum(i, min(i + bolumBoyu, satirlar.length))];
    for (final b in bolumler) {
      var tamam = true;
      for (var i = b.bas; i < b.son; i++) {
        if (ceviri[i] == null) tamam = false;
      }
      if (tamam) b.durum = 2;
    }
  }

  Future<void> dosyaSec() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt']);
    final yol = r?.files.single.path;
    if (yol == null) return;
    try {
      final metin = utf8.decode(await File(yol).readAsBytes(), allowMalformed: true);
      final l = metin.split('\n').map((s) => s.endsWith('\r') ? s.substring(0, s.length - 1) : s).toList();
      final son = yol.split('/').last;
      ad = son.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');
      satirlar = l;
      ceviri = [for (final s in l) s.trim().isEmpty ? '' : null];
      gunluk.clear();
      // Önceki yarım kalmış çeviri varsa yükle
      final d = await getApplicationDocumentsDirectory();
      await Directory('${d.path}/txt_ilerleme').create(recursive: true);
      final guvenli = ad.replaceAll(RegExp(r'[^\w\-]'), '_');
      ilerlemeDosyasi = File('${d.path}/txt_ilerleme/${guvenli}_${l.length}.jsonl');
      var yuklenen = 0;
      if (await ilerlemeDosyasi!.exists()) {
        for (final satir in await ilerlemeDosyasi!.readAsLines()) {
          try {
            final j = jsonDecode(satir);
            final b = j['b'] as int;
            final t = (j['t'] as List).map((e) => e as String?).toList();
            for (var k = 0; k < t.length && b + k < ceviri.length; k++) {
              if (t[k] != null && ceviri[b + k] == null) {
                ceviri[b + k] = t[k];
                yuklenen++;
              }
            }
          } catch (_) {}
        }
      }
      bolumleriKur();
      setState(() {});
      if (yuklenen > 0) mesaj('Önceki çeviriden $yuklenen satır geri yüklendi, kaldığı yerden devam eder.');
    } catch (e) {
      mesaj('Dosya okunamadı: $e');
    }
  }

  // ---------- çeviri ----------

  _Bolum? sonraki(Servis s) {
    if (!s.musait) return null;
    for (final b in bolumler) {
      if (b.durum == 0 && !b.denenen.contains(s.kod)) return b;
    }
    return null;
  }

  Future<void> bolumCevir(Servis s, _Bolum b) async {
    final sonuc = <int, String>{};
    final servisIdx = <int>[];
    for (var i = b.bas; i < b.son; i++) {
      if (ceviri[i] != null) continue;
      final tam = widget.sozluk.map[norm(satirlar[i])]; // sözlükte tam satır varsa onu kullan
      if (tam != null) {
        sonuc[i] = tam;
      } else {
        servisIdx.add(i);
      }
    }
    final kaynak = s is CihazServis ? dil[0] : 'auto';
    var grup = <int>[];
    var n = 0;
    Future<void> bosalt() async {
      if (grup.isEmpty) return;
      final r = await s.satirlar([for (final i in grup) satirlar[i].trim()], kaynak, dil[1]);
      for (var k = 0; k < grup.length; k++) {
        sonuc[grup[k]] = r[k];
      }
      grup = [];
      n = 0;
    }

    for (final i in servisIdx) {
      final uzun = satirlar[i].length + 1;
      if (n + uzun > s.maksKarakter && grup.isNotEmpty) await bosalt();
      grup.add(i);
      n += uzun;
    }
    await bosalt();
    // hepsi başarılıysa yaz (yarım bölüm kalmasın)
    sonuc.forEach((i, t) => ceviri[i] = t);
  }

  Future<void> bolumuKaydet(_Bolum b) async {
    try {
      final satir = jsonEncode({'b': b.bas, 't': [for (var i = b.bas; i < b.son; i++) ceviri[i]]});
      await ilerlemeDosyasi?.writeAsString('$satir\n', mode: FileMode.append);
    } catch (_) {}
  }

  Future<void> isci(Servis s, int toplam) async {
    while (!durdur) {
      final b = sonraki(s);
      if (b == null) {
        if (!bolumler.any((x) => x.durum == 0 || x.durum == 1)) break;
        await Future.delayed(const Duration(milliseconds: 400));
        continue;
      }
      b.durum = 1;
      if (mounted) setState(() {});
      try {
        await bolumCevir(s, b);
        b.durum = 2;
        s.basari();
        await bolumuKaydet(b);
      } catch (e) {
        s.hata();
        b.denenen.add(s.kod);
        b.hatalar.add('${s.ad}: ${e.toString().replaceFirst('Exception: ', '')}');
        if (b.denenen.length >= toplam) {
          b.durum = 3;
          log('Satır ${b.bas + 1}-${b.son}: çevrilemedi (${b.hatalar.join('; ')})');
        } else {
          b.durum = 0; // başka hizmet denesin
        }
        await Future.delayed(Duration(seconds: min(10, 2 * s.ardArdaHata)));
      }
      if (mounted) setState(() {});
    }
  }

  Future<void> baslat({bool hatalilariSifirla = false}) async {
    if (satirlar.isEmpty) {
      mesaj('Önce bir TXT dosyası seç.');
      return;
    }
    var servisler = ServisAyar.secilenler();
    if (servisler.isEmpty) {
      mesaj('En az bir çeviri hizmeti seç.');
      return;
    }
    setState(() {
      calisiyor = true;
      durdur = false;
    });
    if (hatalilariSifirla) {
      for (final b in bolumler) {
        if (b.durum == 3) {
          b.durum = 0;
          b.denenen.clear();
          b.hatalar.clear();
        }
      }
    }
    for (final s in servisler) {
      s.basari(); // eski dinlendirmeleri sıfırla
    }
    if (servisler.any((s) => s is CihazServis)) {
      try {
        await cihazModelHazirla(dil, (b) => mesaj(b));
      } catch (e) {
        log('Cihaz modeli kullanılamadı: ${e.toString().replaceFirst('Exception: ', '')}');
        servisler = servisler.where((s) => s is! CihazServis).toList();
      }
    }
    if (servisler.isNotEmpty) {
      await Future.wait(servisler.map((s) => isci(s, servisler.length)));
    }
    final hatali = bolumler.where((b) => b.durum == 3).length;
    final bitti = bolumler.where((b) => b.durum == 2).length;
    log(durdur
        ? 'Durduruldu: $bitti/${bolumler.length} bölüm çevrildi.'
        : 'Bitti: $bitti/${bolumler.length} bölüm çevrildi, $hatali bölüm çevrilemedi.');
    // durdurulunca "çevriliyor" kalan bölümleri bekliyora al
    for (final b in bolumler) {
      if (b.durum == 1) b.durum = 0;
    }
    if (mounted) {
      setState(() => calisiyor = false);
      if (hatali > 0) mesaj('$hatali bölüm çevrilemedi, günlüğe bak. Hatalıları yeniden deneyebilirsin.');
    }
  }

  // ---------- kaydetme ----------

  Future<void> kaydet() async {
    if (satirlar.isEmpty) return;
    final cikti = [for (var i = 0; i < satirlar.length; i++) ceviri[i] ?? satirlar[i]];
    final yol = await FilePicker.platform.saveFile(
      dialogTitle: 'Çevrilmiş TXT\'i kaydet',
      fileName: '${ad}_tr.txt',
      bytes: utf8.encode(cikti.join('\n')),
    );
    if (yol != null) mesaj('Kaydedildi. Çevrilemeyen satırlar orijinal haliyle yazıldı.');
  }

  Future<void> gunluguGoster() async {
    await showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Günlük (${gunluk.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: gunluk.isEmpty
              ? const Text('Kayıt yok.')
              : ListView(shrinkWrap: true, children: [for (final g in gunluk) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(g, style: const TextStyle(fontSize: 12)))]),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await FilePicker.platform.saveFile(
                dialogTitle: 'Günlüğü kaydet',
                fileName: '${ad}_hata_gunlugu.txt',
                bytes: utf8.encode(gunluk.join('\n')),
              );
            },
            child: const Text('Günlüğü kaydet'),
          ),
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Kapat')),
        ],
      ),
    );
  }

  // ---------- ekran ----------

  @override
  Widget build(BuildContext context) {
    final bitti = bolumler.where((b) => b.durum == 2).length;
    final hatali = bolumler.where((b) => b.durum == 3).length;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(ad.isEmpty ? 'TXT çevir' : ad, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(icon: const Icon(Icons.folder_open), tooltip: 'TXT seç', onPressed: calisiyor ? null : dosyaSec),
          IconButton(icon: const Icon(Icons.save_alt), tooltip: 'Kaydet', onPressed: satirlar.isEmpty ? null : kaydet),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Wrap(spacing: 6, runSpacing: 0, crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final s in tumServisler.values)
              FilterChip(
                label: Text(s.ad, style: const TextStyle(fontSize: 12)),
                selected: ServisAyar.secili.contains(s.kod),
                onSelected: calisiyor
                    ? null
                    : (v) {
                        setState(() => v ? ServisAyar.secili.add(s.kod) : ServisAyar.secili.remove(s.kod));
                        ServisAyar.kaydet();
                      },
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(children: [
            const Text('Bölüm: '),
            DropdownButton<int>(
              value: bolumBoyu,
              items: [for (final n in const [10, 20, 30, 50, 100]) DropdownMenuItem(value: n, child: Text('$n satır'))],
              onChanged: calisiyor || satirlar.isEmpty
                  ? null
                  : (v) => setState(() {
                        bolumBoyu = v ?? 30;
                        bolumleriKur();
                      }),
            ),
            const Spacer(),
            if (hatali > 0 && !calisiyor)
              TextButton(onPressed: () => baslat(hatalilariSifirla: true), child: const Text('Hatalıları dene')),
            FilledButton.icon(
              onPressed: satirlar.isEmpty ? null : (calisiyor ? () => setState(() => durdur = true) : () => baslat()),
              icon: Icon(calisiyor ? Icons.stop : Icons.play_arrow),
              label: Text(calisiyor ? 'Durdur' : (bitti > 0 ? 'Devam' : 'Başlat')),
            ),
          ]),
        ),
        if (bolumler.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              LinearProgressIndicator(value: bitti / bolumler.length),
              Row(children: [
                Text('$bitti/${bolumler.length} bölüm${hatali > 0 ? ', $hatali hatalı' : ''}', style: const TextStyle(fontSize: 12)),
                const Spacer(),
                TextButton(
                  onPressed: gunluguGoster,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: Text('Günlük (${gunluk.length})'),
                ),
              ]),
            ]),
          ),
        const Divider(height: 1),
        Expanded(
          child: satirlar.isEmpty
              ? const Center(child: Text('Başlamak için üstten bir TXT dosyası seç.\nÇeviri sürerken aşağıdan okuyabilirsin.', textAlign: TextAlign.center))
              : ListView.builder(
                  itemCount: satirlar.length,
                  itemBuilder: (c, i) {
                    final t = ceviri[i];
                    final bolum = bolumler.isEmpty ? null : bolumler[min(i ~/ bolumBoyu, bolumler.length - 1)];
                    final hataliSatir = bolum?.durum == 3 && t == null;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      child: Text(
                        t ?? satirlar[i],
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.35,
                          color: t != null ? null : (hataliSatir ? cs.error : Theme.of(context).hintColor),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

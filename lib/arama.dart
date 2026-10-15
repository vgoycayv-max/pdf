import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:permission_handler/permission_handler.dart';
import 'pdf_tools.dart';

/// Bulunan sayfaların resimleri buraya kaydedilir.
const cikisKlasoru = '/storage/emulated/0/Cikti';

/// Aramada büyük/küçük harf ve Türkçe harf farkı (ç, ğ, ı, ö, ş, ü) yok sayılır.
String katla(String s) {
  const m = {
    'İ': 'i', 'I': 'i', 'ı': 'i', 'Ğ': 'g', 'ğ': 'g', 'Ş': 's', 'ş': 's',
    'Ç': 'c', 'ç': 'c', 'Ö': 'o', 'ö': 'o', 'Ü': 'u', 'ü': 'u',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    b.write(m[ch] ?? ch.toLowerCase());
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _dosyaAdi(String yol) {
  final son = yol.split('/').last;
  final ad = son.toLowerCase().endsWith('.pdf') ? son.substring(0, son.length - 4) : son;
  return ad.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
}

class AramaSayfasi extends StatefulWidget {
  const AramaSayfasi({super.key});

  @override
  State<AramaSayfasi> createState() => _AramaSayfasiState();
}

class _AramaSayfasiState extends State<AramaSayfasi> {
  String? klasor;
  final sorgu = TextEditingController();
  bool tumu = false; // false: her PDF'te ilk eşleşme, true: tüm eşleşmeler
  bool calisiyor = false;
  bool durdur = false;
  String durum = '';
  int bulunan = 0;
  final List<String> kayitlar = [];
  final Set<String> buOturum = {};

  void kayit(String m) {
    if (mounted) setState(() => kayitlar.insert(0, m));
  }

  void mesaj(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<bool> izinVar() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    if ((await Permission.manageExternalStorage.request()).isGranted) return true;
    return (await Permission.storage.request()).isGranted;
  }

  Future<void> klasorSec() async {
    if (!await izinVar()) {
      mesaj('Klasörlere erişmek için "tüm dosyalara erişim" izni gerekli. Açılan ayarda Bono Çeviri için izni aç.');
      return;
    }
    final yol = await FilePicker.platform.getDirectoryPath();
    if (yol != null) setState(() => klasor = yol);
  }

  Future<void> sayfayiKaydet(PdfPage p, String ad, String pdfYolu, int no) async {
    final im = await sayfaResmi(p, <Blok>[], genislik: 1600);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    var yol = '$cikisKlasoru/${ad}_sayfa_$no.png';
    var k = 2;
    // Bu aramada aynı isim zaten yazıldıysa (başka alt klasörde aynı PDF adı) üstüne yazma
    while (buOturum.contains(yol)) {
      yol = '$cikisKlasoru/${ad}_sayfa_${no}_$k.png';
      k++;
    }
    buOturum.add(yol);
    await File(yol).writeAsBytes(bd!.buffer.asUint8List());
    bulunan++;
    kayit('Kaydedildi: ${yol.split('/').last}');
  }

  Future<void> ara() async {
    final kok = klasor;
    final q = katla(sorgu.text);
    if (kok == null || q.isEmpty) {
      mesaj('Önce klasör seç ve aranacak kelimeyi yaz.');
      return;
    }
    if (!await izinVar()) {
      mesaj('Tüm dosyalara erişim izni gerekli.');
      return;
    }
    setState(() {
      calisiyor = true;
      durdur = false;
      bulunan = 0;
      kayitlar.clear();
      buOturum.clear();
      durum = 'PDF dosyaları aranıyor...';
    });
    try {
      final pdfler = <File>[];
      await for (final e in Directory(kok).list(recursive: true, followLinks: false).handleError((_) {})) {
        if (e is File && e.path.toLowerCase().endsWith('.pdf')) pdfler.add(e);
        if (durdur) break;
      }
      pdfler.sort((a, b) => a.path.compareTo(b.path));
      await Directory(cikisKlasoru).create(recursive: true);
      kayit('${pdfler.length} PDF bulundu.');

      for (var f = 0; f < pdfler.length && !durdur; f++) {
        final dosya = pdfler[f];
        final ad = _dosyaAdi(dosya.path);
        final PdfDocument d;
        try {
          d = await PdfDocument.openFile(dosya.path);
        } catch (_) {
          kayit('Açılamadı (atlandı): $ad');
          continue;
        }
        try {
          for (var i = 0; i < d.pages.length && !durdur; i++) {
            if (i % 5 == 0 && mounted) {
              setState(() => durum = 'Dosya ${f + 1}/${pdfler.length}: $ad, sayfa ${i + 1}/${d.pages.length}');
            }
            final raw = await d.pages[i].loadText();
            if (raw == null) continue;
            if (!katla(raw.fullText).contains(q)) continue;
            await sayfayiKaydet(d.pages[i], ad, dosya.path, i + 1);
            if (!tumu) break; // ilk eşleşme modu: bu PDF'i bitir, sonrakine geç
          }
        } catch (e) {
          kayit('Hata ($ad): $e');
        } finally {
          d.dispose();
        }
      }
      kayit(durdur ? 'Durduruldu. $bulunan sayfa kaydedildi.' : 'Bitti. $bulunan sayfa kaydedildi: $cikisKlasoru');
    } catch (e) {
      kayit('Hata: $e');
    } finally {
      if (mounted) {
        setState(() {
          calisiyor = false;
          durum = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PDF\'lerde ara')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OutlinedButton.icon(
            onPressed: calisiyor ? null : klasorSec,
            icon: const Icon(Icons.folder_open),
            label: Text(klasor ?? 'Klasör seç (alt klasörler dahil taranır)', overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: sorgu,
            enabled: !calisiyor,
            decoration: const InputDecoration(labelText: 'Aranacak kelime veya ifade', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('İlk eşleşme')),
              ButtonSegment(value: true, label: Text('Tüm eşleşmeler')),
            ],
            selected: {tumu},
            onSelectionChanged: calisiyor ? null : (s) => setState(() => tumu = s.first),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              tumu
                  ? 'Her PDF\'te kelimenin geçtiği tüm sayfalar kaydedilir.'
                  : 'Her PDF\'te kelimenin geçtiği ilk sayfa kaydedilir, sonra sonraki PDF\'e geçilir.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Text('Çıktı klasörü: $cikisKlasoru\nDosya adı: pdfadı_sayfa_numara.png', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: calisiyor ? () => setState(() => durdur = true) : ara,
            icon: Icon(calisiyor ? Icons.stop : Icons.search),
            label: Text(calisiyor ? 'Durdur' : 'Ara'),
          ),
          if (calisiyor) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
            Text(durum, style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: kayitlar.length,
              itemBuilder: (c, i) => Text(kayitlar[i], style: const TextStyle(fontSize: 12)),
            ),
          ),
        ]),
      ),
    );
  }
}

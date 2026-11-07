import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

/// Kullanıcı ayarları (Ayarlar ekranından değişir).
class Ayar {
  static double yazi = 1.0; // çeviri yazısı boyu çarpanı
  static double kutu = 0.2; // eski yazıyı kapatan kutunun payı (satır yüksekliği oranı)
  static double sutun = 1.0; // kelime arası boşluk eşiği çarpanı (düşük = sütunları daha kolay ayırır)
}

/// Sayfadaki bir yazı bloğu (paragraf). Konum 0..1 arası oran (sol-üst köşe başlangıç).
class Blok {
  Rect n;
  String kaynak;
  double satir; // bir satırın yüksekliği (sayfa yüksekliğine oran)
  int satirSayisi;
  String? ceviri;
  bool bitti = false; // çeviri denendi (sonuç null olabilir: zaten hedef dilde)
  Blok(this.n, this.kaynak, this.satir, this.satirSayisi);
}

class _K {
  final Rect r;
  final String t;
  _K(this.r, this.t);
}

class _P {
  Rect r;
  Rect son;
  String t;
  double lh;
  int n = 1;
  final List<double> hs = [];
  _P(this.r, this.son, this.t, this.lh) {
    hs.add(lh);
  }
}

/// Formül, sayfa numarası gibi çevrilmeyecek parçaları eler.
bool _cevrilsinMi(String s) {
  final harf = RegExp(r'\p{L}', unicode: true).allMatches(s).length;
  final dolu = s.replaceAll(RegExp(r'\s'), '').length;
  if (dolu == 0) return false;
  return harf / dolu >= 0.6 && RegExp(r'\p{L}{3,}', unicode: true).hasMatch(s);
}

String _birlestir(String a, String b) {
  if (RegExp(r'\p{L}-$', unicode: true).hasMatch(a)) {
    return a.substring(0, a.length - 1) + b; // satır sonu tire: "re-" + "sulting"
  }
  return '$a $b';
}

/// Sayfadaki yazıyı harf harf konumlarıyla okur; kelime → satır parçası → paragraf yapar.
/// Satırlar büyük boşlukta bölünür, bu yüzden yan yana sütunlar karışmaz.
Future<List<Blok>> bloklariBul(PdfPage page) async {
  final raw = await page.loadText();
  if (raw == null) return [];
  final txt = raw.fullText;
  final rects = raw.charRects;
  final w = page.width, h = page.height;

  // 1) kelimeler
  final kelimeler = <_K>[];
  final sb = StringBuffer();
  Rect? kr;
  void kelimeBitir() {
    if (kr != null && sb.isNotEmpty) kelimeler.add(_K(kr!, sb.toString()));
    sb.clear();
    kr = null;
  }

  final n = min(txt.length, rects.length);
  for (var i = 0; i < n; i++) {
    final ch = txt[i];
    if (ch.trim().isEmpty) {
      kelimeBitir();
      continue;
    }
    final b = rects[i];
    final r = Rect.fromPoints(Offset(b.left, h - b.top), Offset(b.right, h - b.bottom));
    if (r.height <= 0) continue;
    kr = kr == null ? r : kr!.expandToInclude(r);
    sb.write(ch);
  }
  kelimeBitir();

  // 2) satır parçaları (aynı satırda ve yakın olan kelimeler)
  final parca = <_K>[];
  _K? cur;
  for (final k in kelimeler) {
    if (cur != null) {
      final lh = cur.r.height;
      final ayniSatir = (k.r.center.dy - cur.r.center.dy).abs() < lh * 0.5;
      final bosluk = k.r.left - cur.r.right;
      if (ayniSatir && bosluk > -lh * 0.3 && bosluk < lh * Ayar.sutun) {
        cur = _K(cur.r.expandToInclude(k.r), '${cur.t} ${k.t}');
        continue;
      }
      parca.add(cur);
    }
    cur = k;
  }
  if (cur != null) parca.add(cur);

  // sayfanın tipik satır yüksekliği (OCR'lı PDF'lerde tek tek kutular güvenilmez)
  final yuks = parca.map((e) => e.r.height).toList()..sort();
  final sayfaMed = yuks.isEmpty ? 10.0 : yuks[yuks.length ~/ 2];

  // 3) paragraflar (alt alta, aynı sütunda, girinti/kısa satır yoksa)
  final acik = <_P>[];
  for (final s in parca) {
    _P? hedef;
    final baslangic = max(0, acik.length - 30);
    for (var j = acik.length - 1; j >= baslangic; j--) {
      final p = acik[j];
      final son = p.son;
      final lh = son.height;
      final alt = s.r.top > son.center.dy && s.r.top - son.bottom < lh * 0.9;
      final ayniSutun = (s.r.left - p.r.left).abs() < lh * 3 &&
          min(s.r.right, son.right) - max(s.r.left, son.left) > 0;
      final girinti = s.r.left > son.left + lh * 0.7;
      final kisaSon = son.right < p.r.right - lh * 2.5;
      if (alt && ayniSutun && !girinti && !kisaSon) {
        hedef = p;
        break;
      }
    }
    if (hedef != null) {
      hedef.r = hedef.r.expandToInclude(s.r);
      hedef.son = s.r;
      hedef.t = _birlestir(hedef.t, s.t);
      hedef.n++;
      hedef.hs.add(s.r.height);
    } else {
      acik.add(_P(s.r, s.r, s.t, s.r.height));
    }
  }

  final sonuc = <Blok>[];
  for (final p in acik) {
    final t = p.t.trim();
    if (!_cevrilsinMi(t) || p.r.width < w * 0.03) continue;
    final hs = List<double>.from(p.hs)..sort();
    final medyan = hs[hs.length ~/ 2].clamp(sayfaMed * 0.75, sayfaMed * 1.35).toDouble();
    sonuc.add(Blok(Rect.fromLTRB(p.r.left / w, p.r.top / h, p.r.right / w, p.r.bottom / h), t, medyan / h, p.n));
  }
  // Üst üste binen kopya blokları ele (aynı yazı iki katmanda olabilir): büyük olan kalır.
  sonuc.sort((a, b) => (b.n.width * b.n.height).compareTo(a.n.width * a.n.height));
  final temiz = <Blok>[];
  for (final b in sonuc) {
    final alan = b.n.width * b.n.height;
    var tekrar = false;
    for (final k in temiz) {
      final kes = k.n.intersect(b.n);
      if (kes.width > 0 && kes.height > 0 && kes.width * kes.height > alan * 0.5) {
        tekrar = true;
        break;
      }
    }
    if (!tekrar) temiz.add(b);
  }
  return temiz;
}

/// Çevirileri eski yazının üstüne beyaz kutu + yeni yazı olarak çizer.
/// Yazı kutunun dışına taşmaz: sığana kadar küçülür, yine de sığmazsa kutudan kırpılır.
void cevirileriCiz(Canvas c, Size boyut, List<Blok> bloklar) {
  final kutular = <Blok, Rect>{};
  for (final b in bloklar) {
    if (b.ceviri == null) continue;
    final lh = b.satir * boyut.height;
    kutular[b] = Rect.fromLTRB(b.n.left * boyut.width - 2, b.n.top * boyut.height - lh * Ayar.kutu,
        b.n.right * boyut.width + 2, b.n.bottom * boyut.height + lh * Ayar.kutu);
  }
  final beyaz = Paint()..color = const Color(0xFFFFFFFF);
  for (final r in kutular.values) {
    c.drawRect(r, beyaz);
  }
  kutular.forEach((b, r) {
    // Başlangıç boyu: asıl yazının boyu (satır yüksekliğinin ~%82'si) x kullanıcı çarpanı.
    // Çeviri sığmazsa sığana kadar küçülür; asıl yazıdan büyük olmaz.
    var fs = (b.satir * boyut.height * 0.82 * Ayar.yazi).clamp(4.5, 60.0).toDouble();
    TextPainter tp;
    while (true) {
      tp = TextPainter(
        text: TextSpan(text: b.ceviri, style: TextStyle(color: const Color(0xFF000000), fontSize: fs, height: 1.08)),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: r.width);
      if (tp.height <= r.height || fs <= 4.5) break;
      fs *= 0.94;
    }
    c.save();
    c.clipRect(r);
    tp.paint(c, r.topLeft);
    c.restore();
  });
}

/// Sayfayı resim olarak çizer, çeviriler üstüne işlenmiş halde döner.
Future<ui.Image> sayfaResmi(PdfPage page, List<Blok> bloklar, {double genislik = 1500}) async {
  final h = genislik * page.height / page.width;
  final img = await page.render(fullWidth: genislik, fullHeight: h);
  if (img == null) throw Exception('Sayfa çizilemedi.');
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(img.pixels, img.width, img.height, ui.PixelFormat.bgra8888, c.complete);
  final arka = await c.future;
  img.dispose();

  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawImage(arka, Offset.zero, Paint());
  cevirileriCiz(canvas, Size(arka.width.toDouble(), arka.height.toDouble()), bloklar);
  final sonuc = await rec.endRecording().toImage(arka.width, arka.height);
  arka.dispose();
  return sonuc;
}

/// Çevrilmiş sayfalardan yeni bir PDF üretir (sayfa görüntüsü olarak).
Future<Uint8List> pdfUret(
  PdfDocument doc,
  Map<int, List<Blok>> tum,
  void Function(int, int) ilerleme,
) async {
  final cikti = pw.Document();
  for (var i = 0; i < doc.pages.length; i++) {
    ilerleme(i + 1, doc.pages.length);
    final page = doc.pages[i];
    final im = await sayfaResmi(page, tum[i] ?? <Blok>[], genislik: 1400);
    final bd = await im.toByteData(format: ui.ImageByteFormat.png);
    im.dispose();
    final resim = pw.MemoryImage(bd!.buffer.asUint8List());
    cikti.addPage(pw.Page(
      pageFormat: PdfPageFormat(page.width, page.height, marginAll: 0),
      build: (_) => pw.Image(resim, fit: pw.BoxFit.fill),
    ));
  }
  return cikti.save();
}

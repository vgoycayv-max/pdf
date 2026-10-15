import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'arama.dart';
import 'pdf_tools.dart';
import 'translator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  runApp(const BonoCeviriApp());
}

class BonoCeviriApp extends StatelessWidget {
  const BonoCeviriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bono Çeviri',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: const Color(0xFF3F51B5)),
      darkTheme: ThemeData(
          useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF3F51B5)),
      home: const Ana(),
    );
  }
}

class Ana extends StatefulWidget {
  const Ana({super.key});

  @override
  State<Ana> createState() => _AnaState();
}

class _AnaState extends State<Ana> {
  PdfDocument? doc;
  final Map<int, List<Blok>> bloklar = {};
  final Map<int, ui.Image> resimler = {};
  final Set<int> yukleniyor = {};
  final Set<int> hatali = {};
  final Set<int> cevrildi = {};
  final List<int> ceviriKuyrugu = [];

  final itemScroll = ItemScrollController();
  final itemPos = ItemPositionsListener.create();

  int gorunen = 0;
  bool ceviriAcik = false; // kaydırırken otomatik çevir
  int mod = 2; // 0 sadece sözlük, 1 sözlük + cihaz modeli (internetsiz), 2 sözlük + internet
  double zoom = 1.0;
  final Map<int, Offset> dokunuslar = {};
  double pinchD0 = 0, pinchZ0 = 1;
  bool sikistiriyor = false;
  bool iscide = false;
  bool mesgul = false; // uzun işlem (tümünü çevir, PDF kaydet)
  bool durdur = false;
  String durum = '';

  Sozluk? sozluk;
  Cevirici? cevirici;

  @override
  void initState() {
    super.initState();
    itemPos.itemPositions.addListener(konumDegisti);
    ayarYukle();
    Sozluk.yukle().then((s) {
      if (!mounted) return;
      setState(() {
        sozluk = s;
        cevirici = Cevirici(s)..mod = mod;
      });
    });
  }

  Future<File> _ayarDosyasi() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/ayar.json');
  }

  Future<void> ayarYukle() async {
    try {
      final f = await _ayarDosyasi();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      Ayar.yazi = (j['yazi'] as num?)?.toDouble() ?? Ayar.yazi;
      Ayar.kutu = (j['kutu'] as num?)?.toDouble() ?? Ayar.kutu;
      Ayar.sutun = (j['sutun'] as num?)?.toDouble() ?? Ayar.sutun;
      mod = (j['mod'] as num?)?.toInt() ?? 2;
      cevirici?.mod = mod;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> ayarKaydet() async {
    try {
      final f = await _ayarDosyasi();
      await f.writeAsString(jsonEncode({'yazi': Ayar.yazi, 'kutu': Ayar.kutu, 'sutun': Ayar.sutun, 'mod': mod}));
    } catch (_) {}
  }

  /// Çeviri modu seçimi. Cihaz modeli seçilirse model yoksa bir kez indirilir.
  Future<void> modSec(int yeni) async {
    final c = cevirici;
    if (yeni == mod || c == null) return;
    if (yeni == 1) {
      setState(() {
        mesgul = true;
        durdur = false;
        durum = 'Dil modeli kontrol ediliyor...';
      });
      try {
        await c.modelHazirla((b) {
          if (mounted) setState(() => durum = b);
        });
      } catch (e) {
        mesaj(e.toString().replaceFirst('Exception: ', ''));
        if (mounted) {
          setState(() {
            mesgul = false;
            durum = '';
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          mesgul = false;
          durum = '';
        });
      }
    }
    setState(() => mod = yeni);
    c.mod = yeni;
    await ayarKaydet();
    mesaj(const [
      'Sadece sözlük (internet yok).',
      'Sözlük + cihaz içi model (internet yok).',
      'Sözlük + internet (Google).',
    ][yeni]);
    if (doc != null) duzeniSifirla();
  }

  // ---------- yakınlaştırma (iki parmakla ya da +/- düğmeleri) ----------

  void imlecInd(PointerDownEvent e) {
    dokunuslar[e.pointer] = e.position;
    if (dokunuslar.length == 2) {
      final p = dokunuslar.values.toList();
      pinchD0 = (p[0] - p[1]).distance;
      pinchZ0 = zoom;
      setState(() => sikistiriyor = true);
    }
  }

  void imlecHareket(PointerMoveEvent e) {
    if (!dokunuslar.containsKey(e.pointer)) return;
    dokunuslar[e.pointer] = e.position;
    if (sikistiriyor && dokunuslar.length >= 2 && pinchD0 > 10) {
      final p = dokunuslar.values.toList();
      final yeni = (pinchZ0 * (p[0] - p[1]).distance / pinchD0).clamp(1.0, 3.0).toDouble();
      if ((yeni - zoom).abs() > 0.02) setState(() => zoom = yeni);
    }
  }

  void imlecKalk(PointerEvent e) {
    dokunuslar.remove(e.pointer);
    if (dokunuslar.length < 2 && sikistiriyor) setState(() => sikistiriyor = false);
  }

  /// Yazı boyu / kutu payı değişince açık sayfaları yeniden çizer.
  Future<void> yenidenCiz() async {
    for (final i in resimler.keys.toList()) {
      if (!mounted) return;
      try {
        await resmiYenile(i);
      } catch (_) {}
    }
  }

  /// Sütun ayarı değişince sayfa düzeni baştan çözülür (çeviriler önbellekten gelir).
  void duzeniSifirla() {
    ceviriKuyrugu.clear();
    for (final im in resimler.values) {
      eskiyiAt(im);
    }
    resimler.clear();
    bloklar.clear();
    cevrildi.clear();
    yukleniyor.clear();
    hatali.clear();
    setState(() {});
    if (ceviriAcik) kuyrukDoldur();
  }

  Future<void> ayarlarAc() async {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (c) => StatefulBuilder(builder: (c, setS) {
        Widget satir(String baslik, String aciklama, double deger, double min_, double max_, int bol,
            void Function(double) degis, Future<void> Function() bitti) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('$baslik: ${deger.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(aciklama, style: const TextStyle(fontSize: 12)),
              Slider(
                value: deger,
                min: min_,
                max: max_,
                divisions: bol,
                onChanged: (v) => setS(() => degis(v)),
                onChangeEnd: (v) async {
                  await ayarKaydet();
                  await bitti();
                },
              ),
            ]),
          );
        }

        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            satir('Yazı boyu', 'Çeviri yazısı büyük çıkıyorsa azalt, küçük çıkıyorsa artır.', Ayar.yazi, 0.5, 1.5, 20,
                (v) => Ayar.yazi = v, yenidenCiz),
            satir('Kutu payı', 'Eski yazı çevirinin altından görünüyorsa artır.', Ayar.kutu, 0.0, 1.0, 20,
                (v) => Ayar.kutu = v, yenidenCiz),
            satir('Sütun ayırma', 'İki sütun birbirine karışıyorsa azalt, tek satır bölünüyorsa artır.', Ayar.sutun, 0.5, 2.5,
                20, (v) => Ayar.sutun = v, () async => duzeniSifirla()),
          ]),
        );
      }),
    );
  }

  void mesaj(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  void eskiyiAt(ui.Image? im) {
    if (im != null) Future.delayed(const Duration(seconds: 2), im.dispose);
  }

  // ---------- kaydırma ve görünen sayfa ----------

  void konumDegisti() {
    final pos = itemPos.itemPositions.value;
    if (pos.isEmpty) return;
    final ilk = pos.where((p) => p.itemTrailingEdge > 0.35).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final yeni = (ilk.isEmpty ? pos.first : ilk.first).index;
    if (yeni != gorunen) {
      setState(() => gorunen = yeni);
      sinirla();
      if (ceviriAcik) kuyrukDoldur();
    }
  }

  /// Bellek için: görünen sayfadan uzak resimleri atar.
  void sinirla() {
    if (resimler.length <= 8) return;
    final silinecek = resimler.keys.where((k) => (k - gorunen).abs() > 3).toList()
      ..sort((a, b) => (b - gorunen).abs().compareTo((a - gorunen).abs()));
    for (final k in silinecek.take(resimler.length - 8)) {
      eskiyiAt(resimler.remove(k));
    }
  }

  void resimIste(int i) {
    final d = doc;
    if (d == null || yukleniyor.contains(i) || hatali.contains(i)) return;
    yukleniyor.add(i);
    Future(() async {
      try {
        final im = await sayfaResmi(d.pages[i], bloklar[i] ?? <Blok>[]);
        if (!mounted || !identical(d, doc)) {
          im.dispose();
          return;
        }
        setState(() {
          eskiyiAt(resimler[i]);
          resimler[i] = im;
        });
        sinirla();
      } catch (_) {
        hatali.add(i);
        if (mounted) setState(() {});
      } finally {
        yukleniyor.remove(i);
      }
    });
  }

  Future<void> resmiYenile(int i) async {
    final d = doc;
    if (d == null) return;
    final im = await sayfaResmi(d.pages[i], bloklar[i] ?? <Blok>[]);
    if (!mounted || !identical(d, doc)) {
      im.dispose();
      return;
    }
    setState(() {
      eskiyiAt(resimler[i]);
      resimler[i] = im;
    });
  }

  // ---------- PDF açma ----------

  Future<void> pdfAc() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    final yol = r?.files.single.path;
    if (yol == null) return;
    try {
      final yeni = await PdfDocument.openFile(yol);
      ceviriKuyrugu.clear();
      for (final im in resimler.values) {
        eskiyiAt(im);
      }
      resimler.clear();
      bloklar.clear();
      yukleniyor.clear();
      hatali.clear();
      cevrildi.clear();
      final eski = doc;
      setState(() {
        doc = yeni;
        gorunen = 0;
      });
      eski?.dispose();
      if (ceviriAcik) kuyrukDoldur();
    } catch (e) {
      mesaj('PDF açılamadı: $e');
    }
  }

  // ---------- çeviri ----------

  Future<List<Blok>> sayfaBloklari(int i) async {
    return bloklar[i] ??= await bloklariBul(doc!.pages[i]);
  }

  Future<void> sayfaCevir(int i) async {
    final bekleyen = (await sayfaBloklari(i)).where((b) => !b.bitti).toList();
    for (var j = 0; j < bekleyen.length; j += 4) {
      final grup = bekleyen.sublist(j, min(j + 4, bekleyen.length));
      await Future.wait(grup.map((b) async {
        b.ceviri = await cevirici!.cevir(b.kaynak);
        b.bitti = true;
      }));
    }
    cevrildi.add(i);
  }

  void ceviriDegistir() {
    if (doc == null) return;
    setState(() => ceviriAcik = !ceviriAcik);
    if (ceviriAcik) {
      kuyrukDoldur();
    } else {
      ceviriKuyrugu.clear();
    }
  }

  /// Görünen sayfa ve sonraki 2 sayfa sıraya girer.
  void kuyrukDoldur() {
    final d = doc;
    if (d == null || cevirici == null) return;
    for (var k = 0; k < 3; k++) {
      final i = gorunen + k;
      if (i < d.pages.length && !cevrildi.contains(i) && !ceviriKuyrugu.contains(i)) {
        ceviriKuyrugu.add(i);
      }
    }
    isci();
  }

  Future<void> isci() async {
    if (iscide) return;
    iscide = true;
    try {
      while (ceviriAcik && ceviriKuyrugu.isNotEmpty && doc != null) {
        ceviriKuyrugu.sort((a, b) => (a - gorunen).abs().compareTo((b - gorunen).abs()));
        final i = ceviriKuyrugu.removeAt(0);
        if (cevrildi.contains(i)) continue;
        if (mounted) setState(() => durum = 'Çevriliyor: sayfa ${i + 1}');
        await sayfaCevir(i);
        await resmiYenile(i);
      }
    } catch (e) {
      ceviriAcik = false;
      ceviriKuyrugu.clear();
      mesaj('Çeviri durdu: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      iscide = false;
      if (mounted) setState(() => durum = '');
    }
  }

  Future<void> tumunuCevir() async {
    final d = doc;
    if (d == null) return;
    setState(() {
      mesgul = true;
      durdur = false;
    });
    try {
      for (var i = 0; i < d.pages.length && !durdur; i++) {
        if (cevrildi.contains(i)) continue;
        setState(() => durum = 'Çevriliyor: sayfa ${i + 1}/${d.pages.length}');
        await sayfaCevir(i);
        if ((i - gorunen).abs() < 3) await resmiYenile(i);
      }
      mesaj(durdur ? 'Durduruldu.' : 'Tüm sayfalar çevrildi.');
    } catch (e) {
      mesaj('Hata: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) {
        setState(() {
          mesgul = false;
          durum = '';
        });
      }
    }
  }

  /// Bir .txt dosyasını satır satır çevirir, yeni txt olarak kaydeder.
  Future<void> txtCevir() async {
    final c = cevirici;
    if (c == null) return;
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt']);
    final yol = r?.files.single.path;
    if (yol == null) return;
    setState(() {
      mesgul = true;
      durdur = false;
      durum = 'TXT okunuyor...';
    });
    try {
      final satirlar = utf8.decode(await File(yol).readAsBytes(), allowMalformed: true).split('\n');
      final cikti = List<String>.from(satirlar);
      final idx = [
        for (var i = 0; i < satirlar.length; i++)
          if (satirlar[i].trim().isNotEmpty) i
      ];
      for (var j = 0; j < idx.length && !durdur; j += 4) {
        final grup = idx.sublist(j, min(j + 4, idx.length));
        if (mounted) setState(() => durum = 'TXT çevriliyor: ${min(j + 4, idx.length)}/${idx.length} satır');
        await Future.wait(grup.map((i) async {
          final t = await c.cevir(satirlar[i].trim());
          if (t != null) cikti[i] = t;
        }));
      }
      final ad = yol.split('/').last.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '');
      final kayitYolu = await FilePicker.platform.saveFile(
        dialogTitle: 'Çevrilmiş TXT\'i kaydet',
        fileName: '${ad}_tr.txt',
        bytes: utf8.encode(cikti.join('\n')),
      );
      if (kayitYolu != null) mesaj(durdur ? 'Durduruldu, o ana kadarki kısım kaydedildi.' : 'TXT kaydedildi.');
    } catch (e) {
      mesaj('Hata: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) {
        setState(() {
          mesgul = false;
          durum = '';
        });
      }
    }
  }

  Future<void> pdfKaydet() async {
    final d = doc;
    if (d == null) return;
    setState(() {
      mesgul = true;
      durdur = false;
    });
    try {
      final bytes = await pdfUret(d, bloklar, (i, n) {
        if (mounted) setState(() => durum = 'PDF hazırlanıyor: $i/$n');
      });
      final yol = await FilePicker.platform.saveFile(
        dialogTitle: 'Çevrilmiş PDF\'i kaydet',
        fileName: 'ceviri.pdf',
        bytes: bytes,
      );
      if (yol != null) mesaj('PDF kaydedildi.');
    } catch (e) {
      mesaj('Hata: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) {
        setState(() {
          mesgul = false;
          durum = '';
        });
      }
    }
  }

  // ---------- düzeltme ve sözlük ----------

  Future<void> duzelt(int sayfa, Blok b) async {
    final kontrol = TextEditingController(text: b.ceviri);
    final yeni = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Çeviriyi düzelt'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(b.kaynak, maxLines: 6, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            TextField(controller: kontrol, maxLines: 6, autofocus: true),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, kontrol.text), child: const Text('Kaydet')),
        ],
      ),
    );
    if (yeni == null || yeni.trim().isEmpty) return;
    b.ceviri = yeni.replaceAll('\n', ' ').trim();
    b.bitti = true;
    sozluk!.map[norm(b.kaynak)] = b.ceviri!;
    await sozluk!.kaydet();
    await resmiYenile(sayfa);
    mesaj('Düzeltme sözlüğe kaydedildi.');
  }

  void dokun(int sayfa, Offset p, Size boyut) {
    final bl = bloklar[sayfa];
    if (bl == null) return;
    final nokta = Offset(p.dx / boyut.width, p.dy / boyut.height);
    for (final b in bl) {
      if (b.ceviri != null && b.n.contains(nokta)) {
        duzelt(sayfa, b);
        return;
      }
    }
  }

  Future<void> sozlukIceAktar() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['txt']);
    final yol = r?.files.single.path;
    if (yol == null || sozluk == null) return;
    final n = sozluk!.metinEkle(await File(yol).readAsString());
    await sozluk!.kaydet();
    mesaj('$n satır sözlüğe eklendi. Yeni çeviriler bunu kullanır.');
  }

  Future<void> sozlukDisaAktar() async {
    if (sozluk == null) return;
    final yol = await FilePicker.platform.saveFile(
      dialogTitle: 'Sözlüğü kaydet',
      fileName: 'sozluk_$langPair.txt',
      bytes: utf8.encode(sozluk!.disaMetin()),
    );
    if (yol != null) mesaj('Sözlük kaydedildi (${sozluk!.map.length} kayıt).');
  }

  Future<void> sayfayaGit() async {
    final d = doc;
    if (d == null) return;
    final k = TextEditingController(text: '${gorunen + 1}');
    final s = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Sayfaya git (1-${d.pages.length})'),
        content: TextField(controller: k, keyboardType: TextInputType.number, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, k.text), child: const Text('Git')),
        ],
      ),
    );
    final n = int.tryParse(s ?? '');
    if (n != null && n >= 1 && n <= d.pages.length) itemScroll.jumpTo(index: n - 1);
  }

  // ---------- ekran ----------

  Widget sayfaOgesi(int i) {
    final p = doc!.pages[i];
    return AspectRatio(
      aspectRatio: p.width / p.height,
      child: LayoutBuilder(builder: (context, k) {
        final im = resimler[i];
        if (im == null) {
          resimIste(i);
          return Container(
            color: Colors.white,
            alignment: Alignment.center,
            child: Text(hatali.contains(i) ? 'Sayfa ${i + 1} çizilemedi' : 'Sayfa ${i + 1}...',
                style: const TextStyle(color: Colors.black54)),
          );
        }
        return GestureDetector(
          onTapUp: (t) => dokun(i, t.localPosition, k.biggest),
          child: RawImage(image: im, fit: BoxFit.fill),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final calisiyor = mesgul || (ceviriAcik && iscide);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bono Çeviri'),
        actions: [
          IconButton(icon: const Icon(Icons.folder_open), tooltip: 'PDF aç', onPressed: mesgul ? null : pdfAc),
          PopupMenuButton<int>(
            enabled: !mesgul,
            tooltip: 'Çeviri modu',
            icon: Icon(const [Icons.menu_book, Icons.phone_android, Icons.cloud_queue][mod],
                color: mod != 2 ? Theme.of(context).colorScheme.primary : null),
            onSelected: modSec,
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 0, checked: mod == 0, child: const Text('Sadece sözlük (internetsiz)')),
              CheckedPopupMenuItem(value: 1, checked: mod == 1, child: const Text('Sözlük + cihaz modeli (internetsiz)')),
              CheckedPopupMenuItem(value: 2, checked: mod == 2, child: const Text('Sözlük + internet (Google)')),
            ],
          ),
          IconButton(
            icon: Icon(ceviriAcik ? Icons.pause_circle : Icons.translate),
            tooltip: ceviriAcik ? 'Otomatik çeviriyi durdur' : 'Kaydırırken otomatik çevir',
            color: ceviriAcik ? Theme.of(context).colorScheme.primary : null,
            onPressed: mesgul || d == null ? null : ceviriDegistir,
          ),
          PopupMenuButton<String>(
            enabled: !mesgul,
            onSelected: (v) {
              if (v == 'hepsi') tumunuCevir();
              if (v == 'kaydet') pdfKaydet();
              if (v == 'sozluk') {
                if (sozluk != null) {
                  Navigator.push(context, MaterialPageRoute(builder: (_) => SozlukSayfasi(sozluk: sozluk!)));
                }
              }
              if (v == 'ayar') ayarlarAc();
              if (v == 'txt') txtCevir();
              if (v == 'ara') Navigator.push(context, MaterialPageRoute(builder: (_) => const AramaSayfasi()));
              if (v == 'ice') sozlukIceAktar();
              if (v == 'disa') sozlukDisaAktar();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'hepsi', child: Text('Tüm sayfaları çevir')),
              PopupMenuItem(value: 'kaydet', child: Text('Çevrilmiş PDF\'i kaydet')),
              PopupMenuItem(value: 'ara', child: Text('PDF\'lerde ara (klasör)')),
              PopupMenuItem(value: 'txt', child: Text('TXT dosyası çevir')),
              PopupMenuItem(value: 'ayar', child: Text('Ayarlar (yazı boyu, kutu)')),
              PopupMenuItem(value: 'sozluk', child: Text('Sözlüğü göster / düzenle')),
              PopupMenuItem(value: 'ice', child: Text('Sözlüğü içe aktar (.txt)')),
              PopupMenuItem(value: 'disa', child: Text('Sözlüğü dışa aktar (.txt)')),
            ],
          ),
        ],
        bottom: calisiyor
            ? PreferredSize(
                preferredSize: const Size.fromHeight(28),
                child: Column(children: [
                  const LinearProgressIndicator(),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(durum, style: const TextStyle(fontSize: 12)),
                    if (mesgul && !durdur)
                      TextButton(
                        onPressed: () => setState(() => durdur = true),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('Durdur'),
                      ),
                  ]),
                ]),
              )
            : null,
      ),
      body: d == null
          ? const Center(child: Text('Başlamak için üstteki klasör simgesiyle bir PDF aç.'))
          : LayoutBuilder(builder: (context, k) {
              final kilit = sikistiriyor ? const NeverScrollableScrollPhysics() : null;
              return Listener(
                onPointerDown: imlecInd,
                onPointerMove: imlecHareket,
                onPointerUp: imlecKalk,
                onPointerCancel: imlecKalk,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: kilit,
                  child: SizedBox(
                    width: k.maxWidth * zoom,
                    height: k.maxHeight,
                    child: ScrollablePositionedList.builder(
                      physics: kilit,
                      itemCount: d.pages.length,
                      itemScrollController: itemScroll,
                      itemPositionsListener: itemPos,
                      itemBuilder: (c, i) =>
                          Padding(padding: const EdgeInsets.only(bottom: 6), child: sayfaOgesi(i)),
                    ),
                  ),
                ),
              );
            }),
      bottomNavigationBar: d == null
          ? null
          : BottomAppBar(
              height: 56,
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: gorunen == 0
                      ? null
                      : () => itemScroll.scrollTo(index: gorunen - 1, duration: const Duration(milliseconds: 200)),
                ),
                IconButton(
                    icon: const Icon(Icons.zoom_out),
                    onPressed: zoom <= 1.0 ? null : () => setState(() => zoom = (zoom - 0.5).clamp(1.0, 3.0))),
                TextButton(onPressed: sayfayaGit, child: Text('${gorunen + 1} / ${d.pages.length}')),
                IconButton(
                    icon: const Icon(Icons.zoom_in),
                    onPressed: zoom >= 3.0 ? null : () => setState(() => zoom = (zoom + 0.5).clamp(1.0, 3.0))),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: gorunen >= d.pages.length - 1
                      ? null
                      : () => itemScroll.scrollTo(index: gorunen + 1, duration: const Duration(milliseconds: 200)),
                ),
              ]),
            ),
    );
  }
}

/// Sözlüğü listeler; kayda dokununca düzenlenir, + ile yenisi eklenir.
class SozlukSayfasi extends StatefulWidget {
  final Sozluk sozluk;
  const SozlukSayfasi({super.key, required this.sozluk});

  @override
  State<SozlukSayfasi> createState() => _SozlukSayfasiState();
}

class _SozlukSayfasiState extends State<SozlukSayfasi> {
  String ara = '';

  Future<void> duzenle(String? eskiAnahtar) async {
    final s = widget.sozluk;
    final k1 = TextEditingController(text: eskiAnahtar ?? '');
    final k2 = TextEditingController(text: eskiAnahtar == null ? '' : s.map[eskiAnahtar]);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(eskiAnahtar == null ? 'Yeni kayıt' : 'Kaydı düzenle'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: k1, maxLines: 3, decoration: const InputDecoration(labelText: 'İngilizce öbek')),
            TextField(controller: k2, maxLines: 3, decoration: const InputDecoration(labelText: 'Türkçe karşılığı')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Vazgeç')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Kaydet')),
        ],
      ),
    );
    if (ok != true) return;
    final yeniK = norm(k1.text);
    final yeniV = k2.text.replaceAll('\n', ' ').trim();
    if (yeniK.isEmpty || yeniV.isEmpty) return;
    if (eskiAnahtar != null && eskiAnahtar != yeniK) s.map.remove(eskiAnahtar);
    s.map[yeniK] = yeniV;
    await s.kaydet();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sozluk;
    final anahtarlar = s.map.keys.where((k) => ara.isEmpty || k.contains(ara.toLowerCase()) || s.map[k]!.toLowerCase().contains(ara.toLowerCase())).toList()
      ..sort();
    return Scaffold(
      appBar: AppBar(title: Text('Sözlük (${s.map.length})')),
      floatingActionButton: FloatingActionButton(onPressed: () => duzenle(null), child: const Icon(Icons.add)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Ara', border: OutlineInputBorder()),
            onChanged: (v) => setState(() => ara = v),
          ),
        ),
        Expanded(
          child: anahtarlar.isEmpty
              ? const Center(child: Text('Sözlük boş. Çevirileri düzeltince ya da + ile buraya kayıt eklenir.'))
              : ListView.builder(
                  itemCount: anahtarlar.length,
                  itemBuilder: (c, i) {
                    final k = anahtarlar[i];
                    return ListTile(
                      title: Text(k, maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: Text(s.map[k]!, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => duzenle(k),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          s.map.remove(k);
                          await s.kaydet();
                          setState(() {});
                        },
                      ),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

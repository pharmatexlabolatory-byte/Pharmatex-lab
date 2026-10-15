import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:intl/intl.dart';
import 'package:excel/excel.dart' as ex;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FullWarehouseApp());
}

// ================= قاعدة البيانات =================
class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('warehouse_master.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            code TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            opening_stock REAL NOT NULL DEFAULT 0.0,
            expiry_date TEXT,
            reorder_level REAL DEFAULT 10.0
          )
        ''');

        await db.execute('''
          CREATE TABLE movements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            item_id INTEGER NOT NULL,
            date TEXT NOT NULL,
            party_name TEXT NOT NULL,
            movement_type TEXT NOT NULL, -- 'in' أو 'out'
            in_sub_type TEXT,            -- 'استلام كميات' أو 'فاتورة مردود'
            manual_ref TEXT,
            out_ref_type TEXT,
            out_ref_no TEXT,
            batch_no TEXT,
            qty REAL NOT NULL,
            status TEXT DEFAULT 'posted', -- 'draft' أو 'posted'
            notes TEXT,
            FOREIGN KEY (item_id) REFERENCES items (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE audits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            audit_date TEXT NOT NULL,
            item_id INTEGER NOT NULL,
            system_qty REAL NOT NULL,
            actual_qty REAL NOT NULL,
            diff_qty REAL NOT NULL,
            notes TEXT,
            FOREIGN KEY (item_id) REFERENCES items (id) ON DELETE CASCADE
          )
        ''');

        // صنف افتراضي تجريبي
        await db.insert('items', {
          'code': 'ITEM-001',
          'name': 'صنف تجريبي أولي',
          'opening_stock': 50.0,
          'expiry_date': '2027-12-31',
          'reorder_level': 10.0
        });
      },
    );
  }

  Future<String> exportBackup() async {
    final dbPath = await getDatabasesPath();
    final currentDb = File(p.join(dbPath, 'warehouse_master.db'));
    final appDir = await getApplicationDocumentsDirectory();
    final backupPath = p.join(appDir.path, 'Backup_Warehouse_${DateTime.now().millisecondsSinceEpoch}.db');
    await currentDb.copy(backupPath);
    return backupPath;
  }

  Future<void> importBackup(String sourcePath) async {
    final dbPath = await getDatabasesPath();
    final targetPath = p.join(dbPath, 'warehouse_master.db');
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
    await File(sourcePath).copy(targetPath);
  }
}

// ================= التطبيق الرئيسي =================
class FullWarehouseApp extends StatelessWidget {
  const FullWarehouseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'إدارة المخازن',
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(primarySwatch: Colors.teal, useMaterial3: false),
      home: const MainNavigationScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _currentIndex = 0;
  final List<Widget> _screens = [
    const MasterInventoryScreen(),
    const AuditScreen(),
    const BackupScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (idx) => setState(() => _currentIndex = idx),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2), label: 'المخزون الإجمالي'),
          BottomNavigationBarItem(icon: Icon(Icons.fact_check), label: 'الجرد المخزني'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_backup_restore), label: 'النسخ الاحتياطي'),
        ],
      ),
    );
  }
}

// ================= 1. شاشة المخزون الإجمالي =================
class MasterInventoryScreen extends StatefulWidget {
  const MasterInventoryScreen({super.key});

  @override
  State<MasterInventoryScreen> createState() => _MasterInventoryScreenState();
}

class _MasterInventoryScreenState extends State<MasterInventoryScreen> {
  List<Map<String, dynamic>> itemsReport = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchInventoryData();
  }

  Future<void> _fetchInventoryData() async {
    setState(() => isLoading = true);
    final db = await DatabaseHelper.instance.database;

    final results = await db.rawQuery('''
      SELECT 
        i.id,
        i.code,
        i.name,
        i.opening_stock,
        i.expiry_date,
        i.reorder_level,
        COALESCE(SUM(CASE WHEN m.movement_type = 'in' AND m.status = 'posted' THEN m.qty ELSE 0 END), 0) as total_in,
        COALESCE(SUM(CASE WHEN m.movement_type = 'out' AND m.status = 'posted' THEN m.qty ELSE 0 END), 0) as total_out,
        (i.opening_stock + 
         COALESCE(SUM(CASE WHEN m.movement_type = 'in' AND m.status = 'posted' THEN m.qty ELSE 0 END), 0) - 
         COALESCE(SUM(CASE WHEN m.movement_type = 'out' AND m.status = 'posted' THEN m.qty ELSE 0 END), 0)) as balance
      FROM items i
      LEFT JOIN movements m ON i.id = m.item_id
      GROUP BY i.id
    ''');

    setState(() {
      itemsReport = results;
      isLoading = false;
    });
  }

  void _showAddItemDialog() {
    final codeCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final openingCtrl = TextEditingController();
    final expiryCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة صنف جديد'),
        content: SingleChildScrollView(
          child: Column(
            children: [
              TextField(controller: codeCtrl, decoration: const InputDecoration(labelText: 'رقم الصنف (الكود)')),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'اسم الصنف')),
              TextField(controller: openingCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'مخزون افتتاحي')),
              TextField(controller: expiryCtrl, decoration: const InputDecoration(labelText: 'تاريخ الصلاحية (YYYY-MM-DD)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () async {
              if (codeCtrl.text.isEmpty || nameCtrl.text.isEmpty) return;
              final db = await DatabaseHelper.instance.database;
              await db.insert('items', {
                'code': codeCtrl.text,
                'name': nameCtrl.text,
                'opening_stock': double.tryParse(openingCtrl.text) ?? 0.0,
                'expiry_date': expiryCtrl.text,
              });
              Navigator.pop(ctx);
              _fetchInventoryData();
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportExcel() async {
    var excel = ex.Excel.createExcel();
    ex.Sheet sheet = excel['المخزون'];
    excel.delete('Sheet1');

    sheet.appendRow([
      ex.TextCellValue('رقم الصنف'),
      ex.TextCellValue('اسم الصنف'),
      ex.TextCellValue('مخزون افتتاحي'),
      ex.TextCellValue('إجمالي الوارد'),
      ex.TextCellValue('إجمالي المنصرف'),
      ex.TextCellValue('الرصيد الحالي'),
      ex.TextCellValue('تاريخ الصلاحية'),
    ]);

    for (var r in itemsReport) {
      sheet.appendRow([
        ex.TextCellValue(r['code'].toString()),
        ex.TextCellValue(r['name'].toString()),
        ex.DoubleCellValue((r['opening_stock'] as num).toDouble()),
        ex.DoubleCellValue((r['total_in'] as num).toDouble()),
        ex.DoubleCellValue((r['total_out'] as num).toDouble()),
        ex.DoubleCellValue((r['balance'] as num).toDouble()),
        ex.TextCellValue(r['expiry_date'] ?? '-'),
      ]);
    }

    final bytes = excel.save();
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/Warehouse_Report.xlsx');
    await file.writeAsBytes(bytes!);
    await Share.shareXFiles([XFile(file.path)], text: 'تقرير المخزون الإجمالي');
  }

  Future<void> _exportPdf() async {
    final pdf = pw.Document();
    final font = await PdfGoogleFonts.cairoRegular();
    final fontBold = await PdfGoogleFonts.cairoBold();

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        textDirection: pw.TextDirection.rtl,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(child: pw.Text('تقرير المخزون الإجمالي', style: pw.TextStyle(font: fontBold, fontSize: 18))),
              pw.SizedBox(height: 12),
              pw.TableHelper.fromTextArray(
                headers: ['رقم الصنف', 'الصنف', 'افتتاحي', 'وارد', 'منصرف', 'الرصيد', 'الصلاحية'],
                data: itemsReport.map((i) => [
                  i['code'].toString(),
                  i['name'].toString(),
                  i['opening_stock'].toString(),
                  i['total_in'].toString(),
                  i['total_out'].toString(),
                  i['balance'].toString(),
                  i['expiry_date'] ?? '-',
                ]).toList(),
                cellStyle: pw.TextStyle(font: font, fontSize: 9),
                headerStyle: pw.TextStyle(font: fontBold, fontSize: 10, color: PdfColors.white),
                headerDecoration: const pw.BoxDecoration(color: PdfColors.teal),
                cellAlignment: pw.Alignment.center,
              ),
            ],
          );
        },
      ),
    );
    await Printing.layoutPdf(onLayout: (PdfPageFormat format) async => pdf.save());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('المخزون والأصناف'),
        actions: [
          IconButton(icon: const Icon(Icons.picture_as_pdf), tooltip: 'تصدير PDF', onPressed: _exportPdf),
          IconButton(icon: const Icon(Icons.table_chart), tooltip: 'تصدير Excel', onPressed: _exportExcel),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddItemDialog,
        child: const Icon(Icons.add),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: itemsReport.length,
              itemBuilder: (ctx, i) {
                final item = itemsReport[i];
                final balance = (item['balance'] as num).toDouble();
                final reorder = (item['reorder_level'] as num?)?.toDouble() ?? 10.0;
                final isLow = balance <= reorder;

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  elevation: 2,
                  child: ListTile(
                    title: Text('${item['name']} (${item['code']})', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('افتتاحي: ${item['opening_stock']} \vert{} وارد: ${item['total_in']} | منصرف: ${item['total_out']}\nالصلاحية: ${item['expiry_date'] ?? '-'}'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('$balance', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isLow ? Colors.red : Colors.teal)),
                        Text(isLow ? 'طلب عاجل' : 'متوفر', style: TextStyle(fontSize: 11, color: isLow ? Colors.red : Colors.green)),
                      ],
                    ),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => ItemMovementScreen(item: item)),
                      ).then((_) => _fetchInventoryData());
                    },
                  ),
                );
              },
            ),
    );
  }
}

// ================= 2. شاشة حركات الصنف التفصيلية =================
class ItemMovementScreen extends StatefulWidget {
  final Map<String, dynamic> item;
  const ItemMovementScreen({super.key, required this.item});

  @override
  State<ItemMovementScreen> createState() => _ItemMovementScreenState();
}

class _ItemMovementScreenState extends State<ItemMovementScreen> {
  List<Map<String, dynamic>> movements = [];

  @override
  void initState() {
    super.initState();
    _loadMovements();
  }

  Future<void> _loadMovements() async {
    final db = await DatabaseHelper.instance.database;
    final res = await db.query('movements', where: 'item_id = ?', whereArgs: [widget.item['id']], orderBy: 'id DESC');
    setState(() => movements = res);
  }

  void _showAddMovementDialog(String type) {
    final partyCtrl = TextEditingController();
    final qtyCtrl = TextEditingController();
    final manualRefCtrl = TextEditingController();
    final outRefTypeCtrl = TextEditingController();
    final outRefNoCtrl = TextEditingController();
    final batchCtrl = TextEditingController();
    String inSubType = 'استلام كميات';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDState) => AlertDialog(
          title: Text(type == 'in' ? 'إدخال وارد' : 'إخراج منصرف'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: partyCtrl, decoration: const InputDecoration(labelText: 'اسم العميل / المورد')),
                if (type == 'in') ...[
                  DropdownButtonFormField<String>(
                    value: inSubType,
                    decoration: const InputDecoration(labelText: 'نوع الوارد'),
                    items: const [
                      DropdownMenuItem(value: 'استلام كميات', child: Text('استلام كميات')),
                      DropdownMenuItem(value: 'فاتورة مردود', child: Text('فاتورة مردود')),
                    ],
                    onChanged: (v) => setDState(() => inSubType = v!),
                  ),
                  TextField(controller: manualRefCtrl, decoration: const InputDecoration(labelText: 'رقم المرجع اليدوي')),
                ] else ...[
                  TextField(controller: outRefTypeCtrl, decoration: const InputDecoration(labelText: 'نوع المرجع')),
                  TextField(controller: outRefNoCtrl, decoration: const InputDecoration(labelText: 'رقم المرجع')),
                ],
                TextField(controller: batchCtrl, decoration: const InputDecoration(labelText: 'رقم التشغيلة / الوجبة')),
                TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'الكمية')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
            OutlinedButton(
              onPressed: () => _saveMovement(type, partyCtrl.text, inSubType, manualRefCtrl.text, outRefTypeCtrl.text, outRefNoCtrl.text, batchCtrl.text, qtyCtrl.text, 'draft', ctx),
              child: const Text('حفظ كمسودة'),
            ),
            ElevatedButton(
              onPressed: () => _saveMovement(type, partyCtrl.text, inSubType, manualRefCtrl.text, outRefTypeCtrl.text, outRefNoCtrl.text, batchCtrl.text, qtyCtrl.text, 'posted', ctx),
              child: const Text('اعتماد وترحيل'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveMovement(String type, String party, String inSubType, String manRef, String outType, String outNo, String batch, String qtyStr, String status, BuildContext ctx) async {
    final qty = double.tryParse(qtyStr) ?? 0.0;
    if (party.isEmpty || qty <= 0) return;

    final db = await DatabaseHelper.instance.database;
    await db.insert('movements', {
      'item_id': widget.item['id'],
      'date': DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()),
      'party_name': party,
      'movement_type': type,
      'in_sub_type': type == 'in' ? inSubType : null,
      'manual_ref': type == 'in' ? manRef : null,
      'out_ref_type': type == 'out' ? outType : null,
      'out_ref_no': type == 'out' ? outNo : null,
      'batch_no': batch,
      'qty': qty,
      'status': status,
    });
    Navigator.pop(ctx);
    _loadMovements();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('بطاقة الصنف: ${widget.item['name']}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                    icon: const Icon(Icons.arrow_downward),
                    label: const Text('إدخال وارد'),
                    onPressed: () => _showAddMovementDialog('in'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
                    icon: const Icon(Icons.arrow_upward),
                    label: const Text('إخراج منصرف'),
                    onPressed: () => _showAddMovementDialog('out'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: movements.isEmpty
                ? const Center(child: Text('لا توجد حركات مسجلة لهذا الصنف'))
                : ListView.builder(
                    itemCount: movements.length,
                    itemBuilder: (ctx, i) {
                      final m = movements[i];
                      final isIn = m['movement_type'] == 'in';
                      final isDraft = m['status'] == 'draft';
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        child: ListTile(
                          leading: Icon(
                            isIn ? Icons.add_circle : Icons.remove_circle,
                            color: isDraft ? Colors.grey : (isIn ? Colors.green : Colors.red),
                          ),
                          title: Text('${m['party_name']} - الكمية: ${m['qty']}${isDraft ? "(مسودة)" : ""}'),
                          subtitle: Text(
                            isIn
                                ? 'التاريخ: ${m['date']} | نوع الوارد: ${m['in_sub_type']} \vert{} مرجع: ${m['manual_ref'] ?? '-'}'
                                : 'التاريخ: ${m['date']} \vert{} نوع المرجع: ${m['out_ref_type']} |

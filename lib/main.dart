import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

const String kApiUrl = 'https://socialmedia-ad.ir/panel.php';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dbHelper = DatabaseHelper();
  await dbHelper.initDatabase();
  runApp(const HoloAccountingApp());
}

class HoloAccountingApp extends StatelessWidget {
  const HoloAccountingApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'حسابداری و انبارداری جامع',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('fa', 'IR')],
      locale: const Locale('fa', 'IR'),
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        fontFamily: 'Tahoma',
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F6FA),
      ),
      home: const MainHomeScreen(),
    );
  }
}

// ============================================================================
// DATABASE HELPER (Local SQLite)
// ============================================================================
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  static Database? _database;

  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await initDatabase();
    return _database!;
  }

  Future<Database> initDatabase() async {
    String dbPath = await getDatabasesPath();
    String path = p.join(dbPath, 'holo_accounting.db');

    return await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        // ۱. جدول کالاها
        await db.execute('''
          CREATE TABLE products (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            code TEXT UNIQUE,
            category TEXT,
            unit TEXT,
            buy_price REAL,
            sell_price REAL,
            stock_quantity INTEGER DEFAULT 0,
            min_stock INTEGER DEFAULT 5
          )
        ''');

        // ۲. جدول اشخاص (طرف حساب)
        await db.execute('''
          CREATE TABLE parties (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT,
            type TEXT, -- customer / supplier
            balance REAL DEFAULT 0.0
          )
        ''');

        // ۳. جدول فاکتورها
        await db.execute('''
          CREATE TABLE invoices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            invoice_type TEXT, -- sale / purchase / return_sale / return_purchase
            party_name TEXT,
            total_amount REAL,
            created_at TEXT
          )
        ''');

        // ۴. جدول اقلام فاکتور
        await db.execute('''
          CREATE TABLE invoice_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            invoice_id INTEGER,
            product_id INTEGER,
            product_name TEXT,
            quantity INTEGER,
            unit_price REAL,
            total_price REAL
          )
        ''');

        // ۵. جدول اسناد حسابداری (معین / دفتر روزنامه)
        await db.execute('''
          CREATE TABLE journal_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT,
            debit REAL,
            credit REAL,
            description TEXT,
            created_at TEXT
          )
        ''');

        // داده‌های اولیه نمونه
        await db.insert('products', {
          'name': 'کالای نمونه ۱',
          'code': '1001',
          'category': 'عمومی',
          'unit': 'عدد',
          'buy_price': 100000,
          'sell_price': 150000,
          'stock_quantity': 50,
          'min_stock': 10
        });

        await db.insert('parties', {
          'name': 'مشتری نمونه (علی محمدی)',
          'phone': '09120000000',
          'type': 'customer',
          'balance': 0.0
        });
      },
    );
  }

  Future<List>> getProducts() async {
    final db = await database;
    return await db.query('products', orderBy: 'id DESC');
  }

  Future<int> insertProduct(Map<String, dynamic> row) async {
    final db = await database;
    return await db.insert('products', row);
  }

  Future<int> updateProductStock(int id, int newQuantity) async {
    final db = await database;
    return await db.update('products', {'stock_quantity': newQuantity}, where: 'id = ?', whereArgs: [id]);
  }

  Future<List>> getParties() async {
    final db = await database;
    return await db.query('parties', orderBy: 'id DESC');
  }

  Future<int> insertParty(Map<String, dynamic> row) async {
    final db = await database;
    return await db.insert('parties', row);
  }

  Future<int> createInvoice(String type, String partyName, double total, List> items) async {
    final db = await database;
    int invoiceId = await db.insert('invoices', {
      'invoice_type': type,
      'party_name': partyName,
      'total_amount': total,
      'created_at': DateTime.now().toIso8601String(),
    });

    for (var item in items) {
      await db.insert('invoice_items', {
        'invoice_id': invoiceId,
        'product_id': item['product_id'],
        'product_name': item['product_name'],
        'quantity': item['quantity'],
        'unit_price': item['unit_price'],
        'total_price': item['total_price'],
      });

      // به روزرسانی موجودی انبار
      int pId = item['product_id'];
      int qty = item['quantity'];
      List pList = await db.query('products', where: 'id = ?', whereArgs: [pId]);
      if (pList.isNotEmpty) {
        int currentStock = pList.first['stock_quantity'];
        int newStock = (type == 'sale') ? (currentStock - qty) : (currentStock + qty);
        await db.update('products', {'stock_quantity': newStock}, where: 'id = ?', whereArgs: [pId]);
      }
    }

    // ثبت سند روزنامه اتوماتیک
    await db.insert('journal_entries', {
      'title': type == 'sale' ? 'فاکتور فروش شماره $invoiceId' : 'فاکتور خرید شماره $invoiceId',
      'debit': type == 'sale' ? total : 0,
      'credit': type == 'sale' ? 0 : total,
      'description': 'ثبت اتوماتیک فاکتور برای $partyName',
      'created_at': DateTime.now().toIso8601String(),
    });

    return invoiceId;
  }

  Future<List>> getInvoices() async {
    final db = await database;
    return await db.query('invoices', orderBy: 'id DESC');
  }

  Future<List>> getJournalEntries() async {
    final db = await database;
    return await db.query('journal_entries', orderBy: 'id DESC');
  }
}

// ============================================================================
// MAIN HOME SCREEN WITH BOTTOM NAVIGATION
// ============================================================================
class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({Key? key}) : super(key: key);

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const DashboardTab(),
    const InventoryTab(),
    const InvoiceTab(),
    const AccountingTab(),
    const CloudSyncTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('حسابداری و انبارداری هلو (همه‌کاره)', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        elevation: 2,
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: _screens[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.indigo,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'داشبورد'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2), label: 'انبارداری'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long), label: 'فاکتورها'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance), label: 'حسابداری'),
          BottomNavigationBarItem(icon: Icon(Icons.cloud_sync), label: 'بکاپ ابری'),
        ],
      ),
    );
  }
}

// ============================================================================
// TAB 1: DASHBOARD
// ============================================================================
class DashboardTab extends StatelessWidget {
  const DashboardTab({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('خلاصه وضعیت کسب و کار', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(child: _buildCard('فروش کل امروز', '۰ تومان', Colors.green, Icons.arrow_upward)),
              const SizedBox(width: 10),
              Expanded(child: _buildCard('خرید کل امروز', '۰ تومان', Colors.red, Icons.arrow_downward)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildCard('تعداد کالاها', 'فعال', Colors.blue, Icons.inventory)),
              const SizedBox(width: 10),
              Expanded(child: _buildCard('هشدار کمبود انبار', '۰ کالا', Colors.orange, Icons.warning)),
            ],
          ),
          const SizedBox(height: 25),
          const Text('دسترسی‌های سریع', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 15),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            children: [
              _buildQuickAction(context, 'فاکتور فروش جدید', Icons.add_shopping_cart, Colors.teal, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateInvoiceScreen(type: 'sale')));
              }),
              _buildQuickAction(context, 'فاکتور خرید جدید', Icons.add_business, Colors.indigo, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateInvoiceScreen(type: 'purchase')));
              }),
              _buildQuickAction(context, 'تعریف کالا جدید', Icons.add_box, Colors.purple, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const AddProductScreen()));
              }),
              _buildQuickAction(context, 'انبارگردانی فوری', Icons.fact_check, Colors.deepOrange, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const StocktakingScreen()));
              }),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildCard(String title, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontSize: 13, color: Colors.grey)),
          const SizedBox(height: 5),
          Text(value, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildQuickAction(BuildContext context, String title, IconData icon, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 36, color: color),
            const SizedBox(height: 10),
            Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// TAB 2: INVENTORY & STOCKTAKING
// ============================================================================
class InventoryTab extends StatefulWidget {
  const InventoryTab({Key? key}) : super(key: key);

  @override
  State<InventoryTab> createState() => _InventoryTabState();
}

class _InventoryTabState extends State<InventoryTab> {
  final dbHelper = DatabaseHelper();
  List> _products = [];

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  void _loadProducts() async {
    final list = await dbHelper.getProducts();
    setState(() {
      _products = list;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _products.isEmpty
          ? const Center(child: Text('کالایی تعریف نشده است'))
          : ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final p = _products[index];
                final isLowStock = p['stock_quantity'] <= p['min_stock'];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isLowStock ? Colors.red.shade100 : Colors.indigo.shade100,
                      child: Icon(Icons.inventory_2, color: isLowStock ? Colors.red : Colors.indigo),
                    ),
                    title: Text(p['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('کد: ${p['code']} | قیمت فروش: ${p['sell_price']} تومان'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('موجودی: ${p['stock_quantity']}', style: TextStyle(fontWeight: FontWeight.bold, color: isLowStock ? Colors.red : Colors.black)),
                        if (isLowStock) const Text('هشدار کمبود', style: TextStyle(color: Colors.red, fontSize: 10)),
                      ],
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'btn1',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const StocktakingScreen()));
              _loadProducts();
            },
            label: const Text('انبارگردانی'),
            icon: const Icon(Icons.fact_check),
            backgroundColor: Colors.orange,
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'btn2',
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddProductScreen()));
              _loadProducts();
            },
            label: const Text('کالای جدید'),
            icon: const Icon(Icons.add),
            backgroundColor: Colors.indigo,
          ),
        ],
      ),
    );
  }
}

class AddProductScreen extends StatefulWidget {
  const AddProductScreen({Key? key}) : super(key: key);

  @override
  State<AddProductScreen> createState() => _AddProductScreenState();
}

class _AddProductScreenState extends State<AddProductScreen> {
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _buyPriceController = TextEditingController();
  final _sellPriceController = TextEditingController();
  final _stockController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تعریف کالای جدید')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: ListView(
          children: [
            TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'نام کالا')),
            TextField(controller: _codeController, decoration: const InputDecoration(labelText: 'کد کالا / بارکد')),
            TextField(controller: _buyPriceController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قیمت خرید (تومان)')),
            TextField(controller: _sellPriceController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قیمت فروش (تومان)')),
            TextField(controller: _stockController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'موجودی اولیه')),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () async {
                if (_nameController.text.isNotEmpty) {
                  await DatabaseHelper().insertProduct({
                    'name': _nameController.text,
                    'code': _codeController.text,
                    'category': 'عمومی',
                    'unit': 'عدد',
                    'buy_price': double.tryParse(_buyPriceController.text) ?? 0,
                    'sell_price': double.tryParse(_sellPriceController.text) ?? 0,
                    'stock_quantity': int.tryParse(_stockController.text) ?? 0,
                    'min_stock': 5,
                  });
                  Navigator.pop(context);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
              child: const Text('ذخیره کالا'),
            )
          ],
        ),
      ),
    );
  }
}

class StocktakingScreen extends StatefulWidget {
  const StocktakingScreen({Key? key}) : super(key: key);

  @override
  State<StocktakingScreen> createState() => _StocktakingScreenState();
}

class _StocktakingScreenState extends State<StocktakingScreen> {
  final dbHelper = DatabaseHelper();
  List> _products = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() async {
    final list = await dbHelper.getProducts();
    setState(() => _products = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('انبارگردانی و مغایرت‌گیری')),
      body: ListView.builder(
        itemCount: _products.length,
        itemBuilder: (context, index) {
          final p = _products[index];
          final textCtrl = TextEditingController(text: p['stock_quantity'].toString());
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: ListTile(
              title: Text(p['name']),
              subtitle: Text('موجودی سیستم: ${p['stock_quantity']}'),
              trailing: SizedBox(
                width: 120,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: textCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'واقعی'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () async {
                        int newQty = int.tryParse(textCtrl.text) ?? p['stock_quantity'];
                        await dbHelper.updateProductStock(p['id'], newQty);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('موجودی جدید به‌روز شد')));
                      },
                    )
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// TAB 3: INVOICES & SALES
// ============================================================================
class InvoiceTab extends StatefulWidget {
  const InvoiceTab({Key? key}) : super(key: key);

  @override
  State<InvoiceTab> createState() => _InvoiceTabState();
}

class _InvoiceTabState extends State<InvoiceTab> {
  List> _invoices = [];

  @override
  void initState() {
    super.initState();
    _loadInvoices();
  }

  void _loadInvoices() async {
    final list = await DatabaseHelper().getInvoices();
    setState(() => _invoices = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _invoices.isEmpty
          ? const Center(child: Text('هیچ فاکتوری ثبت نشده است'))
          : ListView.builder(
              itemCount: _invoices.length,
              itemBuilder: (context, index) {
                final inv = _invoices[index];
                final isSale = inv['invoice_type'] == 'sale';
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isSale ? Colors.green.shade100 : Colors.blue.shade100,
                      child: Icon(isSale ? Icons.arrow_upward : Icons.arrow_downward, color: isSale ? Colors.green : Colors.blue),
                    ),
                    title: Text('${isSale ? "فاکتور فروش" : "فاکتور خرید"} - ${inv['party_name']}'),
                    subtitle: Text('تاریخ: ${inv['created_at'].toString().split('T')[0]}'),
                    trailing: Text('${inv['total_amount']} تومان', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateInvoiceScreen(type: 'sale')));
          _loadInvoices();
        },
        label: const Text('صدور فاکتور جدید'),
        icon: const Icon(Icons.add_shopping_cart),
        backgroundColor: Colors.teal,
      ),
    );
  }
}

class CreateInvoiceScreen extends StatefulWidget {
  final String type; // sale / purchase
  const CreateInvoiceScreen({Key? key, required this.type}) : super(key: key);

  @override
  State<CreateInvoiceScreen> createState() => _CreateInvoiceScreenState();
}

class _CreateInvoiceScreenState extends State<CreateInvoiceScreen> {
  final dbHelper = DatabaseHelper();
  List> _products = [];
  Map<int, int> _selectedQuantities = {};
  String _partyName = 'مشتری عمومی';

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  void _loadProducts() async {
    final list = await dbHelper.getProducts();
    setState(() => _products = list);
  }

  double _calculateTotal() {
    double total = 0;
    _selectedQuantities.forEach((productId, qty) {
      if (qty > 0) {
        final p = _products.firstWhere((element) => element['id'] == productId);
        double price = (widget.type == 'sale') ? p['sell_price'] : p['buy_price'];
        total += price * qty;
      }
    });
    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.type == 'sale' ? 'صدور فاکتور فروش' : 'صدور فاکتور خرید')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: const InputDecoration(labelText: 'نام طرف حساب / مشتری', border: OutlineInputBorder()),
              onChanged: (v) => _partyName = v,
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final p = _products[index];
                int qty = _selectedQuantities[p['id']] ?? 0;
                double price = (widget.type == 'sale') ? p['sell_price'] : p['buy_price'];

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: ListTile(
                    title: Text(p['name']),
                    subtitle: Text('قیمت واحد: $price | موجودی فعلی: ${p['stock_quantity']}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.red),
                          onPressed: () {
                            if (qty > 0) {
                              setState(() => _selectedQuantities[p['id']] = qty - 1);
                            }
                          },
                        ),
                        Text('$qty', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline, color: Colors.green),
                          onPressed: () {
                            setState(() => _selectedQuantities[p['id']] = qty + 1);
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('جمع کل: ${_calculateTotal()} تومان', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ElevatedButton(
                  onPressed: () async {
                    List> items = [];
                    _selectedQuantities.forEach((pId, qty) {
                      if (qty > 0) {
                        final p = _products.firstWhere((element) => element['id'] == pId);
                        double price = (widget.type == 'sale') ? p['sell_price'] : p['buy_price'];
                        items.add({
                          'product_id': pId,
                          'product_name': p['name'],
                          'quantity': qty,
                          'unit_price': price,
                          'total_price': price * qty,
                        });
                      }
                    });

                    if (items.isNotEmpty) {
                      await dbHelper.createInvoice(widget.type, _partyName, _calculateTotal(), items);
                      Navigator.pop(context);
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.indigo, foregroundColor: Colors.white),
                  child: const Text('ثبت و صدور فاکتور'),
                )
              ],
            ),
          )
        ],
      ),
    );
  }
}

// ============================================================================
// TAB 4: ACCOUNTING & JOURNAL ENTRIES
// ============================================================================
class AccountingTab extends StatefulWidget {
  const AccountingTab({Key? key}) : super(key: key);

  @override
  State<AccountingTab> createState() => _AccountingTabState();
}

class _AccountingTabState extends State<AccountingTab> {
  List> _entries = [];

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  void _loadEntries() async {
    final list = await DatabaseHelper().getJournalEntries();
    setState(() => _entries = list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _entries.isEmpty
          ? const Center(child: Text('دفتر روزنامه خالی است'))
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final item = _entries[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    title: Text(item['title'], style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(item['description'] ?? ''),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('بدهکار: ${item['debit']}', style: const TextStyle(color: Colors.green, fontSize: 12)),
                        Text('بستانکار: ${item['credit']}', style: const TextStyle(color: Colors.red, fontSize: 12)),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

// ============================================================================
// TAB 5: BACKUP & CLOUD SYNC
// ============================================================================
class CloudSyncTab extends StatefulWidget {
  const CloudSyncTab({Key? key}) : super(key: key);

  @override
  State<CloudSyncTab> createState() => _CloudSyncTabState();
}

class _CloudSyncTabState extends State<CloudSyncTab> {
  final _usernameCtrl = TextEditingController(text: 'user1');
  final _passwordCtrl = TextEditingController(text: '123456');
  bool _isLoading = false;
  String _statusMessage = '';

  Future<void> _performBackup() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'در حال تهیه نسخه پشتیبان...';
    });

    try {
      final dbHelper = DatabaseHelper();
      final products = await dbHelper.getProducts();
      final invoices = await dbHelper.getInvoices();
      final journal = await dbHelper.getJournalEntries();

      Map<String, dynamic> backupData = {
        'products': products,
        'invoices': invoices,
        'journal': journal,
      };

      final response = await http.post(
        Uri.parse(kApiUrl),
        body: {
          'action': 'backup',
          'username': _usernameCtrl.text,
          'password': _passwordCtrl.text,
          'backup_data': jsonEncode(backupData),
        },
      );

      final resJson = jsonDecode(response.body);
      if (resJson['status'] == 'success') {
        setState(() => _statusMessage = 'پشتیبان‌گیری ابری با موفقیت انجام شد!');
      } else {
        setState(() => _statusMessage = 'خطا: ${resJson['message']}');
      }
    } catch (e) {
      setState(() => _statusMessage = 'خطا در ارتباط با سرور: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('اتصال به حساب کاربری و پشتیبان‌گیری', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 15),
          TextField(controller: _usernameCtrl, decoration: const InputDecoration(labelText: 'نام کاربری', border: OutlineInputBorder())),
          const SizedBox(height: 10),
          TextField(controller: _passwordCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'کلمه عبور', border: OutlineInputBorder())),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _isLoading ? null : _performBackup,
            icon: const Icon(Icons.cloud_upload),
            label: const Text('ارسال بکاپ به سرور مرکز (socialmedia-ad.ir)'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              backgroundColor: Colors.indigo,
              foregroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: 20),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
          if (_statusMessage.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.indigo.shade50, borderRadius: BorderRadius.circular(8)),
              child: Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
        ],
      ),
    );
  }
}

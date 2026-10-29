import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:http/http.dart' as http;

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

        await db.execute('''
          CREATE TABLE parties (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            phone TEXT,
            type TEXT,
            balance REAL DEFAULT 0.0
          )
        ''');

        await db.execute('''
          CREATE TABLE invoices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            invoice_type TEXT,
            party_name TEXT,
            total_amount REAL,
            created_at TEXT
          )
        ''');

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

      int pId = item['product_id'];
      int qty = item['quantity'];
      List> pList = await db.query('products', where: 'id = ?', whereArgs: [pId]);
      if (pList.isNotEmpty) {
        int currentStock = (pList.first['stock_quantity'] as num).toInt();
        int newStock = (type == 'sale') ? (currentStock - qty) : (currentStock + qty);
        await db.update('products', {'stock_quantity': newStock}, where: 'id = ?', whereArgs: [pId]);
      }
    }

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

class MainHomeScreen extends StatefulWidget {
  const MainHomeScreen({Key? key}) : super(key: key);

  @override
  State<MainHomeScreen> createState() => _MainHomeScreenState();
}

class _MainHomeScreenState extends State<MainHomeScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    DashboardTab(),
    InventoryTab(),
    InvoiceTab(),
    AccountingTab(),
    CloudSyncTab(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('حسابداری و انبارداری هلو', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
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
              _buildQuickAction(context, 'فاکتور فروش', Icons.add_shopping_cart, Colors.teal, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateInvoiceScreen(type: 'sale')));
              }),
              _buildQuickAction(context, 'فاکتور خرید', Icons.add_business, Colors.indigo, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateInvoiceScreen(type: 'purchase')));
              }),
              _buildQuickAction(context, 'تعریف کالا', Icons.add_box, Colors.purple, () {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const AddProductScreen()));
              }),
              _buildQuickAction(context, 'انبارگردانی', Icons.fact_check, Colors.deepOrange, () {
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
    setState(() => _products = list);
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
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.inventory_2)),
                    title: Text(p['name']),
                    subtitle: Text('کد: ${p['code']} | قیمت فروش: ${p['sell_price']}'),
                    trailing: Text('موجودی: ${p['stock_quantity']}'),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddProductScreen()));
          _loadProducts();
        },
        label: const Text('کالای جدید'),
        icon: const Icon(Icons.add),
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
            TextField(controller: _codeController, decoration: const InputDecoration(labelText: 'کد کالا')),
            TextField(controller: _buyPriceController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قیمت خرید')),
            TextField(controller: _sellPriceController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'قیمت فروش')),
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
      appBar: AppBar(title: const Text('انبارگردانی')),
      body: ListView.builder(
        itemCount: _products.length,
        itemBuilder: (context, index) {
          final p = _products[index];
          final textCtrl = TextEditingController(text: p['stock_quantity'].toString());
          return Card(
            child: ListTile(
              title: Text(p['name']),
              subtitle: Text('موجودی فعلی: ${p['stock_quantity']}'),
              trailing: SizedBox(
                width: 120,
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(controller: textCtrl, keyboardType: TextInputType.number),
                    ),
                    IconButton(
                      icon: const Icon(Icons.check, color: Colors.green),
                      onPressed: () async {
                        int newQty = int.tryParse(textCtrl.text) ?? p['stock_quantity'];
                        await dbHelper.updateProductStock(p['id'], newQty);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('بروز شد')));
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
          ? const Center(child: Text('فاکتوری ثبت نشده است'))
          : ListView.builder(
              itemCount: _invoices.length,
              itemBuilder: (context, index) {
                final inv = _invoices[index];
                return Card(
                  child: ListTile(
                    title: Text('${inv['invoice_type']} - ${inv['party_name']}'),
                    trailing: Text('${inv['total_amount']} تومان'),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const CreateInvoiceScreen(type: 'sale')));
          _loadInvoices();
        },
        label: const Text('فاکتور جدید'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

class CreateInvoiceScreen extends StatefulWidget {
  final String type;
  const CreateInvoiceScreen({Key? key, required this.type}) : super(key: key);

  @override
  State<CreateInvoiceScreen> createState() => _CreateInvoiceScreenState();
}

class _CreateInvoiceScreenState extends State<CreateInvoiceScreen> {
  final dbHelper = DatabaseHelper();
  List> _products = [];
  final Map<int, int> _selectedQuantities = {};
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
        double price = (widget.type == 'sale') ? (p['sell_price'] as num).toDouble() : (p['buy_price'] as num).toDouble();
        total += price * qty;
      }
    });
    return total;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.type == 'sale' ? 'فاکتور فروش' : 'فاکتور خرید')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              decoration: const InputDecoration(labelText: 'نام مشتری'),
              onChanged: (v) => _partyName = v,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _products.length,
              itemBuilder: (context, index) {
                final p = _products[index];
                int qty = _selectedQuantities[p['id']] ?? 0;
                return Card(
                  child: ListTile(
                    title: Text(p['name']),
                    subtitle: Text('موجودی: ${p['stock_quantity']}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          onPressed: () {
                            if (qty > 0) setState(() => _selectedQuantities[p['id']] = qty - 1);
                          },
                        ),
                        Text('$qty'),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () => setState(() => _selectedQuantities[p['id']] = qty + 1),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: () async {
                List> items = [];
                _selectedQuantities.forEach((pId, qty) {
                  if (qty > 0) {
                    final p = _products.firstWhere((element) => element['id'] == pId);
                    double price = (widget.type == 'sale') ? (p['sell_price'] as num).toDouble() : (p['buy_price'] as num).toDouble();
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
              child: const Text('ثبت نهایی فاکتور'),
            ),
          )
        ],
      ),
    );
  }
}

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
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final item = _entries[index];
        return Card(
          child: ListTile(
            title: Text(item['title']),
            subtitle: Text(item['description'] ?? ''),
          ),
        );
      },
    );
  }
}

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
      _statusMessage = 'در حال ارسال بکاپ...';
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
        setState(() => _statusMessage = 'بکاپ با موفقیت در سرور ذخیره شد!');
      } else {
        setState(() => _statusMessage = 'خطا: ${resJson['message']}');
      }
    } catch (e) {
      setState(() => _statusMessage = 'خطا در ارتباط: $e');
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
          TextField(controller: _usernameCtrl, decoration: const InputDecoration(labelText: 'نام کاربری')),
          const SizedBox(height: 10),
          TextField(controller: _passwordCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'رمز عبور')),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isLoading ? null : _performBackup,
            child: const Text('ارسال پشتیبان به سرور ابری'),
          ),
          const SizedBox(height: 20),
          Text(_statusMessage, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
  } catch (e) {
    debugPrint('Firebase initialization failed (running in local mode): $e');
  }
  runApp(const UslyApp());
}

const Color backgroundColor = Color(0xFFFFFAF6);
const Color primaryColor = Color(0xFFD9AFA5);
const Color darkColor = Color(0xFF55443F);
const Color softColor = Color(0xFFF4E7E1);

const int reminderNotificationId = 100;
const String widgetAndroidName = 'UslyWidgetProvider';

final FlutterLocalNotificationsPlugin notifications =
    FlutterLocalNotificationsPlugin();

bool notificationsInitialized = false;

Future<void> initializeNotifications() async {
  if (notificationsInitialized) return;

  tz.initializeTimeZones();

  try {
    final timezoneInfo = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timezoneInfo.identifier));
  } catch (e) {
    debugPrint('Nie udało się ustawić strefy czasowej: $e');
  }

  const initializationSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    ),
  );

  await notifications.initialize(
    settings: initializationSettings,
  );

  notificationsInitialized = true;
}

Future<bool> requestNotificationPermission() async {
  await initializeNotifications();

  if (Platform.isAndroid) {
    final android = notifications.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();

    final result = await android?.requestNotificationsPermission();
    return result ?? false;
  }

  if (Platform.isIOS) {
    final ios = notifications.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();

    final result = await ios?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    return result ?? false;
  }

  return false;
}

Future<void> scheduleDailyReminder(int hour, int minute) async {
  await initializeNotifications();

  await notifications.cancel(id: reminderNotificationId);

  final now = tz.TZDateTime.now(tz.local);

  var scheduledDate = tz.TZDateTime(
    tz.local,
    now.year,
    now.month,
    now.day,
    hour,
    minute,
  );

  if (!scheduledDate.isAfter(now)) {
    scheduledDate = scheduledDate.add(const Duration(days: 1));
  }

  const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'usly_daily_reminder',
      'Przypomnienia Usly',
      channelDescription: 'Codzienne przypomnienie o dodaniu zdjęcia',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    ),
  );

  await notifications.zonedSchedule(
    id: reminderNotificationId,
    title: 'Czas na nowe wspomnienie',
    body: 'Dodajcie dzisiaj zdjęcie do Usly.',
    scheduledDate: scheduledDate,
    notificationDetails: details,
    androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    matchDateTimeComponents: DateTimeComponents.time,
  );
}

class UslyApp extends StatelessWidget {
  const UslyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Usly',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: backgroundColor,
        colorScheme: ColorScheme.fromSeed(
          seedColor: primaryColor,
          brightness: Brightness.light,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: backgroundColor,
          foregroundColor: darkColor,
          elevation: 0,
          centerTitle: false,
        ),
        textTheme: const TextTheme(
          headlineMedium: TextStyle(
            color: darkColor,
            fontWeight: FontWeight.bold,
          ),
          titleLarge: TextStyle(
            color: darkColor,
            fontWeight: FontWeight.bold,
          ),
          bodyMedium: TextStyle(color: darkColor),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final ImagePicker _picker = ImagePicker();

  List<Map<String, dynamic>> photos = [];
  DateTime? relationshipDate;

  bool loading = true;
  bool saving = false;

  bool reminderEnabled = false;
  int reminderHour = 20;
  int reminderMinute = 0;

  String spaceId = 'USLY01';
  String myDeviceId = '';
  bool isCloudConnected = false;
  StreamSubscription? _photosSubscription;
  StreamSubscription? _spaceSubscription;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _photosSubscription?.cancel();
    _spaceSubscription?.cancel();
    super.dispose();
  }

  Future<File> _dataFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/usly_data.json');
  }

  String _generateSpaceCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random();
    return List.generate(6, (index) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _loadData() async {
    try {
      final file = await _dataFile();

      if (await file.exists()) {
        final content = await file.readAsString();
        final data = jsonDecode(content);

        final savedPhotos = data['photos'] as List? ?? [];

        photos = savedPhotos
            .map((photo) => Map<String, dynamic>.from(photo))
            .where((photo) => File(photo['path']).existsSync())
            .toList();

        photos.sort((a, b) {
          return DateTime.parse(b['createdAt'])
              .compareTo(DateTime.parse(a['createdAt']));
        });

        if (data['relationshipDate'] != null) {
          relationshipDate = DateTime.parse(data['relationshipDate']);
        }

        reminderEnabled = data['reminderEnabled'] ?? false;
        reminderHour = data['reminderHour'] ?? 20;
        reminderMinute = data['reminderMinute'] ?? 0;
        
        if (data['spaceId'] != null && (data['spaceId'] as String).isNotEmpty) {
          spaceId = data['spaceId'];
        }

        if (data['myDeviceId'] != null && (data['myDeviceId'] as String).isNotEmpty) {
          myDeviceId = data['myDeviceId'];
        }
      }
    } catch (e) {
      debugPrint('Błąd odczytu danych: $e');
    }

    if (myDeviceId.isEmpty) {
      myDeviceId = 'dev_${_generateSpaceCode()}';
      await _saveData();
    }

    if (relationshipDate == null) {
      relationshipDate = DateTime(2024, 2, 2);
      await _saveData();
    }

    // Initialize Firebase Auth & Cloud Sync
    try {
      if (Firebase.apps.isNotEmpty) {
        await FirebaseAuth.instance.signInAnonymously();
        isCloudConnected = true;
        _initCloudSync();
      }
    } catch (e) {
      debugPrint('Błąd uwierzytelniania w chmurze: $e');
      isCloudConnected = false;
    }

    try {
      await initializeNotifications();

      if (reminderEnabled) {
        await scheduleDailyReminder(reminderHour, reminderMinute);
      }
    } catch (e) {
      debugPrint('Błąd inicjalizacji powiadomień: $e');
    }

    await _syncWidget();

    if (mounted) {
      setState(() {
        loading = false;
      });
    }
  }

  void _initCloudSync() {
    if (!isCloudConnected) return;

    _photosSubscription?.cancel();
    _spaceSubscription?.cancel();

    try {
      final firestore = FirebaseFirestore.instance;

      // Listen to space document for relationship date
      _spaceSubscription = firestore
          .collection('spaces')
          .doc(spaceId)
          .snapshots()
          .listen((doc) async {
        if (doc.exists) {
          final data = doc.data();
          if (data != null && data['relationshipDate'] != null) {
            final remoteDate = DateTime.parse(data['relationshipDate']);
            if (relationshipDate != remoteDate) {
              setState(() {
                relationshipDate = remoteDate;
              });
              await _saveData();
              await _syncWidget();
            }
          }
        } else {
          // Initialize space document if not exists
          await firestore.collection('spaces').doc(spaceId).set({
            'relationshipDate': relationshipDate?.toIso8601String(),
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      });

      // Listen to photos collection in Firestore (Base64 sync)
      _photosSubscription = firestore
          .collection('spaces')
          .doc(spaceId)
          .collection('photos')
          .snapshots()
          .listen((snapshot) async {
        final appDirectory = await getApplicationDocumentsDirectory();
        final photoDirectory = Directory('${appDirectory.path}/photos');
        if (!await photoDirectory.exists()) {
          await photoDirectory.create(recursive: true);
        }

        bool updated = false;
        final remotePhotoIds = <String>{};

        // Process all documents currently in Firestore
        for (final doc in snapshot.docs) {
          final data = doc.data();
          final pId = data['id'] as String? ?? doc.id;
          remotePhotoIds.add(pId);

          final base64Data = data['base64Data'] as String? ?? '';
          final fileName = data['fileName'] as String? ?? 'photo_$pId.jpg';
          final createdAt = data['createdAt'] as String? ?? DateTime.now().toIso8601String();
          final senderDevice = data['senderDevice'] as String? ?? data['uploader'] as String? ?? 'unknown';

          final localPath = '${photoDirectory.path}/$fileName';
          final localFile = File(localPath);

          if (!await localFile.exists() && base64Data.isNotEmpty) {
            try {
              final bytes = base64Decode(base64Data);
              await localFile.writeAsBytes(bytes);
            } catch (e) {
              debugPrint('Błąd dekodowania zdjęcia z chmury: $e');
            }
          }

          final index = photos.indexWhere((p) => (p['id'] != null && p['id'] == pId) || p['path'] == localPath || p['fileName'] == fileName);
          if (index == -1) {
            if (await localFile.exists()) {
              photos.add({
                'id': pId,
                'path': localPath,
                'createdAt': createdAt,
                'fileName': fileName,
                'senderDevice': senderDevice,
              });
              updated = true;
            }
          } else {
            if (photos[index]['id'] == null) {
              photos[index]['id'] = pId;
              updated = true;
            }
            if (photos[index]['senderDevice'] == null) {
              photos[index]['senderDevice'] = senderDevice;
              updated = true;
            }
          }
        }

        // Handle deletions from remote by checking both ID and fileName against remote snapshot docs
        final existingCount = photos.length;
        photos.removeWhere((p) {
          final pId = p['id'];
          final pFileName = p['fileName'];

          bool existsRemotely = false;
          for (final doc in snapshot.docs) {
            final data = doc.data();
            final remoteId = data['id'] as String? ?? doc.id;
            final remoteFileName = data['fileName'] as String? ?? '';
            if ((pId != null && remoteId == pId) || (pFileName != null && remoteFileName == pFileName)) {
              existsRemotely = true;
              break;
            }
          }

          if (!existsRemotely) {
            try {
              final f = File(p['path']);
              if (f.existsSync()) f.deleteSync();
            } catch (_) {}
            return true;
          }
          return false;
        });

        if (photos.length != existingCount) {
          updated = true;
        }

        if (updated) {
          photos.sort((a, b) {
            return DateTime.parse(b['createdAt'])
                .compareTo(DateTime.parse(a['createdAt']));
          });
          await _saveData();
          await _syncWidget();
          if (mounted) setState(() {});
        }
      });
    } catch (e) {
      debugPrint('Błąd nasłuchiwania chmury: $e');
    }
  }

  Future<void> _saveData() async {
    try {
      final file = await _dataFile();

      final data = {
        'photos': photos,
        'relationshipDate': relationshipDate?.toIso8601String(),
        'reminderEnabled': reminderEnabled,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
        'spaceId': spaceId,
        'myDeviceId': myDeviceId,
      };

      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      debugPrint('Błąd zapisywania danych: $e');
      _showMessage('Nie udało się zapisać danych.');
    }
  }

  Future<void> _syncWidget() async {
    if (!Platform.isAndroid) return;

    try {
      final latestPhoto = photos.isNotEmpty ? photos.first : null;

      String photoPath = '';
      String emptyText = 'Wasze zdjęcia pojawią się tutaj';

      if (latestPhoto != null) {
        final sender = latestPhoto['senderDevice'];
        if (sender != null && myDeviceId.isNotEmpty && sender == myDeviceId) {
          // Latest photo was uploaded by me -> show waiting placeholder on widget
          photoPath = '';
          emptyText = 'Czekanie na odpowiedź drugiej połówki ⏳';
        } else {
          // Latest photo was uploaded by partner -> show photo
          photoPath = latestPhoto['path'] ?? '';
        }
      }

      await HomeWidget.saveWidgetData<String>('photoPath', photoPath);
      await HomeWidget.saveWidgetData<String>('emptyText', emptyText);
      await HomeWidget.saveWidgetData<String>('relationshipDays', '$relationshipDays');
      await HomeWidget.saveWidgetData<String>('photoStreak', '$photoStreak');

      await HomeWidget.updateWidget(
        androidName: widgetAndroidName,
      );
    } catch (e) {
      debugPrint('Błąd aktualizacji widgetu: $e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: darkColor,
      ),
    );
  }

  Future<void> _savePhoto(Map<String, dynamic> photo, BuildContext context) async {
    try {
      final sourcePath = photo['path'] as String;
      final file = File(sourcePath);
      if (!await file.exists()) {
        _showMessage('Plik zdjęcia nie istnieje lokalnie.');
        return;
      }

      final picturesDir = Directory('/storage/emulated/0/Pictures/Usly');
      if (!await picturesDir.exists()) {
        await picturesDir.create(recursive: true);
      }

      final fileName = 'usly_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final targetPath = '${picturesDir.path}/$fileName';
      await file.copy(targetPath);

      _showMessage('Zdjęcie zostało zapisane w galerii (Pictures/Usly)!');
    } catch (e) {
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final targetPath = '${extDir.path}/usly_${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(photo['path']).copy(targetPath);
          _showMessage('Zdjęcie zapisane w pamięci zewnętrznej.');
          return;
        }
      } catch (_) {}
      _showMessage('Nie udało się zapisać zdjęcia.');
    }
  }

  Future<void> _saveAllPhotos() async {
    if (photos.isEmpty) {
      _showMessage('Brak zdjęć do pobrania.');
      return;
    }

    int count = 0;
    try {
      final picturesDir = Directory('/storage/emulated/0/Pictures/Usly');
      if (!await picturesDir.exists()) {
        await picturesDir.create(recursive: true);
      }

      for (final photo in photos) {
        final file = File(photo['path'] as String);
        if (await file.exists()) {
          final fileName = 'usly_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
          final targetPath = '${picturesDir.path}/$fileName';
          await file.copy(targetPath);
          count++;
        }
      }

      _showMessage('Pomyślnie pobrano $count zdjęć do folderu Pictures/Usly!');
    } catch (e) {
      _showMessage('Nie udało się pobrać wszystkich zdjęć.');
    }
  }

  Future<void> _changeReminder(bool enabled) async {
    if (enabled) {
      try {
        final permissionGranted = await requestNotificationPermission();

        if (!permissionGranted) {
          _showMessage(
            'Zezwól aplikacji Usly na wysyłanie powiadomień w ustawieniach telefonu.',
          );
          return;
        }

        await scheduleDailyReminder(reminderHour, reminderMinute);

        setState(() {
          reminderEnabled = true;
        });

        await _saveData();
        _showMessage('Codzienne przypomnienie zostało włączone.');
      } catch (e) {
        debugPrint('Błąd włączania przypomnienia: $e');
        _showMessage('Nie udało się włączyć przypomnienia.');
      }
    } else {
      try {
        await notifications.cancel(id: reminderNotificationId);

        setState(() {
          reminderEnabled = false;
        });

        await _saveData();
        _showMessage('Przypomnienie zostało wyłączone.');
      } catch (e) {
        debugPrint('Błąd wyłączania przypomnienia: $e');
        _showMessage('Nie udało się wyłączyć przypomnienia.');
      }
    }
  }

  Future<void> _changeReminderTime() async {
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: reminderHour,
        minute: reminderMinute,
      ),
      helpText: 'Wybierz godzinę przypomnienia',
      cancelText: 'Anuluj',
      confirmText: 'Zapisz',
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: primaryColor,
              brightness: Brightness.light,
            ),
          ),
          child: child!,
        );
      },
    );

    if (selectedTime == null) return;

    setState(() {
      reminderHour = selectedTime.hour;
      reminderMinute = selectedTime.minute;
    });

    if (reminderEnabled) {
      try {
        await scheduleDailyReminder(reminderHour, reminderMinute);
      } catch (e) {
        debugPrint('Błąd zmiany godziny przypomnienia: $e');
        _showMessage('Nie udało się zmienić godziny przypomnienia.');
      }
    }

    await _saveData();
  }

  Future<void> _addPhoto(ImageSource source) async {
    if (saving) return;

    try {
      final XFile? selectedPhoto = await _picker.pickImage(
        source: source,
        imageQuality: 75,
        maxWidth: 1024,
        maxHeight: 1024,
      );

      if (selectedPhoto == null) return;

      setState(() {
        saving = true;
      });

      final appDirectory = await getApplicationDocumentsDirectory();
      final photoDirectory = Directory('${appDirectory.path}/photos');

      if (!await photoDirectory.exists()) {
        await photoDirectory.create(recursive: true);
      }

      final photoId = DateTime.now().microsecondsSinceEpoch.toString();
      final fileName = 'photo_$photoId.jpg';
      final savedFile = File('${photoDirectory.path}/$fileName');

      final bytes = await selectedPhoto.readAsBytes();
      await savedFile.writeAsBytes(bytes);

      final base64Data = base64Encode(bytes);
      final createdAt = DateTime.now().toIso8601String();

      // Upload to Cloud Firestore via Base64 if connected
      if (isCloudConnected) {
        try {
          await FirebaseFirestore.instance
              .collection('spaces')
              .doc(spaceId)
              .collection('photos')
              .doc(photoId)
              .set({
            'id': photoId,
            'fileName': fileName,
            'base64Data': base64Data,
            'createdAt': createdAt,
            'senderDevice': myDeviceId,
          });
        } catch (e) {
          debugPrint('Błąd zapisu w chmurze: $e');
          _showMessage('Zdjęcie zapisane lokalnie. Synchronizacja nastąpi po połączeniu.');
        }
      }

      // Check if already in photos list
      if (!photos.any((p) => p['id'] == photoId || p['fileName'] == fileName)) {
        photos.insert(0, {
          'id': photoId,
          'path': savedFile.path,
          'createdAt': createdAt,
          'fileName': fileName,
          'senderDevice': myDeviceId,
        });
      }

      await _saveData();
      await _syncWidget();

      if (mounted) {
        setState(() {
          saving = false;
        });
      }

      _showMessage('Zdjęcie zostało dodane!');
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
        });
      }

      _showMessage('Nie udało się dodać zdjęcia. Spróbuj ponownie.');
      debugPrint('Błąd dodawania zdjęcia: $e');
    }
  }

  Future<void> _showPhotoOptions() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: backgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Dodaj nowe zdjęcie',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: darkColor,
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const Icon(
                    Icons.camera_alt_outlined,
                    color: primaryColor,
                  ),
                  title: const Text('Zrób zdjęcie'),
                  onTap: () {
                    Navigator.pop(context);
                    _addPhoto(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.photo_library_outlined,
                    color: primaryColor,
                  ),
                  title: const Text('Wybierz z galerii'),
                  onTap: () {
                    Navigator.pop(context);
                    _addPhoto(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showPairingDialog() async {
    final codeController = TextEditingController(text: spaceId);

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: backgroundColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text(
            'Połączenie z partnerem',
            style: TextStyle(color: darkColor, fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Twój kod przestrzeni pary:',
                style: TextStyle(color: Color(0xFF9B8178), fontSize: 13),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: softColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    spaceId,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: darkColor,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Wpisz lub wygeneruj kod przestrzeni:',
                style: TextStyle(color: darkColor, fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: codeController,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        hintText: 'np. USLY01',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: softColor),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: softColor),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Wygeneruj losowy kod',
                    onPressed: () {
                      codeController.text = _generateSpaceCode();
                    },
                    icon: const Icon(Icons.refresh, color: primaryColor),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: darkColor,
                  side: const BorderSide(color: primaryColor),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  minimumSize: const Size(double.infinity, 45),
                ),
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _saveAllPhotos();
                },
                icon: const Icon(Icons.download_rounded, color: primaryColor),
                label: const Text('Pobierz wszystkie zdjęcia na telefon'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Anuluj', style: TextStyle(color: darkColor)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: primaryColor),
              onPressed: () async {
                final newCode = codeController.text.trim().toUpperCase();
                if (newCode.isNotEmpty) {
                  setState(() {
                    spaceId = newCode;
                  });
                  await _saveData();
                  _initCloudSync();
                  if (!dialogContext.mounted) return;
                  Navigator.pop(dialogContext);
                  _showMessage('Połączono z przestrzenią: $newCode');
                }
              },
              child: const Text('Połącz'),
            ),
          ],
        );
      },
    );
  }

  int get relationshipDays {
    if (relationshipDate == null) return 0;

    final today = DateUtils.dateOnly(DateTime.now());
    final start = DateUtils.dateOnly(relationshipDate!);

    return today.difference(start).inDays + 1;
  }

  int get photoStreak {
    final Set<DateTime> photoDays = photos.map((photo) {
      final date = DateTime.parse(photo['createdAt']);
      return DateUtils.dateOnly(date);
    }).toSet();

    if (photoDays.isEmpty) return 0;

    final today = DateUtils.dateOnly(DateTime.now());

    DateTime currentDay;

    if (photoDays.contains(today)) {
      currentDay = today;
    } else {
      currentDay = today.subtract(const Duration(days: 1));
    }

    if (!photoDays.contains(currentDay)) return 0;

    int streak = 0;

    while (photoDays.contains(currentDay)) {
      streak++;
      currentDay = currentDay.subtract(const Duration(days: 1));
    }

    return streak;
  }

  String _formatDate(DateTime date) {
    const months = [
      'stycznia',
      'lutego',
      'marca',
      'kwietnia',
      'maja',
      'czerwca',
      'lipca',
      'sierpnia',
      'września',
      'października',
      'listopada',
      'grudnia',
    ];

    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  String _formatTime(DateTime date) {
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Future<void> _openPhoto(Map<String, dynamic> photo) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoViewerPage(
          photo: photo,
          onDelete: _deletePhoto,
          onSave: _savePhoto,
        ),
      ),
    );

    if (deleted == true && mounted) {
      setState(() {});
    }
  }

  Future<void> _deletePhoto(Map<String, dynamic> photo) async {
    try {
      final file = File(photo['path']);

      if (await file.exists()) {
        await file.delete();
      }

      final photoId = photo['id'];

      photos.removeWhere((item) => item['path'] == photo['path'] || item['id'] == photoId);

      // Delete from Cloud Firestore if connected
      if (isCloudConnected && photoId != null) {
        try {
          await FirebaseFirestore.instance
              .collection('spaces')
              .doc(spaceId)
              .collection('photos')
              .doc(photoId)
              .delete();
        } catch (e) {
          debugPrint('Błąd usuwania z chmury: $e');
        }
      }

      await _saveData();
      await _syncWidget();

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Błąd usuwania z chmury: $e');
      _showMessage('Nie udało się usunąć zdjęcia.');
      rethrow;
    }
  }

  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoHistoryPage(
          photos: photos,
          onDelete: _deletePhoto,
          onSave: _savePhoto,
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.bold,
          color: darkColor,
        ),
      ),
    );
  }

  Widget _relationshipCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: softColor,
        borderRadius: BorderRadius.circular(25),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.12),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        children: [
          const Icon(
            Icons.calendar_month_rounded,
            color: Color(0xFFB8877B),
            size: 30,
          ),
          const SizedBox(height: 9),
          const Text(
            'Każdy dzień razem jest wyjątkowy',
            style: TextStyle(color: darkColor, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            '$relationshipDays',
            style: const TextStyle(
              color: darkColor,
              fontSize: 46,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Text(
            'dni razem',
            style: TextStyle(
              color: darkColor,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _streakCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: softColor),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withValues(alpha: 0.10),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '🔥',
                  style: TextStyle(
                    fontSize: 25,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  photoStreak == 0
                      ? 'Dodaj zdjęcie, aby rozpocząć serię'
                      : 'Dodajcie zdjęcie również dzisiaj!',
                  style: const TextStyle(
                    color: Color(0xFF9B8178),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            '$photoStreak',
            style: const TextStyle(
              color: darkColor,
              fontSize: 30,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 5),
          const Text(
            'dni',
            style: TextStyle(
              color: darkColor,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reminderCard() {
    final time =
        '${reminderHour.toString().padLeft(2, '0')}:'
        '${reminderMinute.toString().padLeft(2, '0')}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: softColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: softColor,
                  borderRadius: BorderRadius.circular(15),
                ),
                child: const Icon(
                  Icons.notifications_none_rounded,
                  color: Color(0xFF98766D),
                  size: 26,
                ),
              ),
              const SizedBox(width: 13),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Codzienne przypomnienie',
                      style: TextStyle(
                        color: darkColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Nie zapomnijcie o wspólnym zdjęciu',
                      style: TextStyle(
                        color: Color(0xFF9B8178),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: reminderEnabled,
                activeThumbColor: primaryColor,
                onChanged: _changeReminder,
              ),
            ],
          ),
          if (reminderEnabled) ...[
            const Divider(color: softColor),
            InkWell(
              onTap: _changeReminderTime,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 9,
                  horizontal: 4,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.access_time_rounded,
                      color: Color(0xFF98766D),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Godzina przypomnienia',
                        style: TextStyle(
                          color: darkColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Text(
                      time,
                      style: const TextStyle(
                        color: Color(0xFF98766D),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(width: 5),
                    const Icon(
                      Icons.chevron_right,
                      color: Color(0xFF98766D),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _photoCard(Map<String, dynamic> photo) {
    final path = photo['path'] as String;
    final date = DateTime.parse(photo['createdAt']);
    final sender = photo['senderDevice'];
    final isMe = sender == null || (myDeviceId.isNotEmpty && sender == myDeviceId);

    return GestureDetector(
      onTap: () => _openPhoto(photo),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(
              File(path),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  color: softColor,
                  child: const Icon(Icons.broken_image_outlined),
                );
              },
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  isMe ? 'Ty' : 'Druga połówka',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.55),
                    ],
                  ),
                ),
                child: Text(
                  '${_formatDate(date)} • ${_formatTime(date)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyGallery() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: softColor),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.photo_library_outlined,
            size: 45,
            color: primaryColor,
          ),
          SizedBox(height: 12),
          Text(
            'Tutaj pojawią się Wasze zdjęcia',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: darkColor,
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          ),
          SizedBox(height: 5),
          Text(
            'Dodajcie pierwsze wspólne wspomnienie.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.black54),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: primaryColor),
        ),
      );
    }

    final recentPhotos = photos.take(4).toList();

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 15, 20, 30),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'usly.',
                        style: TextStyle(
                          color: darkColor,
                          fontSize: 34,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.5,
                        ),
                      ),
                      Row(
                        children: [
                          const Text(
                            'Para: ',
                            style: TextStyle(
                              color: Color(0xFF9B8178),
                              fontSize: 13,
                            ),
                          ),
                          InkWell(
                            onTap: _showPairingDialog,
                            child: Text(
                              spaceId,
                              style: const TextStyle(
                                color: darkColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Połączenie pary',
                  onPressed: _showPairingDialog,
                  icon: Container(
                    decoration: const BoxDecoration(
                      color: softColor,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(12),
                    child: const Icon(
                      Icons.favorite_rounded,
                      color: Color(0xFF98766D),
                      size: 25,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 25),
            _relationshipCard(),
            const SizedBox(height: 14),
            _streakCard(),
            const SizedBox(height: 14),
            _reminderCard(),
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionTitle('Ostatnie zdjęcia'),
                TextButton(
                  onPressed: _openHistory,
                  child: const Text(
                    'Zobacz całą historię',
                    style: TextStyle(
                      color: Color(0xFF98766D),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            if (recentPhotos.isEmpty)
              _emptyGallery()
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: recentPhotos.length,
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.92,
                ),
                itemBuilder: (context, index) {
                  return _photoCard(recentPhotos[index]);
                },
              ),
            const SizedBox(height: 25),
            SizedBox(
              height: 55,
              child: FilledButton.icon(
                onPressed: saving ? null : _showPhotoOptions,
                icon: saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.add_a_photo_outlined),
                label: Text(saving ? 'Zapisywanie...' : 'Dodaj zdjęcie'),
                style: FilledButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PhotoHistoryPage extends StatefulWidget {
  final List<Map<String, dynamic>> photos;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  final Future<void> Function(Map<String, dynamic>, BuildContext) onSave;

  const PhotoHistoryPage({
    super.key,
    required this.photos,
    required this.onDelete,
    required this.onSave,
  });

  @override
  State<PhotoHistoryPage> createState() => _PhotoHistoryPageState();
}

class _PhotoHistoryPageState extends State<PhotoHistoryPage> {
  late List<Map<String, dynamic>> photos;

  @override
  void initState() {
    super.initState();
    photos = List<Map<String, dynamic>>.from(widget.photos);
  }

  String _dateKey(DateTime date) {
    return '${date.year}-${date.month}-${date.day}';
  }

  String _dateTitle(DateTime date) {
    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(date);

    if (day == today) return 'Dzisiaj';
    if (day == today.subtract(const Duration(days: 1))) {
      return 'Wczoraj';
    }

    const months = [
      'stycznia',
      'lutego',
      'marca',
      'kwietnia',
      'maja',
      'czerwca',
      'lipca',
      'sierpnia',
      'września',
      'października',
      'listopada',
      'grudnia',
    ];

    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }

  Future<void> _openPhoto(Map<String, dynamic> photo) async {
    final deleted = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PhotoViewerPage(
          photo: photo,
          onDelete: widget.onDelete,
          onSave: widget.onSave,
        ),
      ),
    );

    if (deleted == true && mounted) {
      setState(() {
        photos.removeWhere((item) => item['path'] == photo['path'] || item['id'] == photo['id']);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final sortedPhotos = [...photos];

    sortedPhotos.sort((a, b) {
      return DateTime.parse(b['createdAt'])
          .compareTo(DateTime.parse(a['createdAt']));
    });

    final Map<String, List<Map<String, dynamic>>> groups = {};

    for (final photo in sortedPhotos) {
      final date = DateTime.parse(photo['createdAt']);
      final key = _dateKey(date);

      groups.putIfAbsent(key, () => []);
      groups[key]!.add(photo);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Historia zdjęć',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: sortedPhotos.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.photo_library_outlined,
                      size: 55,
                      color: primaryColor,
                    ),
                    SizedBox(height: 15),
                    Text(
                      'Nie ma jeszcze żadnych zdjęć',
                      style: TextStyle(
                        color: darkColor,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Dodane zdjęcia pojawią się tutaj.',
                      style: TextStyle(color: Colors.black54),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(18),
              children: groups.entries.map((entry) {
                final date = DateTime.parse(
                  entry.value.first['createdAt'],
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        top: 12,
                        bottom: 13,
                      ),
                      child: Text(
                        _dateTitle(date),
                        style: const TextStyle(
                          color: darkColor,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: entry.value.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 11,
                        mainAxisSpacing: 11,
                        childAspectRatio: 0.9,
                      ),
                      itemBuilder: (context, index) {
                        final photo = entry.value[index];

                        return GestureDetector(
                          onTap: () => _openPhoto(photo),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(17),
                            child: Image.file(
                              File(photo['path']),
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return Container(
                                  color: softColor,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                );
              }).toList(),
            ),
    );
  }
}

class PhotoViewerPage extends StatefulWidget {
  final Map<String, dynamic> photo;
  final Future<void> Function(Map<String, dynamic>) onDelete;
  final Future<void> Function(Map<String, dynamic>, BuildContext) onSave;

  const PhotoViewerPage({
    super.key,
    required this.photo,
    required this.onDelete,
    required this.onSave,
  });

  @override
  State<PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<PhotoViewerPage> {
  bool deleting = false;
  bool savingPhoto = false;

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: backgroundColor,
          title: const Text(
            'Usunąć zdjęcie?',
            style: TextStyle(
              color: darkColor,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: const Text(
            'Tego zdjęcia nie będzie już w aplikacji.',
            style: TextStyle(color: darkColor),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },
              child: const Text(
                'Anuluj',
                style: TextStyle(color: darkColor),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, true);
              },
              child: const Text(
                'Usuń',
                style: TextStyle(color: Colors.red),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed != true || !mounted) return;

    setState(() {
      deleting = true;
    });

    try {
      await widget.onDelete(widget.photo);

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          deleting = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nie udało się usunąć zdjęcia.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = DateTime.parse(widget.photo['createdAt']);
    final hour = date.hour.toString().padLeft(2, '0');
    final minute = date.minute.toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${date.day}.${date.month}.${date.year} • $hour:$minute',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: 'Zapisz zdjęcie',
            onPressed: () async {
              setState(() => savingPhoto = true);
              await widget.onSave(widget.photo, context);
              if (mounted) setState(() => savingPhoto = false);
            },
            icon: savingPhoto
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(
                    Icons.download_rounded,
                    color: Colors.white,
                  ),
          ),
          IconButton(
            tooltip: 'Usuń zdjęcie',
            onPressed: deleting ? null : _confirmDelete,
            icon: deleting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.white,
                  ),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.8,
          maxScale: 4,
          child: Image.file(
            File(widget.photo['path']),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return const Icon(
                Icons.broken_image_outlined,
                color: Colors.white,
                size: 60,
              );
            },
          ),
        ),
      ),
    );
  }
}

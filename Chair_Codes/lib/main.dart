import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:developer' as devtools;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    devtools.log("✅ Firebase initialized successfully");
  } catch (e) {
    devtools.log("❌ Firebase initialization failed: $e");
  }
  runApp(const MyApp());
}

// App Colors - Pink & Blue Theme
class AppColors {
  static const Color background = Color(0xFFFFE5F1); // Light pink background
  static const Color surface = Color(0xFFFFF0F8); // Very light pink surface
  static const Color card = Color(0xFFFFFFFF); // White cards
  static const Color primaryBlue = Color(0xFF3B82F6); // Bright blue
  static const Color primaryPink = Color(0xFFEC4899); // Bright pink
  static const Color accentBlue = Color(0xFF60A5FA); // Light blue
  static const Color accentPink = Color(0xFFF472B6); // Light pink
  static const Color neonBlue = Color(0xFF00D4FF); // Neon blue
  static const Color neonPink = Color(0xFFFF1493); // Neon pink
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);
  static const Color textPrimary = Color(0xFF1A1A2E); // Dark text for light background
  static const Color textSecondary = Color(0xFF6B6B7A); // Medium gray for light background
  
  // Legacy names for compatibility (mapped to new colors)
  static const Color neonCyan = primaryBlue;
  static const Color neonPurple = primaryPink;
  static const Color neonGreen = success;
  static const Color neonOrange = warning;
  static const Color neonYellow = Color(0xFFFACC15);
  
  static const List<Color> chartColors = [
    primaryBlue,
    primaryPink,
    accentBlue,
    accentPink,
    neonBlue,
    neonPink,
    Color(0xFF8B5CF6), // Purple
    Color(0xFF06B6D4), // Cyan
    Color(0xFF34D399), // Green
    Color(0xFFF59E0B), // Orange
  ];
}

// Detection History Item Model - now includes ALL class predictions
class DetectionItem {
  final String imagePath;
  final String topLabel;
  final double topConfidence;
  final DateTime timestamp;
  final bool isUnknown;
  final Map<String, double> allPredictions; // All class predictions

  DetectionItem({
    required this.imagePath,
    required this.topLabel,
    required this.topConfidence,
    required this.timestamp,
    required this.allPredictions,
    this.isUnknown = false,
  });

  // Convert to JSON for storage
  Map<String, dynamic> toJson() {
    return {
      'imagePath': imagePath,
      'topLabel': topLabel,
      'topConfidence': topConfidence,
      'timestamp': timestamp.toIso8601String(),
      'isUnknown': isUnknown,
      'allPredictions': allPredictions.map((key, value) => MapEntry(key, value)),
    };
  }

  // Create from JSON
  factory DetectionItem.fromJson(Map<String, dynamic> json) {
    return DetectionItem(
      imagePath: json['imagePath'] as String,
      topLabel: json['topLabel'] as String,
      topConfidence: (json['topConfidence'] as num).toDouble(),
      timestamp: DateTime.parse(json['timestamp'] as String),
      isUnknown: json['isUnknown'] as bool? ?? false,
      allPredictions: Map<String, double>.from(
        (json['allPredictions'] as Map).map((key, value) => 
          MapEntry(key as String, (value as num).toDouble())
        ),
      ),
    );
  }
}

// Global list for history
List<DetectionItem> detectionHistory = [];
List<String> knownClassLabels = [];

// Global callback for history updates
VoidCallback? onHistoryChanged;

// Version counter to force rebuilds
int historyVersion = 0;

// Helper function to format percentage without rounding (for detailed views)
String formatPercentage(double value) {
  // Remove trailing zeros but keep significant digits
  if (value == 0) return '0%';
  // Use toString() to avoid rounding, then format
  String str = value.toString();
  // If it's a whole number, show as integer
  if (str.endsWith('.0')) {
    return '${value.toInt()}%';
  }
  // Otherwise show with appropriate precision (up to 6 decimal places)
  // Remove trailing zeros
  str = value.toStringAsFixed(6).replaceAll(RegExp(r'0*$'), '').replaceAll(RegExp(r'\.$'), '');
  return '$str%';
}

// Helper function to format percentage for scan results (2 decimal places only)
String formatScanPercentage(double value) {
  if (value == 0) return '0%';
  return '${value.toStringAsFixed(2)}%';
}

// Function to delete a scan (local only)
Future<bool> deleteScan(DetectionItem item) async {
  // Remove from local history
  detectionHistory.remove(item);
  
  // Save updated history to storage
  await saveHistoryToStorage();
  
  // Increment version to force rebuilds
  historyVersion++;
  
  // Notify listeners
  onHistoryChanged?.call();
  
  devtools.log("✅ Scan deleted from local history and storage");
  return true;
}

// Function to save history to local storage
Future<void> saveHistoryToStorage() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = detectionHistory.map((item) => item.toJson()).toList();
    await prefs.setString('detection_history', jsonEncode(historyJson));
    devtools.log("✅ History saved to storage: ${detectionHistory.length} scans");
  } catch (e) {
    devtools.log("❌ Error saving history to storage: $e");
  }
}

// Function to load history from local storage
Future<void> loadHistory() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final historyJsonString = prefs.getString('detection_history');
    
    if (historyJsonString != null && historyJsonString.isNotEmpty) {
      final List<dynamic> historyJson = jsonDecode(historyJsonString);
      detectionHistory = historyJson
          .map((json) => DetectionItem.fromJson(json as Map<String, dynamic>))
          .toList();
      
      // Filter out items with missing image files
      detectionHistory = detectionHistory.where((item) {
        final file = File(item.imagePath);
        return file.existsSync();
      }).toList();
      
      // Save back the filtered list
      if (detectionHistory.length != historyJson.length) {
        await saveHistoryToStorage();
      }
      
      devtools.log("✅ History loaded from storage: ${detectionHistory.length} scans");
    } else {
      devtools.log("ℹ️ No saved history found");
      detectionHistory = [];
    }
  } catch (e) {
    devtools.log("❌ Error loading history from storage: $e");
    detectionHistory = [];
  }
  
  // Increment version to force rebuilds
  historyVersion++;
  
  // Notify listeners
  onHistoryChanged?.call();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Chair Detector X',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: AppColors.background,
        textTheme: GoogleFonts.poppinsTextTheme(
          ThemeData.dark().textTheme,
        ),
        colorScheme: const ColorScheme.dark(
          primary: AppColors.primaryBlue,
          secondary: AppColors.primaryPink,
          surface: AppColors.surface,
        ),
      ),
      home: const MainScreen(),
    );
  }
}

// Animated Particle Background
class ParticleBackground extends StatefulWidget {
  final Widget child;
  const ParticleBackground({super.key, required this.child});

  @override
  State<ParticleBackground> createState() => _ParticleBackgroundState();
}

class _ParticleBackgroundState extends State<ParticleBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<Particle> particles = [];
  final int particleCount = 50;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    
    for (int i = 0; i < particleCount; i++) {
      particles.add(Particle());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return CustomPaint(
              painter: ParticlePainter(particles, _controller.value),
              size: Size.infinite,
            );
          },
        ),
        widget.child,
      ],
    );
  }
}

class Particle {
  double x = math.Random().nextDouble();
  double y = math.Random().nextDouble();
  double speed = math.Random().nextDouble() * 0.02 + 0.005;
  double size = math.Random().nextDouble() * 3 + 1;
  Color color = [
    AppColors.primaryBlue.withOpacity(0.3),
    AppColors.primaryPink.withOpacity(0.3),
    AppColors.accentPink.withOpacity(0.2),
  ][math.Random().nextInt(3)];
}

class ParticlePainter extends CustomPainter {
  final List<Particle> particles;
  final double animationValue;

  ParticlePainter(this.particles, this.animationValue);

  @override
  void paint(Canvas canvas, Size size) {
    for (var particle in particles) {
      final paint = Paint()
        ..color = particle.color
        ..style = PaintingStyle.fill;
      
      double newY = (particle.y + animationValue * particle.speed * 50) % 1.0;
      
      canvas.drawCircle(
        Offset(particle.x * size.width, newY * size.height),
        particle.size,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

// Glassmorphism Container
class GlassContainer extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final BorderRadius? borderRadius;
  final Color? borderColor;
  final double? blur;

  const GlassContainer({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.borderColor,
    this.blur,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur ?? 10, sigmaY: blur ?? 10),
        child: Container(
          padding: padding ?? const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.1),
                Colors.white.withOpacity(0.05),
              ],
            ),
            borderRadius: borderRadius ?? BorderRadius.circular(20),
            border: Border.all(
              color: borderColor ?? AppColors.primaryBlue.withOpacity(0.2),
              width: 1.5,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// Neon Glow Box
class NeonGlowBox extends StatelessWidget {
  final Widget child;
  final Color glowColor;
  final double intensity;
  final BorderRadius? borderRadius;

  const NeonGlowBox({
    super.key,
    required this.child,
    this.glowColor = AppColors.primaryBlue,
    this.intensity = 0.5,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius ?? BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: glowColor.withOpacity(intensity * 0.6),
            blurRadius: 20,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: glowColor.withOpacity(intensity * 0.3),
            blurRadius: 40,
            spreadRadius: 5,
          ),
        ],
      ),
      child: child,
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with TickerProviderStateMixin {
  int _currentIndex = 0;
  bool _isLoadingHistory = true;

  @override
  void initState() {
    super.initState();
    // Set global callback
    onHistoryChanged = _onHistoryChanged;
    _loadHistory();
  }

  @override
  void dispose() {
    // Clear global callback
    onHistoryChanged = null;
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _isLoadingHistory = true;
    });
    await loadHistory();
    setState(() {
      _isLoadingHistory = false;
    });
  }

  void _onHistoryUpdate() {
    setState(() {});
  }

  void _onHistoryChanged() {
    // Force rebuild of all screens when history changes
    if (mounted) {
      setState(() {
        // Force rebuild by incrementing a dummy state
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild screens list every time to ensure fresh widgets
    // Note: MyHomePage doesn't use historyVersion key to preserve its state during scans
    final List<Widget> screens = [
      HomePage(onNavigateToScan: () {
        setState(() {
          _currentIndex = 1; // Navigate to Scan page
        });
      }),
      MyHomePage(key: const ValueKey('home'), onHistoryUpdate: _onHistoryUpdate),
      AnalyticsPage(key: ValueKey('analytics_$historyVersion')),
      LogsPage(key: ValueKey('logs_$historyVersion')),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: screens[_currentIndex],
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withOpacity(0.95),
        border: Border(
          top: BorderSide(
            color: AppColors.primaryBlue.withOpacity(0.3),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryBlue.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildNavItem(0, Icons.home_rounded, 'Home', isCenter: false),
              _buildNavItem(1, Icons.chair_rounded, 'Scan', isCenter: false),
              _buildNavItem(2, Icons.insights_rounded, 'Analytics', isCenter: false),
              _buildNavItem(3, Icons.history_rounded, 'Logs', isCenter: false),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem(int index, IconData icon, String label, {bool isCenter = false}) {
    final isSelected = _currentIndex == index;
    final iconSize = 22.0;
    
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _currentIndex = index;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          decoration: BoxDecoration(
            gradient: isSelected
                ? LinearGradient(
                    colors: [
                      AppColors.primaryBlue.withOpacity(0.2),
                      AppColors.primaryPink.withOpacity(0.2),
                    ],
                  )
                : null,
            borderRadius: BorderRadius.circular(12),
            border: isSelected
                ? Border.all(
                    color: AppColors.primaryBlue.withOpacity(0.5),
                    width: 1,
                  )
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                color: isSelected ? AppColors.primaryBlue : AppColors.textSecondary,
                size: iconSize,
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 9,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: isSelected ? AppColors.primaryBlue : AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== HOME PAGE (LANDING) ====================
class HomePage extends StatefulWidget {
  final VoidCallback onNavigateToScan;

  const HomePage({super.key, required this.onNavigateToScan});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late PageController _pageController;
  late AnimationController _iconAnimationController;
  late Animation<double> _iconAnimation;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: 500); // Start in the middle for infinite scroll
    _iconAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _iconAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _iconAnimationController, curve: Curves.easeInOut),
    );
    
    // Ensure labels are loaded for the gallery
    if (knownClassLabels.isEmpty) {
      _loadLabels();
    }
  }

  Future<void> _loadLabels() async {
    try {
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      final labels = labelsData
          .split('\n')
          .map((label) => label.replaceAll(RegExp(r'^\d+\s*'), '').trim())
          .where((label) => label.isNotEmpty)
          .toList();
      
      if (mounted) {
        setState(() {
          knownClassLabels = List<String>.from(labels);
        });
      }
    } catch (e) {
      devtools.log("Error loading labels in home: $e");
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _iconAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Static Header
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.primaryBlue.withOpacity(0.5),
                    width: 1,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.primaryBlue, AppColors.primaryPink],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryBlue.withOpacity(0.5),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.chair_rounded, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'CHAIR DETECTOR',
                      style: GoogleFonts.poppins(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        color: Colors.black,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Scrollable Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
              
              // Circular Tap to Scan Button with Gradient Border
              Center(
                child: GestureDetector(
                  onTap: widget.onNavigateToScan,
                  child: Container(
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          AppColors.primaryBlue,
                          AppColors.primaryPink,
                          AppColors.accentPink,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.background,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: _iconAnimation,
                            builder: (context, child) {
                              return Transform.scale(
                                scale: 1.0 + (_iconAnimation.value * 0.15),
                                child: Transform.rotate(
                                  angle: _iconAnimation.value * 0.2,
                                  child: Icon(
                                    Icons.chair_rounded,
                                    color: Color.lerp(
                                      AppColors.primaryBlue,
                                      AppColors.primaryPink,
                                      _iconAnimation.value,
                                    ),
                                    size: 72,
                                  ),
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'TAP TO SCAN',
                            style: GoogleFonts.poppins(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textPrimary,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // App Description - Below the border
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Advanced AI-powered chair detection system. Identify and classify different types of chairs with precision.',
                  style: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.textSecondary,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 30),
              
                    // Chair Gallery Section
                    _buildSectionTitle('Chair Gallery'),
                    const SizedBox(height: 16),
                    _buildChairGallery(),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 24,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.primaryBlue, AppColors.primaryPink],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  String _getChairImagePath(int index) {
    // Map index to chair image asset path (chair0.jpg through chair9.jpg)
    return 'assets/chairs/chair$index.jpg';
  }

  Widget _buildChairGallery() {
    // Use actual class names from labels.txt (knownClassLabels)
    // If labels aren't loaded yet, show empty or loading state
    if (knownClassLabels.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Loading chair classes...',
            style: GoogleFonts.poppins(
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      );
    }

    // Create chair types list from knownClassLabels
    final List<Color> colorPalette = [
      AppColors.primaryBlue,
      AppColors.primaryPink,
      AppColors.accentBlue,
      AppColors.accentPink,
      AppColors.primaryBlue,
      AppColors.primaryPink,
      AppColors.accentBlue,
      AppColors.accentPink,
      AppColors.primaryBlue,
      AppColors.primaryPink,
    ];

    final chairTypes = knownClassLabels.asMap().entries.map((entry) {
      final index = entry.key;
      final name = entry.value;
      return {
        'name': name,
        'color': colorPalette[index % colorPalette.length],
        'index': index,
      };
    }).toList();

    // Preload images
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (var chair in chairTypes) {
        final chairIndex = chair['index'] as int;
        precacheImage(AssetImage(_getChairImagePath(chairIndex)), context);
      }
    });

    return SizedBox(
      height: 200,
      child: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.horizontal,
        itemCount: chairTypes.length * 1000, // Large number for infinite scroll
        itemBuilder: (context, index) {
          final actualIndex = index % chairTypes.length;
          final chair = chairTypes[actualIndex];
          final chairIndex = chair['index'] as int;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: AspectRatio(
              aspectRatio: 1.0, // Square shape
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: (chair['color'] as Color).withOpacity(0.3),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (chair['color'] as Color).withOpacity(0.15),
                      blurRadius: 15,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Container(
                        width: double.infinity,
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: (chair['color'] as Color).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (chair['color'] as Color).withOpacity(0.2),
                            width: 1,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(11),
                          child: Image.asset(
                            _getChairImagePath(chairIndex),
                            fit: BoxFit.contain, // Changed from cover to contain to prevent cropping
                            cacheWidth: 200,
                            cacheHeight: 200,
                            errorBuilder: (context, error, stackTrace) {
                              // Fallback to gradient with icon if image not found
                              return Container(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      (chair['color'] as Color).withOpacity(0.2),
                                      (chair['color'] as Color).withOpacity(0.05),
                                    ],
                                  ),
                                ),
                                child: Icon(
                                  Icons.chair_rounded,
                                  color: chair['color'] as Color,
                                  size: 48,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      flex: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        child: Text(
                          chair['name'] as String,
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
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

// ==================== SCAN PAGE ====================
class MyHomePage extends StatefulWidget {
  final VoidCallback onHistoryUpdate;

  const MyHomePage({super.key, required this.onHistoryUpdate});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with TickerProviderStateMixin {
  File? filePath;
  String label = '';
  double confidence = 0.0;
  bool isLoading = false;
  bool isUnknown = false;
  Map<String, double> allPredictions = {};
  late AnimationController _pulseController;
  late AnimationController _rotationController;
  late Animation<double> _pulseAnimation;
  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isProcessing = false; // Prevent concurrent processing
  bool _showActionButtons = false; // Control floating buttons visibility

  @override
  void initState() {
    super.initState();
    _tfLteInit();
    
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _rotationController.dispose();
    _interpreter?.close();
    super.dispose();
  }

  Future<void> _tfLteInit() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model_unquant.tflite');
      devtools.log("Model loaded successfully");
      
      final labelsData = await rootBundle.loadString('assets/labels.txt');
      _labels = labelsData
          .split('\n')
          .map((label) => label.replaceAll(RegExp(r'^\d+\s*'), '').trim())
          .where((label) => label.isNotEmpty)
          .toList();
      knownClassLabels = List<String>.from(_labels);
      devtools.log("Labels loaded: $_labels");
    } catch (e) {
      devtools.log("Error loading model or labels: $e");
    }
  }

  Float32List _preprocessImage(img.Image image, int inputSize) {
    final resizedImage = img.copyResize(image, width: inputSize, height: inputSize);
    final inputBuffer = Float32List(1 * inputSize * inputSize * 3);
    int pixelIndex = 0;
    
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resizedImage.getPixel(x, y);
        inputBuffer[pixelIndex++] = pixel.r / 255.0;
        inputBuffer[pixelIndex++] = pixel.g / 255.0;
        inputBuffer[pixelIndex++] = pixel.b / 255.0;
      }
    }
    
    return inputBuffer;
  }


  Future<void> _addToHistory(String imagePath, String detectedLabel, double conf, bool unknown, Map<String, double> predictions) async {
    final timestamp = DateTime.now();
    
    // Save to local history
    detectionHistory.insert(
      0,
      DetectionItem(
        imagePath: imagePath,
        topLabel: detectedLabel,
        topConfidence: conf,
        timestamp: timestamp,
        isUnknown: unknown,
        allPredictions: predictions,
      ),
    );
    
    devtools.log("Scan saved to local history");
    
    // Save to local storage (persistent)
    await saveHistoryToStorage();
    
    // Save to Firebase Firestore
    try {
      // Check if Firebase is initialized
      final firebaseApps = Firebase.apps;
      if (firebaseApps.isEmpty) {
        devtools.log("⚠️ Firebase not initialized! Attempting to initialize...");
        await Firebase.initializeApp();
      }
      
      final firestore = FirebaseFirestore.instance;
      
      // Structure: Ytac_Chairs (direct collection) -> scan documents
      // Path: Ytac_Chairs/[scan_document]
      // Direct collection - only 2 levels: Ytac_Chairs → scan documents
      final logsCollectionRef = firestore.collection('Ytac_Chairs');
      
      // Save accuracy with exactly 2 decimal places (matches app display)
      // Round to 2 decimal places to match formatScanPercentage() output
      final accuracyRate = double.parse(conf.toStringAsFixed(2));
      
      // Use detectedLabel as Class_type
      final classType = detectedLabel;
      
      devtools.log("🔄 Saving to Firebase...");
      devtools.log("   Path: Ytac_Chairs → [scan_document]");
      devtools.log("   Class: $classType");
      devtools.log("   Accuracy: $accuracyRate%");
      
      // Add new document to Ytac_Chairs collection
      // Use reverse timestamp as document ID so newest scans appear first
      // Reverse timestamp = max timestamp - current timestamp (ensures descending order)
      final reverseTimestamp = DateTime.now().millisecondsSinceEpoch;
      final documentId = '${9999999999999 - reverseTimestamp}_${DateTime.now().millisecondsSinceEpoch}';
      
      // Save document with custom ID for proper ordering (newest first)
      final docRef = logsCollectionRef.doc(documentId);
      await docRef.set({
        'Accuracy_rate': accuracyRate,
        'Class_type': classType,
        'Time': Timestamp.fromDate(timestamp),
        'timestamp': timestamp.millisecondsSinceEpoch, // Additional field for sorting
      });
      
      devtools.log("✅ SUCCESS! Scan saved to Firebase!");
      devtools.log("   Document ID: ${docRef.id}");
      devtools.log("   Class: $classType");
      devtools.log("   Accuracy: $accuracyRate%");
      devtools.log("   Time: $timestamp");
      
      // Show success message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Saved to Firebase: $classType'),
            duration: const Duration(seconds: 2),
            backgroundColor: AppColors.success,
          ),
        );
      }
    } catch (e, stackTrace) {
      devtools.log("❌ ERROR saving to Firebase!");
      devtools.log("   Error: $e");
      devtools.log("   Stack trace: $stackTrace");
      
      // Show error message to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Firebase error: ${e.toString()}'),
            duration: const Duration(seconds: 4),
            backgroundColor: AppColors.warning,
          ),
        );
      }
      
      // Common error messages
      if (e.toString().contains('PERMISSION_DENIED')) {
        devtools.log("⚠️ PERMISSION DENIED - Check Firestore Security Rules!");
        devtools.log("   Go to Firebase Console → Firestore → Rules");
        devtools.log("   Make sure writes are allowed");
      } else if (e.toString().contains('UNAVAILABLE')) {
        devtools.log("⚠️ Firebase UNAVAILABLE - Check internet connection");
      }
      
      // Continue even if Firebase save fails - local history is more important
    }
    
    // Increment version to force rebuilds
    historyVersion++;
    
    // Notify listeners
    widget.onHistoryUpdate();
    onHistoryChanged?.call();
  }

  Future<void> _processImage(ImageSource source) async {
    // Prevent concurrent processing
    if (_isProcessing) {
      devtools.log("Image processing already in progress, ignoring request");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Processing in progress, please wait...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    
    try {
      _isProcessing = true;
      
      devtools.log("Starting image picker from ${source == ImageSource.camera ? 'camera' : 'gallery'}");
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: source,
        imageQuality: 85, // Optimize image quality
        maxWidth: 1920, // Limit image size
        maxHeight: 1920,
      );

      if (image == null) {
        devtools.log("Image picker returned null - user may have cancelled or permission denied");
        _isProcessing = false;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'No image selected',
                style: GoogleFonts.poppins(
                  color: Colors.red,
                ),
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      devtools.log("Image picked: ${image.path}");
      var imageMap = File(image.path);
      
      // Validate image file exists and is readable
      if (!await imageMap.exists()) {
        devtools.log("Image file does not exist: ${image.path}");
        setState(() {
          isLoading = false;
          label = 'FILE NOT FOUND';
          isUnknown = true;
          filePath = null;
        });
        _isProcessing = false;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Image file not found'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      // Display image immediately before processing
      devtools.log("Setting filePath and starting processing");
      if (mounted) {
      setState(() {
        filePath = imageMap;
        isLoading = true;
        label = '';
        confidence = 0.0;
        isUnknown = false;
        allPredictions = {};
        _showActionButtons = false; // Hide buttons when processing starts
      });
      }

      if (_interpreter == null) {
        devtools.log("Interpreter not initialized");
        setState(() {
          isLoading = false;
          label = 'MODEL NOT LOADED';
          isUnknown = true;
          confidence = 0.0;
        });
        await _addToHistory(image.path, 'Error - Model not loaded', 0.0, true, {});
        return;
      }

      final imageBytes = await image.readAsBytes();
      
      // Validate image size (prevent memory issues with very large images)
      const maxImageSize = 10 * 1024 * 1024; // 10MB
      if (imageBytes.length > maxImageSize) {
        devtools.log("Image too large: ${imageBytes.length} bytes");
        setState(() {
          isLoading = false;
          label = 'IMAGE TOO LARGE';
          isUnknown = true;
          confidence = 0.0;
        });
        _isProcessing = false;
        return;
      }
      
      final decodedImage = img.decodeImage(imageBytes);
      
      if (decodedImage == null) {
        devtools.log("Failed to decode image");
        setState(() {
          isLoading = false;
          label = 'INVALID IMAGE';
          isUnknown = true;
          confidence = 0.0;
        });
        _isProcessing = false;
        return;
      }
      
      // Validate decoded image dimensions
      if (decodedImage.width <= 0 || decodedImage.height <= 0) {
        devtools.log("Invalid image dimensions: ${decodedImage.width}x${decodedImage.height}");
        setState(() {
          isLoading = false;
          label = 'INVALID IMAGE';
          isUnknown = true;
          confidence = 0.0;
        });
        _isProcessing = false;
        return;
      }

      final inputShape = _interpreter!.getInputTensor(0).shape;
      final inputSize = inputShape[1];
      
      final inputBuffer = _preprocessImage(decodedImage, inputSize);
      final input = inputBuffer.reshape([1, inputSize, inputSize, 3]);
      
      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final outputSize = outputShape[1];
      final output = List.filled(1 * outputSize, 0.0).reshape([1, outputSize]);
      
      _interpreter!.run(input, output);
      
      final results = output[0] as List<double>;
      
      // Validate results
      if (results.isEmpty) {
        throw Exception("Model returned empty results");
      }
      
      // Store ALL predictions
      Map<String, double> predictions = {};
      int maxIndex = 0;
      double maxConfidence = results[0];
      
      for (int i = 0; i < results.length; i++) {
        String labelName = i < _labels.length ? _labels[i] : 'Class $i';
        predictions[labelName] = results[i] * 100;
        
        if (results[i] > maxConfidence) {
          maxConfidence = results[i];
          maxIndex = i;
        }
      }
      
      // Sort predictions by confidence (descending)
      var sortedPredictions = Map.fromEntries(
        predictions.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value))
      );
      
      // Normalize predictions to ensure total is exactly 100%
      final total = sortedPredictions.values.fold<double>(0, (sum, value) => sum + value);
      if (total > 0) {
        final scale = 100.0 / total;
        sortedPredictions = Map<String, double>.fromEntries(
          sortedPredictions.entries.map(
            (entry) => MapEntry(entry.key, entry.value * scale),
          ),
        );
      }
      
      devtools.log("All predictions: $sortedPredictions");

      double detectedConfidence = maxConfidence * 100;
      String detectedLabel = maxIndex < _labels.length 
          ? _labels[maxIndex].replaceAll(RegExp(r'^\d+\s*'), '').trim()
          : 'Class $maxIndex';
      
      if (detectedConfidence < 30) {
        if (mounted) {
          setState(() {
            confidence = detectedConfidence;
            label = 'LOW CONFIDENCE';
            isUnknown = true;
            isLoading = false;
            allPredictions = sortedPredictions;
          });
        }
        await _addToHistory(image.path, 'Unknown - Low Confidence', detectedConfidence, true, sortedPredictions);
        // Force UI update after history is saved
        if (mounted) {
          setState(() {});
        }
      } else {
        if (mounted) {
          setState(() {
            confidence = detectedConfidence;
            label = detectedLabel.toUpperCase();
            isUnknown = false;
            isLoading = false;
            allPredictions = sortedPredictions;
          });
        }
        await _addToHistory(image.path, detectedLabel, detectedConfidence, false, sortedPredictions);
        // Force UI update after history is saved
        if (mounted) {
          setState(() {});
        }
      }
    } catch (e, stackTrace) {
      devtools.log("Error processing image: $e");
      devtools.log("Stack trace: $stackTrace");
      setState(() {
        isLoading = false;
        label = 'ERROR PROCESSING';
        isUnknown = true;
        confidence = 0.0;
        allPredictions = {};
        // Keep filePath so image is still visible even if processing failed
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing image: ${e.toString()}'),
            duration: const Duration(seconds: 3),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    } finally {
      _isProcessing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Compact Header
            _buildCompactHeader(),
            
            // Main Content - Centered
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Centered Scanner Area
                      _buildCenteredScannerArea(),
                      
                      // Floating Action Buttons (only show when ready to scan is tapped)
                      if (_showActionButtons) ...[
                        const SizedBox(height: 30),
                        _buildActionButtons(),
                      ],
                      
                      // Prediction Chart (shows after scan)
                      if (allPredictions.isNotEmpty && !isLoading) ...[
                        const SizedBox(height: 30),
                        _buildPredictionChart(),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactHeader() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(
          bottom: BorderSide(
            color: AppColors.primaryBlue.withOpacity(0.5),
            width: 1,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primaryBlue, AppColors.primaryPink],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primaryBlue.withOpacity(0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: const Icon(Icons.chair_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Text(
              'CHAIR DETECTOR',
              style: GoogleFonts.poppins(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: Colors.black,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenteredScannerArea() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Image Display Card
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 400),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryPink.withOpacity(0.2),
                blurRadius: 30,
                spreadRadius: 5,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: AspectRatio(
              aspectRatio: 1.0,
              child: filePath == null
                  ? _buildCenteredPlaceholder()
                  : _buildImageWithOverlay(),
            ),
          ),
        ),
        
        // Quick Results (below image)
        if (label.isNotEmpty && !isLoading) ...[
          const SizedBox(height: 20),
          _buildQuickResult(),
        ],
      ],
    );
  }

  Widget _buildCenteredPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primaryPink.withOpacity(0.1),
            AppColors.primaryBlue.withOpacity(0.1),
          ],
        ),
      ),
      child: Center(
        child: GestureDetector(
          onTap: () {
            setState(() {
              _showActionButtons = !_showActionButtons;
            });
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Animated Icon Container
              AnimatedBuilder(
                animation: _pulseAnimation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _pulseAnimation.value,
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [AppColors.primaryBlue, AppColors.primaryPink],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryPink.withOpacity(0.4),
                            blurRadius: 20,
                            spreadRadius: 5,
                          ),
                        ],
                      ),
                      child: Icon(
                        _showActionButtons ? Icons.close_rounded : Icons.chair_rounded,
                        size: 50,
                        color: Colors.white,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 24),
              Text(
                'READY TO SCAN',
                style: GoogleFonts.poppins(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Tap the icon to select image source',
                style: GoogleFonts.poppins(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.textPrimary,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageWithOverlay() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.file(
          filePath!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            devtools.log("Error loading image file: $error");
            return Container(
              color: AppColors.background,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.broken_image_rounded,
                      color: AppColors.danger,
                      size: 48,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Failed to load image',
                      style: GoogleFonts.poppins(
                        color: AppColors.danger,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        if (isLoading) _buildLoadingOverlay(),
        if (isLoading)
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Positioned(
                top: _pulseController.value * 230,
                left: 0,
                right: 0,
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.transparent,
                        AppColors.primaryBlue.withOpacity(0.8),
                        Colors.transparent,
                      ],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryBlue.withOpacity(0.8),
                        blurRadius: 10,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildLoadingOverlay() {
    return Container(
      color: AppColors.background.withOpacity(0.85),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 60,
              height: 60,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryBlue),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'ANALYZING...',
              style: GoogleFonts.poppins(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: AppColors.primaryBlue,
                letterSpacing: 2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickResult() {
    final color = isUnknown ? AppColors.danger : AppColors.primaryBlue;
    
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3), width: 2),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.2),
            blurRadius: 20,
            spreadRadius: 2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              isUnknown ? Icons.warning_rounded : Icons.check_circle_rounded,
              color: color,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Confidence: ${formatScanPercentage(confidence)}',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper function to get predictions excluding 0.00%
  Map<String, double> _getFilteredPredictions() {
    if (allPredictions.isEmpty) return {};
    
    // Filter out classes that would display as "0.00%"
    // Threshold set to 0.005 (0.005%) which rounds up to "0.01%"
    return Map<String, double>.fromEntries(
      allPredictions.entries.where((entry) => entry.value >= 0.005)
    );
  }

  // NEW: Prediction Chart showing ALL classes
  Widget _buildPredictionChart() {
    final filteredPredictions = _getFilteredPredictions();
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topEntry = entries.isNotEmpty ? entries.first : null;
    
    // Calculate other share as the residual from 100%
    // This ensures that even if small items are filtered out, the math adds up
    final otherShareValue = topEntry != null ? (100.0 - topEntry.value).clamp(0.0, 100.0) : 0.0;
    final otherShare = formatScanPercentage(otherShareValue);
    
    // Determine if we should show the "Other Share" value
    // Show it if it's significant (> 0.01%), even if no other individual class passed the filter
    final showOtherShare = otherShareValue >= 0.01;

    return Column(
      children: [
        // Scan Again Button
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxWidth: 400),
          margin: const EdgeInsets.only(bottom: 20),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _showImageSourceDialog(),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      AppColors.primaryBlue,
                      AppColors.primaryPink,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primaryBlue.withOpacity(0.3),
                      blurRadius: 15,
                      spreadRadius: 2,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.refresh_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Scan Again',
                      style: GoogleFonts.poppins(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // Prediction Breakdown Container
        Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 400),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.primaryPink.withOpacity(0.3), width: 2),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryPink.withOpacity(0.2),
            blurRadius: 30,
            spreadRadius: 5,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primaryPink, AppColors.accentPink],
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.analytics_rounded, size: 20, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Text(
                'Prediction Breakdown',
                style: GoogleFonts.poppins(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          
          if (topEntry != null) ...[
            Row(
              children: [
                Expanded(
                  child: _buildMetricChip(
                    icon: Icons.percent,
                    label: 'CONFIDENCE',
                    value: formatScanPercentage(topEntry.value),
                    color: AppColors.primaryPink,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMetricChip(
                    icon: Icons.stacked_bar_chart_rounded,
                    label: 'OTHER SHARE',
                    value: showOtherShare ? otherShare : '—',
                    color: AppColors.neonPink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          
          const SizedBox(height: 18),
          
          // Horizontal Bar Chart for all predictions
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.background.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: AppColors.primaryPink.withOpacity(0.2),
              ),
            ),
            child: _buildHorizontalBarChart(),
          ),
          
          const SizedBox(height: 20),
        ],
      ),
        ),
      ],
    );
  }

  void _showImageSourceDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select Image Source',
                  style: GoogleFonts.poppins(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildDialogOption(
                      icon: Icons.camera_alt_rounded,
                      label: 'Camera',
                      color: AppColors.primaryBlue,
                      onTap: () {
                        Navigator.pop(context);
                        _processImage(ImageSource.camera);
                      },
                    ),
                    _buildDialogOption(
                      icon: Icons.photo_library_rounded,
                      label: 'Gallery',
                      color: AppColors.primaryPink,
                      onTap: () {
                        Navigator.pop(context);
                        _processImage(ImageSource.gallery);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.poppins(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDialogOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: color.withOpacity(0.3),
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 8),
              Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHorizontalBarChart() {
    final filteredPredictions = _getFilteredPredictions();
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Column(
      children: entries.asMap().entries.map((entry) {
        final label = entry.value.key;
        final value = entry.value.value.clamp(0, 100).toDouble();
        final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
        return _buildPredictionBarRow(label, value, color);
      }).toList(),
    );
  }

  Widget _buildPredictionBarRow(String label, double value, Color color) {
    String labelText = label;
    if (labelText.length > 20) {
      labelText = '${labelText.substring(0, 18)}…';
    }
    // Show even very small percentages - minimum 1% width for visibility, but use actual value
    final widthFactor = value <= 0 ? 0.01 : (value / 100).clamp(0.01, 1.0).toDouble();
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  labelText.toUpperCase(),
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    letterSpacing: 0.5,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                formatScanPercentage(value),
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppColors.card.withOpacity(0.5),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: widthFactor,
                  child: Container(
                    height: 12,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          color,
                          color.withOpacity(0.5),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    final filteredPredictions = _getFilteredPredictions();
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: entries.asMap().entries.map((entry) {
        final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
        String labelText = entry.value.key;
        if (labelText.length > 10) {
          labelText = '${labelText.substring(0, 8)}..';
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [
                    BoxShadow(color: color.withOpacity(0.5), blurRadius: 4),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  labelText,
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                formatScanPercentage(entry.value.value),
                style: GoogleFonts.poppins(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildFloatingActionButton(
          onPressed: () {
            setState(() {
              _showActionButtons = false;
            });
            _processImage(ImageSource.camera);
          },
          icon: Icons.camera_alt_rounded,
          label: 'CAMERA',
          color: AppColors.primaryBlue,
        ),
        const SizedBox(width: 20),
        _buildFloatingActionButton(
          onPressed: () {
            setState(() {
              _showActionButtons = false;
            });
            _processImage(ImageSource.gallery);
          },
          icon: Icons.photo_library_rounded,
          label: 'GALLERY',
          color: AppColors.primaryPink,
        ),
      ],
    );
  }
  
  Widget _buildFloatingActionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [color, color.withOpacity(0.8)],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.4),
                blurRadius: 20,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 24),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return NeonGlowBox(
      glowColor: color,
      intensity: 0.3,
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [color.withOpacity(0.3), color.withOpacity(0.1)],
              ),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: color.withOpacity(0.5)),
            ),
            child: Column(
              children: [
                Icon(icon, color: color, size: 28),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildAmbientGlows() {
    return [
      Positioned(
        top: -60,
        right: -30,
        child: _buildGlowCircle(AppColors.primaryPink, size: 220),
      ),
      Positioned(
        bottom: 90,
        left: -40,
        child: _buildGlowCircle(AppColors.primaryBlue, size: 260),
      ),
    ];
  }

  Widget _buildGlowCircle(Color color, {double size = 200}) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withOpacity(0.35),
              color.withOpacity(0.0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionDivider() {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            AppColors.primaryBlue.withOpacity(0.35),
            AppColors.primaryPink.withOpacity(0.35),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _buildMetricChip({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.1),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.poppins(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: GoogleFonts.poppins(
              fontSize: 9,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ==================== ANALYTICS PAGE ====================
class AnalyticsPage extends StatefulWidget {
  const AnalyticsPage({super.key});

  @override
  State<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends State<AnalyticsPage> with WidgetsBindingObserver {
  int _lastHistoryVersion = 0;
  int? _floatingCardIndex; // Track which card is floating
  String? _floatingCardTitle;
  String? _floatingCardValue;
  IconData? _floatingCardIcon;
  Color? _floatingCardColor;
  int? _expandedCardIndex; // Track which card is expanded

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastHistoryVersion = historyVersion;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndUpdate();
    }
  }

  void _checkAndUpdate() {
    if (_lastHistoryVersion != historyVersion) {
      _lastHistoryVersion = historyVersion;
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check for updates when page becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndUpdate();
    });
  }

  Map<String, int> _getLabelCounts() {
    Map<String, int> counts = {};
    for (var item in detectionHistory) {
      String key = item.isUnknown ? 'Unknown' : item.topLabel;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> _getTrendDataset(Map<String, int> counts) {
    if (knownClassLabels.isEmpty) return counts;

    final Map<String, int> trend = {
      for (final label in knownClassLabels) label: counts[label] ?? 0,
    };

    if (counts.containsKey('Unknown')) {
      trend['Unknown'] = counts['Unknown']!;
    }

    return trend;
  }

  List<Map<String, dynamic>> _getDailyStats() {
    final now = DateTime.now();
    final Map<String, int> dailyCounts = {};
    
    // Initialize last 7 days with proper date matching (including year for accuracy)
    final List<DateTime> last7Days = [];
    for (int i = 6; i >= 0; i--) {
      final date = DateTime(now.year, now.month, now.day).subtract(Duration(days: i));
      last7Days.add(date);
      final key = '${date.year}-${date.month}-${date.day}';
      dailyCounts[key] = 0;
    }
    
    // Count scans for each day in the last 7 days (accurate date matching)
    for (var item in detectionHistory) {
      final itemDate = DateTime(item.timestamp.year, item.timestamp.month, item.timestamp.day);
      final key = '${itemDate.year}-${itemDate.month}-${itemDate.day}';
      
      if (dailyCounts.containsKey(key)) {
        dailyCounts[key] = dailyCounts[key]! + 1;
      }
    }
    
    // Convert to display format with day/month (preserving order)
    return last7Days.map((date) {
      final key = '${date.year}-${date.month}-${date.day}';
      return {
        'date': '${date.day}/${date.month}',
        'count': dailyCounts[key] ?? 0,
      };
    }).toList();
  }

  double _getAverageConfidence() {
    if (detectionHistory.isEmpty) return 0;
    double total = detectionHistory
        .where((e) => !e.isUnknown)
        .fold(0.0, (sum, item) => sum + item.topConfidence);
    int count = detectionHistory.where((e) => !e.isUnknown).length;
    return count > 0 ? total / count : 0;
  }

  Map<String, double> _getClassConfidenceAverages() {
    // Show the latest confidence for each class from when it was the TOP class in a scan
    // Each class only updates when it's scanned again as the top class
    // Scanning a different class doesn't change other classes' percentages
    Map<String, double> latestConfidences = {};
    
    // Iterate through history from oldest to newest
    // For each scan, update the confidence of the TOP class
    // This way, if the same class is scanned again, it updates to the newer value
    for (var item in detectionHistory) {
      if (item.isUnknown) continue;
      
      // Get the top class (highest confidence) from this scan
      final topClass = item.topLabel;
      final topConfidence = item.topConfidence;
      
      // Always update the top class's confidence
      // Since we're going oldest to newest, the last occurrence = most recent
      latestConfidences[topClass] = topConfidence;
    }
    
    return latestConfidences;
  }

  @override
  Widget build(BuildContext context) {
    final labelCounts = _getLabelCounts();
    final trendDataset = _getTrendDataset(labelCounts);
    final dailyStats = _getDailyStats();
    final avgConfidence = _getAverageConfidence();
    final successRate = detectionHistory.isEmpty
        ? 0.0
        : (detectionHistory.where((e) => !e.isUnknown).length /
                detectionHistory.length) *
            100;
    final scannedClassCount = labelCounts.entries
        .where((e) => e.value > 0 && e.key != 'Unknown')
        .length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Static Header
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.primaryBlue.withOpacity(0.5),
                    width: 1,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [AppColors.primaryBlue, AppColors.primaryPink],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.primaryBlue.withOpacity(0.5),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.analytics, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'ANALYTICS',
                      style: GoogleFonts.poppins(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Scrollable Content
            Expanded(
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                // Stats Cards - 4 inline columns (square floating)
                Row(
                  children: [
                    Expanded(child: _buildStatCard(0, 'Total Scans', '${detectionHistory.length}', Icons.chair_rounded, AppColors.primaryBlue)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildStatCard(1, 'Success', '${successRate.toStringAsFixed(0)}%', Icons.check_circle, AppColors.neonGreen)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildStatCard(2, 'Avg Conf', '${avgConfidence.toStringAsFixed(0)}%', Icons.speed, AppColors.primaryPink)),
                    const SizedBox(width: 8),
                    Expanded(child: _buildStatCard(3, 'Classes', '$scannedClassCount', Icons.category, AppColors.neonOrange)),
                  ],
                ),
                const SizedBox(height: 30),

                // Class Confidence Line Graph
                _buildSectionTitle('CLASS ACCURACY'),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primaryBlue.withOpacity(0.3), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryBlue.withOpacity(0.15),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      SizedBox(
                        height: 240,
                        child: _getClassConfidenceAverages().isEmpty
                            ? _buildEmptyChart('Scan some classes to see confidence')
                            : _buildConfidenceLineChart(_getClassConfidenceAverages()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Detection Distribution
                _buildSectionTitle('DETECTION DISTRIBUTION'),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primaryPink.withOpacity(0.3), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.primaryPink.withOpacity(0.15),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    height: 240,
                    child: labelCounts.isEmpty
                        ? _buildEmptyChart('No detections yet')
                        : _buildDistributionChart(labelCounts),
                  ),
                ),
                const SizedBox(height: 20),

                // Class Scan Trend
                _buildSectionTitle('CLASS SCAN TREND'),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.accentPink.withOpacity(0.3), width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.accentPink.withOpacity(0.15),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    height: 240,
                    child: trendDataset.isEmpty
                        ? _buildEmptyChart('Scan some classes to see trends')
                        : _buildClassLineChart(trendDataset),
                  ),
                ),
                const SizedBox(height: 100),
                      ],
                    ),
                  ),
                  // Floating square card overlay
                  if (_floatingCardIndex != null)
                    _buildFloatingCard(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.neonCyan, AppColors.neonPurple],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: GoogleFonts.poppins(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
            color: AppColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildStatCard(int index, String title, String value, IconData icon, Color color) {
    return GestureDetector(
      onLongPress: () {
        setState(() {
          _floatingCardIndex = index;
          _floatingCardTitle = title;
          _floatingCardValue = value;
          _floatingCardIcon = icon;
          _floatingCardColor = color;
        });
      },
      child: AspectRatio(
        aspectRatio: 1.0, // Square shape
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.3), width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.2),
                blurRadius: 15,
                spreadRadius: 2,
              ),
            ],
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(icon, color: color, size: 16),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    value,
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  title,
                  style: GoogleFonts.poppins(
                    fontSize: 8,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildFloatingCard() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _floatingCardIndex = null;
            _floatingCardTitle = null;
            _floatingCardValue = null;
            _floatingCardIcon = null;
            _floatingCardColor = null;
          });
        },
        child: Container(
          color: Colors.black.withOpacity(0.5),
          child: Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              builder: (context, scale, child) {
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: 280,
                      maxHeight: MediaQuery.of(context).size.height * 0.7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _floatingCardColor!.withOpacity(0.5),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: _floatingCardColor!.withOpacity(0.5),
                          blurRadius: 30,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: _floatingCardColor!.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(_floatingCardIcon!, color: _floatingCardColor, size: 40),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _floatingCardValue!,
                            style: GoogleFonts.poppins(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textPrimary,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _floatingCardTitle!,
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: _floatingCardColor!.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              _getStatDescription(_floatingCardTitle!),
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                color: AppColors.textSecondary,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
  
  String _getStatDescription(String title) {
    switch (title) {
      case 'Total Scans':
        return 'Total number of images scanned';
      case 'Success':
        return 'Percentage of successful detections';
      case 'Avg Conf':
        return 'Average confidence level of detections';
      case 'Classes':
        return 'Number of different classes detected';
      default:
        return '';
    }
  }

  Widget _buildEmptyChart(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.insert_chart_outlined, size: 40, color: AppColors.textSecondary.withOpacity(0.5)),
          const SizedBox(height: 10),
          Text(message, style: GoogleFonts.poppins(color: AppColors.textSecondary, fontSize: 12)),
        ],
      ),
    );
  }

  List<Widget> _buildAmbientGlows() {
    return [
      Positioned(
        top: -40,
        left: -30,
        child: _buildGlowCircle(AppColors.primaryBlue, size: 200),
      ),
      Positioned(
        bottom: 120,
        right: -20,
        child: _buildGlowCircle(AppColors.neonPink, size: 240),
      ),
    ];
  }

  Widget _buildGlowCircle(Color color, {double size = 180}) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withOpacity(0.3),
              color.withOpacity(0.0),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBarChart(List<Map<String, dynamic>> data) {
    if (data.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final maxCount = data.map((e) => e['count'] as int).reduce(math.max);
    
    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: (maxCount + 2).toDouble(),
        titlesData: FlTitlesData(
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                if (value.toInt() >= 0 && value.toInt() < data.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      data[value.toInt()]['date'],
                      style: GoogleFonts.poppins(
                        color: AppColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                }
                return const Text('');
              },
              reservedSize: 32,
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                return Text(
                  value.toInt().toString(),
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                );
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          drawHorizontalLine: true,
          horizontalInterval: 1,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: AppColors.primaryPink.withOpacity(0.1),
              strokeWidth: 1,
              dashArray: [5, 5],
            );
          },
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            bottom: BorderSide(color: AppColors.primaryPink.withOpacity(0.3), width: 1),
            left: BorderSide(color: AppColors.primaryPink.withOpacity(0.3), width: 1),
          ),
        ),
        barGroups: data.asMap().entries.map((entry) {
          return BarChartGroupData(
            x: entry.key,
            barRods: [
              BarChartRodData(
                toY: entry.value['count'].toDouble(),
                gradient: LinearGradient(
                  colors: [
                    AppColors.primaryBlue,
                    AppColors.primaryPink,
                    AppColors.accentPink,
                  ],
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                ),
                width: 22,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                backDrawRodData: BackgroundBarChartRodData(
                  show: true,
                  toY: (maxCount + 2).toDouble(),
                  color: AppColors.background.withOpacity(0.3),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildDistributionChart(Map<String, int> data) {
    final total = data.values.fold<int>(0, (sum, value) => sum + value);
    
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: PieChart(
            PieChartData(
              sectionsSpace: 4,
              centerSpaceRadius: 50,
              sections: data.entries.toList().asMap().entries.map((entry) {
                final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
                final percentage = formatScanPercentage((entry.value.value / total) * 100);
                return PieChartSectionData(
                  value: entry.value.value.toDouble(),
                  title: percentage,
                  color: color,
                  radius: 60,
                  titleStyle: GoogleFonts.poppins(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                  badgeWidget: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withOpacity(0.3),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Icon(Icons.circle, size: 8, color: color),
                  ),
                  badgePositionPercentageOffset: 1.2,
                );
              }).toList(),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: data.entries.toList().asMap().entries.map((entry) {
                final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
                final percentage = formatScanPercentage((entry.value.value / total) * 100);
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: color.withOpacity(0.3), width: 1),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(3),
                          boxShadow: [
                            BoxShadow(
                              color: color.withOpacity(0.4),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.value.key,
                              style: GoogleFonts.poppins(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '$percentage (${entry.value.value})',
                              style: GoogleFonts.poppins(
                                fontSize: 9,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfidenceLineChart(Map<String, double> data) {
    if (data.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final entries = data.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final maxY = entries.map((e) => e.value).fold<double>(0, math.max);
    final maxYValue = (maxY > 100 ? 100.0 : (maxY + 10).clamp(0.0, 100.0)).toDouble();
    final maxX = entries.length > 1 ? entries.length - 1 : 1;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX.toDouble(),
        minY: 0,
        maxY: maxYValue,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          drawHorizontalLine: true,
          horizontalInterval: maxYValue / 5,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: AppColors.primaryBlue.withOpacity(0.1),
              strokeWidth: 1,
              dashArray: [5, 5],
            );
          },
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            bottom: BorderSide(color: AppColors.primaryPink.withOpacity(0.3), width: 1),
            left: BorderSide(color: AppColors.primaryPink.withOpacity(0.3), width: 1),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '${value.toInt()}%',
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index >= 0 && index < entries.length) {
                  var label = entries[index].key;
                  if (label.length > 8) {
                    label = '${label.substring(0, 6)}..';
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Transform.rotate(
                      angle: -0.5,
                      child: Text(
                        label,
                        style: GoogleFonts.poppins(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) => AppColors.primaryPink,
            tooltipBorderRadius: BorderRadius.circular(8),
            getTooltipItems: (items) => items.map((item) {
              final label = entries[item.x.toInt()].key;
              final percentage = entries[item.x.toInt()].value;
              return LineTooltipItem(
                '$label\n${formatScanPercentage(percentage)}',
                GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: entries.asMap().entries
                .map((entry) => FlSpot(entry.key.toDouble(), entry.value.value))
                .toList(),
            isCurved: true,
            gradient: const LinearGradient(
              colors: [AppColors.accentPink, AppColors.primaryPink],
            ),
            barWidth: 4,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 5,
                color: Colors.white,
                strokeColor: AppColors.neonPink,
                strokeWidth: 2,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  AppColors.neonPink.withOpacity(0.2),
                  AppColors.primaryPink.withOpacity(0.05),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            shadow: const Shadow(
              color: Colors.black54,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClassLineChart(Map<String, int> data) {
    if (data.isEmpty) {
      return const SizedBox.shrink();
    }
    
    final entries = data.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final maxY = entries.map((e) => e.value.toDouble()).fold<double>(0, math.max) + 1;
    final maxX = entries.length > 1 ? entries.length - 1 : 1;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX.toDouble(),
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          drawHorizontalLine: true,
          horizontalInterval: 1,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: AppColors.primaryBlue.withOpacity(0.1),
              strokeWidth: 1,
              dashArray: [5, 5],
            );
          },
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            bottom: BorderSide(color: AppColors.primaryPink.withOpacity(0.3), width: 1),
            left: BorderSide(color: AppColors.primaryPink.withOpacity(0.3), width: 1),
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  value.toInt().toString(),
                  style: GoogleFonts.poppins(
                    color: AppColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: 1,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index >= 0 && index < entries.length) {
                  var label = entries[index].key;
                  if (label.length > 8) {
                    label = '${label.substring(0, 6)}..';
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Transform.rotate(
                      angle: -0.5, // Slant the text (approximately -28.6 degrees)
                      child: Text(
                        label,
                        style: GoogleFonts.poppins(
                          color: AppColors.textSecondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
          ),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) => AppColors.primaryPink,
            tooltipBorderRadius: BorderRadius.circular(8),
            getTooltipItems: (items) => items.map((item) {
              final label = entries[item.x.toInt()].key;
              final count = entries[item.x.toInt()].value;
              return LineTooltipItem(
                '$label\n$count scans',
                GoogleFonts.poppins(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              );
            }).toList(),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: entries.asMap().entries
                .map((entry) => FlSpot(entry.key.toDouble(), entry.value.value.toDouble()))
                .toList(),
            isCurved: true,
            gradient: const LinearGradient(
              colors: [AppColors.accentPink, AppColors.primaryPink],
            ),
            barWidth: 4,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, percent, bar, index) => FlDotCirclePainter(
                radius: 5,
                color: Colors.white,
                strokeColor: AppColors.neonPink,
                strokeWidth: 2,
              ),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  AppColors.neonPink.withOpacity(0.2),
                  AppColors.primaryPink.withOpacity(0.05),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            shadow: const Shadow(
              color: Colors.black54,
              blurRadius: 4,
              offset: Offset(0, 2),
            ),
          ),
        ],
      ),
    );
  }
}

// ==================== LOGS PAGE ====================
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> with WidgetsBindingObserver {
  int _lastHistoryVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lastHistoryVersion = historyVersion;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndUpdate();
    }
  }

  void _checkAndUpdate() {
    if (_lastHistoryVersion != historyVersion) {
      _lastHistoryVersion = historyVersion;
      if (mounted) {
        setState(() {});
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check for updates when page becomes visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndUpdate();
      // History is already in memory, no need to reload
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            // Static Header
            Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border(
                  bottom: BorderSide(
                    color: AppColors.primaryBlue.withOpacity(0.5),
                    width: 1,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [AppColors.primaryBlue, AppColors.primaryPink],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primaryBlue.withOpacity(0.5),
                                blurRadius: 10,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.list_alt_rounded, color: Colors.white, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'SCAN LOGS',
                          style: GoogleFonts.poppins(
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                    if (detectionHistory.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.delete_sweep_rounded, color: AppColors.danger),
                        onPressed: _showClearDialog,
                      ),
                  ],
                ),
              ),
            ),
            // Scrollable Content
            Expanded(
              child: detectionHistory.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      key: ValueKey('logs_$historyVersion'),
                      padding: const EdgeInsets.all(16),
                      itemCount: detectionHistory.length,
                      itemBuilder: (context, index) {
                        if (index >= detectionHistory.length) {
                          return const SizedBox.shrink();
                        }
                        final item = detectionHistory[index];
                        return Dismissible(
                          key: Key('log_${item.timestamp}_$index'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            decoration: BoxDecoration(
                              color: AppColors.danger,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: const Icon(
                              Icons.delete_rounded,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                          confirmDismiss: (direction) async {
                            return await _showDeleteDialog(item);
                          },
                          onDismissed: (direction) {
                            deleteScan(item);
                            if (mounted) {
                              setState(() {});
                            }
                          },
                          child: _buildLogItem(item, index),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [AppColors.neonCyan, AppColors.neonPurple],
            ).createShader(bounds),
            child: const Icon(Icons.inbox_rounded, size: 80, color: Colors.white),
          ),
          const SizedBox(height: 20),
          Text(
            'NO LOGS',
            style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.textPrimary, letterSpacing: 2),
          ),
          const SizedBox(height: 8),
          Text(
            'Your scan history will appear here',
            style: GoogleFonts.poppins(fontSize: 13, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildLogItem(DetectionItem item, int index) {
    final color = item.isUnknown ? AppColors.danger : AppColors.primaryBlue;
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GestureDetector(
        onTap: () => _showDetailDialog(item),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: color.withOpacity(0.3), width: 2),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.15),
                blurRadius: 15,
                spreadRadius: 1,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              // Thumbnail
              ClipRRect(
                borderRadius: const BorderRadius.horizontal(left: Radius.circular(14)),
                child: Image.file(
                  File(item.imagePath),
                  height: 100,
                  width: 100,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      height: 100,
                      width: 100,
                      color: AppColors.surface,
                      child: const Icon(Icons.broken_image, color: AppColors.textSecondary),
                    );
                  },
                ),
              ),
              // Info
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: color.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: color.withOpacity(0.4), width: 1.5),
                            ),
                            child: Text(
                              item.isUnknown ? 'UNKNOWN' : 'DETECTED',
                              style: GoogleFonts.poppins(
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                                color: color,
                                letterSpacing: 1,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _formatDateTime(item.timestamp),
                            style: GoogleFonts.poppins(fontSize: 10, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        item.topLabel.toUpperCase(),
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.speed, size: 12, color: color),
                                  const SizedBox(width: 4),
                                  Text(
                                    formatScanPercentage(item.topConfidence),
                                    style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _formatFullDateTime(item.timestamp),
                                style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                          const Spacer(),
                          Text(
                            'Swipe to delete',
                            style: GoogleFonts.poppins(fontSize: 9, color: AppColors.textSecondary),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetailDialog(DetectionItem item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.75,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textSecondary.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppColors.primaryBlue, AppColors.primaryPink],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.pie_chart, size: 20, color: Colors.white),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'PREDICTION DETAILS',
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primaryBlue,
                            letterSpacing: 1,
                          ),
                        ),
                        Text(
                          item.topLabel,
                          style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Image
                    ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.file(
                        File(item.imagePath),
                        height: 150,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            height: 150,
                            color: AppColors.card,
                            child: const Icon(Icons.broken_image, size: 50, color: AppColors.textSecondary),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Bar Chart
                    _buildDetailBarChart(item.allPredictions),
                    const SizedBox(height: 20),
                    // Prediction Explanations
                    _buildPredictionExplanations(item.allPredictions),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper function to get predictions, filtering out negligible contributions (User Request)
  Map<String, double> _filterAndNormalizePredictions(Map<String, double> predictions) {
    if (predictions.isEmpty) return {};
    
    // Filter out classes that would display as "0.00%"
    // Threshold set to 0.005 (0.005%) which rounds up to "0.01%"
    return Map<String, double>.fromEntries(
      predictions.entries.where((entry) => entry.value >= 0.005)
    );
  }

  Widget _buildDetailBarChart(Map<String, double> predictions) {
    final filteredPredictions = _filterAndNormalizePredictions(predictions);
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primaryPink.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          ...entries.asMap().entries.map((entry) {
            final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
            final value = entry.value.value.clamp(0, 100).toDouble();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          entry.value.key,
                          style: GoogleFonts.poppins(fontSize: 11, color: AppColors.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatScanPercentage(value),
                        style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.bold, color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: value <= 0 ? 0.0 : (value / 100).clamp(0.01, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [color, color.withOpacity(0.6)]),
                          borderRadius: BorderRadius.circular(4),
                          boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 4)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // Generate explanation for why a chair class received its confidence percentage
  String _generateClassExplanation(String className, double confidence, Map<String, double> allPredictions) {
    final topClass = allPredictions.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    final isTopClass = className == topClass;
    
    // Define feature explanations for each chair type - what was detected in the image
    final Map<String, Map<String, String>> chairExplanations = {
      'Ball chair': {
        'high': 'Spherical shape and curved edges detected',
        'medium': 'Rounded form similar to ball structure',
        'low': 'Some curved edges match ball chair shape',
      },
      'Chiase Lounge chair': {
        'high': 'Elongated seat and extended backrest detected',
        'medium': 'Sloping backrest and extended posture visible',
        'low': 'Similar elongated proportions to lounge chair',
      },
      'Bean Bag chair': {
        'high': 'Soft formless structure and fabric texture detected',
        'medium': 'Flexible shape without rigid frame visible',
        'low': 'Similar soft, rounded form to bean bag',
      },
      'Office chair': {
        'high': 'Swivel base, wheels, and ergonomic backrest detected',
        'medium': 'Structured backrest similar to office chair design',
        'low': 'Similar structured shape to office chair',
      },
      'Rocking chair': {
        'high': 'Curved rocker base and traditional backrest detected',
        'medium': 'Curved structure similar to rocking mechanism',
        'low': 'Some curved edges match rocking chair shape',
      },
      'Waiting chair': {
        'high': 'Simple design and basic backrest detected',
        'medium': 'Standard proportions similar to waiting chair',
        'low': 'Similar simple, utilitarian shape',
      },
      'Wheelchair': {
        'high': 'Large wheels and specialized seat design detected',
        'medium': 'Wheel-like structures or rounded base visible',
        'low': 'Similar rounded base shape to wheelchair (may share shape with plastic chair)',
      },
      'Hammock chair': {
        'high': 'Suspended structure and hanging form detected',
        'medium': 'Curved hanging shape similar to hammock',
        'low': 'Some curved, suspended-like features visible',
      },
      'Plastic chair': {
        'high': 'Molded plastic construction and geometric shape detected',
        'medium': 'Simple geometric form similar to plastic chair',
        'low': 'Similar simple shape and structure (may share features with wheelchair or waiting chair)',
      },
      'High chair': {
        'high': 'Elevated height and safety features detected',
        'medium': 'Taller proportions similar to high chair',
        'low': 'Similar elevated structure or proportions',
      },
    };
    
    final explanations = chairExplanations[className] ?? {
      'high': 'General chair features detected',
      'medium': 'Some chair-like features visible',
      'low': 'Minimal chair features detected',
    };
    
    // Generate explanation based on confidence level
    String explanation = '';
    
    if (confidence >= 70) {
      explanation = explanations['high'] ?? '';
    } else if (confidence >= 40) {
      explanation = explanations['medium'] ?? '';
    } else if (confidence >= 10) {
      explanation = explanations['low'] ?? '';
    } else {
      explanation = 'Very few matching features detected';
    }
    
    return explanation;
  }

  Widget _buildPredictionExplanations(Map<String, double> predictions) {
    final filteredPredictions = _filterAndNormalizePredictions(predictions);
    final entries = filteredPredictions.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    
    if (entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primaryPink.withOpacity(0.3)),
        ),
        child: Center(
          child: Text(
            'No predictions available',
            style: GoogleFonts.poppins(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      );
    }
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primaryPink.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: AppColors.primaryBlue),
              const SizedBox(width: 8),
              Text(
                'Prediction Analysis',
                style: GoogleFonts.poppins(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryBlue,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...entries.asMap().entries.map((entry) {
            final color = AppColors.chartColors[entry.key % AppColors.chartColors.length];
            final className = entry.value.key;
            final confidence = entry.value.value.clamp(0, 100).toDouble();
            final explanation = _generateClassExplanation(className, confidence, filteredPredictions);
            
            return Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 4,
                        height: 16,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          className,
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      Text(
                        formatScanPercentage(confidence),
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      explanation,
                      style: GoogleFonts.poppins(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<bool> _showDeleteDialog(DetectionItem item) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.danger.withOpacity(0.5)),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_rounded, color: AppColors.danger),
            const SizedBox(width: 12),
            Text(
              'DELETE SCAN',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: AppColors.danger, letterSpacing: 1),
            ),
          ],
        ),
        content: Text(
          'Delete this scan log permanently?',
          style: GoogleFonts.poppins(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('CANCEL', style: GoogleFonts.poppins(color: AppColors.textSecondary, letterSpacing: 1)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context, true); // Close confirmation dialog first
              
              // Show loading indicator
              if (!context.mounted) return;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => Center(
                  child: GlassContainer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryBlue),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Deleting...',
                          style: GoogleFonts.poppins(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              
              // Update UI immediately (optimistic update)
              detectionHistory.remove(item);
              historyVersion++;
              onHistoryChanged?.call();
              if (mounted) {
                setState(() {});
              }
              
              // Perform deletion
              final success = await deleteScan(item);
              
              // Close loading dialog
              if (context.mounted) {
                Navigator.pop(context);
                
                // Show notification
                await Future.delayed(const Duration(milliseconds: 100));
                
                if (!context.mounted) return;
                
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      success ? 'Scan deleted successfully' : 'Failed to delete scan',
                      style: GoogleFonts.poppins(),
                    ),
                    backgroundColor: success ? AppColors.success : AppColors.danger,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            child: Text('DELETE', style: GoogleFonts.poppins(color: AppColors.danger, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showClearDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: AppColors.danger.withOpacity(0.5)),
        ),
        title: Row(
          children: [
            const Icon(Icons.warning_rounded, color: AppColors.danger),
            const SizedBox(width: 12),
            Text(
              'CLEAR LOGS',
              style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: AppColors.danger, letterSpacing: 1),
            ),
          ],
        ),
        content: Text(
          'Delete all scan logs permanently?',
          style: GoogleFonts.poppins(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('CANCEL', style: GoogleFonts.poppins(color: AppColors.textSecondary, letterSpacing: 1)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context); // Close confirmation dialog first
              
              // Show loading indicator
              if (!context.mounted) return;
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => Center(
                  child: GlassContainer(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryBlue),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Deleting all...',
                          style: GoogleFonts.poppins(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              );
              
              // Update UI immediately (optimistic update)
              detectionHistory.clear();
              await saveHistoryToStorage();
              historyVersion++;
              onHistoryChanged?.call();
              if (mounted) {
                setState(() {});
              }
              
              // Delete all from local history
              bool success = true;
              try {
                detectionHistory.clear();
              await saveHistoryToStorage();
                historyVersion++;
                onHistoryChanged?.call();
                devtools.log("All scans deleted from local history");
              } catch (e) {
                devtools.log("Error deleting all scans: $e");
                success = false;
              }
              
              // Close loading dialog
              if (context.mounted) {
                Navigator.pop(context);
                
                // Always show notification
                await Future.delayed(const Duration(milliseconds: 100));
                
                if (!context.mounted) return;
                
                // Show success alert
                showDialog(
                  context: context,
                  barrierDismissible: true,
                  builder: (context) => AlertDialog(
                    backgroundColor: AppColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(color: AppColors.neonGreen.withOpacity(0.5)),
                    ),
                    title: Row(
                      children: [
                        const Icon(Icons.check_circle, color: AppColors.neonGreen),
                        const SizedBox(width: 12),
                        Text(
                          'DELETED SUCCESSFULLY',
                          style: GoogleFonts.poppins(
                            fontWeight: FontWeight.bold,
                            color: AppColors.neonGreen,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                    content: Text(
                      success 
                        ? 'All scans have been deleted successfully.'
                        : 'Scans cleared locally. Some may still exist in cloud.',
                      style: GoogleFonts.poppins(color: AppColors.textSecondary),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          'OK',
                          style: GoogleFonts.poppins(
                            color: AppColors.neonGreen,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }
            },
            child: Text('DELETE', style: GoogleFonts.poppins(color: AppColors.danger, fontWeight: FontWeight.bold, letterSpacing: 1)),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inHours < 1) return '${difference.inMinutes}m ago';
    if (difference.inDays < 1) return '${difference.inHours}h ago';
    if (difference.inDays == 1) return 'Yesterday';
    return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
  }

  String _formatFullDateTime(DateTime dateTime) {
    final monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final hour = dateTime.hour % 12 == 0 ? 12 : dateTime.hour % 12;
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final amPm = dateTime.hour < 12 ? 'AM' : 'PM';
    return '${monthNames[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year} ${hour}:${minute} $amPm';
  }
}

import 'package:flutter/foundation.dart';
import 'package:kanshi_gui/models/profiles.dart';
import '../repositories/config_repository.dart';

/// Manages profile state and persistence for the UI.
class ProfileProvider extends ChangeNotifier {
  final ConfigRepository _repo;
  List<Profile> _profiles = [];
  int? _activeIndex;

  ProfileProvider({ConfigRepository? repository})
    : _repo = repository ?? ConfigRepository();

  List<Profile> get profiles => List.unmodifiable(_profiles);
  int? get activeIndex => _activeIndex;

  /// Initializes by loading profiles and setting default.
  Future<void> init() async {
    _profiles = await _repo.loadProfiles();
    if (_profiles.isNotEmpty) _activeIndex = 0;
    notifyListeners();
  }

  /// Selects a profile and saves the choice.
  Future<void> selectProfile(int index) async {
    _activeIndex = index;
    notifyListeners();
    await _repo.updateCurrentProfile(_profiles[index].name);
  }

  /// Renames a profile and persists change.
  Future<void> renameProfile(int index, String newName) async {
    _profiles[index].name = newName;
    notifyListeners();
    await _repo.saveProfiles(_profiles);
  }

  /// Deletes a profile and persists change.
  Future<void> deleteProfile(int index) async {
    _profiles.removeAt(index);
    if (_activeIndex == index) _activeIndex = null;
    notifyListeners();
    await _repo.saveProfiles(_profiles);
  }

  /// Saves all profile layouts after edits.
  Future<void> saveCurrentLayout() async {
    await _repo.saveProfiles(_profiles);
  }
}

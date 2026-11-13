import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/errors.dart';
import '../models/device.dart';
import '../models/house.dart';
import '../services/device_repository.dart';
import '../services/house_repository.dart';

/// Guarda a casa selecionada e resolve os streams dependentes dela.
/// Trocar de casa cancela as assinaturas antigas (isolamento na UI).
class HouseController extends ChangeNotifier {
  HouseController({
    required HouseRepository houseRepository,
    required DeviceRepository deviceRepository,
  })  : _houses = houseRepository,
        _devices = deviceRepository {
    _loadPreferences();
  }

  final HouseRepository _houses;
  final DeviceRepository _devices;

  StreamSubscription<List<House>>? _housesSub;
  StreamSubscription<HouseMember?>? _memberSub;
  StreamSubscription<List<Device>>? _devicesSub;

  SharedPreferences? _prefs;
  String? _uid;
  bool _disposed = false;

  List<House> _houseList = const [];
  House? _selectedHouse;
  HouseMember? _membership;
  List<Device> _deviceList = const [];
  Device? _selectedDevice;
  bool _loadingHouses = true;
  String? _error;

  List<House> get houses => _houseList;
  House? get selectedHouse => _selectedHouse;
  HouseMember? get membership => _membership;
  MemberRole get role => _membership?.role ?? MemberRole.viewer;
  bool get canEditConfig => _membership?.role.canEditConfig ?? false;
  bool get canManageMembers => _membership?.role.canManageMembers ?? false;
  List<Device> get devices => _deviceList;
  Device? get selectedDevice => _selectedDevice;
  bool get loadingHouses => _loadingHouses;
  String? get error => _error;
  bool get hasHouse => _selectedHouse != null;

  Future<void> _loadPreferences() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs?.getString('selectedHouseId');
    if (saved != null && _selectedHouse == null) {
      final match = _houseList.where((house) => house.id == saved);
      if (match.isNotEmpty) _selectHouse(match.first, persist: false);
    }
  }

  /// Chamado pelo ProxyProvider quando o usuário autenticado muda.
  Future<void> updateAuth(User? user) async {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    await _housesSub?.cancel();
    await _memberSub?.cancel();
    await _devicesSub?.cancel();
    _housesSub = null;
    _memberSub = null;
    _devicesSub = null;
    _houseList = const [];
    _selectedHouse = null;
    _membership = null;
    _deviceList = const [];
    _selectedDevice = null;
    _error = null;

    if (user == null) {
      _loadingHouses = false;
      _notify();
      return;
    }

    _loadingHouses = true;
    _notify();

    final savedId = _prefs?.getString('selectedHouseId');
    _housesSub = _houses.watchHousesForUser(user.uid).listen(
      (houses) {
        _houseList = houses;
        _loadingHouses = false;
        _error = null;
        if (houses.isEmpty) {
          _selectedHouse = null;
          _devicesSub?.cancel();
          _devicesSub = null;
          _deviceList = const [];
          _selectedDevice = null;
        } else {
          final current = _selectedHouse;
          House? next;
          if (current != null) {
            final match = houses.where((h) => h.id == current.id);
            next = match.isEmpty ? null : match.first;
          }
          next ??= houses.where((h) => h.id == savedId).firstOrNull;
          next ??= houses.first;
          _selectHouse(next, persist: next.id != savedId);
        }
        _notify();
      },
      onError: (Object error) {
        _error = describeError(error);
        _loadingHouses = false;
        _notify();
      },
    );
  }

  void _selectHouse(House house, {bool persist = true}) {
    final changed = _selectedHouse?.id != house.id;
    _selectedHouse = house;
    if (persist) {
      _prefs?.setString('selectedHouseId', house.id);
    }
    if (changed) {
      _deviceList = const [];
      _selectedDevice = null;
      _membership = null;
      _listenToHouse(house);
    }
    _notify();
  }

  Future<void> selectHouse(House house) async {
    _selectHouse(house);
    try {
      await _prefs?.setString('selectedHouseId', house.id);
    } catch (_) {
      // preferência é best-effort
    }
  }

  void selectDevice(Device device) {
    _selectedDevice = device;
    _notify();
  }

  void _listenToHouse(House house) {
    _memberSub?.cancel();
    _devicesSub?.cancel();

    if (_uid != null) {
      _memberSub = _houses.watchMembership(house.id, _uid!).listen(
        (member) {
          _membership = member;
          _notify();
        },
        onError: (Object error) {
          _error = describeError(error);
          _notify();
        },
      );
    }

    _devicesSub = _devices.watchDevices(house.id).listen(
      (devices) {
        _deviceList = devices;
        if (devices.isEmpty) {
          _selectedDevice = null;
        } else {
          final current = _selectedDevice;
          final match = devices.where((d) => d.id == current?.id);
          _selectedDevice = match.isEmpty ? devices.first : match.first;
        }
        _notify();
      },
      onError: (Object error) {
        _error = describeError(error);
        _notify();
      },
    );
  }

  /// Reassina os streams (botão "tentar novamente").
  Future<void> refresh() async {
    final user = _uid;
    if (user == null) return;
    final currentUid = _uid;
    _uid = null;
    await updateAuth(FirebaseAuth.instance.currentUser);
    if (currentUid == null) return;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _housesSub?.cancel();
    _memberSub?.cancel();
    _devicesSub?.cancel();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

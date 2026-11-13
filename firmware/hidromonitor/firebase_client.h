#pragma once

#include <Arduino.h>

#include "types.h"

/// Cliente REST mínimo do Firebase (Auth + Firestore) para o ESP32.
///
/// Usa TLS sem pinning de certificado (setInsecure) para simplificar a
/// instalação. Em produção, troque por `setCACert()` com a CA raiz.
class FirebaseClient {
 public:
  void configure(const Credentials& credentials);

  /// Login com e-mail/senha do device. Retorna false em falha.
  bool signIn();

  /// Garante idToken válido (login ou refresh).
  bool ensureToken();

  bool postReading(float distanceCm, float levelPercent, float levelCm,
                   float volumeL, bool pumpOn, bool valveOpen, bool sensorOk,
                   int rssi, const String& ts);

  bool patchLatest(float distanceCm, float levelPercent, float levelCm,
                   float volumeL, bool pumpOn, bool valveOpen, bool sensorOk,
                   int rssi, const String& ts, const String& lastSeen);

  bool patchLastSeen(const String& ts);

  /// Lê `config` do documento do device e atualiza [out] se válido.
  bool fetchConfig(DeviceConfig& out);

  bool postEvent(const String& type, const String& detail, const String& ts);

  /// Busca o comando pendente mais recente (não expirado).
  bool fetchPendingCommand(DeviceCommand& out);

  /// Marca o comando como done/rejected (só o device pode).
  bool updateCommand(const String& id, const String& status,
                     const String& detail);

  /// Timestamp ISO UTC atual (vazio se o relógio ainda não sincronizou).
  static String isoTimestampNow();
  bool postAlert(const String& type, const String& severity,
                 const String& message, const String& ts);

  int lastHttpCode = 0;
  String lastError;

 private:
  Credentials creds;
  String idToken;
  String refreshToken;
  uint32_t tokenExpiresMs = 0;

  bool refreshTokenNow();
  bool request(const String& method, const String& url, const String& body,
               String& response, bool withAuth);
  String deviceUrl() const;
  String readingsUrl() const;
  String eventsUrl() const;
  String alertsUrl() const;

};

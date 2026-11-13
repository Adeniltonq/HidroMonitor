#include "firebase_client.h"

#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <WiFiClientSecure.h>

#include <math.h>
#include <time.h>

#include "config.h"
#include "certs.h"

namespace {

constexpr uint32_t kTokenSafetyMs = 60UL * 1000UL;

double numValue(JsonVariant v) {
  if (v.isNull()) return NAN;
  JsonVariant d = v["doubleValue"];
  if (!d.isNull()) return d.as<double>();
  JsonVariant i = v["integerValue"];
  if (!i.isNull()) {
    if (i.is<const char*>()) return atof(i.as<const char*>());
    return i.as<double>();
  }
  if (v.is<double>()) return v.as<double>();
  if (v.is<long>()) return static_cast<double>(v.as<long>());
  return NAN;
}

String doubleField(double value) {
  return String(value, 2);
}

}  // namespace

void FirebaseClient::configure(const Credentials& credentials) {
  creds = credentials;
  idToken = "";
  refreshToken = "";
  tokenExpiresMs = 0;
}

String FirebaseClient::deviceUrl() const {
  return String(FIRESTORE_BASE) + "/houses/" + creds.houseId + "/devices/" +
         creds.deviceId;
}

String FirebaseClient::readingsUrl() const { return deviceUrl() + "/readings"; }
String FirebaseClient::eventsUrl() const { return deviceUrl() + "/events"; }

String FirebaseClient::alertsUrl() const {
  return String(FIRESTORE_BASE) + "/houses/" + creds.houseId + "/alerts";
}

bool FirebaseClient::request(const String& method, const String& url,
                             const String& body, String& response,
                             bool withAuth) {
  if (withAuth && !ensureToken()) return false;

  WiFiClientSecure client;
  client.setCACert(GTS_ROOT_CA);
  client.setTimeout(12);

  HTTPClient http;
  http.setTimeout(12000);
  if (!http.begin(client, url)) {
    lastError = F("http_begin");
    return false;
  }
  http.addHeader(F("Content-Type"), F("application/json"));
  if (withAuth) {
    http.addHeader(F("Authorization"), "Bearer " + idToken);
  }

  int code = 0;
  if (method == "GET") {
    code = http.GET();
  } else if (method == "POST") {
    code = http.POST(body);
  } else {
    code = http.sendRequest(method.c_str(),
                            reinterpret_cast<uint8_t*>(
                                const_cast<char*>(body.c_str())),
                            body.length());
  }

  lastHttpCode = code;
  response = "";
  if (code > 0) response = http.getString();
  http.end();

  if (code < 200 || code >= 300) {
    lastError = "HTTP " + String(code);
    return false;
  }
  return true;
}

bool FirebaseClient::signIn() {
  if (creds.fbEmail.isEmpty() || creds.fbPass.isEmpty()) {
    lastError = F("sem_credencial");
    return false;
  }

  const String url =
      String("https://identitytoolkit.googleapis.com/v1/accounts:"
             "signInWithPassword?key=") +
      FIREBASE_API_KEY;

  JsonDocument req;
  req["email"] = creds.fbEmail;
  req["password"] = creds.fbPass;
  req["returnSecureToken"] = true;
  String body;
  serializeJson(req, body);

  String response;
  if (!request("POST", url, body, response, false)) {
    lastError = F("auth_http");
    return false;
  }

  JsonDocument doc;
  if (deserializeJson(doc, response) != DeserializationError::Ok) {
    lastError = F("auth_json");
    return false;
  }
  idToken = doc["idToken"].as<String>();
  refreshToken = doc["refreshToken"].as<String>();
  uint32_t expiresIn = 3600;
  if (doc["expiresIn"].is<const char*>()) {
    expiresIn = String(doc["expiresIn"].as<const char*>()).toInt();
  } else {
    expiresIn = doc["expiresIn"].as<uint32_t>();
  }
  if (expiresIn == 0) expiresIn = 3600;
  if (idToken.isEmpty()) {
    lastError = F("auth_token");
    return false;
  }
  tokenExpiresMs = millis() + expiresIn * 1000UL;
  return true;
}

bool FirebaseClient::refreshTokenNow() {
  if (refreshToken.isEmpty()) return false;

  WiFiClientSecure client;
  client.setCACert(GTS_ROOT_CA);
  client.setTimeout(12);
  HTTPClient http;
  http.setTimeout(12000);
  const String url =
      String("https://securetoken.googleapis.com/v1/token?key=") +
      FIREBASE_API_KEY;
  if (!http.begin(client, url)) return false;
  http.addHeader(F("Content-Type"),
                 F("application/x-www-form-urlencoded"));
  const String body =
      "grant_type=refresh_token&refresh_token=" + refreshToken;
  const int code = http.POST(body);
  const String response = code > 0 ? http.getString() : "";
  http.end();
  if (code < 200 || code >= 300) return false;

  JsonDocument doc;
  if (deserializeJson(doc, response) != DeserializationError::Ok) return false;
  idToken = doc["id_token"].as<String>();
  refreshToken = doc["refresh_token"].as<String>();
  uint32_t expiresIn = 3600;
  if (doc["expires_in"].is<const char*>()) {
    expiresIn = String(doc["expires_in"].as<const char*>()).toInt();
  } else {
    expiresIn = doc["expires_in"].as<uint32_t>();
  }
  if (expiresIn == 0) expiresIn = 3600;
  if (idToken.isEmpty()) return false;
  tokenExpiresMs = millis() + expiresIn * 1000UL;
  return true;
}

bool FirebaseClient::ensureToken() {
  if (idToken.isEmpty()) return signIn();
  if (static_cast<int32_t>(millis() - (tokenExpiresMs - kTokenSafetyMs)) >= 0) {
    if (refreshTokenNow()) return true;
    return signIn();
  }
  return true;
}

String FirebaseClient::isoTimestampNow() {
  const time_t now = time(nullptr);
  if (now < 1700000000) return "";
  struct tm tmUtc;
  gmtime_r(&now, &tmUtc);
  char buffer[26];
  strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &tmUtc);
  return String(buffer);
}

bool FirebaseClient::postReading(float distanceCm, float levelPercent,
                                 float levelCm, float volumeL, bool pumpOn,
                                 bool valveOpen, bool sensorOk, int rssi,
                                 const String& ts) {
  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["distanceCm"]["doubleValue"] = doubleField(distanceCm).toDouble();
  fields["levelPercent"]["doubleValue"] = doubleField(levelPercent).toDouble();
  fields["levelCm"]["doubleValue"] = doubleField(levelCm).toDouble();
  fields["volumeL"]["doubleValue"] = doubleField(volumeL).toDouble();
  fields["pumpOn"]["booleanValue"] = pumpOn;
  fields["valveOpen"]["booleanValue"] = valveOpen;
  fields["sensorOk"]["booleanValue"] = sensorOk;
  fields["rssi"]["integerValue"] = String(rssi);
  fields["ts"]["timestampValue"] = ts;

  String body;
  serializeJson(doc, body);
  String response;
  return request("POST", readingsUrl(), body, response, true);
}

bool FirebaseClient::patchLatest(float distanceCm, float levelPercent,
                                 float levelCm, float volumeL, bool pumpOn,
                                 bool valveOpen, bool sensorOk, int rssi,
                                 const String& ts, const String& lastSeen) {
  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["lastSeen"]["timestampValue"] = lastSeen;
  fields["fwVersion"]["stringValue"] = FW_VERSION;
  JsonObject latest =
      fields["latest"]["mapValue"]["fields"].to<JsonObject>();
  latest["distanceCm"]["doubleValue"] = doubleField(distanceCm).toDouble();
  latest["levelPercent"]["doubleValue"] = doubleField(levelPercent).toDouble();
  latest["levelCm"]["doubleValue"] = doubleField(levelCm).toDouble();
  latest["volumeL"]["doubleValue"] = doubleField(volumeL).toDouble();
  latest["pumpOn"]["booleanValue"] = pumpOn;
  latest["valveOpen"]["booleanValue"] = valveOpen;
  latest["sensorOk"]["booleanValue"] = sensorOk;
  latest["rssi"]["integerValue"] = String(rssi);
  latest["ts"]["timestampValue"] = ts;

  String body;
  serializeJson(doc, body);
  String response;
  const String url = deviceUrl() +
                     "?updateMask.fieldPaths=latest&"
                     "updateMask.fieldPaths=lastSeen&"
                     "updateMask.fieldPaths=fwVersion";
  return request("PATCH", url, body, response, true);
}

bool FirebaseClient::patchLastSeen(const String& ts) {
  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["lastSeen"]["timestampValue"] = ts;
  // Também publica a versão do firmware: o app usa esses dois campos para
  // confirmar o primeiro contato (regra: changed().hasOnly([... fwVersion])).
  fields["fwVersion"]["stringValue"] = FW_VERSION;
  String body;
  serializeJson(doc, body);
  String response;
  const String url = deviceUrl() +
                     "?updateMask.fieldPaths=lastSeen&"
                     "updateMask.fieldPaths=fwVersion";
  return request("PATCH", url, body, response, true);
}

bool FirebaseClient::fetchConfig(DeviceConfig& out) {
  String response;
  if (!request("GET", deviceUrl(), "", response, true)) return false;

  JsonDocument doc;
  if (deserializeJson(doc, response) != DeserializationError::Ok) {
    lastError = F("config_json");
    return false;
  }
  JsonObject fields = doc["fields"].as<JsonObject>();
  if (fields.isNull()) return false;
  JsonObject cfg =
      fields["config"]["mapValue"]["fields"].as<JsonObject>();
  if (cfg.isNull()) return false;

  const double version = numValue(cfg["configVersion"]);
  const double interval = numValue(cfg["reportIntervalSec"]);
  const double windowSec = numValue(cfg["sensorWindowSec"]);
  const double lowPct = numValue(cfg["alerts"]["mapValue"]["fields"]["lowLevelPercent"]);
  const double offline = numValue(cfg["alerts"]["mapValue"]["fields"]["offlineAfterSec"]);
  const double sensorFail = numValue(cfg["alerts"]["mapValue"]["fields"]["sensorFailAfterSec"]);
  const double liga = numValue(cfg["limits"]["mapValue"]["fields"]["ligaCm"]);
  const double desliga = numValue(cfg["limits"]["mapValue"]["fields"]["desligaCm"]);
  const double height = numValue(cfg["tank"]["mapValue"]["fields"]["heightCm"]);
  const double capacity = numValue(cfg["tank"]["mapValue"]["fields"]["capacityL"]);
  const double minRange = numValue(cfg["tank"]["mapValue"]["fields"]["minRangeCm"]);
  const double maxRange = numValue(cfg["tank"]["mapValue"]["fields"]["maxRangeCm"]);
  const double offset = numValue(cfg["tank"]["mapValue"]["fields"]["sensorOffsetCm"]);

  if (!isfinite(version) || version < 1) return false;

  DeviceConfig cfgOut = out;
  cfgOut.version = static_cast<int>(version);
  if (isfinite(interval) && interval >= 15 && interval <= 3600) {
    cfgOut.intervalSec = static_cast<uint16_t>(interval);
  }
  if (isfinite(windowSec) && windowSec >= 5 && windowSec <= 60) {
    cfgOut.sensorWindowSec = static_cast<uint16_t>(windowSec);
  }
  if (isfinite(height) && height > 0) cfgOut.heightCm = height;
  if (isfinite(capacity) && capacity > 0) cfgOut.capacityL = capacity;
  if (isfinite(offset) && offset >= 0) cfgOut.sensorOffsetCm = offset;
  if (isfinite(minRange) && minRange >= 0) cfgOut.minRangeCm = minRange;
  if (isfinite(maxRange) && maxRange > cfgOut.minRangeCm) {
    cfgOut.maxRangeCm = maxRange;
  }
  if (isfinite(liga) && isfinite(desliga) && liga > desliga &&
      desliga >= cfgOut.minRangeCm) {
    cfgOut.ligaCm = liga;
    cfgOut.desligaCm = desliga;
  }
  if (isfinite(lowPct) && lowPct >= 0 && lowPct <= 100) {
    cfgOut.lowLevelPct = static_cast<int>(lowPct);
  }
  if (isfinite(offline) && offline >= 30) {
    cfgOut.offlineAfterSec = static_cast<uint32_t>(offline);
  }
  if (isfinite(sensorFail) && sensorFail >= 30) {
    cfgOut.sensorFailAfterSec = static_cast<uint32_t>(sensorFail);
  }

  // Sanidade final (não aceita inversão de limites)
  if (cfgOut.ligaCm <= cfgOut.desligaCm) return false;

  out = cfgOut;
  return true;
}

bool FirebaseClient::postEvent(const String& type, const String& detail,
                               const String& ts) {
  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["type"]["stringValue"] = type;
  fields["detail"]["stringValue"] = detail;
  fields["ts"]["timestampValue"] = ts;
  String body;
  serializeJson(doc, body);
  String response;
  return request("POST", eventsUrl(), body, response, true);
}

bool FirebaseClient::fetchPendingCommand(DeviceCommand& out) {
  const String now = isoTimestampNow();
  if (now.isEmpty()) return false;

  String response;
  const String url = deviceUrl() +
                     "/commands?pageSize=10&orderBy=createdAt%20desc";
  if (!request("GET", url, "", response, true)) return false;

  JsonDocument doc;
  if (deserializeJson(doc, response) != DeserializationError::Ok) return false;

  JsonArray documents = doc["documents"].as<JsonArray>();
  if (documents.isNull()) return false;

  for (JsonObject document : documents) {
    JsonObject fields = document["fields"].as<JsonObject>();
    if (fields.isNull()) continue;
    const String status = fields["status"]["stringValue"].as<String>();
    if (status != "pending") continue;

    const String action = fields["action"]["stringValue"].as<String>();
    if (action != "pump_on" && action != "pump_off" && action != "auto") {
      continue;
    }

    String expires = fields["expiresAt"]["timestampValue"].as<String>();
    if (expires.length() > 19) expires = expires.substring(0, 19);
    const String nowShort = now.substring(0, 19);
    if (expires.length() == 19 && expires < nowShort) continue;  // expirado

    const String name = document["name"].as<String>();
    const int slash = name.lastIndexOf('/');
    out.id = slash >= 0 ? name.substring(slash + 1) : name;
    out.action = action;
    out.createdByName = fields["createdByName"]["stringValue"].as<String>();
    return out.id.length() > 0;
  }
  return false;
}

bool FirebaseClient::updateCommand(const String& id, const String& status,
                                   const String& detail) {
  const String ts = isoTimestampNow();
  if (ts.isEmpty()) return false;

  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["status"]["stringValue"] = status;
  fields["executedAt"]["timestampValue"] = ts;
  fields["detail"]["stringValue"] = detail;

  String body;
  serializeJson(doc, body);
  String response;
  const String url = deviceUrl() + "/commands/" + id +
                     "?updateMask.fieldPaths=status&"
                     "updateMask.fieldPaths=executedAt&"
                     "updateMask.fieldPaths=detail";
  return request("PATCH", url, body, response, true);
}

bool FirebaseClient::postAlert(const String& type, const String& severity,
                               const String& message, const String& ts) {
  JsonDocument doc;
  JsonObject fields = doc["fields"].to<JsonObject>();
  fields["type"]["stringValue"] = type;
  fields["severity"]["stringValue"] = severity;
  fields["message"]["stringValue"] = message;
  fields["deviceId"]["stringValue"] = creds.deviceId;
  fields["source"]["stringValue"] = "device";
  fields["ts"]["timestampValue"] = ts;
  fields["ack"]["booleanValue"] = false;
  String body;
  serializeJson(doc, body);
  String response;
  return request("POST", alertsUrl(), body, response, true);
}

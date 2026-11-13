/// Quando true, mostra detalhes técnicos (UID, documento, firmware, JSON/QR).
/// O build de usuário final usa false; o build interno pode usar
/// --dart-define=SHOW_TECHNICAL_TOOLS=true.
const bool kShowTechnicalTools =
    bool.fromEnvironment('SHOW_TECHNICAL_TOOLS', defaultValue: false);

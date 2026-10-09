/**
 * Jarvis direct Google Sheets bridge.
 * Deploy as a Web App bound to the spreadsheet you want Jarvis to access.
 *
 * Script Properties:
 *   API_TOKEN       required, long random secret also entered in Jarvis settings
 *   SPREADSHEET_ID  optional; set this if getActiveSpreadsheet() is unavailable in the Web App
 */

function doPost(e) {
  try {
    var request = JSON.parse((e && e.postData && e.postData.contents) || "{}");
    var expected = PropertiesService.getScriptProperties().getProperty("API_TOKEN");
    if (!expected || !constantTimeEqual_(String(request.token || ""), expected)) {
      return json_({ ok: false, error: "Unauthorized: token non valido o non configurato." });
    }

    var spreadsheet = getSpreadsheet_();
    if (!spreadsheet) {
      return json_({ ok: false, error: "Foglio non trovato. Imposta SPREADSHEET_ID nelle Script Properties." });
    }

    if (request.action === "inspect") return json_(inspect_(spreadsheet));
    if (request.action !== "apply") {
      return json_({ ok: false, error: "Azione non supportata." });
    }
    return json_(apply_(spreadsheet, request));
  } catch (error) {
    return json_({ ok: false, error: String(error && error.message ? error.message : error) });
  }
}

function doGet() {
  return json_({
    ok: true,
    service: "Jarvis Google Sheets bridge",
    hint: "Invia richieste POST autenticate da Jarvis."
  });
}

function getSpreadsheet_() {
  var id = PropertiesService.getScriptProperties().getProperty("SPREADSHEET_ID");
  if (id && id.trim()) return SpreadsheetApp.openById(id.trim());
  return SpreadsheetApp.getActiveSpreadsheet();
}

function inspect_(spreadsheet) {
  var sheets = spreadsheet.getSheets().map(function (sheet) {
    var lastRow = sheet.getLastRow();
    var lastColumn = sheet.getLastColumn();
    var columnCount = Math.min(Math.max(lastColumn, 1), 12);
    var firstCount = Math.min(lastRow, 8);
    var tailStart = Math.max(1, lastRow - 7);
    var firstRows = firstCount
      ? sheet.getRange(1, 1, firstCount, columnCount).getDisplayValues()
      : [];
    var lastRows = lastRow > firstCount
      ? sheet.getRange(tailStart, 1, lastRow - tailStart + 1, columnCount).getDisplayValues()
      : firstRows;

    return {
      name: sheet.getName(),
      lastRow: lastRow,
      lastColumn: lastColumn,
      previewColumns: columnCount,
      firstRowsStartAt: 1,
      firstRows: firstRows,
      lastRowsStartAt: lastRow > firstCount ? tailStart : 1,
      lastRows: lastRows
    };
  });

  return {
    ok: true,
    title: spreadsheet.getName(),
    spreadsheetId: spreadsheet.getId(),
    url: spreadsheet.getUrl(),
    sheets: sheets
  };
}

function apply_(spreadsheet, request) {
  var operation = String(request.operation || "");
  var sheetName = String(request.sheet || "").trim();

  if (operation === "create_sheet") {
    if (!sheetName) throw new Error("Nome della nuova scheda mancante.");
    if (sheetName.length > 100) throw new Error("Il nome della scheda supera 100 caratteri.");
    if (spreadsheet.getSheetByName(sheetName)) throw new Error("Esiste già una scheda chiamata " + sheetName + ".");
    spreadsheet.insertSheet(sheetName);
    return { ok: true, message: "Ho creato la scheda " + sheetName + ".", sheet: sheetName };
  }

  var sheet = spreadsheet.getSheetByName(sheetName);
  if (!sheet) throw new Error("Scheda non trovata: " + (sheetName || "(nome vuoto)"));

  if (operation === "append_rows") {
    var rows = normalizeMatrix_(request.values, 2000);
    var startRow = Math.max(1, sheet.getLastRow() + 1);
    var width = rows[0].length;
    sheet.getRange(startRow, 1, rows.length, width).setValues(normalizeFormulas_(rows, request.allow_formulas === true));
    var rangeText = startRow + ":" + (startRow + rows.length - 1);
    return { ok: true, message: "Aggiunte " + rows.length + " righe alla scheda " + sheetName + ".", sheet: sheetName, affectedRows: rangeText };
  }

  var a1 = String(request.range || "").trim();
  if (!a1) throw new Error("Intervallo A1 mancante.");
  var range = sheet.getRange(a1);
  if (range.getNumRows() * range.getNumColumns() > 2000) {
    throw new Error("Per sicurezza, una singola operazione può modificare al massimo 2.000 celle.");
  }

  if (operation === "update_range") {
    var values = normalizeMatrix_(request.values, 2000);
    if (values.length !== range.getNumRows() || values[0].length !== range.getNumColumns()) {
      throw new Error("Le dimensioni dei dati non corrispondono all'intervallo " + a1 + ".");
    }
    range.setValues(normalizeFormulas_(values, request.allow_formulas === true));
    return { ok: true, message: "Aggiornato " + sheetName + "!" + a1 + ".", sheet: sheetName, range: a1 };
  }

  if (operation === "clear_range") {
    if (range.getNumRows() * range.getNumColumns() > 5000) {
      throw new Error("Per sicurezza, non posso cancellare più di 5.000 celle in una sola operazione.");
    }
    range.clearContent();
    return { ok: true, message: "Svuotato " + sheetName + "!" + a1 + ".", sheet: sheetName, range: a1 };
  }

  if (operation === "sort_range") {
    var sortColumn = Number(request.sort_column || 1);
    if (!Number.isInteger(sortColumn) || sortColumn < 1 || sortColumn > range.getNumColumns()) {
      throw new Error("La colonna di ordinamento deve essere relativa all'intervallo e partire da 1.");
    }
    range.sort({ column: range.getColumn() + sortColumn - 1, ascending: request.ascending !== false });
    return { ok: true, message: "Ordinato " + sheetName + "!" + a1 + ".", sheet: sheetName, range: a1 };
  }

  throw new Error("Operazione non supportata: " + operation);
}

function normalizeMatrix_(value, maxCells) {
  if (!Array.isArray(value) || value.length === 0 || !Array.isArray(value[0]) || value[0].length === 0) {
    throw new Error("Matrice di dati vuota o non valida.");
  }
  var width = value[0].length;
  if (value.length * width > maxCells) throw new Error("La modifica supera il limite di celle consentito.");
  value.forEach(function (row) {
    if (!Array.isArray(row) || row.length !== width) throw new Error("Tutte le righe devono avere lo stesso numero di colonne.");
    row.forEach(function (cell) {
      if (typeof cell !== "string" && typeof cell !== "number" && typeof cell !== "boolean" && cell !== null) {
        throw new Error("Tipo di cella non supportato.");
      }
    });
  });
  return value;
}

function normalizeFormulas_(matrix, allowFormulas) {
  return matrix.map(function (row) {
    return row.map(function (value) {
      if (typeof value !== "string") return value;
      if (value.charAt(0) === "=" && !allowFormulas) return "'" + value;
      if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value)) return Number(value);
      if (/^(true|false)$/i.test(value)) return value.toLowerCase() === "true";
      return value;
    });
  });
}

function constantTimeEqual_(a, b) {
  if (a.length !== b.length) return false;
  var result = 0;
  for (var i = 0; i < a.length; i++) result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return result === 0;
}

function json_(value) {
  return ContentService.createTextOutput(JSON.stringify(value))
    .setMimeType(ContentService.MimeType.JSON);
}

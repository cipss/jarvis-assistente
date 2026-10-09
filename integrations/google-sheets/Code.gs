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
    if (request.action === "sync_nhl_results") return json_(syncNHLResults_(spreadsheet, request));
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

function syncNHLResults_(spreadsheet, request) {
  var sheetName = String(request.sheet || "Risultati_Partite_NHL").trim();
  if (sheetName !== "Risultati_Partite_NHL") {
    return { ok: false, error: "Per la sincronizzazione NHL la scheda consentita è Risultati_Partite_NHL." };
  }
  var sheet = spreadsheet.getSheetByName(sheetName);
  if (!sheet) return { ok: false, error: "Scheda non trovata: " + sheetName + "." };

  var games = request.games;
  if (!Array.isArray(games) || games.length === 0 || games.length > 100) {
    return { ok: false, error: "Il payload NHL è vuoto o supera 100 partite." };
  }
  var map = request.column_map || {};
  var lastColumn = Math.max(sheet.getLastColumn(), 1);
  var headers = sheet.getRange(1, 1, 1, lastColumn).getDisplayValues()[0];

  var columns = {
    date: Number(map.date || 0),
    away_team: Number(map.away_team || 0),
    home_team: Number(map.home_team || 0),
    away_score: Number(map.away_score || 0),
    home_score: Number(map.home_score || 0),
    score: Number(map.score || 0),
    game_id: Number(map.game_id || 0)
  };
  if (!columns.date || !columns.away_team || !columns.home_team) {
    return { ok: false, error: "Mappatura incompleta: servono data, squadra ospite e squadra di casa." };
  }

  var hasScorePair = columns.away_score > 0 && columns.home_score > 0;
  var hasSingleScore = columns.score > 0;
  if (!hasScorePair && !hasSingleScore) {
    return { ok: false, error: "Mappatura punteggio incompleta: servono le due colonne dei gol oppure una colonna Risultato/Punteggio." };
  }
  if (hasScorePair && columns.away_score === columns.home_score) {
    return { ok: false, error: "Le colonne dei gol in casa e in trasferta devono essere diverse." };
  }
  if (hasSingleScore && !hasScorePair && !["away-home", "home-away"].includes(String(map.score_order || "away-home"))) {
    return { ok: false, error: "Ordine del punteggio non valido." };
  }

  var requiredFields = ["date", "away_team", "home_team"];
  if (hasScorePair) requiredFields.push("away_score", "home_score");
  else requiredFields.push("score");
  requiredFields.forEach(function (field) {
    var index = columns[field];
    if (!Number.isInteger(index) || index < 1 || index > headers.length || !headerMatchesNHLField_(headers[index - 1], field)) {
      throw new Error("La colonna " + index + " ('" + String(headers[index - 1] || "") + "') non è riconoscibile come " + field + ". Controlla le intestazioni di Risultati_Partite_NHL.");
    }
  });
  if (columns.game_id > 0 && (!Number.isInteger(columns.game_id) || columns.game_id > headers.length ||
      !headerMatchesNHLField_(headers[columns.game_id - 1], "game_id"))) {
    return { ok: false, error: "La colonna scelta per l'ID partita non sembra contenere un ID NHL." };
  }

  var usedColumns = [columns.date, columns.away_team, columns.home_team];
  if (hasScorePair) usedColumns.push(columns.away_score, columns.home_score);
  else usedColumns.push(columns.score);
  if (new Set(usedColumns).size !== usedColumns.length) {
    return { ok: false, error: "Due campi NHL sono stati associati alla stessa colonna." };
  }

  var updated = 0;
  var inserted = 0;
  var alreadyCorrect = 0;
  var spreadsheetLastColumn = Math.max(sheet.getLastColumn(), Math.max.apply(null, Object.keys(columns).map(function (key) { return columns[key]; })));
  if (sheet.getMaxColumns() < spreadsheetLastColumn) {
    sheet.insertColumnsAfter(sheet.getMaxColumns(), spreadsheetLastColumn - sheet.getMaxColumns());
  }

  games.forEach(function (game) {
    var id = String(game.game_id || "").trim();
    var date = String(game.date || "").trim();
    var awayName = String(game.away_team || "").trim();
    var awayAbbrev = String(game.away_abbrev || "").trim();
    var homeName = String(game.home_team || "").trim();
    var homeAbbrev = String(game.home_abbrev || "").trim();
    var awayScore = Number(game.away_score);
    var homeScore = Number(game.home_score);
    if (!id || !date || !awayName || !homeName ||
        !Number.isInteger(awayScore) || !Number.isInteger(homeScore)) {
      throw new Error("Partita NHL incompleta o non valida nel payload.");
    }

    var rowNumber = findNHLGameRow_(sheet, columns, {
      id: id, date: date,
      awayName: awayName, awayAbbrev: awayAbbrev,
      homeName: homeName, homeAbbrev: homeAbbrev
    }, spreadsheet);

    if (rowNumber > 0) {
      var beforeAway = hasScorePair ? sheet.getRange(rowNumber, columns.away_score).getValue() : null;
      var beforeHome = hasScorePair ? sheet.getRange(rowNumber, columns.home_score).getValue() : null;
      var beforeSingle = hasSingleScore ? sheet.getRange(rowNumber, columns.score).getDisplayValue() : "";
      if (hasScorePair) {
        sheet.getRange(rowNumber, columns.away_score).setValue(awayScore);
        sheet.getRange(rowNumber, columns.home_score).setValue(homeScore);
      } else {
        var scoreText = String(map.score_order || "away-home") === "home-away"
          ? homeScore + "-" + awayScore
          : awayScore + "-" + homeScore;
        sheet.getRange(rowNumber, columns.score).setValue(scoreText);
      }
      if (columns.game_id > 0) sheet.getRange(rowNumber, columns.game_id).setValue(Number(id));
      var wasCorrect = hasScorePair
        ? Number(beforeAway) === awayScore && Number(beforeHome) === homeScore
        : String(beforeSingle).replace(/\s/g, "") === String(hasSingleScore
            ? (String(map.score_order || "away-home") === "home-away" ? homeScore + "-" + awayScore : awayScore + "-" + homeScore)
            : "");
      if (wasCorrect) alreadyCorrect++; else updated++;
    } else {
      var row = Array(spreadsheetLastColumn).fill("");
      row[columns.date - 1] = date;
      row[columns.away_team - 1] = teamValueForNHLHeader_(headers[columns.away_team - 1], awayName, awayAbbrev);
      row[columns.home_team - 1] = teamValueForNHLHeader_(headers[columns.home_team - 1], homeName, homeAbbrev);
      if (hasScorePair) {
        row[columns.away_score - 1] = awayScore;
        row[columns.home_score - 1] = homeScore;
      } else {
        row[columns.score - 1] = String(map.score_order || "away-home") === "home-away"
          ? homeScore + "-" + awayScore : awayScore + "-" + homeScore;
      }
      if (columns.game_id > 0) row[columns.game_id - 1] = Number(id);
      var newRowNumber = sheet.getLastRow() + 1;
      sheet.getRange(newRowNumber, 1, 1, row.length).setValues([row]);
      inserted++;
    }
  });

  return {
    ok: true,
    message: "Risultati NHL sincronizzati in " + sheetName + ": " + updated + " partite aggiornate, " +
      inserted + " aggiunte, " + alreadyCorrect + " già corrette. Altre schede e colonne non sono state modificate.",
    sheet: sheetName,
    updated: updated,
    inserted: inserted,
    unchanged: alreadyCorrect
  };
}

function headerMatchesNHLField_(header, field) {
  var value = normalizeNHLText_(header);
  var aliases = {
    date: ["date", "gamedate", "data", "datapartita", "datagara", "giorno", "dataincontro", "gameday"],
    away_team: ["away", "awayteam", "squadraospite", "ospite", "trasferta", "teamaway", "teamospite", "squadratrasferta", "teamtrasferta", "visitingteam", "teamvisitor", "squadrafuoricasa"],
    home_team: ["home", "hometeam", "squadracasa", "casa", "teamhome", "squadradicasa", "squadra dicasa", "hometeamname"],
    away_score: ["awayscore", "awaygoals", "scoreaway", "punteggioospite", "golospite", "retiospite", "goltrasferta", "retitrasferta", "punteggioaway", "punteggiotrasferta", "scorevisitor"],
    home_score: ["homescore", "homegoals", "scorehome", "punteggiocasa", "golcasa", "reticasa", "punteggiohome"],
    score: ["risultato", "punteggio", "finalscore", "risultatofinale", "score"],
    game_id: ["gameid", "nhlgameid", "idpartita", "idnhl", "idgara", "matchid", "idmatch"]
  };
  var options = aliases[field] || [];
  if (!value) return false;
  if (field === "score" && /(away|home|ospite|trasferta|casa|gol|reti)/.test(value)) return false;
  return options.some(function (alias) {
    var normalized = normalizeNHLText_(alias);
    return value === normalized || value.indexOf(normalized) !== -1;
  });
}

function normalizeNHLText_(value) {
  return String(value == null ? "" : value)
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]/g, "");
}

function findNHLGameRow_(sheet, columns, game, spreadsheet) {
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return 0;
  var lastColumn = Math.max(sheet.getLastColumn(), 1);
  var rows = sheet.getRange(2, 1, lastRow - 1, lastColumn).getValues();
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    if (columns.game_id > 0 && String(row[columns.game_id - 1] || "").trim() === game.id) return i + 2;
    if (nhlDateMatches_(row[columns.date - 1], game.date, spreadsheet) &&
        nhlTeamMatches_(row[columns.away_team - 1], game.awayName, game.awayAbbrev) &&
        nhlTeamMatches_(row[columns.home_team - 1], game.homeName, game.homeAbbrev)) {
      return i + 2;
    }
  }
  return 0;
}

function nhlDateMatches_(value, expectedDate, spreadsheet) {
  if (value instanceof Date && !isNaN(value.getTime())) {
    return Utilities.formatDate(value, spreadsheet.getSpreadsheetTimeZone(), "yyyy-MM-dd") === expectedDate;
  }
  var text = String(value == null ? "" : value).trim();
  if (text === expectedDate || text.indexOf(expectedDate) === 0) return true;
  var iso = text.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})/);
  if (iso) return iso[1] + "-" + ("0" + iso[2]).slice(-2) + "-" + ("0" + iso[3]).slice(-2) === expectedDate;
  var local = text.match(/^(\d{1,2})[/. -](\d{1,2})[/. -](\d{4})$/);
  if (local) {
    var locale = String(spreadsheet.getSpreadsheetLocale() || "").toLowerCase();
    var first = Number(local[1]), second = Number(local[2]), year = Number(local[3]);
    var day, month;
    if (locale.indexOf("it") === 0 || first > 12) { day = first; month = second; }
    else { month = first; day = second; }
    return year + "-" + ("0" + month).slice(-2) + "-" + ("0" + day).slice(-2) === expectedDate;
  }
  return false;
}

function nhlTeamMatches_(cell, teamName, abbreviation) {
  var value = normalizeNHLText_(cell);
  if (!value) return false;
  var candidates = [teamName, abbreviation].map(normalizeNHLText_).filter(function (item) { return item.length > 0; });
  return candidates.some(function (candidate) {
    return value === candidate || (candidate.length >= 3 && value.indexOf(candidate) !== -1) ||
      (value.length >= 4 && candidate.indexOf(value) !== -1);
  });
}

function teamValueForNHLHeader_(header, teamName, abbreviation) {
  var value = normalizeNHLText_(header);
  if (/(abbrev|sigla|codice|code|abbr)/.test(value)) return abbreviation || teamName;
  return teamName || abbreviation;
}

function inspect_(spreadsheet) {
  var sheets = spreadsheet.getSheets()
    .filter(function (sheet) { return !sheet.isSheetHidden() && sheet.getName().indexOf("_Jarvis_") !== 0; })
    .map(function (sheet) {
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

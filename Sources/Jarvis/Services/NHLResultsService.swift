import Foundation

/// Reads completed NHL regular-season/playoff scores from the public NHL scoreboard API.
struct NHLResultsService {
    struct FinalGame: Sendable {
        let id: Int
        let date: String
        let startTimeUTC: String
        let awayName: String
        let awayAbbrev: String
        let awayScore: Int
        let homeName: String
        let homeAbbrev: String
        let homeScore: Int
        let gameState: String

        var dictionary: [String: Any] {
            [
                "game_id": id,
                "date": date,
                "start_time_utc": startTimeUTC,
                "away_team": awayName,
                "away_abbrev": awayAbbrev,
                "away_score": awayScore,
                "home_team": homeName,
                "home_abbrev": homeAbbrev,
                "home_score": homeScore,
                "state": gameState
            ]
        }

        var summary: String {
            "\(date): \(awayAbbrev) \(awayScore)–\(homeScore) \(homeAbbrev) (ID \(id))"
        }
    }

    enum ResultsError: LocalizedError {
        case invalidResponse
        case http(Int, String)
        case missingDate

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "L'API NHL ha restituito una risposta non valida."
            case .http(let status, let detail):
                return "API NHL HTTP \(status): \(detail)"
            case .missingDate:
                return "Non riesco a determinare le date del tabellone NHL."
            }
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 25
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// Fetches the NHL's current scoreboard plus the immediately preceding NHL date.
    /// The previous date is included because games commonly finish after midnight in Italy.
    static func fetchLatestFinalGames() async throws -> [FinalGame] {
        let current = try await scoreboard(path: "now")
        guard let currentDate = current["currentDate"] as? String, !currentDate.isEmpty else {
            throw ResultsError.missingDate
        }

        var rawGames = current["games"] as? [[String: Any]] ?? []
        if let previousDate = current["prevDate"] as? String,
           !previousDate.isEmpty, previousDate != currentDate {
            let previous = try await scoreboard(path: previousDate)
            rawGames.append(contentsOf: previous["games"] as? [[String: Any]] ?? [])
        }

        var byID: [Int: FinalGame] = [:]
        for raw in rawGames {
            guard let game = decodeFinalGame(raw) else { continue }
            byID[game.id] = game
        }

        return byID.values.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.startTimeUTC < $1.startTimeUTC
        }
    }

    /// Builds a trusted-source context for Gemini. The model maps columns, but never invents scores.
    static func sourceContext(for games: [FinalGame]) throws -> String {
        let payload = try JSONSerialization.data(
            withJSONObject: games.map(\.dictionary),
            options: [.prettyPrinted, .sortedKeys]
        )
        let json = String(data: payload, encoding: .utf8) ?? "[]"
        let summaries = games.map(\.summary).joined(separator: "\n")

        return """
        Richiesta di sincronizzazione risultati NHL.
        Fonte dei risultati: API pubblica ufficiale NHL, letta direttamente da Jarvis. Usa esclusivamente i punteggi nel payload JSON qui sotto; non inventare, correggere o completare risultati.
        Destinazione obbligatoria: scheda Risultati_Partite_NHL del documento HOCKEY.
        Aggiorna i punteggi delle partite già presenti quando puoi identificare senza ambiguità la riga; aggiungi solo le partite concluse che non sono già presenti. Non toccare Dashboard_Analisi, Rating_Squadre, Registro_Scommesse, quote, stake, pronostici o altre colonne.
        Seleziona la mappatura delle colonne usando le intestazioni e gli esempi reali dell'anteprima. Se non riesci a distinguere data, squadra in trasferta, squadra in casa e colonne del risultato, chiedi chiarimenti invece di scrivere dati in colonne ipotetiche.
        Per ogni partita considera il game_id stabile. I punteggi sono nell'ordine squadra in trasferta e squadra di casa.
        
        Riepilogo:
        \(summaries)

        Payload JSON autorevole:
        \(json)
        """
    }

    private static func scoreboard(path: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://api-web.nhle.com/v1/score/\(path)") else {
            throw ResultsError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Jarvis-Mac/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ResultsError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "(risposta vuota)"
            throw ResultsError.http(http.statusCode, String(detail.prefix(240)))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ResultsError.invalidResponse
        }
        return root
    }

    private static func decodeFinalGame(_ raw: [String: Any]) -> FinalGame? {
        guard let id = raw["id"] as? Int,
              let date = raw["gameDate"] as? String,
              let away = raw["awayTeam"] as? [String: Any],
              let home = raw["homeTeam"] as? [String: Any],
              let awayScore = away["score"] as? Int,
              let homeScore = home["score"] as? Int else { return nil }

        let state = (raw["gameState"] as? String ?? "").uppercased()
        let finalStates: Set<String> = ["OFF", "FINAL", "FINAL/OT", "FINAL/SO", "FINAL_OT", "FINAL_SO"]
        guard finalStates.contains(state) else { return nil }

        // Do not import preseason results into the regular-season betting log.
        if let gameType = raw["gameType"] as? Int, gameType == 1 { return nil }

        let awayAbbrev = away["abbrev"] as? String ?? ""
        let homeAbbrev = home["abbrev"] as? String ?? ""
        guard !awayAbbrev.isEmpty, !homeAbbrev.isEmpty else { return nil }

        let awayName = ((away["name"] as? [String: Any])?["default"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? awayAbbrev
        let homeName = ((home["name"] as? [String: Any])?["default"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? homeAbbrev

        return FinalGame(
            id: id,
            date: date,
            startTimeUTC: raw["startTimeUTC"] as? String ?? "",
            awayName: awayName,
            awayAbbrev: awayAbbrev,
            awayScore: awayScore,
            homeName: homeName,
            homeAbbrev: homeAbbrev,
            homeScore: homeScore,
            gameState: state
        )
    }
}

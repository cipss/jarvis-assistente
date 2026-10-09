# Collegare Jarvis direttamente a Google Sheets (Gemini)

Questa integrazione evita di avviare Claude Code o Codex per le operazioni sui fogli. Gemini riceve la richiesta, esamina l'anteprima dei dati e prepara un'operazione strutturata; Jarvis la applica tramite questa Web App di Google Apps Script.

## 1. Crea la Web App collegata al foglio

1. Apri il foglio Google che Jarvis deve modificare.
2. Vai su **Estensioni → Apps Script**.
3. Sostituisci il contenuto di `Code.gs` con il file `Code.gs` presente in questa cartella.
4. In **Impostazioni progetto → Proprietà script**, aggiungi:
   - `API_TOKEN`: una stringa segreta lunga e casuale.
   - `SPREADSHEET_ID` (facoltativa): ID del foglio, se lo script non riesce a rilevare il foglio associato.
5. Premi **Distribuisci → Nuova distribuzione → App web**.
   - Esegui come: **te stesso**.
   - Chi può accedere: **chiunque**, se disponibile per il tuo account. L'endpoint verifica comunque il token segreto in ogni richiesta.
6. Distribuisci e copia l'URL che termina in `/exec`.

Genera un token casuale, ad esempio da Terminale:

```bash
openssl rand -hex 32
```

Usa lo stesso valore sia nella proprietà script `API_TOKEN` sia nelle impostazioni Jarvis. Non condividere il token.

## 2. Configura Jarvis

1. Apri **Jarvis → Impostazioni → Cervello**.
2. Nella sezione **Google Sheets · esecuzione diretta con Gemini**, incolla l'URL `/exec`.
3. Incolla lo stesso token salvato nella proprietà script `API_TOKEN` e premi **Salva**.
4. Premi **Testa connessione**. Jarvis deve mostrare il nome del documento e le schede presenti.

## 3. Prova

Puoi dire, ad esempio:
- «Aggiungi queste righe al foglio Google…»
- «Ordina la scheda Risultati per data dal più recente al più vecchio».
- «Aggiorna le celle B2:D4 della scheda Riepilogo con questi valori…»
- «Quanti record sono presenti nella scheda Risultati?»

Le richieste riconosciute come operazioni sui fogli vengono instradate a Gemini soltanto. Se Gemini non sa quale scheda o intervallo usare, Jarvis ti chiede un chiarimento invece di avviare un agente CLI.

## Operazioni supportate

- Lettura di un'anteprima del documento: prime e ultime righe di ciascuna scheda (max 12 colonne).
- Aggiunta di righe in fondo a una scheda.
- Aggiornamento di un intervallo A1 esistente.
- Svuotamento dei contenuti di un intervallo, soltanto se richiesto.
- Ordinamento di un intervallo.
- Creazione di una nuova scheda.

Per sicurezza non sono supportate l'eliminazione di schede e la cancellazione di interi documenti. Una singola operazione modifica al massimo 2.000 celle. Le stringhe che iniziano con `=` sono trattate come testo, a meno che tu non chieda esplicitamente di inserire una formula.

## Sicurezza e limiti

- Il token viene inviato nel corpo HTTPS, mai nell'URL, e Jarvis lo conserva nella cartella privata `Application Support/Jarvis/secrets`.
- La Web App è configurata per eseguire come proprietario: il token è quindi una credenziale sensibile. Non inserirlo nel codice sorgente, nei fogli o nei log.
- Le celle del foglio sono dati, non istruzioni per Gemini; il piano viene vincolato a un elenco limitato di operazioni.
- Se Google Workspace non permette la distribuzione accessibile a chiunque, questa modalità webhook non funziona così com'è: serve un'integrazione OAuth Google.
- Dopo aver modificato il codice Apps Script, crea una **nuova versione della distribuzione** oppure aggiorna quella esistente per rendere attive le modifiche.

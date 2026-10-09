# Jarvis, assistente personale

Jarvis è un assistente vocale per Mac con **Gemini come cervello principale** e [Claude Code](https://claude.com/claude-code) / [Codex](https://github.com/openai/codex) come agenti esecutori. Lo chiami per nome o batti due volte le mani, gli dici cosa ti serve e lui apre una sessione dell'agente scelto (Claude Code o Codex) in background. Mentre lavora ti aggiorna a voce. Quando ha finito ti dice cosa ha fatto e ti apre il risultato.

Parla italiano, con la voce di [Fish Audio](https://fish.audio).

## Cosa fa

- **Si attiva a voce o con le mani.** Dici «Jarvis» e poi la richiesta, oppure batti due volte le mani e parli. Risponde quando hai finito di parlare. In alternativa tieni premuto ⇧⌘Spazio, parli e rilasci.
- **Puoi interromperlo.** Se gli parli sopra mentre sta parlando, si ferma e ti ascolta.
- **Lavora in background.** Gemini interpreta ogni richiesta e decide l'azione e l'agente. Le attività operative generiche vengono eseguite da Claude Code o Codex; le richieste Google Sheets possono invece usare l'integrazione diretta Gemini + Apps Script senza login dell'agente CLI.
- **Ti aggiorna mentre lavora**, non solo alla fine: una frase breve ogni tanto su cosa sta facendo.
- **Ti mostra le sessioni.** In alto a destra vedi le sessioni aperte, con lo stato di ognuna. «Pulisci» toglie quelle finite e azzera la conversazione.
- **Apre il risultato.** Se una sessione ha costruito una pagina o un sito, Jarvis lo apre da solo.
- **Non ripete il lavoro.** Se la risposta è già nel risultato di una sessione recente te la dice subito. Se la richiesta continua un lavoro di pochi minuti prima, riprende quella sessione invece di aprirne una nuova.
- **Si ricorda le tue preferenze.** «Ricordati che…», «d'ora in poi…»: le tiene e le passa a ogni sessione.

## Cosa serve

- Un Mac con **macOS 15** o successivo (con macOS 26 il pannello usa l'effetto vetro).
- **Xcode 26**, oppure i Command Line Tools con Swift 6, per compilare l'app.
- **Una chiave Gemini API**, configurabile in Impostazioni › Agenti. Il modello predefinito è `gemini-3.8-flash`.
- **Claude Code** e/o [Codex](https://github.com/openai/codex) per eseguire le attività operative.
- Una **chiave API di Fish Audio** per la voce. È facoltativa: senza chiave Jarvis usa la voce di macOS.
- La **dettatura in italiano scaricata sul Mac**: Impostazioni di Sistema › Tastiera › Dettatura. Serve per riconoscere il nome senza mandare audio a nessun server.

## Installazione

```bash
git clone https://github.com/riccardo-belli/jarvis-assistente-personale.git
cd jarvis-assistente-personale
./scripts/build-app.sh
open build/Jarvis.app
```

Se vuoi, sposta `build/Jarvis.app` nella cartella Applicazioni.

Al primo avvio una configurazione guidata chiede il permesso per il microfono e per il riconoscimento vocale, la chiave di Fish Audio e la cartella dei tuoi progetti. Jarvis compare come icona nella barra dei menu.

L'app è firmata in locale, senza un certificato Apple. Se la ricompili, macOS ti chiederà di nuovo il permesso per il microfono: è normale.

## Come si usa

Qualche esempio da dire dopo «Jarvis»:

- «nel progetto sito fammi una landing page per il nuovo prodotto»
- «a che punto sei?»
- «aggiungi anche il footer» (continua la sessione di prima)
- «fermati»
- «ricordati che i siti li voglio sempre in italiano»

Esc annulla quello che stai dicendo. ⇧⌘O mostra o nasconde il pannello delle sessioni. Le scorciatoie si cambiano nelle Impostazioni.

**Le richieste che non riguardano un progetto** (mail, calendario, domande) partono da una cartella che scegli in Impostazioni › Comportamento. Conviene indicare la cartella delle tue note, con un `CLAUDE.md` che dice quali strumenti usi. Così Claude Code sa, per esempio, quale casella di posta leggere.

## Google Sheets diretto

Per modificare un foglio Google senza passare da Claude Code o Codex, configura la Web App Apps Script descritta in [integrations/google-sheets/README.md](integrations/google-sheets/README.md). Gemini prepara un piano a partire da una breve anteprima dei dati e Jarvis applica l'operazione tramite l'endpoint configurato. La chiave e il token si impostano in Impostazioni → Cervello.

## Privacy

- Il microfono resta acceso per sentire il nome, ma **il riconoscimento avviene sul Mac**: l'audio non va a nessun server. Nei log finisce solo il comando, mai quello che si dice nella stanza.
- Il testo delle richieste va a Gemini per l'orchestrazione. Le attività operative vengono poi passate a Claude Code o Codex. Le risposte da leggere a voce vanno a Fish Audio.
- La chiave di Fish Audio sta in `~/Library/Application Support/Jarvis/secrets/`, leggibile solo dal tuo utente. Nel codice non ci sono chiavi.
- La chiave Gemini viene salvata localmente nella cartella privata di Jarvis con permessi 0600. Le chiavi `ANTHROPIC_API_KEY` e `OPENAI_API_KEY` non vengono inoltrate dal processo di orchestrazione.

## Crediti

Jarvis nasce da [VoiceMode](https://github.com/albertshiney/VoiceMode) di Albert Shiney. È stato tradotto in italiano e ampliato con l'attivazione a voce e con le mani, la voce di Fish Audio, gli aggiornamenti mentre lavora, le interruzioni e l'apertura dei risultati.

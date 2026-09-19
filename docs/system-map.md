# Turbo Streamer / Turbo Receiver — Mappa del sistema

Review in sola lettura del codice a `0ee9b2a` (v3.0 build 72), 19 settembre 2026. Ogni affermazione è stata verificata leggendo il sorgente; i riferimenti `file:riga` sono quelli del commit. Le criticità sono divise in **BUG** (comportamento diverso da quello che l'interfaccia promette, verificato) e **SCELTA** (deliberata, discutibile ma non rotta).

Come leggere: la sezione 0 è l'architettura in una pagina. La sezione 1 ricostruisce ogni flusso utente nell'ordine: cosa vede l'utente → stati → codice → chiamate → server → risposta → stato → UI, con il perché e le criticità. Le sezioni 2–5 raccolgono algoritmi, bug, debito e aree delicate.

---

## 0. Architettura in una pagina

### Componenti e processi

| Componente | Cos'è | Processi figli che lancia |
|---|---|---|
| **Turbo Streamer** (`Sources/Streamer`, SwiftUI, macOS 13+, no sandbox) | Cattura una sorgente, codifica, invia a una destinazione. Cuore: `StreamManager` (1763 righe, `@MainActor`). | `ffmpeg` (uno per stream, più uno per slate e uno per anteprima), `turbo-net`, opzionale `mediamtx` + `ffmpeg`+`ndi-sender` per il LAN publish |
| **Turbo Receiver** (`receiver/Sources/Receiver`) | Riceve uno o più feed e li ridistribuisce sulla LAN. Cuore: `ServerManager` (500 righe). | `mediamtx`, `turbo-net`, per ogni feed NDI `ffmpeg`+`ndi-sender` |
| **turbolink** (`link-server/index.js`, Node senza dipendenze, porta 8814 dietro nginx) | Rendezvous per il pairing, coordinamento del trasporto, auth del relay, chiavi Tailscale, manifest e zip degli aggiornamenti | — |
| **turborelay** (MediaMTX 1.21 sul VPS, unit `turborelay`) | Relay pubblico SRT 8890/UDP + RTMP 1935/TCP; ogni publish/read chiede a turbolink `/v1/auth` | — |
| **turbo-net** (`net/turbo-net/main.go`, tsnet) | Nodo Tailscale in user space embedded nelle app; tunnel UDP a comando | — |
| **ndi-sender** (`receiver/ndi/ndi-sender.c`) | Legge raw UYVY422 + s16le da due FIFO e li pubblica come sorgente NDI | — |

Le app **non toccano mai i pixel**: orchestrano processi esterni e leggono i loro log. È il modello di isolamento scelto ovunque (un crash di ffmpeg non porta giù l'app).

### Porte fisse

| Porta | Chi | Uso |
|---|---|---|
| 1935/tcp | Receiver, Streamer-LAN, relay | RTMP |
| 8554/tcp | Receiver, Streamer-LAN | RTSP (OBS) |
| 8888/tcp | Receiver, Streamer-LAN | HLS fmp4 (browser) |
| 8890/udp | Receiver, Streamer-LAN, relay | SRT |
| 9997/tcp (loopback) | tutti i MediaMTX | API di controllo |
| 8814/tcp (loopback, nginx→443) | turbolink | HTTP |

Receiver e Streamer-in-modalità-LAN usano **le stesse porte** (`LocalServer.swift:7-9` = `receiver/Models.swift:57-63`): non possono girare sullo stesso Mac contemporaneamente. SCELTA dichiarata nel codice.

### Stato su disco

| Dove | Cosa | Chi |
|---|---|---|
| UserDefaults `TurboStreamer.savedConfigs.v1` | array `StreamConfig` JSON | Streamer, ad ogni modifica (`configs.didSet`) |
| UserDefaults `TurboStreamer.savedProfiles.v1`, `alertWebhookURL.v1`, `localPublish`, `didOnboard`, `linkBase` | profili, webhook, flag | Streamer |
| UserDefaults `TurboReceiver.keys.v1`, `didOnboard`, `linkBase` | feed `IngestKey` JSON | Receiver |
| `~/Documents/TurboStreamer Logs/<data>_<nome>.log` + `preview-debug.log` | log per run, log anteprima | Streamer |
| `~/Documents/TurboStreamer Recordings/*.ts` | safety recording | Streamer |
| `~/Library/Caches/TurboStreamer/` | `latest_<id>.jpg` (frame per slate), `overlay_<id>.txt`, `preview_<id>.jpg`, `previewovl_<id>.txt`, `local-mediamtx.yml`, `ndi/*.raw` (FIFO) | Streamer |
| `~/Library/Caches/TurboReceiver/mediamtx.yml`, `ndi/` | config MediaMTX, FIFO | Receiver |
| `~/Library/Application Support/<App>/tailnet/` | identità del nodo Tailscale | entrambe |
| `/opt/turbolink/data/sessions.json` (0600) | sessioni di pairing | server |
| `/opt/turbolink/downloads/` | `appcast.json`, zip delle app | server |

### Contratti HTTP con turbolink (`link-server/index.js`)

| Metodo e path | Chi chiama | Autenticazione | Corpo → Risposta | Riga |
|---|---|---|---|---|
| `POST /v1/session` | Streamer "Create code" | nessuna | `{name}` → `{code, secret, expiresAt, relay{srtURL, streamKey, rtmpURL, rtmpKey, latencyMs, path, host, ports}}` | 173 |
| `POST /v1/session/:code/join` | Receiver "Link" | il codice è la capability | `{label, protocol, host, port, streamKey, latencyMs}` → `{ok, receiverId, sessionName, relay{source, sourceRTMP, path, latencyMs}}` | 260 |
| `GET /v1/session/:code` | Streamer, poll 3 s nel popover | header `x-secret` | → `{code, name, receivers[], transport, relay}` | 288 |
| `POST /v1/session/:code/transport` | Streamer dopo la scala | `x-secret` | `{mode: direct/relay-srt/relay-rtmp, detail}` → `{ok}` | 214 |
| `GET /v1/session/:code/transport` | Receiver, poll 3 s | **solo codice** | → `{mode, detail, at}` | 229 |
| `DELETE /v1/session/:code` | (mai chiamata dalle app: `LinkClient.close` esiste ma non è usato) | `x-secret` | | 301 |
| `POST /v1/auth` | MediaMTX relay via localhost | rifiutata se presente `X-Real-IP`/`X-Forwarded-For` (cioè se arriva da nginx) | `{action, path, password, ip}` → 200/401 | 242 |
| `POST /v1/tailnet/key` | entrambe le app all'avvio | nessuna | `{app, host}` → `{authKey}` (chiave Tailscale monouso, effimera, taggata) | 189 |
| `GET /v1/appcast`, `GET /downloads/<x>.zip` | `Updater` | nessuna | manifest / zip (path sanificato, solo `.zip`) | 152, 162 |
| `GET /health` | monitor | | | 147 |

Persistenza: `sessions.json` riscritto per intero a ogni mutazione; TTL 24 h dall'**ultimo uso** (`sweep`, riga 99), toccato da poll, join, auth, transport.

### Codice duplicato tra le due app

`TurboNet.swift` e `Updater.swift` sono **byte-identici** nei due target; `RootView.swift` differisce solo per nomi; `LinkClient.isLANAddress`, il lettore di interfacce (`refreshAddresses`), la config MediaMTX, il bridge NDI (`LocalServer` ↔ `NDIBridge`+`ServerManager`) e `WobblingIcon` sono copiati e adattati. Non c'è un package condiviso: i due `Package.swift` sono target eseguibili indipendenti. SCELTA (semplicità di build) con costo di manutenzione doppia.

---

## 1. Flussi utente

### F1 — Avvio dell'app: onboarding, Turbo network, controllo aggiornamenti

**Osservabile.** Al primo avvio compare il foglio "Welcome" con l'account di riferimento `garibaldi@indigital.tv` e lo stato della rete; ai successivi no. In alto, l'header mostra lo stato del nodo Tailscale (Streamer: pulsante nella sub-header; Receiver: badge nell'header). Se il server ha pubblicato una build più nuova, appare un banner blu "Update available".

**Stati UI.** `TurboNet.State`: `off → starting → up | needsLogin(url) | failed(msg)` (`TurboNet.swift:11-13`). `Updater.State`: `idle → checking → upToDate | available(r) → downloading → installing | failed` (`Updater.swift:17-23`). Onboarding: `didOnboard` in `@AppStorage`.

**Implementazione.**
1. `StreamManager.init` (`StreamManager.swift:77-109`) / `ServerManager.init` (`ServerManager.swift:55-91`) creano `TurboNet` e lanciano `Task { await turboNet.start() }` **subito**, prima che l'UI esista.
2. `TurboNet.start` (`TurboNet.swift:55-106`): chiede una chiave a turbolink (`fetchAuthKey`, riga 221: `POST /v1/tailnet/key`); se la ottiene lancia `turbo-net --authkey … --ephemeral`, altrimenti senza chiave, e l'helper stampa `auth_url`. Legge stdout come JSON-lines (`ingest`/`handle`, righe 170-217). Attende fino a 30 s (60 × 500 ms) uno stato terminale.
3. `RootView.onAppear` (`RootView.swift:25-28`): mostra il wizard se `!didOnboard`; lancia `updater.check(silent: true)`.
4. `Updater.check` (`Updater.swift:41-71`): `GET /v1/appcast`, confronta `build` (intero) con `CFBundleVersion`; se maggiore → `.available`.

**Perché così.** Il nodo parte all'avvio perché il pairing deve poter annunciare il 100.x senza attese; la chiave viene dal server perché così non serve login per macchina (il wizard resta il fallback quando il token manca sul server). L'aggiornamento è "silent" per non disturbare se tutto è a posto.

**Criticità.**
- SCELTA: ogni avvio fa due chiamate di rete (chiave tailnet, appcast) prima di qualunque azione dell'utente; senza rete lo stato `TurboNet` finisce in `needsLogin`/`failed` senza che l'app lo evidenzi oltre l'header.
- SCELTA: la chiave Tailscale è `--ephemeral`: il nodo sparisce alla chiusura dell'app; il login manuale invece persiste in `Application Support`. Due identità diverse a seconda della modalità, e `unlinkAccount` (`TurboNet.swift:116-127`) serve solo nel secondo caso.
- SCELTA: il wizard nomina un account fisso hardcoded (`RootView.swift:74`).

### F2 — Configurare uno stream (tab Configure)

**Osservabile.** Da 1 a 8 card, ognuna con: nome, Destination (piattaforma preset/Custom, URL, key, latenza SRT se `srt://`, "Paste full URL", "Link receiver"), Failsafe (backup, safety recording, adaptive bitrate, fallback slate), Text overlay, Video (risoluzione, codec, bitrate, fps, match source, audio bitrate), Input (File/Capture/Blackmagic/Network con le relative opzioni). Tutto si salva da solo. "Profiles" salva/carica/cancella snapshot nominati. Il pulsante Start è disabilitato finché la validazione non passa.

**Stati.** `manager.configs: [StreamConfig]` è l'unica fonte; ogni card ha un `Binding`. `didSet` → `saveConfigs()` + `syncPreviewsToConfigChanges` (`StreamManager.swift:10-12`).

**Implementazione.** `StreamConfig` (`Models.swift:188-294`) è una struct con **decoder resiliente**: ogni campo mancante prende il default, così aggiungere campi non cancella i salvataggi. `SetupView.validationHint` (`SetupView.swift:393-406`) richiede: key non vuota, URL sorgente per Network, file per File. `setCount` (`StreamManager.swift:218-225`) aggiunge/tronca. Profili: array di `Profile{name, configs}` in UserDefaults, sostituzione per nome.

**Convenzioni implicite (non evidenti dalla UI).**
- Cambiare preset piattaforma sovrascrive l'URL e **spegne l'auto-pairing** (`StreamConfigCard.swift:45-47`); anche modificare URL/key a mano lo spegne (righe 71-73, 90-92); "Paste full URL" idem (riga 100). Un riquadro "Auto-pairing on" con pulsante Off rende visibile lo stato (righe 49-64).
- Il campo URL è **disabilitato** quando il preset non è Custom (riga 69).
- Cambiare risoluzione riscrive il bitrate col default (riga 231-234): un bitrate scelto a mano viene perso.
- "Match source" per Blackmagic compare solo con formato esplicito (riga 259).
- Gli stream **in onda non cambiano**: `RunningStreamRecord` porta una copia della config (`Models.swift:544-549`); le modifiche valgono dal prossimo Start.

**Criticità.**
- BUG (UX): con "Publish on LAN" attivo e nessuna piattaforma, Start resta disabilitato perché la key è obbligatoria (`SetupView.swift:395-396`): l'utente deve inventare una key. Il caso "solo LAN" promesso dal popover non è avviabile senza quel trucco.
- SCELTA: la validazione non controlla l'URL (schema, host); un URL malformato arriva a ffmpeg e produce un errore diagnosticato a posteriori.

### F3 — Anteprima (Preview Streams)

**Osservabile.** "Preview Streams" apre un pannello fisso in basso, ridimensionabile, con un riquadro per stream a ~12 fps del programma composto (sorgente + overlay), senza inviare nulla. Il testo dell'overlay si aggiorna dal vivo; font, colore, sorgente richiedono "Refresh Preview".

**Implementazione.** `startPreview` (`StreamManager.swift:1226-1285`): un ffmpeg per config che scrive `preview_<id>.jpg` con `-update 1` (`buildPreviewArgs`, 1392-1418: scala, drawtext con `reload=1` da `previewovl_<id>.txt`, `fps=12,scale=960:-2`, `-q:v 6`). `LivePreviewBox` (`LivePreviewBox.swift:5-32`) rilegge il JPEG con un `Timer` a 12 Hz. `syncPreviewsToConfigChanges` (1362-1381) scrive il nuovo testo nel file; calcola anche una "signature" di stile ma **non la usa** (riga 1379: `_ = (oldSig, newSig, styleChanged)`): il riavvio è manuale via `refreshAllPreviews` → `restartPreviewDebounced` (1307-1341, 350 ms di debounce, attende l'uscita del vecchio processo fino a 3 s).

**Perché.** Polling di un JPEG invece di una pipeline video in-process: zero dipendenze, stesso ffmpeg dello stream, quindi "quello che vedi è quello che parte". Il riavvio manuale evita di riaprire la telecamera a ogni tweak.

**Criticità.**
- SCELTA: `startStreams` chiama `stopAllPreviews()` (riga 256) perché un device di cattura non può essere aperto due volte: l'anteprima non convive con lo stream. Non è scritto nell'UI.
- SCELTA: la telecamera viene sondata (`probeCaptureFramerate`) a ogni avvio dell'anteprima se non in cache; la cache `captureFramerate` è per config e viene azzerata a `stopPreview`.
- Debito: codice morto nella signature di stile; il `preview-debug.log` è molto verboso (`dlog`) ed è sempre attivo.

### F4 — Avviare uno stream: pre-flight → ffmpeg → loop di riconnessione → stop

**Osservabile.** "Start Streams" (⌘↩) avvia tutte le card; la tab Live mostra una card per stream con fase (Live / Reconnecting (n) / Stopped), timer, fps, bitrate, speed, badge arancioni (freeze/black, trasporto in fallback), il pannello "What's happening" in linguaggio semplice quando c'è un errore noto, il log raw copiabile, Stop/Mute/Overlay. Suoni di sistema a riconnessione, ripristino, freeze.

**Stati.** `StreamPhase`: `idle → running ⇄ reconnecting(n) → stopped` (`Models.swift:503-532`). `StreamStatus` (`Models.swift:431-501`) accumula 500 righe di log, metriche, `inputWarning`, `currentDiagnostic`, `transportWarning`, `slowSamples`.

**Implementazione, passo per passo.**
1. `startStreams` (`StreamManager.swift:255-269`) → per ogni config `launch` (274-289): crea `RunningStreamRecord` (UUID **nuovo** per istanza, diverso da `config.id`), apre il file di log, `spawnTask`.
2. `spawnTask` (570-743), **pre-flight**:
   - Capture: permesso camera/microfono via `AVCaptureDevice.requestAccess` (l'app lo chiede lei, ffmpeg lo eredita, 341-366) e `probeCaptureFramerate` (376-396: lancia ffmpeg senza framerate, ne legge i modi supportati dall'errore, sceglie il più vicino o il massimo).
   - File con Match source: `probeFileFramerate` (400-409) dal banner di `ffmpeg -i`.
   - Blackmagic: solo log.
   - **Trasporto**: se `autoPair` ed URL/key sono ancora quelli del pairing → `resolveAutoTransport` (vedi F5). Altrimenti (620-658): se la destinazione è `srt://` con host 100.64/10 apre un tunnel (`turboNet.dial`) e punta ffmpeg a `127.0.0.1:<porta>`; poi `probeSRT`; se fallisce e c'è `altRTMPURL` passa a RTMP e alza `transportWarning`; per RTMP fa un connect TCP (`Preflight.isReachable`, 4 s).
3. **Loop** (665-731): finché non cancellato/stoppato: `runFFmpeg` → attende l'uscita → se exit 0 "ended cleanly" e stop; altrimenti adaptive bitrate (solo se il run ha spinto frame), backoff `[1,2,4,8,15]` s (753-756) con reset dopo un run "sano" > 30 s (762), alert webhook di drop se il run era sano, slate opzionale durante l'attesa.
4. `runFFmpeg` (845-956): risolve fps e codec, scrive il file dell'overlay, costruisce gli argomenti (`buildArgs`), lancia ffmpeg con `DYLD_LIBRARY_PATH` sul `lib/` del bundle, stdin come pipe (per il mute), stdout+stderr in un'unica pipe letta **solo** dal `readabilityHandler` (mai letture bloccanti nel termination handler: commento 924-926, lezione di un crash precedente). **Watchdog** (908-920): ogni 2 s, se `lastProgressAt` è più vecchio di 10 s termina il processo *se è ancora quello* (`ProcessRegistry.terminate(ifMatches:)`), così un watchdog vecchio non uccide un successore.
5. `appendLog` (518-542) è il punto unico: scrive su file, alimenta `StreamStatus.appendLog` che parsa `frame=… fps=… speed=…`, rileva `freeze_start/black_start`, fa il match del catalogo diagnostico e misura l'encoder in ritardo; se arrivano frame durante un `reconnecting` ripristina `running`, suona e manda il webhook di recover.
6. `stopStream` (291-311): flag, cancel del task, `ProcessRegistry.terminate` (SIGTERM, poi SIGKILL dopo 6 s), kill dello slate, chiusura tunnel, rilascio del power assertion.

**Il comando ffmpeg (`buildArgs`, 1591-1762).** Input per tipo (file: `-hwaccel videotoolbox -re -stream_loop -1`; decklink: `-format_code/-video_input/-raw_format`; network: `-rtsp_transport tcp`, streamid SRT estratto dalla query in `-srt_streamid`; capture: `-framerate` sondato). `-y` sempre. Passthrough (`-c copy`) se Network+flag. Codec risolto da `resolveCodec` (1573-1578) e **clampato a H.264 hardware se l'uscita non è SRT** (1673). Catena filtri: `scale,format=yuv420p,freezedetect,blackdetect[,drawtext][,format=p010le]`; audio `-af volume=0|1` sempre presente (è la maniglia del mute) + AAC 48 kHz stereo. Uscita: `-f flv url/key` oppure `-f mpegts -srt_streamid publish:key -pkt_size 1316|1200 -latency …`. Con backup/recording/LAN-tee/snapshot si passa a `-filter_complex` con `split` e `tee` (le uscite secondarie con `onfail=ignore`).

**Perché così.** Un processo ffmpeg per stream, riavviato dal loop: è il modo più robusto per "riacquisire il device" dopo un blocco. Il catalogo diagnostico (`Models.swift:351-426`) traduce i messaggi di ffmpeg in italiano-Disney con un fix suggerito, senza toccare il log raw.

**Criticità.**
- BUG (cosmetico ma fuorviante): la riga di log "✓ Encoder: …" (`StreamManager.swift:862-865`) calcola `isSRT` da `config.rtmpURL`, mentre `buildArgs` lo calcola dalla destinazione effettiva e poi clampa HEVC→H.264 (1673). Con auto-pairing che finisce su RTMP il log dice HEVC e il comando usa H.264.
- SCELTA: su destinazione SRT **niente tee**: backup, safety recording e LAN-tee vengono silenziosamente ignorati (1726). La UI mostra i campi senza avvisare.
- SCELTA: lo slate codifica sempre `libx264` (1068) anche se lo stream principale era HEVC su SRT: cambio di codec a metà sessione che MediaMTX potrebbe non gradire; non verificato.
- SCELTA: `adaptiveBitrate` abbassa del 30 % ogni run < 20 s con frame (696-698), floor a `max(800, orig/4)`, e risale del 30 % dopo 120 s: euristica, non misura la rete.
- SCELTA: file senza traccia audio → nessun audio in uscita e warning `b:a` innocuo (visto nel log di Garlasco). Alcune piattaforme pretendono l'audio; l'app non avvisa.
- Delicato: `runFFmpeg` usa `withCheckedContinuation` risolta dal `terminationHandler`; se ffmpeg non parte, `-2`. Qualsiasi modifica al ciclo di vita del processo deve preservare "una sola resume".

### F5 — Pairing e trasporto: Link, Use (auto)/Direct only/Use relay, scala, receiver che segue

**Osservabile (Streamer).** "Link receiver" → "Create code" mostra un codice di 6 caratteri; la lista dei receiver che entrano si aggiorna ogni 3 s; per ciascuno: **Use (auto)** (consigliato), **Direct only**; in fondo **Use relay**. Un receiver con indirizzo privato è marcato "LAN address".
**Osservabile (Receiver).** "Link" sulla card → inserisci il codice → "Linked … this feed now follows the streamer automatically"; sulla card compare "Receive · Automatic" e un badge verde SRT / arancione RTMP fallback.
**Osservabile (in onda).** Il log dello Streamer racconta la scala ("Direct path…", "trying the relay", "Falling back to RTMP…"); la Live card mostra il badge arancione se in fallback.

**Implementazione, lato Streamer.**
- Create code: `LinkClient.createSession` (`LinkClient.swift:77-84`) → sessione con `relay{}` già pronto. Poll: `receivers(code:secret:)` ogni 3 s finché il popover è aperto (`StreamConfigCard.swift:573-582`).
- **Use (auto)** (472-491) salva nella config: `pairDirectURL/Key` (il receiver), `pairRelaySRTURL/Key`, `pairRelayRTMPURL/Key`, `pairCode/Secret`, `autoPair=true`, e allinea `rtmpURL/streamKey` al diretto (serve alla validazione e al guard).
- Al pre-flight, `resolveAutoTransport` (`StreamManager.swift:1439-1490`): (1) diretto: se 100.x apre il tunnel e sonda il locale, altrimenti sonda l'URL; se risponde → `destinationOverride`, badge nullo, `report("direct")`; (2) relay SRT: `probeSRT`; (3) relay RTMP: sempre, con `transportWarning`. Ogni scelta viene riportata a turbolink (`reportTransport`, `LinkClient.swift:96-104`).
- `probeSRT` (1495-1502): ffmpeg pubblica 0,5 s di `nullsrc` con streamid volutamente errato e timeout 3 s; "rejected" nell'output = il server ha risposto (UDP aperto); "connection to … failed" = bloccato. Non pubblica mai nulla di reale.

**Implementazione, lato Receiver.**
- `sendLink` (`ContentView.swift:275-296`) → `LinkClient.join` con `host = selectedAddress` (che diventa il 100.x appena il nodo è su, `ServerManager.swift:72-79`), porta 8890, `streamKey = key.key` (la key del feed **è** il path MediaMTX e il segreto: `receiver/Models.swift:5-7`).
- `setRelaySource` (`ServerManager.swift:109-116`) salva `relaySource`, `relaySourceRTMP`, `linkCode`, forza `pullFromRelay = true` e avvia `startTransportFollow`.
- `startTransportFollow` (121-136): ogni 3 s `GET /v1/session/:code/transport`; al cambio di `mode` → `applyTransport` (138-156): `direct` → `PATCH /v3/config/paths/patch/<key>` con `source: publisher`; `relay-srt` → source SRT; `relay-rtmp` → source RTMP.
- Feed senza codice (vecchi o manuali): `startRelayPull` (179-204) sonda l'SRT del relay con la stessa euristica e sceglie SRT o RTMP.

**Server.** `transport` è un campo della sessione (`index.js:179`); il report richiede il secret (214-224), la lettura solo il codice (229-235) ed espone solo `mode/detail/at`.

**Perché così.** La regola è "prima il meglio, poi il fallback, sempre con avviso": SRT diretto (bassa latenza, HEVC) > SRT via relay > RTMP via relay (TCP, solo H.264). Il receiver non può sapere da solo se lo streamer arriverà diretto o via relay, quindi turbolink fa da bacheca. Il codice è la capability per unirsi e leggere il trasporto; il secret quella per vedere chi si è unito e scrivere il trasporto.

**Criticità.**
- **BUG (alto)**: `IngestKey.linkCode` non viene decodificato al riavvio del Receiver (`receiver/Models.swift:29-37` assegna `relaySource`, `relaySourceRTMP`, `pullFromRelay` ma non `linkCode`; è **codificato** perché i CodingKeys sono sintetizzati). Effetto a catena: dopo un riavvio dell'app il feed perde il codice → niente auto-follow; e poiché `pullFromRelay` è rimasto `true`, alla `start()` entra nel ramo legacy (`ServerManager.swift:305`) e **tira dal relay anche se lo streamer pubblica diretto**. Il feed resta "waiting" con lo streamer che invece sta pubblicando bene. Va aggiunta una riga al decoder.
- **BUG (medio)**: il badge del trasporto non ha il caso `"direct"` (`ContentView.swift:309-325`): in modalità diretta mostra "no relay" arancione, cioè un avviso di errore quando tutto va bene.
- BUG (basso): `relayTransport` e la riga di testo restano visibili solo se `pullFromRelay` (riga 213); in `direct` il flag è comunque `true` (forzato in `setRelaySource`), quindi il badge sbagliato è sempre visibile.
- SCELTA: la scala gira **una sola volta** al pre-flight; se il diretto cade a metà show il loop riavvia sempre sullo stesso trasporto. Non risale mai al diretto e non scende mai al relay senza uno Stop/Start.
- SCELTA: `probeSRT` ottimista su output vuoto (`!out.contains("connection to")`): se ffmpeg non parte, il probe dice "raggiungibile".
- SCELTA: chiunque conosca il codice può tenere viva la sessione per sempre (`touch` nella GET transport, riga 232) e leggere il modo di trasporto. Il codice ha 32^6 ≈ 1,07 miliardi di combinazioni e nginx limita a 10 req/s: rischio basso.
- SCELTA: `LinkClient.close` (DELETE) non viene mai chiamato: le sessioni vivono 24 h dall'ultimo uso.
- Delicato: `pairedStillActive` (`StreamManager.swift:612-614`) confronta URL e key con quelli del pairing; qualsiasi normalizzazione futura dell'URL (trim, lowercase) va fatta su entrambi i lati o l'auto-pairing si spegne da solo.

### F6 — Publish on LAN (Streamer come ricevitore locale)

**Osservabile.** Sub-header → "Publish on LAN" → interruttore. Acceso: per ogni stream compaiono URL RTSP e HLS sull'IP di LAN e un toggle NDI; il pulsante diventa "On this network". Gli stream già in onda si riavviano.

**Implementazione.** `setLocalPublish` (`StreamManager.swift:1542-1559`): persiste il flag, registra i path (`localPathName` = slug del nome + 8 char dell'id, 1528-1533), avvia `LocalServer`, ferma e rilancia dopo 0,8 s le config live. `LocalServer` (`LocalServer.swift`) è una copia compatta del `ServerManager` del Receiver: scrive `local-mediamtx.yml` (133-162, HLS fmp4, MoQ off), lancia `mediamtx`, polla `/v3/paths/list` ogni 1,5 s, gestisce NDI con lo stesso schema FIFO. In `buildArgs` (1602-1613): se la piattaforma è RTMP la LAN è un ramo `tee` in più; se è SRT la LAN **diventa** l'uscita primaria e la piattaforma viene abbandonata.

**Criticità.**
- BUG (UX): vedi F2, Start disabilitato senza key.
- SCELTA: nel caso "piattaforma SRT + LAN" la piattaforma sparisce senza che la UI lo dica esplicitamente (il popover dice "streams publish here instead of to the platform", che è vero solo in quel caso).
- SCELTA: riavvio automatico degli stream live al toggle: un'interruzione di ~1 s in onda.
- Debito: `LocalServer` duplica ~300 righe del Receiver.

### F7 — Turbo Receiver: server, feed, URL, NDI

**Osservabile.** Header con stato nodo, selettore indirizzo, Start/Stop. Card per feed: LIVE/waiting, kbps, tracce, lettori, NDI, Link, menu (Regenerate key, Remove). Righe URL: Publish RTMP, Publish SRT (con streamid), OBS RTSP, Browser HLS (apribile). Footer: aggiungi feed, log copiabile, versione.

**Implementazione.** `start()` (`ServerManager.swift:263-316`): scrive `mediamtx.yml` con un path per key (solo quelli dichiarati sono accettati: la key è il segreto), lancia MediaMTX, polla l'API (409-447) e deriva `isReceiving`/`isTroubled` per l'icona; avvia il follow o il ladder per i feed; espone l'SRT sulla tailnet con `turboNet.listen` (307-312). Le URL di consumo usano `lanAddress` (IP privato, mai il 100.x, 251-257); quelle di publish usano `selectedAddress`. NDI (`NDIBridge.swift`): ffprobe per formato, due FIFO, `ffmpeg` decodifica RTSP→raw, `ndi-sender` pubblica; supervisore ogni 3 s riavvia se un processo muore e il feed è `ready`.

**Criticità.**
- SCELTA: `regenerateKey` cambia il path MediaMTX ma **non** invalida `relaySource`/`linkCode` del feed: dopo la rigenerazione il pairing fatto prima punta a una key che non esiste più. L'utente deve rifare Link.
- SCELTA: la key del feed viaggia in chiaro nelle URL mostrate e nel pairing; è "segreta" solo nel senso che il path non è indovinabile.
- Delicato: l'ordine di avvio NDI (sender prima, poi decoder) è necessario per lo sblocco delle FIFO (commento in `NDIBridge.swift`); non invertirlo.

### F8 — Comandi live: mute e overlay

**Mute** (`StreamManager.swift:1165-1184`): scrive `cvolume -1 volume 0` sullo stdin di ffmpeg (formato dei comandi interattivi); nessun riavvio, nessun buco (fu la risposta al "ma sei matto? non può esserci un buco di 1s"). Lo stato `mutedStreams` alimenta il valore iniziale del filtro al prossimo riavvio, così una riconnessione riparte muta. In passthrough non c'è filtro: il pulsante logga e non fa nulla.
**Overlay** (1186-1189): scrive il testo in `overlay_<id>.txt` che `drawtext … reload=1` rilegge a ogni frame; preset e campo nella Live card.
Criticità: SCELTA, `SIGPIPE` ignorato a livello di processo (`init`, riga 103) per non morire scrivendo su uno stdin chiuso.

### F9 — Alert webhook

Popover "Alerts" (`SetupView.swift:307-347`): URL globale in UserDefaults, "Send test". `streamDropped`/`streamRecovered` (`StreamManager.swift:795-804`) sono idempotenti per id e scattano solo per run "sani" (> 30 s), così le riconnessioni iniziali non spammano. POST JSON fire-and-forget (`sendWebhookAlert`, 810-815). SCELTA: nessun retry, nessuna coda.

### F10 — Auto-update

**Osservabile.** Banner con versione e note, "Update & Relaunch" → spinner → l'app si chiude e riparte aggiornata. Click sulla versione nel footer = controllo manuale.

**Implementazione** (`Updater.swift`). Manifest `{streamer|receiver: {version, build, url, sha256, notes}}`; aggiornamento se `build > CFBundleVersion`. Download in memoria, SHA-256 verificato (rifiuto su mismatch), `ditto -x -k`, poi uno script bash **staccato** che attende l'uscita del PID, `ditto` in `<App>.app.new`, toglie la quarantena, `rm -rf` del vecchio, `mv` atomico, `open`. Build number = `git rev-list --count HEAD` stampato da `build.sh`; pubblicazione con `deploy-apps.sh` che spinge anche `index.js`.

**Criticità.**
- BUG (medio, osservato sul Mac di Garlasco): la destinazione è **hardcoded** `/Applications/<App>.app` (`Updater.swift:101`). Se l'app gira da un'altra posizione o traslocata (AppTranslocation, quarantena), l'update installa in `/Applications` e l'utente continua a lanciare la copia vecchia. Andrebbe usato `Bundle.main.bundlePath` (risolvendo la traslocazione) o almeno avvisare.
- SCELTA: nessuna firma del manifest: la fiducia è HTTPS + hash. Un server compromesso può pubblicare qualunque build (documentato in `docs/auto-update-recipe.md`).
- SCELTA: il download è in RAM (`URLSession.data`), 40–70 MB; niente progress.

### F11 — Server: turbolink, relay, chiavi tailnet

Vedi tabella in §0. Punti non ovvi:
- L'auth del relay (`/v1/auth`) accetta la **publishPass anche in lettura** (`index.js:254`): lo streamer può leggere il proprio path.
- La chiave Tailscale mint (`/v1/tailnet/key`, 189-210) è aperta: chiunque raggiunga il server ottiene una chiave per entrare nella tailnet, taggata `tag:turbo`. La sicurezza dipende **interamente dalle ACL** della tailnet (il tag può parlare solo con `tag:turbo:8890`). Se le ACL non sono state impostate come nel README, questo è un ingresso libero. Da verificare nella console Tailscale.
- Il TTL 24 h rinnovato dall'auth del relay significa che una sessione usata in show non scade mai durante lo show.
- Rate limit solo via nginx (`limit_req 10r/s`), non nel servizio.

### F12 — turbo-net (helper Go)

`main.go`: un `tsnet.Server` per processo; stdin JSON-lines (`listen`, `dial`, `close`, `logout`), stdout eventi. `listen` (164-201) lega **l'IP del nodo** (non `:porta`, che tsnet rifiuta, lezione di un bug reale) e inoltra a `127.0.0.1:8890` con una tabella di flussi per mittente, reap a 60 s. `dial` (204-245) apre un UDP locale su porta effimera e inoltra al peer; `reportPeer` (294-341) ogni 5 s dice se il percorso è diretto o via DERP e segnala `peer_unknown` se il peer non è nella tailnet (account diverso). SCELTA: MTU del tunnel 1280 → l'app usa `-pkt_size 1200` quando `tailnetRuns` (`StreamManager.swift:871`).

---

## 2. Algoritmi ed euristiche non banali

| Cosa | Dove | Come | Assunzioni / limiti |
|---|---|---|---|
| Codec automatico | `resolveCodec` `StreamManager.swift:1573-1578` + clamp 1673 | ≤1080p → x264; 4K ≤30 fps → H.264 hw; 4K >30 fps → HEVC se SRT altrimenti x264; HEVC mai su RTMP | Soglie misurate su un M2 Pro (h264_vt 0,88×, hevc_vt 1,31×, x264 1,54× a 4K60). Su altri Mac può essere sbagliata: la rete di sicurezza è la diagnostica "encoder behind" |
| Encoder in ritardo | `StreamStatus.appendLog` `Models.swift:485-490` | 6 progress consecutivi con speed < 0,95× → diagnostica | Misurato, indipendente dalla macchina; il primo secondo legge basso ma la serie lo assorbe |
| Adaptive bitrate | 693-703 | −30 % se run con frame < 20 s; +30 % se > 120 s; floor max(800, orig/4); ignora i run senza frame | Non distingue congestione da errori della piattaforma |
| Backoff | 753-756 | 1,2,4,8,15 s; reset dopo run > 30 s | |
| Watchdog | 908-920 | nessun `frame=` per 10 s → SIGTERM del processo *atteso* | Dipende dal progress di ffmpeg (loglevel info) |
| Freeze/black | filtri `freezedetect=n=-60dB:d=3,blackdetect=d=3` | solo log → badge | Costo CPU trascurabile; il badge è "contenuto", non disconnessione |
| Sonda SRT | 1495-1502 e `ServerManager.swift:208-216` | connessione con streamid errato, 3 s | "rejected" = raggiungibile; output vuoto = raggiungibile (ottimista) |
| Framerate cattura | 376-396 | parsa `@[…]` dall'errore di ffmpeg | Se il device non elenca modi → 30 |
| fps decimali | 1596 | `"59.94"` → 60 per il GOP | |
| 10-bit | 1674, 1709 | `format=p010le` **in coda** alla catena | Messo prima costa due conversioni per frame (1,09× vs 1,36×) |
| Path LAN | 1528-1533 | slug(nome)+id[0..8] | Stabile per config, cambia se cambia l'id |
| Diagnostica | `Models.swift:345-348` | primo match del catalogo, ordine = priorità | La prima riga non-progress del batch vince |
| Sessioni turbolink | `index.js:99-107` | TTL dall'ultimo uso; sweep ogni 10 min e a ogni create | `sessions.json` riscritto per intero |

---

## 3. Bug reali (verificati leggendo il codice)

| # | Gravità | Dove | Effetto osservabile | Correzione minima |
|---|---|---|---|---|
| B1 | **Alta** | `receiver/Models.swift:29-37` | `linkCode` non decodificato: dopo un riavvio del Receiver l'auto-follow sparisce e, con `pullFromRelay` rimasto `true`, il feed **tira dal relay anche se lo streamer è diretto** (`ServerManager.swift:305`) | aggiungere `linkCode = (try? c.decode(String.self, forKey: .linkCode)) ?? ""` |
| B2 | Media | `receiver/ContentView.swift:309-325` | in modalità diretta il badge mostra "no relay" arancione (falso allarme) | aggiungere `case "direct"` verde |
| B3 | Media | `Updater.swift:101` | l'update installa sempre in `/Applications`; se l'app gira altrove o traslocata, l'utente resta sulla vecchia | derivare la destinazione dal bundle reale, o avvisare |
| B4 | Media (UX) | `SetupView.swift:395` | Start disabilitato per un uso solo-LAN senza key | esentare dalla key quando `localPublishEnabled` e nessuna piattaforma |
| B5 | Bassa | `StreamManager.swift:862-865` | log "Encoder: HEVC" mentre il comando usa H.264 (clamp su RTMP) | calcolare il log dopo il clamp o loggare in `buildArgs` |
| B6 | Bassa | `ServerManager.swift:222-234` | Regenerate key non invalida pairing/relaySource del feed | azzerare `relaySource/RTMP/linkCode/pullFromRelay` |

Nessuno di questi è stato corretto in questa review, come richiesto.

---

## 4. Scelte progettuali e debito (non bug, ma da conoscere)

- **Duplicazione tra le app**: `TurboNet`, `Updater`, `RootView` identici; `LocalServer` ≈ `ServerManager`+`NDIBridge`; parser di interfacce, LAN detection, icona. Ogni fix va fatto due volte. Un package Swift condiviso (`TurboCore`) toglierebbe ~800 righe.
- **`StreamManager` è un god-object** (1763 righe): persistenza, profili, permessi, device scan, pre-flight, trasporto, ffmpeg, slate, mute, overlay, anteprima, LAN, webhook, power. Funziona ma ogni modifica tocca il file più delicato del progetto. Confini naturali: `TransportResolver`, `FFmpegCommand`, `PreviewEngine`, `Persistence`.
- **`StreamConfig` accumula 40 campi** con tre "modalità" di destinazione sovrapposte (`rtmpURL/streamKey`, `altRTMPURL/Key`, `pair*` ×8). Il guard `pairedStillActive` esiste perché non c'è un enum di modalità (`.platform`, `.direct(url,key)`, `.auto(pair)`).
- **Backup/recording ignorati su SRT** senza avviso in UI.
- **Nessun test** nei target (l'HANDOFF cita test del matcher fatti a mano). I parser di ffmpeg (`parseAVFoundation`, `parseDeckLink`, progress, diagnostica) sono candidati ideali.
- **Log**: tre sistemi separati (file per stream, `networkLog` in memoria, `LocalServer.logLines` in memoria, `preview-debug.log` sempre acceso).
- **Sicurezza**: chiave Tailscale mint aperta (dipende dalle ACL); key dei feed in chiaro; nessuna firma sugli aggiornamenti; `TURBOLINK_DATA` 0600 ma le sessioni contengono i segreti del relay.
- **UI in inglese, diagnostica in italiano-Disney**: coerenza da decidere.

---

## 5. Aree delicate da capire prima di intervenire

1. **`runFFmpeg` + `ProcessRegistry` + watchdog** (`StreamManager.swift:845-956`, `ProcessRegistry.swift`): una sola `resume` della continuation, letture solo nel readability handler, terminazione "se è ancora quel processo". Storia di crash e hang reali.
2. **`buildArgs`** (1591-1762): l'ordine dei filtri (10-bit in coda), la scelta tee/non-tee, la clamp HEVC, il passthrough. Ogni riga ha una ragione misurata; cambiare l'ordine costa prestazioni o rompe SRT.
3. **Il contratto a tre (Streamer ↔ turbolink ↔ Receiver)** per il trasporto: campi `pair*`, `report/transport`, `applyTransport`, e i tre valori di `mode`. Cambiare un nome rompe silenziosamente l'allineamento.
4. **La key del feed come path e segreto** nel Receiver: tutto (URL, pairing, relay, NDI) la usa come identificatore.
5. **Le FIFO NDI**: ordine di avvio e supervisore.
6. **`syncPreviewsToConfigChanges`** e il riavvio debounced: facile reintrodurre il "preview congelato" (`-y`, overwrite prompt) o riaprire la camera a ogni keystroke.
7. **Lo script di swap dell'updater**: gira dopo la morte dell'app; un errore qui lascia l'app assente da `/Applications`.

---

## 6. Coerenza UI ↔ implementazione: discrepanze trovate

| L'interfaccia dice | Il codice fa |
|---|---|
| Popover LAN: "streams publish here instead of to the platform" | vero solo con piattaforma SRT; con RTMP pubblica a entrambe (tee) |
| Failsafe "Backup destination", "Safety recording" sempre visibili | ignorati su destinazione SRT |
| Receiver "Automatic · follows the streamer" | dopo un riavvio dell'app non segue più (B1) e mostra "no relay" in diretta (B2) |
| Footer "v3.0 (build N)" e banner update | l'update finisce in `/Applications` anche se l'app non gira da lì (B3) |
| Log "✓ Encoder: HEVC…" | l'uscita RTMP usa H.264 (B5) |
| "Fallback on input loss: holds the most recent frame" | vero; ma lo slate è sempre x264 anche su uno stream HEVC/SRT |
| Wizard: "Sign in with garibaldi@indigital.tv" | con il token sul server non serve alcun login: il wizard mostra comunque il riquadro |

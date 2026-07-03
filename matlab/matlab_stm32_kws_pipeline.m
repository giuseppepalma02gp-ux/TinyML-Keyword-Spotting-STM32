%percorso da incollare:" "
% =========================================================================
% SCRIPT MATLAB PER REGISTRAZIONE AUDIO E INVIO SERIALE A STM32
% Registra 1.5 s di voce a 16 kHz, estrae 1 s utile basato su inizio voce
% (con fallback al ritaglio centrale), invia il campione allo STM32
% e riceve il risultato della classificazione.     
% =========================================================================

clear; clc; close all; % pulizia dell'ambiente e aggiunto close all per pulire i grafici vecchi
 
%% 1. CONFIGURAZIONE DEI PARAMETRI AUDIO
fs = 16000;          % Frequenza di campionamento (16kHz)
nBit = 16;           % Risoluzione a 16-bit (il firmware stm32 si aspetta campioni int16)
nCanali = 1;         % registrazione su un solo canale (mono)
durata_registrazione = 1.5;   % Registro 1.5 secondi
durata_output = 1.0;          % Voglio comunque esportare 1 secondo
campioni_registrati = round(fs * durata_registrazione); % 24000 campioni(16k*1.5)
campioni_attesi = round(fs * durata_output);            % 16000 campioni (16k*1)

% SOGLIE DI VALIDAZIONE
soglia_minima = 1200;  % Sotto questo valore riavvia la registrazione (per rifiutare segnali deboli)
soglia_massima = 28000; % Sopra questo valore dà un warning di distorsione (per rifiutare segnali troppo forti)

% Inizializza l'oggetto microfono del PC

audiodevreset; %Reset dei dispositivi audio MATLAB, serve se si cambia le periferiche audio
info = audiodevinfo; %Recupera la lista dei dispositivi audio disponibili

fprintf('--- DISPOSITIVI DI INPUT DISPONIBILI ---\n'); 
for k = 1:length(info.input) %Ciclo su tutti gli input disponibili
    fprintf('ID = %d | Nome = %s\n', info.input(k).ID, info.input(k).Name);
end

deviceID = 1;   % Selezione manuale del microfono
recObj = audiorecorder(fs, nBit, nCanali, deviceID); %Crea l'oggetto di registrazione
fprintf('Microfono selezionato in MATLAB: ID = %d\n', deviceID);
disp(recObj); %Visualizza i dettagli dell'oggetto recorder

%% 2. REGISTRAZIONE VOCALE
while true
    disp('=========================================');
    disp('PREPARATI A PARLARE.');
    disp('Premi un tasto qualsiasi sulla tastiera per avviare la registrazione...');
    disp('(Premi Ctrl+C per uscire forzatamente dal programma)');
    pause; % Attende che tu prema un tasto
    
    disp('>>> REGISTRAZIONE IN CORSO (1.5 sec)... PARLA! <<<');
    recordblocking(recObj, durata_registrazione); % Registra per 1.5s
    disp('Registrazione terminata. Analisi in corso...');

    % Estrazione dati
    % I valori andranno da -32768 a +32767
    audioData = getaudiodata(recObj, 'int16');  % Estrae l'intera registrazione (circa 24000 campioni) in formato int16
    audioData = audioData(:); % Forza l'array ad essere un vettore colonna verticale

    % DIFESA 1: Controllo di sicurezza sulla lunghezza (Se il numero di campioni registrati non è esattamente quello atteso, il programma si blocca con un errore. Serve per evitare di esportare un file corrotto o con una durata sbagliata.)
    if length(audioData) ~= campioni_registrati
        error('ERRORE CRITICO: Numero di campioni inatteso (%d invece di %d).', length(audioData), campioni_registrati);
    end 
    
    % RITAGLIO BASATO SU INIZIO VOCE (speech onset detection)
    frame_len = round(0.025 * fs);     % 25 ms
    hop_len   = round(0.01 * fs);      % 10 ms
    pre_roll  = round(0.15 * fs);      % 150 ms prima dell'onset
    min_run   = 2;                     % almeno 2 frame consecutivi attivi

    num_frames = floor((length(audioData) - frame_len) / hop_len) + 1; %Calcola quanti frame si possono estrarre dall'audio.
    energia_frame = zeros(num_frames, 1); %Prealloca il vettore delle energie.

    for k = 1:num_frames
        idx_start = (k-1)*hop_len + 1; %Calcola l'inizio del frame.
        idx_end   = idx_start + frame_len - 1; %Calcola la fine del frame.
        frame = double(audioData(idx_start:idx_end)); %Estrae il frame e lo converte in double.
        energia_frame(k) = sqrt(mean(frame.^2));   % RMS del frame
    end

    % Soglia adattiva semplice:
    % usa il rumore di fondo iniziale e impone anche una soglia minima assoluta
    n_init = min(10, num_frames);  % primi ~100 ms
    rumore_base = median(energia_frame(1:n_init)); %Stima del rumore di fondo iniziale.
    soglia_vad = max(250, 2.2 * rumore_base); %Imposta la soglia VAD.


    frame_attivi = energia_frame > soglia_vad; %Vettore booleano dei frame attivi.


    onset_frame = []; %Inizializza la variabile che conterrà il frame di inizio.

    for k = 1:(num_frames - min_run + 1) %Scorre i frame per cercare una sequenza attiva.
        if all(frame_attivi(k:k+min_run-1)) %Controlla se ci sono min_run frame consecutivi sopra soglia.
            onset_frame = k; %Salva il primo frame valido.
            break;
        end
    end
 
    if isempty(onset_frame) % se non trova nessu onset
        warning('Inizio voce non rilevato con VAD semplice: uso il ritaglio centrale come fallback.');
        inizio = floor((campioni_registrati - campioni_attesi)/2) + 1;
    else %onset trovato
        onset_sample = (onset_frame - 1) * hop_len + 1;
        inizio = max(1, onset_sample - pre_roll); %Sposta l'inizio indietro di 150 ms.
    end

    fine = inizio + campioni_attesi - 1;

    if fine > length(audioData) %Se il ritaglio supera la lunghezza disponibile...
        segmento = audioData(inizio:end);
        padding = zeros(fine - length(audioData), 1, 'int16');         % se la voce parte troppo tardi, completo con zeri
        audioData = [segmento; padding]; %Ricompone il segmento finale.
    else
        audioData = audioData(inizio:fine); %Ritaglia i campioni desiderati.
    end

   fprintf('VAD -> soglia = %.2f, onset_frame = %d, sample_inizio = %d\n', soglia_vad, ...
    double(~isempty(onset_frame)) * onset_frame, inizio);

    % Misure prima del gain
    picco_raw = max(abs(double(audioData))); %Calcola il picco assoluto del segnale prima del gain.
    rms_raw = sqrt(mean(double(audioData).^2)); %Calcola l'energia media del segnale.

    fprintf('Prima del gain -> Min = %d, Max = %d, Picco = %d, RMS = %.2f\n', ...
        min(audioData), max(audioData), picco_raw, rms_raw);

    % Scarta solo audio quasi muto
    if rms_raw < 250 %Se il segnale è troppo debole in media, lo scarta.
        fprintf('>>> ERRORE: Energia media troppo bassa.\n\n');
    continue;
    end

    % Gain leggero per test
    target_peak = 12000;  % Obiettivo di picco dopo il gain. Serve a portare il segnale in una zona più utile senza saturare.
    picco_raw = max(abs(double(audioData))); %Ricalcola il picco raw.

    if picco_raw > 0
        gain_factor = min(2.5, target_peak / picco_raw); %Calcola il guadagno adattivo.
    else
        gain_factor = 1.0; %Se il picco è zero, non amplifica.
    end

    audio_tmp = double(audioData) * gain_factor; %Applica il gain in floating point.
    audio_tmp = max(min(audio_tmp, 32767), -32768); %Limita i valori al range int16.
    audioData = int16(audio_tmp); %Converte di nuovo il segnale in int16.
    fprintf('Gain applicato = %.2f x\n', gain_factor);

    % Misure dopo gain
    picco = max(abs(double(audioData))); %Calcola il picco dopo il gain.
    rms_val = sqrt(mean(double(audioData).^2)); %Calcola l'energia dopo il gain.

    fprintf('Dopo il gain -> Min = %d, Max = %d, Picco = %d, RMS = %.2f\n', ...
        min(audioData), max(audioData), picco, rms_val);
    fprintf('Headroom: %.1f %% del full scale\n', 100 * picco / 32767);

    if picco < soglia_minima %Se anche dopo il gain il segnale resta troppo debole, lo scarta.
        fprintf('>>> ERRORE: Volume troppo basso anche dopo il gain.\n');
        fprintf('>>> Riprova parlando piu'' forte o piu'' vicino al microfono.\n\n');
    continue;
    end
 
    if picco >= soglia_massima %Se il picco è troppo alto, avvisa di possibile clipping.
        warning('ATTENZIONE: Segnale molto vicino al fondo scala. Potrebbe esserci clipping o saturazione del microfono.');
    end

    disp('>>> AUDIO APPROVATO! Passaggio all''esportazione...');
    disp('=========================================');
    break;% ESCE DAL CICLO WHILE
    end


%% 3. ASCOLTO E VISUALIZZAZIONE (Solo per audio approvato)
sound(double(audioData)/32768, fs); % ti permette di sentire subito se la registrazione è buona

figure; %apertura nuova finestra
plot(double(audioData)); %disegna il segnale nel tempo, campione per campione.
grid on; %attiva la griglia per leggere meglio il grafico
title('Forma d''onda registrata (Audio Approvato)'); %aggiunta titolo
xlabel('Campione'); %aggiunta assi
ylabel('Ampiezza'); 
ylim([-32768 32768]); % IMPORTANTE: Scala fissa per vedere le proporzioni reali

audiowrite('test.wav', double(audioData)/32768, fs);
%salva l'audio in un file WAV chiamato test.wav.
%Anche qui il segnale viene normalizzato tra circa -1 e 1, perché audiowrite si aspetta un audio in formato floating-point.
%Questo file ti serve come verifica e, volendo, come confronto con il comportamento del modello.


%% 4. INVIO SERIALE ALL'STM32 (CON HANDSHAKE)
porta = "COM11"; %Imposta la porta seriale.
baudrate = 460800;

try %Inizia il blocco di gestione errori.
    s = serialport(porta, baudrate, ... %Apre la connessione seriale.
        'Timeout', 10, ...
        'DataBits', 8, ...
        'StopBits', 1, ...
        'Parity', 'none', ...
        'FlowControl', 'none');

    configureTerminator(s, "LF"); %Imposta il terminatore a newline.
    flush(s, "input");  %Pulisce il buffer in ingresso. utile per eliminare residui precedenti
    flush(s, "output"); %Pulisce il buffer in uscita.

    num_campioni = length(audioData); %Numero di campioni da inviare.
    num_byte = num_campioni * 2; %Ogni campione int16 occupa 2 byte.

    % 1. Invio header
    header = sprintf('START %d %d', num_campioni, num_byte); %Costruisce il messaggio header.
    writeline(s, header); %Invia l'header testuale con terminatore.
    disp("Header inviato: " + header);

    % 2. Attesa HEADER_OK
    disp("In attesa di HEADER_OK...");
    header_ok_ricevuto = false; %Flag di stato.
    tic; %Avvia il timer.
    while toc < 5 %Aspetta al massimo 5 secondi.
        if s.NumBytesAvailable > 0 %Controlla se ci sono byte da leggere.
            ack = string(strtrim(readline(s))); %Legge una riga ASCII.
 
            if ack == "HEADER_OK" %Verifica il primo ack dallo STM32.
                header_ok_ricevuto = true;
                disp("HEADER_OK ricevuto. STM32 pronto per l'audio.");
                break;
            elseif startsWith(ack, "ERR_") %Gestisce gli errori lato STM32.
                error("Errore dallo STM32 dopo header: %s", ack);
            end
        end
        pause(0.01);
    end

    if ~header_ok_ricevuto %Se scade il timeout senza rispost
        error("Timeout: HEADER_OK non ricevuto.");
    end
    flush(s, "input"); %Pulisce il buffer prima dell'invio audio
  
    % 3. Invio audio binario 
    dati_da_inviare = typecast(audioData(:).', 'uint8'); % Converte in vettore di byte
    disp("Invio audio in corso (Singolo blocco via DMA)...");
    
    % Trasmette tutti i 32.000 byte istantaneamente. 
    % Non serve più spezzare il file né inserire pause artificiali,
    % perché l'hardware dell'STM32 memorizza i dati direttamente in SRAM.
    write(s, dati_da_inviare, "uint8"); 
    
    disp("Audio inviato completamente. In attesa di RX_OK...");

    % 4. Attesa RX_OK
    rx_ok_ricevuto = false; %Flag per conferma ricezione completa.
    tic;
    while toc < 5
        if s.NumBytesAvailable > 0
            ack = string(strtrim(readline(s))); %Legge il messaggio di conferma.

            if strlength(ack) > 0
                if ack == "RX_OK" %Conferma che STM32 ha ricevuto tutto l'audio.
                    rx_ok_ricevuto = true;
                    disp("RX_OK ricevuto. STM32 ha ricevuto tutto l'audio.");
                    break;
                elseif startsWith(ack, "ERR_") %Gestione degli errori di ricezione.
                    error("Errore dallo STM32 durante RX: %s", ack);
                end
            end
        end
        pause(0.02);
    end

    if ~rx_ok_ricevuto
        error("Timeout: RX_OK non ricevuto.");
    end

    % 5. Lettura risultati inferenza
    disp("In attesa dei risultati  di inferenza...");
    risposta_totale = ""; %Stringa accumulatore per i risultati.
    end_result_ricevuto = false; %Flag per fine messaggi.

    tic;
    while toc < 10
        if s.NumBytesAvailable > 0
            riga = string(strtrim(readline(s))); %Legge ogni riga di risultato.

            if strlength(riga) > 0
                disp("" + riga);

                if riga == "END_RESULT" %Se arriva il terminatore, fine ciclo di ricezione
                    end_result_ricevuto = true;
                    break;
                end

                if riga ~= "RESULT_BEGIN" %Esclude il marker iniziale
                    risposta_totale = risposta_totale + riga + newline;
                end
            end
        end
        pause(0.02);
    end

    if end_result_ricevuto
        disp("RICEZIONE COMPLETATA");
        disp("--- SOMMARIO PREDIZIONE ---");
        disp(risposta_totale);
    else
        warning("Timeout: END_RESULT non ricevuto.");
    end

    clear s;

catch e
    fprintf("Errore Seriale: %s\n", e.message);
    if exist('s', 'var')
        clear s;
    end
end
% =========================================================================
% CLONE MATLAB DELLA PIPELINE MFCC EDGE IMPULSE
% =========================================================================
clear; clc; close all;

%% 1. CARICAMENTO SEGNALE
fs = 16000;
try
    audioIn = readmatrix('raw_audio.txt');
    audioIn = audioIn(:);
catch
    warning('File raw_audio.txt non trovato. Genero segnale di test deterministico.');
    rng(0);
    audioIn = randn(fs,1);
end
t = (0:length(audioIn)-1)/fs;



%% 2. PARAMETRI EDGE IMPULSE
implementationVersion = 4;

preEmph = 0.98;
preShift = 1;

frameLength_s = 0.02;
frameStride_s = 0.02;

[frameLen, frameHop] = ei_frame_sizes(fs, frameLength_s, frameStride_s, implementationVersion);

fftLen = 512;      
numFilters = 32;
numCoeffs = 13;

lowFreq = 0;
highFreq = 0;      % in EI: 0 => fs/2

cmvnWin = 101;
dcElimination = true;   % default coerente con SpeechPy mfcc(..., dcelimination=True)
% Se il confronto con ei_features_reference.txt non torna, prova anche false

%% 3. PRE-ENFASI
% Replica della classe ei::audio::processing::preemphasis
% (equivalente a speechpy::processing::preemphasis nel file processing.hpp)
audio_pre = pre_emphasis_ei(audioIn, preEmph, preShift);

%% 4. FRAMING
% Replica del calcolo di stack_frame_info in processing::frame_signal
% (funzione calculate_no_of_stack_frames in processing.hpp)
frames = stack_frames_ei(audio_pre, frameLen, frameHop);

numFrames = size(frames, 1);
if numFrames < 1
    error('Frame length is larger than your window size.');
end
if numFrames > 500
    error('Number of frames is larger than 500; increase frame stride or decrease window size.');
end
%% 5. POWER SPECTRUM
% Replica di numpy::power_spectrum (numpy.hpp) usata dentro mfe(...)
powSpec = power_spectrum_ei(frames, fftLen);

%% 6. MEL FILTERBANK TRIANGOLARE
% Implementa il banco di filtri triangolari come in speechpy::feature::mfe
% (feature.hpp: costruzione di mel_filter_bank)
melFB = mel_filterbank_ei(numFilters, fftLen, fs, lowFreq, highFreq);
melEnergies = powSpec * single(melFB).';
melEnergies(melEnergies == 0) = eps('single'); % Epsilon float32

% DEBUG MIRATO MEL
writematrix(melFB, 'dbg_melFB_full.csv');
writematrix(melFB(1,:), 'dbg_melFB_row1.csv');
writematrix(melFB(2,:), 'dbg_melFB_row2.csv');
writematrix(melFB(3,:), 'dbg_melFB_row3.csv');

test_mel_row = powSpec(1,:) * melFB.';
writematrix(test_mel_row, 'dbg_mel_from_frame1_times_FB.csv');
writematrix(melEnergies(1,:), 'dbg_melEnergies_frame1.csv');

%% 7. LOG NATURALE
% Replica della chiamata numpy::log(features_matrix) in extract_mfcc_features(...)
logMel = log(melEnergies);

% Esporta le energie Mel per confrontarle con Edge Impulse
writematrix(logMel, 'debug_logMel_matlab.csv');

%% 8. DCT-II ORTONORMALE
% Replica di numpy::dct2(features_matrix, DCT_NORMALIZATION_ORTHO)
% (feature.hpp, funzione extract_mfcc_features)
mfcc_full = dct_ortho_ei(logMel);
coeffs_EI = mfcc_full(:, 1:numCoeffs);

if dcElimination
    % Energia compatibile con MFE: somma del power spectrum per frame
    frameEnergy = sum(melEnergies, 2);      % powSpec è già /fftLen
    frameEnergy(frameEnergy == 0) = 1e-10;
    coeffs_EI(:,1) = log(frameEnergy);
end

% DEBUG DCT / RAW MFCC
writematrix(mfcc_full(1,:), 'dbg_mfcc_full32_frame1.csv');
writematrix(coeffs_EI(1,:), 'dbg_mfcc_raw13_frame1.csv');
writematrix(log(sum(melEnergies(1,:))), 'dbg_c0_replacement_frame1.csv');
%% 9. CMVN LOCALE SU FINESTRA MOBILE
% Replica di speechpy::processing::cmvnw(output_matrix, win_size, true, false)
% (processing.hpp) con padding simmetrico sui frame
if cmvnWin > 0
    coeffs_EI_norm = cmvnw_ei(coeffs_EI, cmvnWin, true); 
else
    coeffs_EI_norm = coeffs_EI;
end

%% 10. VISUALIZZAZIONE MATRICE MFCC (STILE EDGE IMPULSE)

numFrames = size(coeffs_EI_norm, 1);
timeAxis  = (0:numFrames-1) * frameStride_s;   % asse x in secondi

figure('Name', 'Matrice temporale dei coefficienti MFCC (13 × 50)');
imagesc(timeAxis, 1:numCoeffs, coeffs_EI_norm.');
axis xy;
colormap('jet');
colorbar;
xlabel('Time [sec]');
ylabel('MFCC coefficient index');
title('MFCC (coefficiente 1-13 vs tempo)');


writematrix(coeffs_EI,        'mfcc_edgeimpulse_clone_raw_rowmajor.csv');
writematrix(coeffs_EI.',      'mfcc_edgeimpulse_clone_raw_columnmajor.csv');
writematrix(coeffs_EI_norm,   'mfcc_edgeimpulse_clone_cmvn_rowmajor.csv');
writematrix(coeffs_EI_norm.', 'mfcc_edgeimpulse_clone_cmvn_columnmajor.csv');
writematrix(coeffs_EI_norm(1,:), 'dbg_mfcc_cmvn_frame1.csv');
%% =========================================================================
% 11. CONFRONTO DIRETTO CON EDGE IMPULSE (PROVA DEL NOVE)
% =========================================================================

% Simula il flatten row-major di NumPy su una matrice [numFrames x numCoeffs]
matlab_features_1D = reshape(coeffs_EI_norm.', [], 1);

try
    raw_txt = fileread('ei_features_reference.txt');
    C = textscan(raw_txt, '%f', 'Delimiter', ',');
    ei_features_1D = C{1};
    ei_features_1D = ei_features_1D(:);

    fprintf('Lunghezza Edge Impulse: %d\n', numel(ei_features_1D));
    fprintf('Lunghezza MATLAB      : %d\n', numel(matlab_features_1D));

    if numel(ei_features_1D) ~= numel(matlab_features_1D)
        error('Dimensioni non compatibili: Edge Impulse = %d elementi, MATLAB = %d elementi.', ...
            numel(ei_features_1D), numel(matlab_features_1D));
    end

    diff_features = matlab_features_1D - ei_features_1D;
    errore_assoluto = abs(diff_features);

    mae = mean(errore_assoluto);
    mse = mean(diff_features.^2);
    rmse = sqrt(mse);
    max_err = max(errore_assoluto);

    fprintf('\n--- RISULTATI CONFRONTO ---\n');
    fprintf('MAE  : %e\n', mae);
    fprintf('MSE  : %e\n', mse);
    fprintf('RMSE : %e\n', rmse);
    fprintf('MAX  : %e\n', max_err);

    figure('Name', 'Sovrapposizione Feature (MATLAB vs Edge Impulse)');
    plot(ei_features_1D, 'b', 'LineWidth', 2); hold on;
    plot(matlab_features_1D, 'r--', 'LineWidth', 1.5);
    title(sprintf('Confronto Array Feature (%d elementi)', numel(matlab_features_1D)));
    legend('Edge Impulse (Golden Ref)', 'MATLAB (Clone)');
    xlabel(sprintf('Indice Vettore (1 - %d)', numel(matlab_features_1D)));
    ylabel('Valore MFCC');
    grid on;

    figure('Name', 'Differenza Feature (MATLAB - Edge Impulse)');
    plot(diff_features, 'k', 'LineWidth', 1.2);
    title('Differenza elemento per elemento');
    xlabel(sprintf('Indice Vettore (1 - %d)', numel(diff_features)));
    ylabel('Errore');
    grid on;

    err_matrix = reshape(diff_features, [size(coeffs_EI_norm, 2), size(coeffs_EI_norm, 1)]).';
    mean_err_per_coeff = mean(abs(err_matrix), 1);

    fprintf('\n--- MAE PER SINGOLO COEFFICIENTE (1-%d) ---\n', size(coeffs_EI_norm, 2));
    for i = 1:size(coeffs_EI_norm, 2)
        fprintf('Coefficiente %02d: MAE = %e\n', i, mean_err_per_coeff(i));
    end

catch ME
    warning('Problema nel confronto con Edge Impulse: %s', ME.message);
end

%% =========================================================================
% 11B. CONFRONTO COMPLETO 2D: EDGE IMPULSE VS MATLAB
% =========================================================================
try
    % Matrice MATLAB finale, coerente con la pipeline EI dopo CMVN
    matlab_matrix = coeffs_EI_norm;

    % Controllo preliminare sulla lunghezza del vettore 1D Edge Impulse
    expected_len = numel(matlab_matrix);
    if numel(ei_features_1D) ~= expected_len
        error(['Il vettore Edge Impulse ha %d elementi, ma la matrice MATLAB ' ...
               'richiede %d elementi (%d x %d).'], ...
               numel(ei_features_1D), expected_len, ...
               size(matlab_matrix,1), size(matlab_matrix,2));
    end

    % Ricostruzione della matrice Edge Impulse assumendo flatten NumPy row-major
    % su una matrice [numFrames x numCoeffs]
    ei_matrix = reshape(ei_features_1D, [size(matlab_matrix,2), size(matlab_matrix,1)]).';

    % Controllo dimensioni
    fprintf('\n--- CONTROLLO DIMENSIONI MATRICI ---\n');
    fprintf('Dimensione MATLAB matrix      : [%d x %d]\n', size(matlab_matrix,1), size(matlab_matrix,2));
    fprintf('Dimensione Edge Impulse matrix: [%d x %d]\n', size(ei_matrix,1), size(ei_matrix,2));

    if ~isequal(size(matlab_matrix), size(ei_matrix))
        error('Le matrici non hanno la stessa dimensione.');
    end

    % Differenze
    diff_matrix = matlab_matrix - ei_matrix;
    abs_diff_matrix = abs(diff_matrix);

    % Metriche globali 2D
    mae_2d  = mean(abs_diff_matrix, 'all');
    mse_2d  = mean(diff_matrix.^2, 'all');
    rmse_2d = sqrt(mse_2d);
    max_2d  = max(abs_diff_matrix, [], 'all');

    fprintf('\n--- RISULTATI CONFRONTO 2D ---\n');
    fprintf('MAE 2D  : %e\n', mae_2d);
    fprintf('MSE 2D  : %e\n', mse_2d);
    fprintf('RMSE 2D : %e\n', rmse_2d);
    fprintf('MAX 2D  : %e\n', max_2d);

    % Errore medio per coefficiente (colonne)
    mae_per_coeff = mean(abs_diff_matrix, 1);
    fprintf('\n--- MAE PER COEFFICIENTE (2D) ---\n');
    for c = 1:size(matlab_matrix,2)
        fprintf('Coeff %02d: MAE = %e\n', c, mae_per_coeff(c));
    end

    % Errore medio per frame (righe)
    mae_per_frame = mean(abs_diff_matrix, 2);
    fprintf('\n--- MAE PER FRAME (2D) ---\n');
    for r = 1:size(matlab_matrix,1)
        fprintf('Frame %02d: MAE = %e\n', r, mae_per_frame(r));
    end

    % Salvataggio CSV utili
    writematrix(ei_matrix, 'ei_features_reference_matrix.csv');
    writematrix(matlab_matrix, 'matlab_features_matrix.csv');
    writematrix(diff_matrix, 'diff_features_matrix.csv');
    writematrix(abs_diff_matrix, 'abs_diff_features_matrix.csv');
    writematrix(mae_per_coeff, 'mae_per_coeff.csv');
    writematrix(mae_per_frame, 'mae_per_frame.csv');

    % Grafico 1: heatmap differenze assolute
    figure('Name', 'Heatmap errore assoluto |MATLAB - Edge Impulse|');
    imagesc(abs_diff_matrix);
    axis xy;
    colormap('hot');
    colorbar;
    title('Errore assoluto per frame e coefficiente');
    xlabel('Coefficiente MFCC');
    ylabel('Frame');

    % Grafico 2: differenza signed
    figure('Name', 'Heatmap differenza signed MATLAB - Edge Impulse');
    imagesc(diff_matrix);
    axis xy;
    colormap('parula');
    colorbar;
    title('Differenza signed per frame e coefficiente');
    xlabel('Coefficiente MFCC');
    ylabel('Frame');

    % Grafico 3: MAE per coefficiente
    figure('Name', 'MAE per coefficiente');
    bar(1:size(matlab_matrix,2), mae_per_coeff, 'FaceColor', [0.2 0.5 0.8]);
    grid on;
    xlabel('Coefficiente MFCC');
    ylabel('MAE');
    title('Errore medio assoluto per coefficiente');

    % Grafico 4: MAE per frame
    figure('Name', 'MAE per frame');
    plot(1:size(matlab_matrix,1), mae_per_frame, '-o', 'LineWidth', 1.2);
    grid on;
    xlabel('Frame');
    ylabel('MAE');
    title('Errore medio assoluto per frame');

catch ME2
    warning('Problema nel confronto completo 2D: %s', ME2.message);
end

%% 11C. FIGURE PER LA TESI: MFCC MATLAB E ERRORE

% Matrice MFCC MATLAB (50x13) = coeffs_EI_norm
MFCC_matlab = coeffs_EI_norm.';   % 13x50

% Matrice Edge Impulse ricostruita (50x13) = ei_matrix
MFCC_edge_impulse = ei_matrix.';  % 13x50

MFCC_error = abs(MFCC_edge_impulse - MFCC_matlab);

numFrames    = size(coeffs_EI_norm,1);
time_axis    = (0:numFrames-1) * frameStride_s;
coeff_axis   = 1:numCoeffs;

% Figura: MFCC MATLAB
figure('Name','MFCC MATLAB','Position',[100 100 900 300]);
imagesc(time_axis, coeff_axis, MFCC_matlab);
axis xy; colormap('jet'); colorbar;
xlabel('Tempo [s]');
ylabel('Indice coefficiente');
title('Coefficienti MFCC - Implementazione MATLAB');
set(gca,'YTick',1:numCoeffs);

% Figura: errore assoluto
figure('Name','Errore assoluto MFCC','Position',[100 100 900 300]);
imagesc(1:numCoeffs, 1:numFrames, MFCC_error.');
axis xy; colormap('hot'); colorbar;
xlabel('Coefficiente MFCC');
ylabel('Frame');
title('Errore assoluto per frame e coefficiente');
%% =========================================================================
% 12. SALVATAGGIO INTERMEDI PER DEBUG
% =========================================================================
% Flatten finale MATLAB che replica il comportamento NumPy row-major
matlab_features_1D = reshape(coeffs_EI_norm.', [], 1);

% Salvataggi CSV dei principali intermedi completi
writematrix(audio_pre,          'dbg_audio_pre.csv');
writematrix(frames,             'dbg_frames.csv');
writematrix(powSpec,            'dbg_powSpec.csv');
writematrix(melFB,              'dbg_melFB.csv');
writematrix(melEnergies,        'dbg_melEnergies.csv');
writematrix(logMel,             'dbg_logMel.csv');
writematrix(coeffs_EI,          'dbg_coeffs_EI_raw.csv');
writematrix(coeffs_EI_norm,     'dbg_coeffs_EI_norm.csv');
writematrix(matlab_features_1D, 'dbg_features_1D_rowmajor.csv');

% Salvataggi del solo frame 1 per debug mirato
writematrix(powSpec(1,:),        'dbg_powspec_frame1.csv');
writematrix(melEnergies(1,:),    'dbg_melEnergies_frame1.csv');
writematrix(logMel(1,:),         'dbg_logMel_frame1.csv');
writematrix(coeffs_EI(1,:),      'dbg_mfcc_raw13_frame1.csv');
writematrix(coeffs_EI_norm(1,:), 'dbg_mfcc_cmvn_frame1.csv');
%% =========================================================================
% FUNZIONI LOCALI
% =========================================================================

function y = pre_emphasis_ei(x, cof, shift)
      % Replica di ei::audio::processing::preemphasis / speechpy::processing::preemphasis
    x = x(:);
    N = length(x);
    if nargin < 3, shift = 1; end
    if nargin < 2, cof = 0.98; end

    y = zeros(size(x));
    % primi 'shift' campioni: usa x(n) - cof * x(N-shift+n) oppure semplicemente copia
    for n = 1:shift
        y(n) = x(n) - cof * x(N - shift + n);  % come nel codice che avevi già reverse-ingegnerizzato
    end
    % resto dei campioni: classico pre-emphasis
    for n = shift+1:N
        y(n) = x(n) - cof * x(n-shift);
    end
end

function frames = stack_frames_ei(x, frameLen, frameHop)
% Replica del framing usato in processing::frame_signal (processing.hpp)

    x = x(:);
    N = length(x);

    numFrames = floor((N - frameLen) / frameHop) + 1;
    if numFrames < 1
        frames = zeros(0, frameLen);
        return;
    end

    frames = zeros(numFrames, frameLen);
    idx = 1;
    for k = 1:numFrames
        frames(k,:) = x(idx:idx+frameLen-1);
        idx = idx + frameHop;
    end
end

function powSpec = power_spectrum_ei(frames, fftLen)
% Replica di numpy::power_spectrum (edge-impulse-sdk/dsp/numpy.hpp)
    if nargin < 2
        error('power_spectrum_ei requires frames and fftLen.');
    end

    if fftLen <= 0 || abs(fftLen - round(fftLen)) > eps
        error('fftLen must be a positive integer.');
    end
    if mod(fftLen, 2) ~= 0
        error('fftLen must be even.');
    end

    numFrames = size(frames, 1);
    numBins   = fftLen/2 + 1;

    if numFrames == 0
        powSpec = zeros(0, numBins);
        return;
    end

    powSpec = zeros(numFrames, numBins, 'single'); 
    for k = 1:numFrames
        frame = single(frames(k, :).'); 
        X = fft(frame, fftLen);
        P = (abs(X(1:numBins)).^2) / single(fftLen); % MANTIENI LA DIVISIONE
        powSpec(k, :) = P.';
    end
end

function fb = mel_filterbank_ei(numFilters, fftLen, fs, lowFreq, highFreq)
    if nargin < 5 || isempty(highFreq) || highFreq == 0
        highFreq = fs / 2;
    end
    if nargin < 4 || isempty(lowFreq)
        lowFreq = 0;
    end

    if numFilters < 2
        error('numFilters must be at least 2.');
    end
    if lowFreq < 0
        error('lowFreq cannot be less than 0.');
    end
    if highFreq > fs/2
        error('highFreq cannot be greater than fs/2.');
    end
    if lowFreq >= highFreq
        error('lowFreq must be smaller than highFreq.');
    end

    numBins = fftLen/2 + 1;
    fb = zeros(numFilters, numBins);

    lowMel  = hz2mel_ei(lowFreq);
    highMel = hz2mel_ei(highFreq);

    melPoints = linspace(lowMel, highMel, numFilters + 2);
    hzPoints  = mel2hz_ei(melPoints);
    hzPoints(end) = hzPoints(end) - 0.001;
    bins = floor((fftLen + 1) * hzPoints / fs);

    for m = 1:numFilters
        left   = bins(m);
        center = bins(m + 1);
        right  = bins(m + 2);

        left   = max(left,   0);
        center = max(center, 0);
        right  = min(right,  numBins - 1);

        if center <= left
            center = left + 1;
        end
        if right <= center
            right = center + 1;
        end

        if right > numBins - 1
            right = numBins - 1;
        end

        % Rampa crescente
        for k = left:(center-1)
            if k >= 0 && k <= numBins-1
                fb(m, k+1) = (k - left) / (center - left);
            end
        end

        % Picco
        if center >= 0 && center <= numBins-1
            fb(m, center+1) = 1;
        end

        % Rampa decrescente
        for k = (center+1):right
            if k >= 0 && k <= numBins-1
                fb(m, k+1) = (right - k) / (right - center);
            end
        end

        % Controllo stile Edge Impulse/SpeechPy:
        % nessuna riga deve essere completamente nulla
        if all(fb(m, :) == 0)
            error(['At least one row of the mel filterbank contains all zeros. ' ...
                   'Suggest lowering numFilters or increasing fftLen.']);
        end
    end
end

function mel = hz2mel_ei(f)
    mel = 1127.0 * log(1.0 + f/700.0);
end

function f = mel2hz_ei(mel)
    f = 700.0 * (exp(mel/1127.0) - 1.0);
end

function Y = cmvnw_ei(X, winSize, varianceNormalization)
        % Replica di speechpy::processing::cmvnw (edge-impulse-sdk/dsp/speechpy/processing.hpp)
    if nargin < 3
        varianceNormalization = false;
    end

    if winSize <= 0
        Y = X;
        return;
    end

    if abs(winSize - round(winSize)) > eps
        error('winSize must be an integer.');
    end
    if mod(winSize, 2) ~= 1
        error('winSize must be odd, consistent with Edge Impulse/SpeechPy.');
    end

    X = single(X);
    padSize = (winSize - 1) / 2;
    epsVal = single(1e-10);

    Xpad = symmetric_pad_rows(X, padSize);

    meansubtracted = zeros(size(X), 'single');
    for i = 1:size(X,1)
        window = Xpad(i:i+winSize-1, :);
        meansubtracted(i,:) = X(i,:) - mean(window, 1);
    end

    if varianceNormalization
        Vpad = symmetric_pad_rows(meansubtracted, padSize);
        Y = zeros(size(X), 'single');
        for i = 1:size(X,1)
            window = Vpad(i:i+winSize-1, :);
            sigma = std(window, 0, 1);   % allineato a np.std(..., axis=0), ddof=0
            Y(i,:) = meansubtracted(i,:) ./ (sigma + epsVal);
        end
    else
        Y = meansubtracted;
    end
end

function Xpad = symmetric_pad_rows(X, padSize)
    if padSize == 0
        Xpad = X;
        return;
    end

    n = size(X,1);
    idx = zeros(1, n + 2*padSize);

    for k = 1:length(idx)
        p = k - padSize;
        while p < 1 || p > n
            if p < 1
                p = 2 - p;
            elseif p > n
                p = 2*n - p;
            end
        end
        idx(k) = p;
    end

    Xpad = X(idx, :);
end

function Y = dct_ortho_ei(X)
% Implementazione MATLAB della DCT-II ortonormale usata da numpy::dct2
    X = single(X); % Mantieni la singola precisione
    [numRows, N] = size(X);
    n = single(0:(N-1));
    k = single(0:(N-1));
    C = cos(pi / single(N) * (n + 0.5).' * k);
    alpha = sqrt(2 / single(N)) * ones(1, N, 'single');
    alpha(1) = sqrt(1 / single(N));
    T = C .* alpha;
    Y = X * T;
end

function [frameLen, frameHop] = ei_frame_sizes(fs, frameLength_s, frameStride_s, implementationVersion)
% Replica della logica di ei_frame_sizes usata in ei_run_dsp.h per MFCC

    if ~ismember(implementationVersion, [1 2 3 4])
        error('implementationVersion must be 1, 2, 3, or 4.');
    end

    if implementationVersion == 1
        frameLen = round(fs * frameLength_s);
    else
        frameLen = ceil_unless_very_close_to_floor(fs * frameLength_s);
    end

    if implementationVersion == 1
        frameHop = round(fs * frameStride_s);
    else
        frameHop = ceil_unless_very_close_to_floor(fs * frameStride_s);
    end
end

function v = ceil_unless_very_close_to_floor(x)
xf = floor(x);
if x > xf && (x - xf) < 0.001
    v = xf;
else
    v = ceil(x);
end
end
function [ok, cfg] = awr_sensor_config(uart, cfgFile)
% AWR_SENSOR_CONFIG  Načíta .cfg súbor a pošle Profile/Chirp/Frame príkazy
%
% Zodpovedá krokom 13-15 v mmWave Studio SensorConfig tab.
% .cfg formát: štandardný TI mmWave CLI (rovnaký ako mmWS exportuje)

ok = false;
cfg = struct();

%% Načítaj .cfg súbor
awr_log(['Načítavam .cfg: ' cfgFile]);
fid = fopen(cfgFile, 'r');
if fid < 0
    awr_log(['ERR: Nemôžem otvoriť: ' cfgFile]);
    return;
end
lines = {};
while ~feof(fid)
    L = fgetl(fid);
    if ischar(L), lines{end+1, 1} = strtrim(L); end
end
fclose(fid);
awr_log(sprintf('Načítaných %d riadkov z .cfg', numel(lines)));

%% Filtruj a pošli príkazy
SKIP_CMDS = {'sensorStart', 'sensorStop', 'flushCfg'};

awr_log('Posielam konfiguračné príkazy na AWR2944...');
sentCount = 0;
errorCount = 0;
firstErrCmd = '';

for i = 1:numel(lines)
    L = lines{i};
    if isempty(L) || L(1) == '%' || L(1) == '#', continue; end
    parts = strsplit(L, ' ');
    cmd = parts{1};
    if ismember(cmd, SKIP_CMDS)
        awr_log(['  SKIP: ' L]);
        continue;
    end
    awr_log(['  CMD: ' L]);
    awr_send_cmd(uart, L);
    pause(0.05);
    respLines = awr_read_lines(uart, 3, 0.3);
    lineHadError = false;
    for j = 1:numel(respLines)
        RL = respLines{j};
        if isempty(RL), continue; end
        if contains(RL, 'Error', 'IgnoreCase', true) || ...
           contains(RL, 'Fail', 'IgnoreCase', true)
            awr_log(['  ERR odpoved: ' RL]);
            lineHadError = true;
        end
    end
    if lineHadError
        errorCount = errorCount + 1;
        if isempty(firstErrCmd), firstErrCmd = L; end
    end
    sentCount = sentCount + 1;
end

awr_log(sprintf('Odoslane: %d prikazov, Chyby: %d', sentCount, errorCount));

%% Parsuj .cfg pre výpočet veľkosti .bin
awr_log('Parsovanie .cfg parametrov...');
cfg = parse_cfg(lines);
print_cfg_summary(cfg);

% Uloz profil ako naposledy pouzity (aby sa nastroje ako micro_doppler dali volat
% rovno na kocku bez opatovneho zadavania .cfg). radar_cfg si ho ulozi sam.
try, radar_cfg(cfgFile); catch, end

% Vysledok: konfiguracia je uspesna LEN ak radar neodmietol ziadny prikaz.
% (Predtym sa vzdy vracalo ok=true, takze odmietnuty chirpCfg/channelCfg presiel
%  ticho a zlyhanie sa prejavilo az 30 s timeoutom DCA bez dat - cervena LED.)
if errorCount > 0
    ok = false;
    awr_log(sprintf(['CHYBA: radar odmietol %d konfiguracny(ch) prikaz(ov). ' ...
        'Prvy chybny: "%s". Skontroluj .cfg (napr. zhodu channelCfg <-> chirpCfg masiek). ' ...
        'SensorConfig NEdokonceny.'], errorCount, firstErrCmd));
else
    ok = true;
    awr_log('OK: SensorConfig dokonceny');
end
pause(0.3);
flush(uart);
end

%% ── Parsovanie .cfg parametrov ────────────────────────────────────────
function cfg = parse_cfg(lines)
cfg = struct();

% Defaultné hodnoty
cfg.numADCSamples   = 256;
cfg.adcSampleRate   = 10000;
cfg.freqSlopeConst  = 29.982;
cfg.startFreq       = 77.0;
cfg.idleTime        = 100.0;
cfg.rampEndTime     = 60.0;
cfg.adcStartTime    = 6.0;
cfg.txChannelEn     = 3;
cfg.rxChannelEn     = 15;
cfg.numRx           = 4;
cfg.numTx           = 2;
cfg.chirpsPerFrame  = 128;
cfg.numFrames       = 0;
cfg.framePeriodicity= 40.0;
cfg.numChirpLoops   = 128;
cfg.startChirpTx    = 0;
cfg.endChirpTx      = 1;
cfg.adcBits         = 16;
cfg.adcFormat       = 0;

for i = 1:numel(lines)
    L = strtrim(lines{i});
    if isempty(L) || L(1) == '%' || L(1) == '#', continue; end

    parts = strsplit(L, ' ');
    cmd = parts{1};
    vals = cellfun(@str2double, parts(2:end), 'UniformOutput', false);
    vals = [vals{:}];
    vals(isnan(vals)) = 0;

    switch lower(cmd)
        case 'profilecfg'
            % TI mmWave CLI profileCfg parameter order (AWR2944):
            % profileCfg profileId startFreq idleTime adcStartTime rampEndTime
            %             txStartTime txOutPower txPhaseShifter freqSlopeConst
            %             txStartTime2 numAdcSamples adcSampleRate rxGain ...
            % Index vals:  1           2           3            4           5
            %               6           7           8            9
            %               10          11          12           13
            %
            % Priklad: profileCfg 0 77 186 2.5 57.14 0 0 70 1 272 5070 0 0 30
            %          vals:       1  2   3   4    5  6  7  8  9  10   11 12 13 14
            % vals(2)=startFreq=77 GHz
            % vals(3)=idleTime=186 us
            % vals(4)=adcStartTime=2.5 us
            % vals(5)=rampEndTime=57.14 us
            % vals(8)=freqSlopeConst [MHz/us]   (POZOR: vals(9) je txStartTime, nie sklon)
            % vals(10)=numAdcSamples
            % vals(11)=adcSampleRate [ksps]
            if numel(vals) >= 11
                cfg.startFreq      = vals(2);
                cfg.idleTime       = vals(3);
                cfg.adcStartTime   = vals(4);
                cfg.rampEndTime    = vals(5);
                cfg.freqSlopeConst = vals(8);
                cfg.numADCSamples  = vals(10);
                cfg.adcSampleRate  = vals(11);
            end

        case 'chirpcfg'
            % chirpCfg startIdx endIdx profileId freqVar slopeVar idleVar adcVar txEnable
            if numel(vals) >= 8
                % Zbiera vsetky TX masky zo vsetkych chirpCfg riadkov
                txMask = vals(8);
                txCount = sum(bitget(uint32(txMask), 1:4));
                cfg.numTx = max(cfg.numTx, txCount);
                % startChirpTx/endChirpTx sa nastavuje z frameCfg
            end

        case 'framecfg'
            % frameCfg startChirpIdx endChirpIdx numLoops numFrames periodicity trigSelect trigDelay
            % Priklad: frameCfg 0 3 16 0 272 200 1 0
            % vals:              1  2   3   4   5   6   7  8
            % vals(1)=startChirp=0, vals(2)=endChirp=3
            % vals(3)=numLoops=16, vals(4)=numFrames=0(infinite)
            % POZOR: periodicita je 6. hodnota [ms] (overene podla LogFile FrameConfig:
            % 1e8 ns = 100 ms pre 'frameCfg 0 2 16 20 560 100 1 0'); 5. hodnota nie je perioda.
            if numel(vals) >= 4
                cfg.startChirpTx     = vals(1);
                cfg.endChirpTx       = vals(2);
                cfg.numChirpLoops    = vals(3);
                cfg.numFrames        = vals(4);
                % chirpsPerFrame = (endChirp - startChirp + 1) * numLoops
                cfg.chirpsPerFrame   = (vals(2) - vals(1) + 1) * vals(3);
            end
            if numel(vals) >= 6
                cfg.framePeriodicity = vals(6);   % [ms]
            end

        case 'channelcfg'
            % channelCfg rxChannelEn txChannelEn cascading
            if numel(vals) >= 2
                cfg.rxChannelEn = vals(1);
                cfg.txChannelEn = vals(2);
                cfg.numRx = sum(bitget(uint32(vals(1)), 1:4));
                cfg.numTx = sum(bitget(uint32(vals(2)), 1:4));
            end

        case 'adccfg'
            % adcCfg numADCBits adcOutputFmt
            % numADCBits: 1=12bit, 2=16bit, 3=14bit  (pozor: 2=16, 3=14 je TI mapovanie)
            if numel(vals) >= 2
                bitMap = [12, 16, 14];  % index 1,2,3
                idx = round(vals(1));
                if idx >= 1 && idx <= 3
                    cfg.adcBits = bitMap(idx);
                end
                cfg.adcFormat = vals(2);
            end
    end
end

% Vypočítaj odvodené hodnoty
cfg.bytesPerSample = cfg.adcBits / 8;
cfg.expectedBytes = cfg.numADCSamples * cfg.chirpsPerFrame * cfg.numRx * cfg.bytesPerSample;
if cfg.numFrames > 0
    cfg.expectedTotalBytes = cfg.expectedBytes * cfg.numFrames;
    cfg.expectedMB = cfg.expectedTotalBytes / 1e6;
else
    cfg.expectedTotalBytes = inf;
    cfg.expectedMB = inf;
end
end

%% ── Výpis súhrnu konfigurácie ─────────────────────────────────────────
function print_cfg_summary(cfg)
awr_log('');
awr_log('=== Konfiguracia radaru ===');
awr_log(sprintf('  Start freq:      %.3f GHz', cfg.startFreq));
awr_log(sprintf('  Freq slope:      %.4f MHz/us', cfg.freqSlopeConst));
awr_log(sprintf('  Idle time:       %.2f us', cfg.idleTime));
awr_log(sprintf('  Ramp end time:   %.2f us', cfg.rampEndTime));
awr_log(sprintf('  ADC samples:     %d', cfg.numADCSamples));
awr_log(sprintf('  ADC sample rate: %d ksps', cfg.adcSampleRate));
awr_log(sprintf('  ADC bits:        %d', cfg.adcBits));
awr_log(sprintf('  Num RX:          %d', cfg.numRx));
awr_log(sprintf('  Num TX:          %d', cfg.numTx));
awr_log(sprintf('  Start chirp TX:  %d', cfg.startChirpTx));
awr_log(sprintf('  End chirp TX:    %d', cfg.endChirpTx));
awr_log(sprintf('  Chirp loops:     %d', cfg.numChirpLoops));
awr_log(sprintf('  Chirps/frame:    %d  (= (%d-%d+1) x %d loops)', ...
    cfg.chirpsPerFrame, cfg.endChirpTx, cfg.startChirpTx, cfg.numChirpLoops));
awr_log(sprintf('  Num frames:      %d  (0=infinite)', cfg.numFrames));
awr_log(sprintf('  Frame period:    %.1f ms', cfg.framePeriodicity));
if cfg.numFrames > 0
    awr_log(sprintf('  Ocakavana velkost .bin: %.2f MB', cfg.expectedMB));
    awr_log(sprintf('    = %d samples x %d chirps/frame x %d RX x %d frames x %d B/sample', ...
        cfg.numADCSamples, cfg.chirpsPerFrame, cfg.numRx, cfg.numFrames, cfg.bytesPerSample));
else
    awr_log('  Ocakavana velkost .bin: neobmedzena (infinite frames)');
end
awr_log('');
end

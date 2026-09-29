function P = radar_cfg(cfgFile)
% RADAR_CFG  Common reader of a .cfg profile (or a LogFile .txt) + derived quantities.
%
%   P = radar_cfg(cfgFile)   % parses the profile and STORES it as the last one used
%   P = radar_cfg()          % returns the LAST profile used (from memory/setpref)
%
% The input can be:
%   - an mmWave CLI .cfg profile (channelCfg/profileCfg/frameCfg ...), or
%   - adc_data_LogFile.txt (mmWave Studio API log stored with the .bin) - the
%     parameters are recomputed back from it.
%
% A single source of truth for the tools (e.g. CFG_EDITOR_2944): profile parsing
% and computation of axes and quantities, so that the formulas are not repeated
% (and cannot diverge).
%
% Memory of the last .cfg: functions can be called directly on a data cube in
% the workspace without entering the profile again.
%
% Returns a structure P with the fields:
%   .cfgFile (path to the file used, '' for defaults)
%   .startFreq_GHz .idle_us .rampEnd_us .slope_MHzus .numAdc .fs_ksps
%   .numRx .numTx .chirpStart .chirpEnd .numLoops .chirpsPerFrame .numFrames
%   .framePeriod_ms
%   .lambda_m .Tr_s .Teff_s  .NfftR .NrBins .rangeAxis .rangeRes_m .Rmax_m
%   .rampBW_MHz .fEnd_GHz  .NfftD .velAxis .vMax_ms  .winR .winD
%
% Note: the maximum range and velocity are for REAL-valued sampling and TDM-MIMO
% (one TX once every numTx chirps).

    persistent LASTP
    PREFGRP = 'awr2944_dca';  PREFKEY = 'lastRadarCfg';

    % ---- no argument: return the last profile used ----
    if nargin < 1 || isempty(cfgFile)
        if ~isempty(LASTP)
            P = LASTP;  return;
        elseif ispref(PREFGRP, PREFKEY)
            P = getpref(PREFGRP, PREFKEY);  LASTP = P;  return;
        else
            warning('radar_cfg: no stored .cfg - using defaults (DCA_RX1111_TX1110_TDM).');
            cfgFile = '';
        end
    end

    P = local_defaults();

    if isstruct(cfgFile)
        % Parameter override (e.g. from CFG_EDITOR_2944): compute from the given values, no file, no cache.
        fn = fieldnames(cfgFile);
        for i = 1:numel(fn)
            if isfield(P, fn{i}), P.(fn{i}) = cfgFile.(fn{i}); end
        end
        P = local_derive(P);
        return;
    end

    if ~isempty(cfgFile) && isfile(char(cfgFile))
        txt   = fileread(char(cfgFile));
        lines = regexp(txt, '\r\n|\n|\r', 'split');
        if any(contains(lines, 'API:ProfileConfig'))   % it is a LogFile (.txt)
            P = local_fromLog(P, lines);
        else                                            % it is a CLI .cfg
            P = local_fromCfg(P, lines);
        end
        P.cfgFile = char(cfgFile);
    elseif ~isempty(cfgFile)
        warning('radar_cfg: file ''%s'' not found, using defaults.', char(cfgFile));
    end

    P = local_derive(P);

    % ---- store as the last profile used (only if from a real file) ----
    if ~isempty(P.cfgFile)
        LASTP = P;
        try, setpref(PREFGRP, PREFKEY, P); catch, end
    end
end

% ===================== parsing =====================
function P = local_defaults()
    P = struct();
    P.cfgFile = '';
    P.startFreq_GHz = 77;  P.idle_us = 267;  P.rampEnd_us = 57.14;  P.slope_MHzus = 70;
    P.numAdc = 560;  P.fs_ksps = 11396;  P.numRx = 4;  P.numTx = 3;
    P.chirpStart = 0;  P.chirpEnd = 2;  P.numLoops = 16;  P.numFrames = 20;  P.framePeriod_ms = NaN;
    P.txPhys = [];   % physical TX indices from the chirpCfg masks
    % Elevation per-pair calibration [rad] (corner reflector on boresight, z = 0,
    % R = 3 m, radar levelled to 0 deg; 19-frame average).
    % Recalibration must always be done with the radar levelled. Pair order = increasing
    % horizontal position [4.5 5.0 5.5 6.0] lambda; valid for the TDM profile TX1110
    % (TX0/TX2/TX1). For other profiles (e.g. TX1011) only some pairs overlap and the
    % calibration is applied partially. The elevation methodology is described in
    % Gamcova & Gamec, Radary v automobiloch: metodika merania a zadania (2026).
    % MASTER value.
    P.elevCalib = [-0.0940, 0.0881, 0.5411, 0.3502];
    % Empirical elevation scale: z was systematically overestimated by ~1.2x
    % (no angular trend -> constant).
    % Use: sinEl = -phase/(2*pi*dz*P.elevScale). The physical cause is not explained
    % (probably the phase slope of the elevation pattern of the 8-patch antenna).
    % A table-top point was excluded from the fit (multipath from the table surface).
    % MASTER value.
    P.elevScale = 1.20;
    % Elevation GATE: z is computed ONLY if |az| <= elevGateAzDeg AND the peak
    % strength >= SNR threshold; otherwise z = NaN (the point stays in the cloud,
    % elevation unknown). The pair-spread metric was rejected - it does not
    % discriminate (coherent clutter, e.g. a door frame, has consistent pairs).
    % Good points: |az| <= 3.0 deg; bad: >= 13.4 deg -> threshold 6 deg in the gap.
    % SNR thresholds are PER TOOL (different units): the live single-frame threshold
    % is set by measurement (elevGateSnrLive).
    P.elevGateAzDeg   = 6;
    P.elevGateSnrLive = 15;   % single-frame peak/median; PRELIMINARY - verify by measurement

    % Optional override of the MASTER values above by an external file
    % elev_calib_local.m (teaching - students' own calibration).
    % If the file is not on the MATLAB path, nothing changes (elev_calib_load returns
    % an empty struct and the block below finds no fields to override).
    c = elev_calib_load();
    if isfield(c,'elevCalib') && isnumeric(c.elevCalib) && numel(c.elevCalib)==4
        P.elevCalib = c.elevCalib(:).';
    end
    if isfield(c,'elevScale') && isnumeric(c.elevScale) && isscalar(c.elevScale)
        P.elevScale = c.elevScale;
    end
    if isfield(c,'elevGateAzDeg') && isnumeric(c.elevGateAzDeg) && isscalar(c.elevGateAzDeg)
        P.elevGateAzDeg = c.elevGateAzDeg;
    end
    if isfield(c,'elevGateSnrLive') && isnumeric(c.elevGateSnrLive) && isscalar(c.elevGateSnrLive)
        P.elevGateSnrLive = c.elevGateSnrLive;
    end
end

function P = local_fromCfg(P, lines)
% mmWave CLI .cfg (channelCfg rxEn txEn ...; profileCfg ...; frameCfg ...; chirpCfg ...)
    txm = [];
    for i = 1:numel(lines)
        t = strtrim(lines{i});
        if isempty(t) || t(1)=='%' || t(1)=='#', continue; end
        pp = strsplit(t);  v = str2double(pp(2:end));  v(isnan(v)) = 0;
        switch lower(pp{1})
            case 'channelcfg'
                if numel(v) >= 2
                    P.numRx = sum(bitget(uint32(v(1)), 1:4));   % cfg: rxEn comes first
                    P.numTx = sum(bitget(uint32(v(2)), 1:4));
                end
            case 'profilecfg'
                if numel(v) >= 11
                    P.startFreq_GHz = v(2);  P.idle_us = v(3);  P.rampEnd_us = v(5);
                    P.slope_MHzus = v(8);    P.numAdc = v(10);  P.fs_ksps = v(11);
                end
            case 'framecfg'
                if numel(v) >= 4
                    P.chirpStart = v(1);  P.chirpEnd = v(2);  P.numLoops = v(3);  P.numFrames = v(4);
                end
                if numel(v) >= 6, P.framePeriod_ms = v(6); end   % 6th value = period [ms]
            case 'chirpcfg'
                if numel(v) >= 8, txm(end+1) = v(8); end %#ok<AGROW>  TX mask
        end
    end
    if ~isempty(txm), P.txPhys = round(log2(max(txm,1))); end   % mask -> physical TX index
end

function P = local_fromLog(P, lines)
% adc_data_LogFile.txt (mmWave Studio API log) - constants converted back.
% ProfileConfig: 0,startFreqC,idleC,adcStartC,rampEndC,0,0,slopeC,0,numAdc,sampleKsps,...
% FrameConfig:   cs,ce,numFrames,numLoops,periodicity_ns,0,numAdc,0
% ChannelConfig: txEn,rxEn,0   (NOTE: in the log, TX comes first!)
% ChirpConfig:   cs,ce,0,0,0,0,0,txMask,0
    txm = [];
    for i = 1:numel(lines)
        t = strtrim(lines{i});
        k = strfind(t, 'API:');
        if isempty(k), continue; end
        parts = strsplit(t(k(1):end), ',');
        cmd = parts{1};  v = str2double(parts(2:end));  v(isnan(v)) = 0;
        switch cmd
            case 'API:ChannelConfig'
                if numel(v) >= 2
                    P.numTx = sum(bitget(uint32(v(1)), 1:4));   % log: txEn comes first
                    P.numRx = sum(bitget(uint32(v(2)), 1:4));
                end
            case 'API:ProfileConfig'
                if numel(v) >= 11
                    P.startFreq_GHz = v(2)*53.6441803/1e9;   % LSB -> GHz
                    P.idle_us       = v(3)/100;
                    P.rampEnd_us    = v(5)/100;
                    P.slope_MHzus   = v(8)*48279/1e6;        % LSB -> MHz/us
                    P.numAdc        = v(10);
                    P.fs_ksps       = v(11);
                end
            case 'API:FrameConfig'
                if numel(v) >= 4
                    P.chirpStart = v(1);  P.chirpEnd = v(2);  P.numFrames = v(3);  P.numLoops = v(4);
                end
                if numel(v) >= 5, P.framePeriod_ms = v(5)/1e6; end   % ns -> ms
            case 'API:ChirpConfig'
                if numel(v) >= 8, txm(end+1) = v(8); end %#ok<AGROW>  TX mask
        end
    end
    if ~isempty(txm), P.txPhys = round(log2(max(txm,1))); end
end

function P = local_derive(P)
    c = 299792458;
    P.numRx = max(1, P.numRx);  P.numTx = max(1, P.numTx);  P.numLoops = max(1, P.numLoops);
    P.chirpsPerFrame = (P.chirpEnd - P.chirpStart + 1) * P.numLoops;

    fs = P.fs_ksps*1e3;  slope = P.slope_MHzus*1e12;
    P.NfftR = 2^nextpow2(max(P.numAdc,1));  P.NrBins = P.NfftR/2;
    P.rangeAxis = (0:P.NrBins-1) * c / (2*slope*(P.NfftR/fs));
    if slope > 0
        P.rangeRes_m = c/(2*slope*(P.numAdc/fs));
        P.Rmax_m     = c*fs/(4*slope);          % REAL-valued sampling -> usable half of the band
    else
        P.rangeRes_m = NaN;  P.Rmax_m = NaN;
    end
    P.rampBW_MHz = P.slope_MHzus * P.rampEnd_us;
    P.fEnd_GHz   = P.startFreq_GHz + P.rampBW_MHz/1000;

    P.lambda_m = c/(P.startFreq_GHz*1e9);
    P.Tr_s     = (P.idle_us + P.rampEnd_us)*1e-6;
    % Doppler TDM factor = number of chirp configurations (chirpEnd-chirpStart+1), NOT numTx.
    % Standard TDM: 3 TX = 3 chirpCfg -> factor 3 (= numTx, no change).
    % NON-TDM (all TX simultaneously, 1 chirpCfg): factor 1 -> Teff = Tr -> 3x higher
    % unambiguous velocity (Doppler sampled every chirp, not every numTx chirps).
    P.tdmFactor = max(1, round(P.chirpEnd - P.chirpStart + 1));
    P.Teff_s   = P.tdmFactor * P.Tr_s;

    [P.velAxis, P.NfftD] = local_velAxis(P.numLoops, P.Teff_s, P.lambda_m);
    P.vMax_ms = max(abs(P.velAxis));
    P.winR = local_hann(P.numAdc);
    P.winD = local_hann(P.numLoops);
end

function [vel, NfftD] = local_velAxis(loops, Teff, lambda)
    loops = max(1, loops);
    NfftD = max(128, 2^nextpow2(loops*8));
    dop = -floor(NfftD/2):ceil(NfftD/2)-1;
    if mod(numel(dop),2)==0, dop = dop(2:end); end
    vel = dop*(1/Teff)/NfftD*lambda/2;     % TDM PRF = 1/Teff
end

function w = local_hann(n)
    if n <= 1, w = ones(n,1); return; end
    w = 0.5 - 0.5*cos(2*pi*(0:n-1)'/n);    % periodic Hann window
end

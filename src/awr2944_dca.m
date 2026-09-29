classdef awr2944_dca < handle
% AWR2944_DCA  Raw ADC data acquisition from the TI AWR2944EVM + DCA1000EVM
% in MATLAB, without mmWave Studio.  [v1.8]
%
% BATCH (record -> cube -> .bin + adc_data_LogFile.txt):
%   src  = awr2944_dca;
%   cube = src.capture();   % asks for profile and port -> configure -> record
%                           % into Downloads\awr2944_<timestamp>\
%   src.release();
%
% LIVE (one frame per call):
%   src = awr2944_dca; src.RecordToFile = false;
%   src.startLive(); fr = src.readFrame(); ... ; src.stopLive(); src.release();
%
% Storage: by default into the current user's Downloads folder, each measurement
% into its own subfolder 'awr2944_YYYY-MM-DD_HH-MM-SS' (.bin + adc_data_LogFile.txt).
% The .bin + LogFile pair follows the mmWave Studio output convention.
%
% NOTE: the AWR2944 outputs REAL-valued samples (not IQ) -> cube/frame are real
% (double converted from int16).
% Cube: [SamplesPerChirp x NumRX x ChirpsPerFrame (x NumFrames in batch mode)]

    properties
        ConfigPort       = "COM9"
        HostIPAddress    = "192.168.33.30"
        DcaIPAddress     = "192.168.33.180"
        ConfigFile       = ""        % empty -> DCA_RX1111_TX1110_TDM.cfg next to the class (set in constructor)
        RecordLocation   = ""        % empty -> Downloads folder (set in constructor)
        RecordFilePrefix = "adc_data_Raw"
        RecordToFile     = true
        WriteLogFile     = true      % write adc_data_LogFile.txt together with the .bin
        RecordSubfolder  = true      % each measurement into its own time-stamped subfolder
        CaptureFrames    = 20        % frames for capture() if the .cfg has numFrames=0 (e.g. Demo Visualizer export)
    end

    properties (SetAccess = private)
        SamplesPerChirp = []
        NumRX           = []
        NumTX           = []
        AdcBits         = 16
        ChirpsPerFrame  = []
        NumFrames       = []
        IsReal          = true
        LastBinFile     = ""
        LiveActive      = false
    end

    properties (Access = private)
        uart = []
        dca  = []
        cfg  = []
        isSetup = false
        nCaptures = 0      % capture() calls since last setup (0 = first start after configuration)
        sRawLeftover  = uint8([])
        sPayloadAccum = uint8([])
        sLastSeq      = -1
        perFrameBytes = 0
    end

    methods
        function obj = awr2944_dca(varargin)
            for k = 1:2:numel(varargin)-1
                p = varargin{k}; v = varargin{k+1};
                if (ischar(p) || isstring(p)) && isprop(obj, char(p))
                    try, obj.(char(p)) = v; catch, warning('Could not set %s', char(p)); end
                else
                    warning('Unknown property: %s', char(p));
                end
            end
            if strlength(string(obj.ConfigFile)) == 0
                here = fileparts(mfilename('fullpath'));   % folder containing awr2944_dca.m
                obj.ConfigFile = string(fullfile(here, 'DCA_RX1111_TX1110_TDM.cfg'));
            end
            if strlength(string(obj.RecordLocation)) == 0
                obj.RecordLocation = string(awr2944_dca.downloadsDir());
            end
            obj.parseCfgDims();
        end

        function openUart(obj)
            obj.pickPort();                 % always asks which COM port to use
            obj.uart = serialport(obj.ConfigPort, 115200, 'DataBits',8, ...
                       'Parity','none', 'StopBits',1, 'FlowControl','none', 'Timeout',5);
            configureTerminator(obj.uart, 'LF');
            pause(1.0);            % cold start: let the XDS110/CDC port settle after opening (DTR reset)
            flush(obj.uart);
            awr_send_cmd(obj.uart, 'sensorStop'); awr_read_lines(obj.uart, 3, 0.4);
            awr_send_cmd(obj.uart, 'flushCfg');   awr_read_lines(obj.uart, 3, 0.4);
        end

        function port = pickPort(obj)
        % Asks which serial (COM) port to use. Lists the available ports; on
        % Windows also with descriptions, marking/offering the 'Application/User UART'
        % (XDS110 configuration UART). Enter = offered default. Cross-platform (serialportlist).
            try, avail = serialportlist("available"); catch, avail = serialportlist(); end
            if isempty(avail)
                error('awr2944_dca:noport', ['No serial port found.\n' ...
                    'Connect the radar (XDS110) over USB, check that Device Manager lists\n' ...
                    '"XDS110 Class Application/User UART", then run setup again.']);
            end
            descMap = obj.portDescr();      % COMx -> description (Windows only; empty otherwise)
            recIdx = 0;
            fprintf('\nAvailable serial ports:\n');
            for i = 1:numel(avail)
                nm = char(avail(i)); d = '';
                if isKey(descMap, nm), d = descMap(nm); end
                tag = '';
                if ~isempty(d) && (contains(d,'Application/User UART','IgnoreCase',true) || ...
                                   contains(d,'Enhanced COM Port','IgnoreCase',true))
                    tag = '  <- recommended (config)'; if recIdx==0, recIdx = i; end
                elseif strcmpi(nm, obj.ConfigPort)
                    tag = '  <- default';
                end
                if isempty(d)
                    fprintf('  [%d] %s%s\n', i, nm, tag);
                else
                    fprintf('  [%d] %s   (%s)%s\n', i, nm, d, tag);
                end
            end
            if recIdx > 0, defStr = char(avail(recIdx)); else, defStr = char(obj.ConfigPort); end
            s = strtrim(input(sprintf('Select config port (number from the list, or name) [%s]: ', defStr), 's'));
            if isempty(s)
                port = defStr;
            else
                n = str2double(s);
                if ~isnan(n) && n>=1 && n<=numel(avail), port = char(avail(n)); else, port = s; end
            end
            obj.ConfigPort = string(port);
            fprintf('  -> using port: %s\n', port);
        end

        function cfg = pickConfig(obj)
        % Selects the .cfg profile. Lists the *.cfg files found in the class folder and asks.
        % Enter = default; a list number, a file name, a full path, or 'b' = browse.
            here  = fileparts(mfilename('fullpath'));
            L     = dir(fullfile(here, '*.cfg'));
            names = string({L.name});
            cur   = char(obj.ConfigFile);
            [~, curN, curE] = fileparts(cur); curFile = [curN curE];
            defIdx = 0;
            for i = 1:numel(names), if strcmpi(names(i), curFile), defIdx = i; break; end, end
            fprintf('\nAvailable .cfg profiles (%s):\n', here);
            if isempty(names)
                fprintf('  (no .cfg in the class folder)\n');
            else
                for i = 1:numel(names)
                    mark = ''; if i == defIdx, mark = '  <- default'; end
                    fprintf('  [%d] %s%s\n', i, names(i), mark);
                end
            end
            if defIdx > 0, defStr = char(names(defIdx));
            elseif ~isempty(cur), defStr = cur; else, defStr = 'DCA_RX1111_TX1110_TDM.cfg'; end
            s = strtrim(input(sprintf('Select profile (number / name / path, b=browse) [%s]: ', defStr), 's'));
            if isempty(s)
                if defIdx > 0, cfg = char(fullfile(here, names(defIdx))); else, cfg = char(obj.ConfigFile); end
            elseif strcmpi(s, 'b')
                [fn, fp] = uigetfile({'*.cfg','mmWave .cfg profile'}, 'Select .cfg profile', here);
                if isequal(fn, 0)
                    if defIdx > 0, cfg = char(fullfile(here, names(defIdx))); else, cfg = char(obj.ConfigFile); end
                else
                    cfg = fullfile(fp, fn);
                end
            else
                n = str2double(s);
                if ~isnan(n) && n >= 1 && n <= numel(names)
                    cfg = char(fullfile(here, names(n)));
                elseif exist(s, 'file') == 2
                    cfg = s;
                elseif exist(fullfile(here, s), 'file') == 2
                    cfg = char(fullfile(here, s));
                else
                    cfg = s;
                end
            end
            obj.ConfigFile = string(cfg);
            if exist(char(cfg), 'file') ~= 2
                warning('awr2944_dca:cfg', 'Profile does not exist: %s', cfg);
            end
            fprintf('  -> profile: %s\n', cfg);
        end

        function setup(obj)
            if obj.isSetup, return; end
            fprintf('awr2944_dca: setup...\n');
            obj.pickConfig();
            capCfg = obj.makeCaptureCfg();      % adds lvdsStreamCfg and replaces numFrames=0 if needed
            obj.parseCfgDims(capCfg);
            obj.openUart();
            [ok, c] = awr_sensor_config(obj.uart, capCfg);
            if ~ok, error('awr2944_dca:cfg', 'SensorConfig failed.'); end
            obj.cfg = c;
            obj.dca = dca_connect(obj.DcaIPAddress, obj.HostIPAddress);
            if isempty(obj.dca), error('awr2944_dca:dca', 'dca_connect failed (Ethernet/IP?).'); end
            obj.isSetup = true;
            obj.nCaptures = 0;   % fresh configuration -> first start is a bare 'sensorStart'
            fprintf('awr2944_dca: setup OK (FPGA v%s)\n', obj.dca.fpgaVersion);
        end

        function cube = capture(obj)
            if ~obj.isSetup, obj.setup(); end
            % mmWave CLI: after sensorStop, a restart is done with 'sensorStart 0'
            % (no reconfiguration); a bare 'sensorStart' is only for the FIRST start
            % after a full configuration - otherwise the CLI rejects it and no data arrive.
            if obj.nCaptures == 0
                obj.cfg.sensorStartCmd = 'sensorStart';
            else
                obj.cfg.sensorStartCmd = 'sensorStart 0';
            end
            [ok, raw] = dca_capture(obj.uart, obj.dca, obj.cfg);
            obj.nCaptures = obj.nCaptures + 1;   % sensorStart+sensorStop were issued even if ok=false
            if ~ok, warning('awr2944_dca:capture', 'Capture failed / no data.'); end
            cube = obj.reshapeRaw(double(raw));
            if obj.RecordToFile
                outDir = obj.makeOutDir();
                bf = char(fullfile(outDir, obj.RecordFilePrefix + "_0.bin"));
                obj.LastBinFile = string(obj.writeBin(raw, bf));
                % also store the .cfg used next to the recording, so the recording
                % is self-contained (data + the configuration that produced them)
                try
                    [~, cn, ce] = fileparts(char(obj.ConfigFile));
                    if ~isempty(cn), copyfile(char(obj.ConfigFile), fullfile(outDir, [cn ce])); end
                catch
                end
            end
            try
                [~, bn, ratio] = awr2944_dca.quickRangeFFT(cube(:,1,1,1));
                fprintf('  [check] cube %s | range FFT chirp0/RX0: peak bin %d, peak/median %.1f\n', ...
                        mat2str(size(cube)), bn, ratio);
            catch
            end
        end

        % ---------- LIVE ----------
        function startLive(obj)
            if obj.LiveActive, return; end
            fprintf('awr2944_dca: startLive (infinite frames)...\n');
            obj.pickConfig(); obj.parseCfgDims();
            liveCfg = obj.makeLiveCfg();
            obj.openUart();
            [ok, c] = awr_sensor_config(obj.uart, liveCfg);
            if ~ok, error('awr2944_dca:cfg', 'SensorConfig (live) failed.'); end
            obj.cfg = c;
            obj.dca = dca_connect(obj.DcaIPAddress, obj.HostIPAddress);
            if isempty(obj.dca), error('awr2944_dca:dca', 'dca_connect failed.'); end
            obj.dcaCmd(5, []);            % START_RECORD (ARM)
            pause(1.0);
            flush(obj.dca.udpData);
            awr_send_cmd(obj.uart, 'sensorStart');
            obj.sRawLeftover = uint8([]); obj.sPayloadAccum = uint8([]); obj.sLastSeq = -1;
            obj.perFrameBytes = obj.SamplesPerChirp * obj.NumRX * obj.ChirpsPerFrame * 2;
            obj.LiveActive = true; obj.isSetup = true;
            fprintf('  live OK: %d B/frame (%d samples)\n', obj.perFrameBytes, obj.perFrameBytes/2);
        end

        function frame = readFrame(obj, timeoutS)
            if ~obj.LiveActive, error('awr2944_dca:live', 'Call startLive() first.'); end
            if nargin < 2, timeoutS = 2.0; end
            PKT=1466; HDR=10; PAY=1456;
            t0 = tic;
            while numel(obj.sPayloadAccum) < obj.perFrameBytes
                n = obj.dca.udpData.NumBytesAvailable;
                if n > 0
                    obj.sRawLeftover = [obj.sRawLeftover, uint8(read(obj.dca.udpData, n, 'uint8'))];
                    while numel(obj.sRawLeftover) >= PKT
                        chunk = obj.sRawLeftover(1:PKT);
                        seq = double(chunk(1)) + double(chunk(2))*256 + double(chunk(3))*65536 + double(chunk(4))*16777216;
                        if obj.sLastSeq >= 0 && seq > obj.sLastSeq + 1
                            miss = seq - obj.sLastSeq - 1;
                            obj.sPayloadAccum = [obj.sPayloadAccum, zeros(1, miss*PAY, 'uint8')];
                        end
                        obj.sLastSeq = seq;
                        obj.sPayloadAccum = [obj.sPayloadAccum, chunk(HDR+1:PKT)];
                        obj.sRawLeftover = obj.sRawLeftover(PKT+1:end);
                    end
                else
                    pause(0.001);
                end
                if toc(t0) > timeoutS, error('awr2944_dca:live', 'readFrame timeout (no data).'); end
            end
            fb = obj.sPayloadAccum(1:obj.perFrameBytes);
            obj.sPayloadAccum = obj.sPayloadAccum(obj.perFrameBytes+1:end);
            d = double(typecast(fb, 'int16'));
            frame = reshape(d, [obj.SamplesPerChirp, obj.NumRX, obj.ChirpsPerFrame]);
        end

        function frame = readFrameLatest(obj, timeoutS)
        % Like readFrame, but for LIVE display: performs ONE pass - drains what is
        % currently in the socket - and returns only the NEWEST complete frame (older
        % ones are discarded). The display is thus decoupled from the capture rate and
        % never falls behind (at 20 fps data keep arriving, so waiting for an empty
        % socket is not possible). If not even one complete frame is available yet, it
        % waits briefly (up to the timeout). readFrame is unaffected.
            if ~obj.LiveActive, error('awr2944_dca:live', 'Call startLive() first.'); end
            if nargin < 2, timeoutS = 2.0; end
            PKT=1466; HDR=10; PAY=1456;
            % --- fast discard of the old backlog (WITHOUT parsing) ---
            % If the socket holds more than ~2 frames of data, read and DISCARD the
            % surplus old packets. Reading is fast; per-packet parsing is slow (array
            % growth O(n^2)). Without this, a slow consumer would parse the whole
            % accumulated backlog (~2 s per call) and the display would stall. Reading
            % is done in whole packets (PKT), so the stream alignment is preserved.
            pktsPerFrame = ceil(obj.perFrameBytes / PAY);
            keepPkts     = 2 * pktsPerFrame;
            nPktAvail    = floor(obj.dca.udpData.NumBytesAvailable / PKT);
            if nPktAvail > keepPkts
                dropBytes = (nPktAvail - keepPkts) * PKT;
                read(obj.dca.udpData, dropBytes, 'uint8');     % read and discard (fast)
                obj.sRawLeftover = uint8([]); obj.sPayloadAccum = uint8([]); obj.sLastSeq = -1;
            end
            t0 = tic;
            while true
                n = obj.dca.udpData.NumBytesAvailable;
                if n > 0
                    obj.sRawLeftover = [obj.sRawLeftover, uint8(read(obj.dca.udpData, n, 'uint8'))];
                    while numel(obj.sRawLeftover) >= PKT
                        chunk = obj.sRawLeftover(1:PKT);
                        seq = double(chunk(1)) + double(chunk(2))*256 + double(chunk(3))*65536 + double(chunk(4))*16777216;
                        if obj.sLastSeq >= 0 && seq > obj.sLastSeq + 1
                            miss = seq - obj.sLastSeq - 1;
                            obj.sPayloadAccum = [obj.sPayloadAccum, zeros(1, miss*PAY, 'uint8')];
                        end
                        obj.sLastSeq = seq;
                        obj.sPayloadAccum = [obj.sPayloadAccum, chunk(HDR+1:PKT)];
                        obj.sRawLeftover = obj.sRawLeftover(PKT+1:end);
                    end
                end
                % at least one complete frame available -> stop now (do NOT wait for an empty socket)
                if numel(obj.sPayloadAccum) >= obj.perFrameBytes, break; end
                % no complete frame yet: wait briefly for more data
                if n == 0, pause(0.001); end
                if toc(t0) > timeoutS
                    error('awr2944_dca:live', 'readFrameLatest timeout (no data).');
                end
            end
            % discard old frames, keep only the NEWEST complete one
            nFull = floor(numel(obj.sPayloadAccum) / obj.perFrameBytes);
            if nFull > 1
                obj.sPayloadAccum = obj.sPayloadAccum((nFull-1)*obj.perFrameBytes + 1 : end);
            end
            fb = obj.sPayloadAccum(1:obj.perFrameBytes);
            obj.sPayloadAccum = obj.sPayloadAccum(obj.perFrameBytes+1:end);
            d = double(typecast(fb, 'int16'));
            frame = reshape(d, [obj.SamplesPerChirp, obj.NumRX, obj.ChirpsPerFrame]);
        end

        function stopLive(obj)
            try, if ~isempty(obj.uart) && isvalid(obj.uart), awr_send_cmd(obj.uart, 'sensorStop'); end, catch, end
            try, obj.dcaCmd(6, []); catch, end
            obj.LiveActive = false;
        end

        % ---------- I/O ----------
        function binFile = writeBin(obj, data, binFile)
            if nargin < 3 || isempty(binFile)
                binFile = char(fullfile(obj.makeOutDir(), obj.RecordFilePrefix + "_0.bin"));
            end
            v = int16(data(:));
            fid = fopen(binFile, 'wb');
            if fid < 0, error('awr2944_dca:writeBin', 'Cannot open %s', binFile); end
            fwrite(fid, v, 'int16'); fclose(fid);
            fprintf('  .bin written: %s (%d samples)\n', binFile, numel(v));
            if obj.WriteLogFile
                try, obj.writeLogFile(binFile);
                catch ME, warning('awr2944_dca:writeLogFile', 'LogFile could not be written: %s', ME.message); end
            end
        end

        function logFile = writeLogFile(obj, binFile)
        % Generates adc_data_LogFile.txt (mmWave Studio API log format) for the given
        % .bin, so tools reading mmWave Studio recordings can read it. Parameters are
        % taken from obj.ConfigFile.
            if nargin < 2 || isempty(binFile)
                binFile = char(obj.LastBinFile);
                if isempty(binFile)
                    binFile = char(fullfile(obj.makeOutDir(), obj.RecordFilePrefix + "_0.bin"));
                end
            end
            folder = fileparts(binFile);
            if isempty(folder), folder = char(obj.RecordLocation); end
            logFile = fullfile(folder, 'adc_data_LogFile.txt');

            % --- parse the CLI .cfg ---
            lines = regexp(fileread(char(obj.ConfigFile)), '\r\n|\n|\r', 'split');
            rxEn=15; txEn=7; bits=2; fmt=0; prof=[]; frm=[]; chirps={};
            for i = 1:numel(lines)
                t = strtrim(lines{i});
                if isempty(t) || t(1)=='%', continue; end
                p = strsplit(t); cmd = p{1}; v = str2double(p(2:end));
                switch cmd
                    case 'channelCfg', if numel(v)>=2, rxEn=v(1); txEn=v(2); end
                    case 'adcCfg',     if numel(v)>=2, bits=v(1); fmt=v(2); end
                    case 'profileCfg', prof=v;
                    case 'frameCfg',   frm=v;
                    case 'chirpCfg',   chirps{end+1}=v; %#ok<AGROW>
                end
            end

            % --- mmWave Studio constants (inverse of the reader's conversion) ---
            startFreqGHz=77; idleUs=7; adcStartUs=7; rampEndUs=60; slopeMHzus=70;
            numAdc=obj.SamplesPerChirp; sampleKsps=10000;
            if numel(prof)>=11
                startFreqGHz=prof(2); idleUs=prof(3); adcStartUs=prof(4);
                rampEndUs=prof(5); slopeMHzus=prof(8); numAdc=prof(10); sampleKsps=prof(11);
            end
            startFreqConst = round(startFreqGHz*1e9/53.6441803);  % mmWS LSB (3.6e9/2^26 Hz)
            slopeConst     = round(slopeMHzus*1e6/48279);
            idleConst      = round(idleUs*100);
            adcStartConst  = round(adcStartUs*100);
            rampEndConst   = round(rampEndUs*100);

            cs=0; ce=2; loops=16; frames=20;
            if numel(frm)>=4, cs=frm(1); ce=frm(2); loops=frm(3); frames=frm(4); end

            % Capture stops at ~98 %, so the last frame in the .bin is usually incomplete
            % (e.g. 31 of 32). A reader divides the total number of chirps by the NUMBER
            % OF FRAMES from the log; with the configured 'frames' (32) and only 31 complete
            % frames in the .bin, the chirps per TX would not be an integer. The log
            % therefore holds the ACTUAL number of complete frames in the .bin.
            framesLog = frames;
            spf = obj.SamplesPerChirp * obj.NumRX * obj.ChirpsPerFrame;   % samples per complete frame
            try
                di = dir(binFile);
                if ~isempty(di) && ~isempty(spf) && spf > 0
                    nfb = floor((di.bytes/2) / spf);
                    if nfb >= 1, framesLog = nfb; end
                end
            catch
            end

            % --- assemble the lines ---
            ts = awr2944_dca.tsString();
            L = {};
            L{end+1} = sprintf('%s: IsFPGA:,0,0,', ts);
            L{end+1} = sprintf('%s: %s,0,', ts, folder);
            L{end+1} = sprintf('%s: API:select_capture_device,DCA1000,0,', ts);
            L{end+1} = sprintf('%s: API:select_chip_version,AWR2944,0,', ts);
            L{end+1} = sprintf('%s: API:ChannelConfig,%d,%d,0,', ts, txEn, rxEn);
            L{end+1} = sprintf('%s: API:AdcOutConfig,%d,%d,0,', ts, bits, fmt);
            L{end+1} = sprintf('%s: API:DataFmtConfig,%d,%d,0,0,1,0,', ts, rxEn, bits);
            L{end+1} = sprintf('%s: API:LaneConfig,1,0,', ts);
            L{end+1} = sprintf('%s: API:LvdsLaneConfig,0,1,0,', ts);
            L{end+1} = sprintf('%s: API:ProfileConfig,0,%d,%d,%d,%d,0,0,%d,0,%d,%d,0,0,30,0,', ...
                       ts, startFreqConst, idleConst, adcStartConst, rampEndConst, slopeConst, numAdc, round(sampleKsps));
            if isempty(chirps)
                L{end+1} = sprintf('%s: API:ChirpConfig,0,0,0,0,0,0,0,1,0,', ts);
            else
                for ci = 1:numel(chirps)
                    cv = chirps{ci}; cstart=0; cend=0; txe=1;
                    if numel(cv)>=1, cstart=cv(1); end
                    if numel(cv)>=2, cend=cv(2); end
                    if numel(cv)>=8, txe=cv(8); end
                    L{end+1} = sprintf('%s: API:ChirpConfig,%d,%d,0,0,0,0,0,%d,0,', ts, cstart, cend, txe); %#ok<AGROW>
                end
            end
            L{end+1} = sprintf('%s: API:FrameConfig,%d,%d,%d,%d,100000000,0,%d,0,', ts, cs, ce, framesLog, loops, numAdc);
            L{end+1} = sprintf('%s: API:SensorStart,0,', ts);

            fid = fopen(logFile, 'w');
            if fid < 0, error('awr2944_dca:writeLogFile', 'Cannot open %s', logFile); end
            for i = 1:numel(L), fprintf(fid, '%s\n', L{i}); end
            fclose(fid);
            fprintf('  LogFile written: %s\n', logFile);
        end

        function cube = readBin(obj, binFile)
            if nargin < 2 || isempty(binFile), binFile = char(obj.LastBinFile); end
            if isempty(binFile) || exist(binFile,'file') ~= 2
                error('awr2944_dca:readBin', '.bin does not exist: %s', binFile);
            end
            fid = fopen(binFile, 'rb'); d = fread(fid, inf, 'int16=>double'); fclose(fid);
            % Auto-detection of the 4 B container (mmWave Studio via the 2-lane '1642'
            % mode of the card): each valid 16-bit word alternates with a zero word
            % (unused second stream). If ALL even (or odd) words are zero and the other
            % half is not, the valid half is kept and the file is read as the 2 B format.
            if mod(numel(d),2) == 0 && numel(d) >= 4
                od = d(1:2:end); ev = d(2:2:end);
                if ~any(ev) && any(od)
                    d = od;
                    fprintf('  [readBin] 4 B container (zero even words) -> valid half, %d samples.\n', numel(d));
                elseif ~any(od) && any(ev)
                    d = ev;
                    fprintf('  [readBin] 4 B container (zero odd words) -> valid half, %d samples.\n', numel(d));
                end
            end
            cube = obj.reshapeRaw(d);
        end

        function release(obj)
            if obj.LiveActive, try, obj.stopLive(); catch, end, end
            try
                if ~isempty(obj.uart) && isvalid(obj.uart)
                    % cleanup: send sensorStop silently (directly, without awr_log) - if
                    % the port is already stale/disconnected, the error is not logged.
                    try, writeline(obj.uart, 'sensorStop'); catch, end
                    delete(obj.uart);
                end
            catch, end
            obj.uart = [];
            try
                if ~isempty(obj.dca)
                    if isfield(obj.dca,'udpCfg')  && ~isempty(obj.dca.udpCfg),  delete(obj.dca.udpCfg);  end
                    if isfield(obj.dca,'udpData') && ~isempty(obj.dca.udpData), delete(obj.dca.udpData); end
                end
            catch, end
            obj.dca = []; obj.isSetup = false; obj.nCaptures = 0;
        end

        function delete(obj), obj.release(); end
    end

    methods (Access = private)
        function outDir = makeOutDir(obj)
        % Determines the output folder of a measurement (Downloads + timestamp) and creates it.
            base = char(obj.RecordLocation);
            if isempty(base), base = awr2944_dca.downloadsDir(); end
            if obj.RecordSubfolder
                stamp = char(datetime('now','Format','yyyy-MM-dd_HH-mm-ss'));
                outDir = fullfile(base, ['awr2944_' stamp]);
            else
                outDir = base;
            end
            if exist(outDir,'dir') ~= 7, mkdir(outDir); end
        end

        function descMap = portDescr(~)
        % Returns a containers.Map 'COMx' -> port description. Windows only (via
        % WMI/PowerShell); on macOS/Linux (or on error) an empty map -> bare port list.
            descMap = containers.Map('KeyType','char','ValueType','char');
            if ~ispc, return; end
            try
                cmd = ['powershell -NoProfile -Command "Get-CimInstance Win32_PnPEntity ' ...
                       '| Where-Object {$_.Name -match ''\(COM\d+\)''} ' ...
                       '| Select-Object -ExpandProperty Name"'];
                [st, out] = system(cmd);
                if st ~= 0 || isempty(out), return; end
                lns = regexp(out, '\r\n|\n|\r', 'split');
                for i = 1:numel(lns)
                    ln = strtrim(lns{i});
                    if isempty(ln), continue; end
                    tok = regexp(ln, '\((COM\d+)\)', 'tokens', 'once');
                    if ~isempty(tok)
                        com  = tok{1};
                        name = strtrim(regexprep(ln, '\s*\(COM\d+\)\s*$', ''));
                        descMap(com) = name;
                    end
                end
            catch
            end
        end

        function resp = dcaCmd(obj, code, payload)
            if nargin < 3, payload = []; end
            payload = uint8(payload(:)'); n = numel(payload);
            pkt = uint8([90,165, bitand(code,255),bitshift(code,-8), ...
                         bitand(n,255),bitshift(n,-8), payload, 170,238]);
            s = obj.dca.udpCfg; flush(s);
            write(s, pkt, 'uint8', obj.dca.dcaIP, obj.dca.configPort);
            resp = uint8([]); t0 = tic;
            while toc(t0) < 1.0
                if s.NumBytesAvailable > 0, resp = read(s, s.NumBytesAvailable, 'uint8'); break; end
                pause(0.02);
            end
        end

        function p = makeLiveCfg(obj)
            lines = regexp(fileread(char(obj.ConfigFile)), '\r\n|\n|\r', 'split');
            for i = 1:numel(lines)
                t = strtrim(lines{i});
                if startsWith(t, 'frameCfg')
                    tok = strsplit(t);
                    if numel(tok) >= 5, tok{5} = '0'; end
                    lines{i} = strjoin(tok, ' ');
                end
            end
            lines = obj.ensureLvds(lines);     % Demo Visualizer export lacks lvdsStreamCfg -> add it
            p = char(fullfile(tempdir, '_awr2944_live.cfg'));
            fid = fopen(p, 'w');
            for i = 1:numel(lines), fprintf(fid, '%s\n', lines{i}); end
            fclose(fid);
        end

        function p = makeCaptureCfg(obj)
        % Prepares the .cfg for capture(): adds lvdsStreamCfg if missing (e.g. a Demo
        % Visualizer export without LVDS streaming), and if frameCfg has numFrames=0
        % (infinite), replaces it with a finite count (obj.CaptureFrames), so that
        % capture() ends properly (otherwise it would record until the 30 s timeout).
            lines = regexp(fileread(char(obj.ConfigFile)), '\r\n|\n|\r', 'split');
            for i = 1:numel(lines)
                t = strtrim(lines{i});
                if startsWith(t, 'frameCfg')
                    tok = strsplit(t);
                    if numel(tok) >= 5 && str2double(tok{5}) == 0
                        tok{5} = num2str(max(round(obj.CaptureFrames),1));
                        lines{i} = strjoin(tok, ' ');
                        fprintf('  [cfg] numFrames=0 -> %s frames (CaptureFrames) for capture.\n', tok{5});
                    end
                end
            end
            [lines, added] = obj.ensureLvds(lines);
            if added, fprintf('  [cfg] lvdsStreamCfg missing (Demo Visualizer export?) -> added -1 0 1 0.\n'); end
            p = char(fullfile(tempdir, '_awr2944_capture.cfg'));
            fid = fopen(p, 'w');
            for i = 1:numel(lines), fprintf(fid, '%s\n', lines{i}); end
            fclose(fid);
        end

        function [lines, added] = ensureLvds(~, lines)
        % Inserts 'lvdsStreamCfg -1 0 1 0' if missing from the profile (e.g. a Demo
        % Visualizer export, which does not use LVDS). Placed before sensorStart
        % (otherwise at the end). 'added' = true if it was inserted.
            added = false; hasLvds = false;
            for i = 1:numel(lines)
                if startsWith(strtrim(lines{i}), 'lvdsStreamCfg'), hasLvds = true; break; end
            end
            if ~hasLvds
                ins = 'lvdsStreamCfg -1 0 1 0'; idx = [];
                for i = 1:numel(lines)
                    if startsWith(strtrim(lines{i}), 'sensorStart'), idx = i; break; end
                end
                if isempty(idx), lines{end+1} = ins;
                else, lines = [lines(1:idx-1), {ins}, lines(idx:end)]; end
                added = true;
            end
        end

        function cube = reshapeRaw(obj, d)
            if isempty(obj.SamplesPerChirp) || isempty(obj.NumRX) || isempty(obj.ChirpsPerFrame)
                error('awr2944_dca:dims', 'Unknown dimensions (parseCfgDims).');
            end
            nS = obj.SamplesPerChirp; nR = obj.NumRX; nC = obj.ChirpsPerFrame;
            perFrame = nS*nR*nC;
            nF = floor(numel(d)/perFrame);
            if nF < 1, error('awr2944_dca:dims', 'Too little data (%d samples, frame=%d).', numel(d), perFrame); end
            % An incomplete last frame is normal (~98 %). Warn only on an actual loss
            % (more than one frame missing).
            if ~isempty(obj.NumFrames) && obj.NumFrames > 0 && nF < obj.NumFrames - 1
                warning('awr2944_dca:tail', 'Only %d of %d frames captured (data loss).', nF, obj.NumFrames);
            end
            d = d(1:nF*perFrame);
            cube = reshape(d, [nS, nR, nC, nF]);
        end

        function parseCfgDims(obj, fileOverride)
            if nargin >= 2 && ~isempty(fileOverride), f = char(fileOverride); else, f = char(obj.ConfigFile); end
            if exist(f,'file') ~= 2, warning('awr2944_dca:cfg','ConfigFile does not exist: %s', f); return; end
            lines = regexp(fileread(f), '\r\n|\n|\r', 'split');
            rxEn=15; txEn=7; nS=[]; bits=16; cs=0; ce=0; loops=1; frames=0;
            for i = 1:numel(lines)
                t = strtrim(lines{i});
                if isempty(t) || t(1) == '%', continue; end
                p = strsplit(t); v = str2double(p(2:end));
                switch p{1}
                    case 'channelCfg', if numel(v)>=2, rxEn=v(1); txEn=v(2); end
                    case 'adcCfg'
                        if numel(v)>=1, m=[12 14 16]; idx=v(1)+1; if idx>=1&&idx<=3, bits=m(idx); end, end
                    case 'profileCfg', if numel(v)>=10, nS=v(10); end
                    case 'frameCfg',   if numel(v)>=4, cs=v(1); ce=v(2); loops=v(3); frames=v(4); end
                end
            end
            obj.NumRX = sum(bitget(round(rxEn),1:8));
            obj.NumTX = sum(bitget(round(txEn),1:8));
            obj.SamplesPerChirp = nS; obj.AdcBits = bits;
            obj.ChirpsPerFrame = (ce-cs+1)*loops; obj.NumFrames = frames;
        end
    end

    methods (Static, Access = private)
        function d = downloadsDir()
        % Downloads folder of the current user (cross-platform), with fallbacks.
            if ispc, home = getenv('USERPROFILE'); else, home = getenv('HOME'); end
            if isempty(home), home = pwd; end
            d = fullfile(home, 'Downloads');
            if exist(d,'dir') ~= 7, d = home; end
        end

        function s = tsString()
            mons = {'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'};
            c = clock; %#ok<CLOCK>
            s = sprintf('%02d-%s-%04d %02d:%02d:%02d', c(3), mons{c(2)}, c(1), c(4), c(5), round(c(6)));
        end

        function [pk, bin, ratio] = quickRangeFFT(seg)
            seg = double(seg(:)); n = numel(seg); seg = seg - mean(seg);
            w = 0.5 - 0.5*cos(2*pi*(0:n-1)'/(n-1));
            S = abs(fft(seg .* w)); half = floor(n/2); S(1) = 0;
            [pk, bin] = max(S(1:half)); med = median(S(2:half)); ratio = pk/max(med,1);
        end
    end
end

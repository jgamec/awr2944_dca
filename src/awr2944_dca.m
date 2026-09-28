classdef awr2944_dca < handle
% AWR2944_DCA  Ekvivalent MathWorks 'dca1000' pre AWR2944 EVM + DCA1000.  [v1.7]
%
% Headless raw-ADC capture bez mmWave Studio.
%
% BATCH (record -> cube -> .bin + adc_data_LogFile.txt):
%   src  = awr2944_dca;
%   cube = src.capture();   % spyta sa na port -> konfig -> zaznam do Downloads\awr2944_<cas>\
%   src.release();
%
% LIVE (jeden ramec na volanie, ako dca1000 obj()):
%   src = awr2944_dca; src.RecordToFile = false;
%   src.startLive(); fr = src.readFrame(); ... ; src.stopLive(); src.release();
%   (hotovy demo: live_display)
%
% Ukladanie: default do priecinka Downloads aktualneho pouzivatela, kazde meranie
% do vlastneho podpriecinka 'awr2944_RRRR-MM-DD_HH-MM-SS' (.bin + adc_data_LogFile.txt).
% Vystup je kompatibilny s BIN2MAT_2944 (lane=1, real).
%
% ⚠ AWR2944 = REALNE vzorky (nie IQ) -> cube/frame su REALNE (double z int16).
% Cube: [SamplesPerChirp x NumRX x ChirpsPerFrame (x NumFrames pri batch)]

    properties
        ConfigPort       = "COM9"
        HostIPAddress    = "192.168.33.30"
        DcaIPAddress     = "192.168.33.180"
        ConfigFile       = ""        % prazdne -> DCA_RX1111_TX1110_TDM.cfg vedla triedy (auto v konstruktore)
        RecordLocation   = ""        % prazdne -> auto Downloads (nastavi sa v konstruktore)
        RecordFilePrefix = "adc_data_Raw"
        RecordToFile     = true
        WriteLogFile     = true      % spolu s .bin zapisat aj adc_data_LogFile.txt (pre bin2mat)
        RecordSubfolder  = true      % kazde meranie do vlastneho podpriecinka s casovou peciatkou
        CaptureFrames    = 20        % pocet ramcov pre capture(), ak .cfg ma numFrames=0 (napr. DV export)
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
        nCaptures = 0      % pocet capture() od posledneho setup (0 = prvy start po konfiguracii)
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
                    try, obj.(char(p)) = v; catch, warning('Nedalo sa nastavit %s', char(p)); end
                else
                    warning('Neznama vlastnost: %s', char(p));
                end
            end
            if strlength(string(obj.ConfigFile)) == 0
                here = fileparts(mfilename('fullpath'));   % priecinok, kde lezi awr2944_dca.m
                obj.ConfigFile = string(fullfile(here, 'DCA_RX1111_TX1110_TDM.cfg'));
            end
            if strlength(string(obj.RecordLocation)) == 0
                obj.RecordLocation = string(awr2944_dca.downloadsDir());
            end
            obj.parseCfgDims();
        end

        function openUart(obj)
            obj.pickPort();                 % vzdy sa opyta, ktory COM/port pouzit
            obj.uart = serialport(obj.ConfigPort, 115200, 'DataBits',8, ...
                       'Parity','none', 'StopBits',1, 'FlowControl','none', 'Timeout',5);
            configureTerminator(obj.uart, 'LF');
            pause(1.0);            % cold-start: nech sa XDS110/CDC port po otvoreni (DTR reset) ustali
            flush(obj.uart);
            awr_send_cmd(obj.uart, 'sensorStop'); awr_read_lines(obj.uart, 3, 0.4);
            awr_send_cmd(obj.uart, 'flushCfg');   awr_read_lines(obj.uart, 3, 0.4);
        end

        function port = pickPort(obj)
        % Opyta sa, ktory seriovy (COM) port pouzit. Vypise dostupne porty; na
        % Windows aj s popisom a oznaci/ponukne 'Application/User UART' (XDS110
        % config UART). Enter = ponuknuty default. Cross-platform (serialportlist).
            try, avail = serialportlist("available"); catch, avail = serialportlist(); end
            if isempty(avail)
                error('awr2944_dca:noport', ['Nenasiel sa ziadny seriovy port.\n' ...
                    'Pripoj radar (XDS110) cez USB a over v Spravcovi zariadeni polozku\n' ...
                    '"XDS110 Class Application/User UART", potom spusti setup znova.']);
            end
            descMap = obj.portDescr();      % COMx -> popis (len Windows; inak prazdne)
            recIdx = 0;
            fprintf('\nDostupne seriove porty:\n');
            for i = 1:numel(avail)
                nm = char(avail(i)); d = '';
                if isKey(descMap, nm), d = descMap(nm); end
                tag = '';
                if ~isempty(d) && (contains(d,'Application/User UART','IgnoreCase',true) || ...
                                   contains(d,'Enhanced COM Port','IgnoreCase',true))
                    tag = '  <- odporucany (config)'; if recIdx==0, recIdx = i; end
                elseif strcmpi(nm, obj.ConfigPort)
                    tag = '  <- predvoleny';
                end
                if isempty(d)
                    fprintf('  [%d] %s%s\n', i, nm, tag);
                else
                    fprintf('  [%d] %s   (%s)%s\n', i, nm, d, tag);
                end
            end
            if recIdx > 0, defStr = char(avail(recIdx)); else, defStr = char(obj.ConfigPort); end
            s = strtrim(input(sprintf('Vyber config port (cislo zo zoznamu, alebo nazov) [%s]: ', defStr), 's'));
            if isempty(s)
                port = defStr;
            else
                n = str2double(s);
                if ~isnan(n) && n>=1 && n<=numel(avail), port = char(avail(n)); else, port = s; end
            end
            obj.ConfigPort = string(port);
            fprintf('  -> pouzivam port: %s\n', port);
        end

        function cfg = pickConfig(obj)
        % Vyber .cfg profilu. Vypise *.cfg najdene v priecinku triedy a opyta sa.
        % Enter = predvoleny; mozno zadat cislo zo zoznamu, nazov, plnu cestu, alebo 'b' = prehladat.
            here  = fileparts(mfilename('fullpath'));
            L     = dir(fullfile(here, '*.cfg'));
            names = string({L.name});
            cur   = char(obj.ConfigFile);
            [~, curN, curE] = fileparts(cur); curFile = [curN curE];
            defIdx = 0;
            for i = 1:numel(names), if strcmpi(names(i), curFile), defIdx = i; break; end, end
            fprintf('\nDostupne .cfg profily (%s):\n', here);
            if isempty(names)
                fprintf('  (ziadny .cfg v priecinku triedy)\n');
            else
                for i = 1:numel(names)
                    mark = ''; if i == defIdx, mark = '  <- predvoleny'; end
                    fprintf('  [%d] %s%s\n', i, names(i), mark);
                end
            end
            if defIdx > 0, defStr = char(names(defIdx));
            elseif ~isempty(cur), defStr = cur; else, defStr = 'DCA_RX1111_TX1110_TDM.cfg'; end
            s = strtrim(input(sprintf('Vyber profil (cislo / nazov / cesta, b=prehladat) [%s]: ', defStr), 's'));
            if isempty(s)
                if defIdx > 0, cfg = char(fullfile(here, names(defIdx))); else, cfg = char(obj.ConfigFile); end
            elseif strcmpi(s, 'b')
                [fn, fp] = uigetfile({'*.cfg','mmWave .cfg profil'}, 'Vyber .cfg profil', here);
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
                warning('awr2944_dca:cfg', 'Profil neexistuje: %s', cfg);
            end
            fprintf('  -> profil: %s\n', cfg);
        end

        function setup(obj)
            if obj.isSetup, return; end
            fprintf('awr2944_dca: setup...\n');
            obj.pickConfig();
            capCfg = obj.makeCaptureCfg();      % doplni lvdsStreamCfg a dorovna numFrames=0, ak treba
            obj.parseCfgDims(capCfg);
            obj.openUart();
            [ok, c] = awr_sensor_config(obj.uart, capCfg);
            if ~ok, error('awr2944_dca:cfg', 'SensorConfig zlyhal.'); end
            obj.cfg = c;
            obj.dca = dca_connect();
            if isempty(obj.dca), error('awr2944_dca:dca', 'dca_connect zlyhal (Ethernet/IP?).'); end
            obj.isSetup = true;
            obj.nCaptures = 0;   % cerstva konfiguracia -> prvy start bude holy 'sensorStart'
            fprintf('awr2944_dca: setup OK (FPGA v%s)\n', obj.dca.fpgaVersion);
        end

        function cube = capture(obj)
            if ~obj.isSetup, obj.setup(); end
            % mmWave CLI: po sensorStop sa restart robi cez 'sensorStart 0'
            % (bez rekonfiguracie); holy 'sensorStart' je len pre PRVY start
            % po plnej konfiguracii - inak CLI prikaz odmietne a data nepridu.
            if obj.nCaptures == 0
                obj.cfg.sensorStartCmd = 'sensorStart';
            else
                obj.cfg.sensorStartCmd = 'sensorStart 0';
            end
            [ok, raw] = dca_capture(obj.uart, obj.dca, obj.cfg);
            obj.nCaptures = obj.nCaptures + 1;   % sensorStart+sensorStop prebehli aj pri ok=false
            if ~ok, warning('awr2944_dca:capture', 'Capture neuspesny / 0 dat.'); end
            cube = obj.reshapeRaw(double(raw));
            if obj.RecordToFile
                outDir = obj.makeOutDir();
                bf = char(fullfile(outDir, obj.RecordFilePrefix + "_0.bin"));
                obj.LastBinFile = string(obj.writeBin(raw, bf));
                % uloz aj pouzity .cfg vedla zaznamu (aby ho nastroje ako micro_doppler
                % nasli priamo pri .bin v Downloads)
                try
                    [~, cn, ce] = fileparts(char(obj.ConfigFile));
                    if ~isempty(cn), copyfile(char(obj.ConfigFile), fullfile(outDir, [cn ce])); end
                catch
                end
            end
            try
                [~, bn, ratio] = awr2944_dca.quickRangeFFT(cube(:,1,1,1));
                fprintf('  [validacia] cube %s | range-FFT chirp0/RX0: peak bin %d, peak/median %.1f\n', ...
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
            if ~ok, error('awr2944_dca:cfg', 'SensorConfig (live) zlyhal.'); end
            obj.cfg = c;
            obj.dca = dca_connect();
            if isempty(obj.dca), error('awr2944_dca:dca', 'dca_connect zlyhal.'); end
            obj.dcaCmd(5, []);            % START_RECORD (ARM)
            pause(1.0);
            flush(obj.dca.udpData);
            awr_send_cmd(obj.uart, 'sensorStart');
            obj.sRawLeftover = uint8([]); obj.sPayloadAccum = uint8([]); obj.sLastSeq = -1;
            obj.perFrameBytes = obj.SamplesPerChirp * obj.NumRX * obj.ChirpsPerFrame * 2;
            obj.LiveActive = true; obj.isSetup = true;
            fprintf('  live OK: %d B/ramec (%d vzoriek)\n', obj.perFrameBytes, obj.perFrameBytes/2);
        end

        function frame = readFrame(obj, timeoutS)
            if ~obj.LiveActive, error('awr2944_dca:live', 'Najprv startLive().'); end
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
                if toc(t0) > timeoutS, error('awr2944_dca:live', 'readFrame timeout (ziadne data).'); end
            end
            fb = obj.sPayloadAccum(1:obj.perFrameBytes);
            obj.sPayloadAccum = obj.sPayloadAccum(obj.perFrameBytes+1:end);
            d = double(typecast(fb, 'int16'));
            frame = reshape(d, [obj.SamplesPerChirp, obj.NumRX, obj.ChirpsPerFrame]);
        end

        function frame = readFrameLatest(obj, timeoutS)
        % Ako readFrame, ale pre LIVE zobrazenie: spravi JEDEN zatah - vycerpa to, co
        % je prave v sockete - a vrati len NAJNOVSI uplny ramec (starsie zahodi). Tym
        % sa display odpoji od capture rychlosti; nikdy nedobieha donekonecna (pri 20 fps
        % stale nieco priteka, takze cakat na prazdny socket nemozno). Ak este nie je ani
        % jeden cely ramec, kratko pocka (do timeoutu). readFrame zostava nedotknuty.
            if ~obj.LiveActive, error('awr2944_dca:live', 'Najprv startLive().'); end
            if nargin < 2, timeoutS = 2.0; end
            PKT=1466; HDR=10; PAY=1456;
            % --- rychle zahodenie stareho backlogu (BEZ parsovania) ---
            % Ak je v sockete viac nez ~2 ramce dat, precitaj a ZAHOD prebytocne stare
            % pakety. Citanie je rychle; pomale je az per-paket parsovanie (rast pola
            % O(n^2)). Bez tohto readFrameLatest pri pomalom view (pc) parsoval cely
            % nahromadeny backlog ~2 s/volanie a display 'tuhol'. Citame v celych
            % paketoch (PKT), takze zarovnanie ostava zachovane.
            pktsPerFrame = ceil(obj.perFrameBytes / PAY);
            keepPkts     = 2 * pktsPerFrame;
            nPktAvail    = floor(obj.dca.udpData.NumBytesAvailable / PKT);
            if nPktAvail > keepPkts
                dropBytes = (nPktAvail - keepPkts) * PKT;
                read(obj.dca.udpData, dropBytes, 'uint8');     % precitaj a zahod (rychle)
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
                % uz mame aspon jeden cely ramec -> hned koniec (NEcakame na prazdny socket)
                if numel(obj.sPayloadAccum) >= obj.perFrameBytes, break; end
                % este nemame cely ramec: kratko pockaj na dalsie data
                if n == 0, pause(0.001); end
                if toc(t0) > timeoutS
                    error('awr2944_dca:live', 'readFrameLatest timeout (ziadne data).');
                end
            end
            % zahod stare ramce, nechaj len NAJNOVSI uplny
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
            if fid < 0, error('awr2944_dca:writeBin', 'Nedaju sa otvorit %s', binFile); end
            fwrite(fid, v, 'int16'); fclose(fid);
            fprintf('  .bin zapisany: %s (%d vzoriek)\n', binFile, numel(v));
            if obj.WriteLogFile
                try, obj.writeLogFile(binFile);
                catch ME, warning('awr2944_dca:writeLogFile', 'LogFile sa nepodaril: %s', ME.message); end
            end
        end

        function logFile = writeLogFile(obj, binFile)
        % Vygeneruj adc_data_LogFile.txt (format mmWS API logu) k danemu .bin,
        % aby ho vedel precitat BIN2MAT_2944. Parametre z obj.ConfigFile.
            if nargin < 2 || isempty(binFile)
                binFile = char(obj.LastBinFile);
                if isempty(binFile)
                    binFile = char(fullfile(obj.makeOutDir(), obj.RecordFilePrefix + "_0.bin"));
                end
            end
            folder = fileparts(binFile);
            if isempty(folder), folder = char(obj.RecordLocation); end
            logFile = fullfile(folder, 'adc_data_LogFile.txt');

            % --- parsuj CLI .cfg ---
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

            % --- mmWS konstanty (inverzia k bin2mat) ---
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

            % Capture sa zastavi na ~98 %, takze posledny ramec v .bin byva neuplny
            % (napr. 31 z 32). bin2mat deli celkovy pocet chirpov POCTOM RAMCOV z logu;
            % ak tam dame konfiguracnych 'frames' (32) a v .bin je len 31 celych ramcov,
            % vyjde nedelitelny pocet chirpov na TX -> pri 4 TX to spadne. Preto do logu
            % zapiseme SKUTOCNY pocet celych ramcov v .bin (tak, ako ho odvodi aj bin2mat).
            framesLog = frames;
            spf = obj.SamplesPerChirp * obj.NumRX * obj.ChirpsPerFrame;   % vzoriek na cely ramec
            try
                di = dir(binFile);
                if ~isempty(di) && ~isempty(spf) && spf > 0
                    nfb = floor((di.bytes/2) / spf);
                    if nfb >= 1, framesLog = nfb; end
                end
            catch
            end

            % --- zostav riadky ---
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
            if fid < 0, error('awr2944_dca:writeLogFile', 'Nedaju sa otvorit %s', logFile); end
            for i = 1:numel(L), fprintf(fid, '%s\n', L{i}); end
            fclose(fid);
            fprintf('  LogFile zapisany: %s\n', logFile);
        end

        function cube = readBin(obj, binFile)
            if nargin < 2 || isempty(binFile), binFile = char(obj.LastBinFile); end
            if isempty(binFile) || exist(binFile,'file') ~= 2
                error('awr2944_dca:readBin', '.bin neexistuje: %s', binFile);
            end
            fid = fopen(binFile, 'rb'); d = fread(fid, inf, 'int16=>double'); fclose(fid);
            % Autodetekcia 4 B kontajnera (mmWS cez 2-linkovy '1642' rezim karty):
            % platne 16-bit slovo striedane nulovym (neobsadeny druhy tok). Ak su
            % VSETKY parne (resp. neparne) slova nulove a druha polovica nie je,
            % vyberie sa platna polovica - subor sa dalej cita ako nas 2 B format.
            if mod(numel(d),2) == 0 && numel(d) >= 4
                od = d(1:2:end); ev = d(2:2:end);
                if ~any(ev) && any(od)
                    d = od;
                    fprintf('  [readBin] 4 B kontajner (nulove parne slova) -> platna polovica, %d vzoriek.\n', numel(d));
                elseif ~any(od) && any(ev)
                    d = ev;
                    fprintf('  [readBin] 4 B kontajner (nulove neparne slova) -> platna polovica, %d vzoriek.\n', numel(d));
                end
            end
            cube = obj.reshapeRaw(d);
        end

        function release(obj)
            if obj.LiveActive, try, obj.stopLive(); catch, end, end
            try
                if ~isempty(obj.uart) && isvalid(obj.uart)
                    % cleanup: sensorStop posli ticho (priamo, bez awr_log) - ak je
                    % port uz zoschnuty/odpojeny, chybu nelogujeme, aby nestrasila.
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
        % Urci vystupny priecinok merania (Downloads + casova peciatka) a vytvori ho.
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
        % Vrati containers.Map 'COMx' -> popis portu. Len Windows (cez WMI/PowerShell);
        % na Mac/Linux (alebo pri chybe) vrati prazdnu mapu -> fallback na holy zoznam.
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
            lines = obj.ensureLvds(lines);     % DV export nema lvdsStreamCfg -> doplnit
            p = char(fullfile(tempdir, '_awr2944_live.cfg'));
            fid = fopen(p, 'w');
            for i = 1:numel(lines), fprintf(fid, '%s\n', lines{i}); end
            fclose(fid);
        end

        function p = makeCaptureCfg(obj)
        % Priprav .cfg pre capture(): doplni lvdsStreamCfg, ak chyba (napr. DV
        % export bez LVDS streamingu), a ak ma frameCfg numFrames=0 (nekonecne),
        % nahradi ho konecnym poctom (obj.CaptureFrames), aby capture() korektne
        % skoncil (inak by zbieral az do 30 s timeoutu).
            lines = regexp(fileread(char(obj.ConfigFile)), '\r\n|\n|\r', 'split');
            for i = 1:numel(lines)
                t = strtrim(lines{i});
                if startsWith(t, 'frameCfg')
                    tok = strsplit(t);
                    if numel(tok) >= 5 && str2double(tok{5}) == 0
                        tok{5} = num2str(max(round(obj.CaptureFrames),1));
                        lines{i} = strjoin(tok, ' ');
                        fprintf('  [cfg] numFrames=0 -> %s ramcov (CaptureFrames) pre capture.\n', tok{5});
                    end
                end
            end
            [lines, added] = obj.ensureLvds(lines);
            if added, fprintf('  [cfg] lvdsStreamCfg chybal (DV export?) -> doplneny -1 0 1 0.\n'); end
            p = char(fullfile(tempdir, '_awr2944_capture.cfg'));
            fid = fopen(p, 'w');
            for i = 1:numel(lines), fprintf(fid, '%s\n', lines{i}); end
            fclose(fid);
        end

        function [lines, added] = ensureLvds(~, lines)
        % Zaradi 'lvdsStreamCfg -1 0 1 0', ak v profile chyba (napr. DV export,
        % ktory LVDS nepouziva). Vlozi ho pred sensorStart (inak na koniec).
        % 'added' = true, ak sa doplnil.
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
                error('awr2944_dca:dims', 'Nezname rozmery (parseCfgDims).');
            end
            nS = obj.SamplesPerChirp; nR = obj.NumRX; nC = obj.ChirpsPerFrame;
            perFrame = nS*nR*nC;
            nF = floor(numel(d)/perFrame);
            if nF < 1, error('awr2944_dca:dims', 'Prilis malo dat (%d vz, ramec=%d).', numel(d), perFrame); end
            % Posledny neuplny ramec je normalny (~98 %). Upozorni len pri realnej strate
            % (chyba viac nez jeden ramec).
            if ~isempty(obj.NumFrames) && obj.NumFrames > 0 && nF < obj.NumFrames - 1
                warning('awr2944_dca:tail', 'Zachytenych len %d z %d ramcov (strata dat).', nF, obj.NumFrames);
            end
            d = d(1:nF*perFrame);
            cube = reshape(d, [nS, nR, nC, nF]);
        end

        function parseCfgDims(obj, fileOverride)
            if nargin >= 2 && ~isempty(fileOverride), f = char(fileOverride); else, f = char(obj.ConfigFile); end
            if exist(f,'file') ~= 2, warning('awr2944_dca:cfg','ConfigFile neexistuje: %s', f); return; end
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
        % Priecinok Downloads aktualneho pouzivatela (cross-platform), s poistkami.
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

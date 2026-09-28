function dca = dca_connect()
% DCA_CONNECT  Pripojenie + konfiguracia DCA1000EVM cez UDP.  [OPRAVENE 31.5]
%
% Opravy oproti v1 (ktora nikdy nefungovala na HW):
%   1) SPRAVNY ramec prikazu: hlavicka 0x5A 0xA5, footer 0xAA 0xEE
%      (v1 mala A5 5A / EE AA -> FPGA vsetko ticho zahadzovala).
%   2) Odpovede sa citaju na TOM ISTOM config sockete (port 4096), nie 1024.
%   3) Pridany uvodny SYSTEM_CONNECT (0x09) handshake + kontrola statusu.
%
% Sekvencia (ako TI DCA1000 CLI / mmWS):
%   0x09 SYSTEM_CONNECT -> 0x0E READ_FPGA_VERSION -> 0x03 CONFIG_FPGA -> 0x0B CONFIG_RECORD
% Porty: config 4096 (send aj recv), data 4098.  IP: FPGA .180, PC .30.
%
% Vystup: dca struct (.udpCfg .udpData .dcaIP .configPort .dataPort .fpgaVersion)
%         alebo [] pri zlyhani.

    dca = [];
    DCA_IP = '192.168.33.180'; PC_IP = '192.168.33.30';
    CONFIG_PORT = 4096; DATA_PORT = 4098; TO = 2.0;

    %% config socket (send + recv na 4096)
    udpCfg = [];
    try
        udpCfg = udpport('byte','LocalHost',PC_IP,'LocalPort',CONFIG_PORT,'Timeout',TO);
    catch e1
        try
            udpCfg = udpport('byte','LocalPort',CONFIG_PORT,'Timeout',TO);
            awr_log(['WARN: config socket bez LocalHost (NIC IP ' PC_IP '?): ' e1.message]);
        catch e2
            awr_log(['ERR: config socket 4096 sa neda otvorit: ' e2.message]);
            awr_log('  -> Drzi port mmWS/DCA CLI? Je NIC na 192.168.33.x?');
            return;
        end
    end

    %% data socket (4098)
    try
        udpData = udpport('byte','LocalPort',DATA_PORT,'Timeout',TO);
    catch
        awr_log('WARN: data socket 4098 sa neda otvorit'); udpData = [];
    end
    awr_log(sprintf('DCA1000: config %s:%d (send+recv), data :%d', PC_IP, CONFIG_PORT, DATA_PORT));

    fpgaVersion = '?';

    %% 0x09 SYSTEM_CONNECT
    [ok09, ~] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 9, [], 'SYSTEM_CONNECT (0x09)');
    if ~ok09
        awr_log('ERR: SYSTEM_CONNECT bez/zlej odpovede -> DCA nedostupny. Koncim.');
        try, delete(udpCfg); catch, end
        try, if ~isempty(udpData), delete(udpData); end, catch, end
        return;
    end

    %% 0x0E READ_FPGA_VERSION
    [ok0E, st0E] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 14, [], 'READ_FPGA_VERSION (0x0E)');
    if ok0E
        major = bitand(st0E,127);
        minor = bitand(bitshift(st0E,-7),127);
        fpgaVersion = sprintf('%d.%d', major, minor);
        awr_log(sprintf('OK: FPGA verzia %s (raw 0x%04X)', fpgaVersion, st0E));
    end

    %% 0x03 CONFIG_FPGA
    % payload[6] = [LogMode, LvdsMode, XferMode, CaptureMode, FormatMode, Timer]
    %   LogMode 1=RAW | LvdsMode 1=4lane 2=2lane | XferMode 1=Capture
    %   CaptureMode 2=Ethernet | FormatMode 3=16bit | Timer=LVDS timeout
    % POZN: LvdsMode (2) je kandidat na overenie pre AWR2944, ak by dato nesedelo.
    fpgaCfg = uint8([1, 2, 1, 2, 3, 30]);
    [ok03, ~] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 3, fpgaCfg, 'CONFIG_FPGA (0x03)');

    %% 0x0B CONFIG_RECORD (packet delay/size)
    recCfg = uint8([190, 5, 53, 12, 0, 0]);   % be 05 35 0c 00 00
    [ok0B, ~] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 11, recCfg, 'CONFIG_RECORD (0x0B)');

    if ~(ok03 && ok0B)
        awr_log('WARN: CONFIG_FPGA alebo CONFIG_RECORD nevratil OK (status!=0). Pozri vyssie.');
    end

    %% vrat struct
    dca = struct('udpCfg',udpCfg, 'udpData',udpData, 'dcaIP',DCA_IP, ...
                 'configPort',CONFIG_PORT, 'dataPort',DATA_PORT, 'fpgaVersion',fpgaVersion);
    awr_log('OK: DCA1000 pripojeny a nakonfigurovany');
end

%% ====== lokalne pomocne ======
function [ok, status] = dca_cmd(sock, ip, port, code, payload, name)
% Posli DCA1000 prikaz so SPRAVNYM ramcom a precitaj odpoved na tom istom sockete.
% ok=true ak ramec sedi a status==0 (alebo ak je to version read, code==14).
    ok = false; status = 0;
    if nargin < 5, payload = []; end
    payload = uint8(payload(:)');
    n = numel(payload);
    pkt = uint8([90,165, bitand(code,255),bitshift(code,-8), ...
                 bitand(n,255),bitshift(n,-8), payload, 170,238]);  % 5A A5 ... AA EE
    flush(sock);
    write(sock, pkt, 'uint8', ip, port);

    resp = uint8([]); t0 = tic;
    while toc(t0) < 1.5
        if sock.NumBytesAvailable > 0
            resp = read(sock, sock.NumBytesAvailable, 'uint8'); break;
        end
        pause(0.02);
    end

    if isempty(resp)
        awr_log(sprintf('  %s: ziadna odpoved (timeout)', name));
        return;
    end
    if numel(resp) >= 8
        hdr = resp(1)+resp(2)*256; cmd = resp(3)+resp(4)*256;
        status = resp(5)+resp(6)*256; ftr = resp(7)+resp(8)*256;
        if hdr == 42330 && ftr == 61098     % 0xA55A , 0xEEAA
            ok = (status == 0) || (code == 14);
            tag = '??'; if ok, tag = 'OK'; end
            awr_log(sprintf('  %s: cmd=0x%02X status=0x%04X  %s', name, cmd, status, tag));
        else
            awr_log(sprintf('  %s: zly ramec hdr=0x%04X ftr=0x%04X', name, hdr, ftr));
        end
    else
        awr_log(sprintf('  %s: kratka odpoved (%d B): %s', name, numel(resp), sprintf('%02X ',resp)));
    end
end

function dca = dca_connect()
% DCA_CONNECT  Connects to and configures the DCA1000EVM over UDP.
%
% Command frame: header 0x5A 0xA5, command code, length, payload, footer 0xAA 0xEE
% (little-endian). Responses are read on the same configuration socket (port 4096).
%
% Sequence (as in the TI DCA1000 CLI / mmWave Studio):
%   0x09 SYSTEM_CONNECT -> 0x0E READ_FPGA_VERSION -> 0x03 CONFIG_FPGA -> 0x0B CONFIG_RECORD
% Ports: config 4096 (send and receive), data 4098.  IP: FPGA .180, PC .30.
%
% Output: dca struct (.udpCfg .udpData .dcaIP .configPort .dataPort .fpgaVersion)
%         or [] on failure.

    dca = [];
    DCA_IP = '192.168.33.180'; PC_IP = '192.168.33.30';
    CONFIG_PORT = 4096; DATA_PORT = 4098; TO = 2.0;

    %% config socket (send + receive on 4096)
    udpCfg = [];
    try
        udpCfg = udpport('byte','LocalHost',PC_IP,'LocalPort',CONFIG_PORT,'Timeout',TO);
    catch e1
        try
            udpCfg = udpport('byte','LocalPort',CONFIG_PORT,'Timeout',TO);
            awr_log(['WARN: config socket without LocalHost (NIC IP ' PC_IP '?): ' e1.message]);
        catch e2
            awr_log(['ERR: config socket 4096 cannot be opened: ' e2.message]);
            awr_log('  -> Is the port held by mmWave Studio/DCA CLI? Is the NIC on 192.168.33.x?');
            return;
        end
    end

    %% data socket (4098)
    try
        udpData = udpport('byte','LocalPort',DATA_PORT,'Timeout',TO);
    catch
        awr_log('WARN: data socket 4098 cannot be opened'); udpData = [];
    end
    awr_log(sprintf('DCA1000: config %s:%d (send+recv), data :%d', PC_IP, CONFIG_PORT, DATA_PORT));

    fpgaVersion = '?';

    %% 0x09 SYSTEM_CONNECT
    [ok09, ~] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 9, [], 'SYSTEM_CONNECT (0x09)');
    if ~ok09
        awr_log('ERR: SYSTEM_CONNECT without/with invalid response -> DCA unavailable. Stopping.');
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
        awr_log(sprintf('OK: FPGA version %s (raw 0x%04X)', fpgaVersion, st0E));
    end

    %% 0x03 CONFIG_FPGA
    % payload[6] = [LogMode, LvdsMode, XferMode, CaptureMode, FormatMode, Timer]
    %   LogMode 1=RAW | LvdsMode 1=4lane 2=2lane | XferMode 1=Capture
    %   CaptureMode 2=Ethernet | FormatMode 3=16bit | Timer=LVDS timeout
    % LvdsMode 2 = two LVDS lanes, as used by the AWR2944.
    fpgaCfg = uint8([1, 2, 1, 2, 3, 30]);
    [ok03, ~] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 3, fpgaCfg, 'CONFIG_FPGA (0x03)');

    %% 0x0B CONFIG_RECORD (packet delay/size)
    recCfg = uint8([190, 5, 53, 12, 0, 0]);   % be 05 35 0c 00 00
    [ok0B, ~] = dca_cmd(udpCfg, DCA_IP, CONFIG_PORT, 11, recCfg, 'CONFIG_RECORD (0x0B)');

    if ~(ok03 && ok0B)
        awr_log('WARN: CONFIG_FPGA or CONFIG_RECORD did not return OK (status!=0). See above.');
    end

    %% return the struct
    dca = struct('udpCfg',udpCfg, 'udpData',udpData, 'dcaIP',DCA_IP, ...
                 'configPort',CONFIG_PORT, 'dataPort',DATA_PORT, 'fpgaVersion',fpgaVersion);
    awr_log('OK: DCA1000 connected and configured');
end

%% ====== local helpers ======
function [ok, status] = dca_cmd(sock, ip, port, code, payload, name)
% Sends a DCA1000 command frame and reads the response on the same socket.
% ok=true if the frame is valid and status==0 (or for the version read, code==14).
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
        awr_log(sprintf('  %s: no response (timeout)', name));
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
            awr_log(sprintf('  %s: invalid frame hdr=0x%04X ftr=0x%04X', name, hdr, ftr));
        end
    else
        awr_log(sprintf('  %s: short response (%d B): %s', name, numel(resp), sprintf('%02X ',resp)));
    end
end

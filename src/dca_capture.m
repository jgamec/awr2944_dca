function [ok, raw] = dca_capture(uart, dca, cfg, outputBin)
% DCA_CAPTURE  ARM -> sensorStart -> receive into MEMORY (raw int16) -> stop.
%
% Order: record -> raw (-> cube in the awr2944_dca class) -> .bin (optional).
% Returns: ok  - true if any data arrived
%          raw - int16 column vector of ADC samples (losses filled with 0)
% A .bin is written ONLY if a non-empty outputBin is given.
%
% Command frame 5A A5 .. AA EE, response on port 4096,
% data packet = 10 B header + 1456 B payload.

    ok = false; raw = int16([]);
    if nargin < 4, outputBin = ''; end
    SEQ_B=4; CNT_B=6; HDR_B=SEQ_B+CNT_B; PAY_B=1456; PKT_B=HDR_B+PAY_B;
    MAX_WAIT_S = 30;

    if cfg.numFrames > 0
        expBytes = cfg.numADCSamples * cfg.chirpsPerFrame * cfg.numRx * (cfg.adcBits/8) * cfg.numFrames;
        awr_log(sprintf('Expected size: %.2f MB (%d B)', expBytes/1e6, expBytes));
    else
        expBytes = 64e6; awr_log('Infinite frames - preallocation limit 64 MB');
    end

    % preallocated output byte buffer (in memory)
    cap = ceil(expBytes*1.05 / PAY_B) * PAY_B;
    out = zeros(1, cap, 'uint8'); widx = 0;

    % ARM
    awr_log('DCA1000 ARM (START_RECORD 0x05)...');
    armResp = dca_send(dca.udpCfg, dca.dcaIP, dca.configPort, 5, []);
    awr_log(['  ARM response: ' armResp]); pause(2.0);

    % Trigger (mmWave CLI: first start after configuration = 'sensorStart',
    % restart after sensorStop = 'sensorStart 0' - chosen by the caller via
    % cfg.sensorStartCmd; without this field a bare 'sensorStart' is sent)
    flush(dca.udpData);
    startCmd = 'sensorStart';
    if isfield(cfg, 'sensorStartCmd') && ~isempty(cfg.sensorStartCmd)
        startCmd = cfg.sensorStartCmd;
    end
    awr_log(['Trigger: ' startCmd '...']);
    awr_send_cmd(uart, startCmd);

    % receive
    buf = uint8([]); pkts=0; lost=0; lastSeq=-1; t0=tic; lastRep=tic; firstData=-1;
    fprintf('\n');
    while true
        n = dca.udpData.NumBytesAvailable;
        if n > 0
            if firstData < 0, firstData = toc(t0); end
            buf = [buf, uint8(read(dca.udpData, n, 'uint8'))]; %#ok<AGROW>
            while numel(buf) >= PKT_B
                seq = double(buf(1)) + double(buf(2))*256 + double(buf(3))*65536 + double(buf(4))*16777216;
                if lastSeq >= 0 && seq > lastSeq + 1
                    miss = seq - lastSeq - 1; lost = lost + miss;
                    z = miss*PAY_B;
                    if widx+z <= cap, widx = widx + z; end   % out is already 0 -> zero fill
                end
                lastSeq = seq;
                if widx+PAY_B <= cap
                    out(widx+1:widx+PAY_B) = buf(HDR_B+1:PKT_B); widx = widx + PAY_B;
                end
                pkts = pkts + 1; buf = buf(PKT_B+1:end);
            end
        else
            pause(0.002);
        end
        if cfg.numFrames > 0 && widx >= expBytes*0.98, break; end
        if toc(t0) > MAX_WAIT_S, awr_log('WARN: timeout'); break; end
        if toc(lastRep) >= 0.5
            fprintf('\r  %.2f / %.2f MB  pkt=%d  lost=%d   ', widx/1e6, expBytes/1e6, pkts, lost);
            lastRep = tic;
        end
    end
    fprintf('\n');

    % stop
    awr_log('sensorStop + STOP_RECORD (0x06)...');
    awr_send_cmd(uart, 'sensorStop'); pause(0.3);
    dca_send(dca.udpCfg, dca.dcaIP, dca.configPort, 6, []);

    % result -> raw int16
    out = out(1:widx);
    raw = typecast(out, 'int16'); raw = raw(:);
    if firstData < 0, awr_log('  WARNING: NOTHING arrived on port 4098 (LVDS->DCA?).');
    else, awr_log(sprintf('  First data %.2f s after sensorStart', firstData)); end
    awr_log(sprintf('Received: %.3f MB (%d B), pkt=%d, lost=%d', widx/1e6, widx, pkts, lost));
    ok = (widx > 0);

    % optional .bin
    if ~isempty(outputBin)
        fid = fopen(outputBin, 'wb');
        if fid > 0, fwrite(fid, out, 'uint8'); fclose(fid); awr_log(['  .bin: ' outputBin]); end
    end
end

%% ====== local helpers ======
function resp = dca_send(sock, ip, port, code, payload)
    if nargin < 5, payload = []; end
    payload = uint8(payload(:)'); n = numel(payload);
    pkt = uint8([90,165, bitand(code,255),bitshift(code,-8), ...
                 bitand(n,255),bitshift(n,-8), payload, 170,238]);  % 5A A5 ... AA EE
    flush(sock); write(sock, pkt, 'uint8', ip, port);
    r = uint8([]); t0 = tic;
    while toc(t0) < 1.0
        if sock.NumBytesAvailable > 0, r = read(sock, sock.NumBytesAvailable, 'uint8'); break; end
        pause(0.02);
    end
    if isempty(r), resp = '(no response)'; else, resp = sprintf('%02X ', r); end
end

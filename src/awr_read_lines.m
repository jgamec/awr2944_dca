function lines = awr_read_lines(uart, maxLines, timeout_s)
% AWR_READ_LINES  Číta odpoveď z UART cez SUROVÉ bajty (bez blokujúceho readline).
%
% Prečo nie readline: demo CLI po odpovedi vypíše prompt 'mmwDemo:/>' BEZ
% koncového \n. readline by čakal na \n až do Timeout portu (~5 s) na KAŽDOM
% príkaze. Tu čítame surové bajty (read vráti hneď to, čo je k dispozícii) a
% skončíme hneď po detekcii 'Done'/'Error'/promptu -> ~50 ms na príkaz.
%
% Vstupy:
%   uart       - serialport objekt
%   maxLines   - max počet vrátených riadkov (nepovinné, default inf)
%   timeout_s  - celkový strop čakania (default 0.5 s)
%
% Výstup:
%   lines  - cell array prečítaných riadkov (strip; prompt vynechaný)

    if nargin < 2 || isempty(maxLines),  maxLines  = inf; end
    if nargin < 3 || isempty(timeout_s), timeout_s = 0.5; end
    lines = {};
    if isempty(uart) || ~isvalid(uart), return; end

    buf = '';
    sawDone = false;
    tStart = tic;
    while toc(tStart) < timeout_s
        n = uart.NumBytesAvailable;
        if n > 0
            chunk = read(uart, n, 'char');      % surové bajty, vráti okamžite
            buf = [buf, char(chunk)];           %#ok<AGROW>
            if contains(buf, 'mmwDemo') || contains(buf, 'Done') || ...
               contains(buf, 'Error', 'IgnoreCase', true) || ...
               contains(buf, 'Fail',  'IgnoreCase', true)
                sawDone = true;
            end
        elseif sawDone
            break;                              % odpoveď prišla a buffer je prázdny -> hotovo
        else
            pause(0.005);
        end
    end

    % rozdeľ buffer na riadky (CRLF/CR/LF) a vynechaj prázdne + holý prompt
    parts = regexp(buf, '\r\n|\n|\r', 'split');
    for k = 1:numel(parts)
        s = strtrim(parts{k});
        if isempty(s) || strcmp(s, 'mmwDemo:/>'), continue; end
        lines{end+1, 1} = s; %#ok<AGROW>
        if numel(lines) >= maxLines, break; end
    end
end

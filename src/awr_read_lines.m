function lines = awr_read_lines(uart, maxLines, timeout_s)
% AWR_READ_LINES  Reads a UART response as RAW bytes (no blocking readline).
%
% Why not readline: after a response the demo CLI prints the prompt 'mmwDemo:/>'
% WITHOUT a trailing \n. readline would wait for \n until the port Timeout (~5 s)
% on EVERY command. Here raw bytes are read (read returns immediately what is
% available) and reading ends as soon as 'Done'/'Error'/the prompt is detected
% -> ~50 ms per command.
%
% Inputs:
%   uart       - serialport object
%   maxLines   - maximum number of returned lines (optional, default inf)
%   timeout_s  - overall wait limit (default 0.5 s)
%
% Output:
%   lines  - cell array of the lines read (trimmed; prompt omitted)

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
            chunk = read(uart, n, 'char');      % raw bytes, returns immediately
            buf = [buf, char(chunk)];           %#ok<AGROW>
            if contains(buf, 'mmwDemo') || contains(buf, 'Done') || ...
               contains(buf, 'Error', 'IgnoreCase', true) || ...
               contains(buf, 'Fail',  'IgnoreCase', true)
                sawDone = true;
            end
        elseif sawDone
            break;                              % response received and buffer empty -> done
        else
            pause(0.005);
        end
    end

    % split the buffer into lines (CRLF/CR/LF), skip empty lines and the bare prompt
    parts = regexp(buf, '\r\n|\n|\r', 'split');
    for k = 1:numel(parts)
        s = strtrim(parts{k});
        if isempty(s) || strcmp(s, 'mmwDemo:/>'), continue; end
        lines{end+1, 1} = s; %#ok<AGROW>
        if numel(lines) >= maxLines, break; end
    end
end

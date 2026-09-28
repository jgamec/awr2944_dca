function resp = awr_send_cmd(uart, cmd)
% AWR_SEND_CMD  Pošle CLI príkaz na AWR2944 cez UART
%
% Príkaz sa posiela ako ASCII string + LF (line feed).
% AWR2944 CLI prijíma príkazy ukončené \n.
%
% Vstupy:
%   uart  - serialport objekt
%   cmd   - string príkaz (napr. 'sensorStart', 'profileCfg 0 77 ...')
%
% Výstup:
%   resp  - prázdny (odpoveď sa číta cez awr_read_lines)

resp = [];

if isempty(uart) || ~isvalid(uart)
    awr_log('ERR: UART nie je platný');
    return;
end

try
    writeline(uart, cmd);
    pause(0.02);
catch e
    awr_log(['ERR: Nepodarilo sa poslať príkaz "' cmd '": ' e.message]);
end

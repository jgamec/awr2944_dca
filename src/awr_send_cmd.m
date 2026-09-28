function resp = awr_send_cmd(uart, cmd)
% AWR_SEND_CMD  Sends a CLI command to the AWR2944 over UART
%
% The command is sent as an ASCII string + LF (line feed).
% The AWR2944 CLI accepts commands terminated by \n.
%
% Inputs:
%   uart  - serialport object
%   cmd   - command string (e.g. 'sensorStart', 'profileCfg 0 77 ...')
%
% Output:
%   resp  - empty (the response is read with awr_read_lines)

resp = [];

if isempty(uart) || ~isvalid(uart)
    awr_log('ERR: UART is not valid');
    return;
end

try
    writeline(uart, cmd);
    pause(0.02);
catch e
    awr_log(['ERR: Could not send command "' cmd '": ' e.message]);
end

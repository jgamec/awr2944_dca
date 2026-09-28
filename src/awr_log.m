function awr_log(msg)
% AWR_LOG  Vypíše správu s časovou značkou (ako mmWave Studio output log)
%
% Formát: [HH:MM:SS] správa
%
% Príklad:
%   awr_log('OK: Firmware nahraný')
%   -> [10:18:32] OK: Firmware nahraný

t = datetime('now', 'Format', 'HH:mm:ss');
fprintf('[%s] %s\n', char(t), msg);

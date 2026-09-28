function awr_log(msg)
% AWR_LOG  Prints a message with a timestamp (like the mmWave Studio output log)
%
% Format: [HH:MM:SS] message
%
% Example:
%   awr_log('OK: sensor configured')
%   -> [10:18:32] OK: sensor configured

t = datetime('now', 'Format', 'HH:mm:ss');
fprintf('[%s] %s\n', char(t), msg);

function calib = elev_calib_load()
% ELEV_CALIB_LOAD  Optional override of the elevation constants by an external
% file elev_calib_local.m (intended for teaching - students' own calibration).
% Each caller (e.g. radar_cfg) checks which fields it received and keeps the
% missing or invalid ones at its MASTER values - this file therefore never
% changes the behaviour of the toolbox if elev_calib_local.m is not on the
% MATLAB path.
%
%   calib = elev_calib_load()
%
% Returns a struct with the (optional) fields elevCalib [1x4 rad], elevScale,
% elevGateAzDeg, elevGateSnrLive - or an empty struct() if the file does not
% exist or its call fails.
%
% Expected form of elev_calib_local.m (created by the student, see
% Gamcova & Gamec, Radary v automobiloch: metodika merania a zadania, 2026):
%
%   function calib = elev_calib_local()
%       calib.elevCalib = [a, b, c, d];   % own calibration vector [rad]
%       calib.elevScale = 1.20;          % optional
%   end

    calib = struct();
    if exist('elev_calib_local', 'file') ~= 2
        return;
    end
    try
        c = elev_calib_local();
        if isstruct(c)
            calib = c;
        end
    catch err
        warning('elev_calib_load: elev_calib_local.m failed (%s) - using MASTER values.', err.message);
        calib = struct();
    end
end

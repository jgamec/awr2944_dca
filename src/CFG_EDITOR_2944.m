function CFG_EDITOR_2944(initialCfg)
% CFG_EDITOR_2944  Visual editor of mmWave .cfg profiles for AWR2944 + DCA1000.
%
% Loads a base .cfg (default = DCA_RX1111_TX1110_TDM.cfg next to this function),
% lets the user adjust the key parameters visually, recomputes live the data-cube
% dimensions, range resolution, maximum range and .bin size, and on export
% ALWAYS adds 'lvdsStreamCfg -1 0 1 0' and keeps 'adcCfg 2 0' (16-bit real).
% Other profile lines (guiMonitor, cfar...) pass through unchanged.
%
%
% RX/TX are entered in BINARY, LEFTMOST = antenna 0 (TX0/RX0):
%   '1110' = TX0+TX1+TX2 = mask 7 ;  '1011' = TX0+TX2+TX3 = mask 13.
%
% chirpCfg (TDM): kept exactly as loaded (including the order from the Demo
% Visualizer). The editor REGENERATES them only if the TX mask is changed so
% that it no longer matches - then it creates one chirpCfg per enabled TX in
% the order TX0,TX2,TX3,TX1 (azimuth ascending, elevation TX1 last - verified
% on Demo Visualizer exports) and adjusts frameCfg. Non-TDM profiles (several
% TX in one chirp) are not edited, only a warning is shown.
%
% Usage:
%   CFG_EDITOR_2944              % loads DCA_RX1111_TX1110_TDM.cfg from the toolbox folder
%   CFG_EDITOR_2944('my.cfg')    % loads a specific profile
%
% Typical workflow: load a Demo Visualizer export -> the editor adds LVDS ->
% Save .cfg -> use it in awr2944_dca (profile selection in setup).

    if nargin < 1, initialCfg = ''; end

    % ---- shared state (nested functions) ----
    H = struct();        % handles of UI elements
    D = struct();        % current parameter values
    rawLines = {};       % original .cfg lines (order preserved)
    loadedPath = '';

    % ===================== UI =====================
    fig = uifigure('Name','AWR2944 .cfg editor', 'Position',[80 80 1000 720]);
    outer = uigridlayout(fig,[1 2]);
    outer.ColumnWidth = {370,'1x'};
    outer.Padding = [8 8 8 8]; outer.ColumnSpacing = 8;

    % ---------- LEFT COLUMN (parameters + buttons) ----------
    left = uigridlayout(outer,[2 1]);
    left.Layout.Column = 1; left.RowHeight = {'1x',38};
    left.Padding = [0 0 0 0]; left.RowSpacing = 6;

    fp = uipanel(left,'Title','Profile parameters'); fp.Layout.Row = 1;
    fg = uigridlayout(fp,[21 2]);
    fg.ColumnWidth = {175,'1x'};
    fg.RowHeight = repmat({26},1,21);
    fg.RowSpacing = 4; fg.Padding = [8 6 8 6];

    hdr(fg, 1, '--- Profile (profileCfg) ---');
    H.startFreq    = mkrow(fg, 2,  'Start frequency [GHz]');
    H.idleTime     = mkrow(fg, 3,  'Idle time [us]');
    H.adcStartTime = mkrow(fg, 4,  'ADC start time [us]');
    H.rampEndTime  = mkrow(fg, 5,  'Ramp end time [us]');
    H.freqSlope    = mkrow(fg, 6,  'Slope [MHz/us]');
    H.numAdc       = mkrow(fg, 7,  'ADC samples');
    H.sampleRate   = mkrow(fg, 8,  'Sampling rate [ksps]');
    H.rxGain       = mkrow(fg, 9,  'RX gain');

    hdr(fg, 10, '--- Frame and channels ---');
    H.chirpStart   = mkrow(fg, 11, 'Chirp start idx');
    H.chirpEnd     = mkrow(fg, 12, 'Chirp end idx');
    H.numLoops     = mkrow(fg, 13, 'Number of loops');
    H.numFrames    = mkrow(fg, 14, 'Number of frames (0=inf)');
    H.framePeriod  = mkrow(fg, 15, 'Frame period [ms]');
    H.rxBin        = mkrowTxt(fg, 16, 'RX (binary, left=ant0)');
    H.txBin        = mkrowTxt(fg, 17, 'TX (binary, left=ant0)');

    hdr(fg, 18, '--- Invariants (enforced) ---');
    la = uilabel(fg,'Text','ADC: 16-bit real (adcCfg 2 0) - locked', ...
                 'FontAngle','italic','FontColor',[0.30 0.30 0.30]);
    la.Layout.Row = 19; la.Layout.Column = [1 2];
    H.lvds = uicheckbox(fg,'Text','lvdsStreamCfg -1 0 1 0  (ADC stream to DCA)','Value',true);
    H.lvds.Layout.Row = 20; H.lvds.Layout.Column = [1 2];
    H.lvds.ValueChangedFcn = @(~,~) refresh();
    ln = uilabel(fg,'Text','(without it the DCA receives no data)', ...
                 'FontSize',11,'FontColor',[0.45 0.45 0.45]);
    ln.Layout.Row = 21; ln.Layout.Column = [1 2];

    bb = uigridlayout(left,[1 3]); bb.Layout.Row = 2;
    bb.Padding = [0 0 0 0]; bb.ColumnSpacing = 6;
    uibutton(bb,'Text','Load .cfg...', 'ButtonPushedFcn',@onLoad);
    uibutton(bb,'Text','Default', 'ButtonPushedFcn',@onDefault);
    uibutton(bb,'Text','Save .cfg...', 'ButtonPushedFcn',@onSave, ...
             'BackgroundColor',[0.16 0.44 0.70],'FontColor',[1 1 1]);

    % ---------- RIGHT COLUMN (computed values + preview) ----------
    right = uigridlayout(outer,[2 1]);
    right.Layout.Column = 2; right.RowHeight = {235,'1x'};
    right.Padding = [0 0 0 0]; right.RowSpacing = 8;

    cp = uipanel(right,'Title','Computed values'); cp.Layout.Row = 1;
    cg = uigridlayout(cp,[2 1]); cg.RowHeight = {'1x','fit'}; cg.Padding = [8 6 8 6];
    H.comp = uilabel(cg,'Text','','FontName','Courier New', ...
                     'VerticalAlignment','top','HorizontalAlignment','left');
    H.comp.Layout.Row = 1;
    H.warn = uilabel(cg,'Text','','FontColor',[0.75 0.15 0.10], ...
                     'VerticalAlignment','top','WordWrap','on');
    H.warn.Layout.Row = 2;

    pp = uipanel(right,'Title','Generated .cfg (preview)'); pp.Layout.Row = 2;
    pg = uigridlayout(pp,[1 1]); pg.Padding = [6 6 6 6];
    H.preview = uitextarea(pg,'Editable','off','FontName','Courier New');

    % ---------- initial load ----------
    here = fileparts(mfilename('fullpath'));
    dflt = fullfile(here,'DCA_RX1111_TX1110_TDM.cfg');
    if ~isempty(initialCfg) && isfile(initialCfg)
        loadFile(initialCfg);
    elseif isfile(dflt)
        loadFile(dflt);
    else
        parseLines(); refresh();
    end

    % ===================== NESTED FUNCTIONS =====================

    function ef = mkrow(parent, r, labelText)
        l = uilabel(parent,'Text',labelText,'HorizontalAlignment','left');
        l.Layout.Row = r; l.Layout.Column = 1;
        ef = uieditfield(parent,'numeric','ValueDisplayFormat','%g');
        ef.Layout.Row = r; ef.Layout.Column = 2;
        ef.ValueChangedFcn = @(~,~) refresh();
    end

    function ef = mkrowTxt(parent, r, labelText)
        l = uilabel(parent,'Text',labelText,'HorizontalAlignment','left');
        l.Layout.Row = r; l.Layout.Column = 1;
        ef = uieditfield(parent,'text');
        ef.Layout.Row = r; ef.Layout.Column = 2;
        ef.ValueChangedFcn = @(~,~) refresh();
    end

    function hdr(parent, r, txt)
        l = uilabel(parent,'Text',txt,'FontWeight','bold','FontColor',[0.04 0.24 0.38]);
        l.Layout.Row = r; l.Layout.Column = [1 2];
    end

    function n = popc(m)
        m = round(m); n = 0;
        for b = 0:7
            if bitand(m, 2^b), n = n + 1; end
        end
    end

    function masks = txBitMasks(m)
        % Masks of the enabled TX in the order of the Demo Visualizer/TI convention
        % (verified on exports): azimuth TX0,TX2,TX3 ascending, elevation TX1
        % (0.8 lambda vertically) ALWAYS last. Order priority = [TX0 TX2 TX3 TX1].
        m = round(m); order = [0 2 3 1]; masks = [];
        for b = order
            if bitand(m, 2^b), masks(end+1) = 2^b; end %#ok<AGROW>
        end
    end

    function s = mask2bin(m)
        % mask -> binary string, LEFTMOST = antenna 0 (4 bits)
        m = round(m); s = repmat('0',1,4);
        for b = 0:3
            if bitand(m, 2^b), s(b+1) = '1'; end
        end
    end

    function m = bin2mask(s)
        % binary string (leftmost = antenna 0) -> mask; max 4 bits
        s = strtrim(char(s)); m = 0;
        for i = 1:min(numel(s),4)
            if s(i) == '1', m = m + 2^(i-1); end
        end
    end

    function s = chList(m, pfx)
        % "TX0, TX2, TX3" / "RX0, RX1, ..."
        m = round(m); nm = {};
        for b = 0:3
            if bitand(m, 2^b), nm{end+1} = sprintf('%s%d', pfx, b); end %#ok<AGROW>
        end
        if isempty(nm), s = '(none)'; else, s = strjoin(nm, ', '); end
    end

    function s = orderStr(masks)
        % chirp order as "TX0 -> TX2 -> TX1"
        if isempty(masks), s = '(no chirpCfg)'; return; end
        nm = cell(1,numel(masks));
        for i = 1:numel(masks)
            b = find(bitget(round(masks(i)),1:4),1) - 1;   % first set bit (0-based)
            if isempty(b), nm{i} = '?'; else, nm{i} = sprintf('TX%d', b); end
        end
        s = strjoin(nm, ' -> ');
    end

    function [regen, enMasks] = chirpPlan()
        % enMasks = TX masks from the current TX mask (order TX0,TX2,TX3,TX1)
        % regen   = regenerate chirpCfg? (only TDM and only if the set changed)
        enMasks = txBitMasks(D.txMask);
        regen = D.isTdm && ~isequal(sort(D.chirpMasks(:)'), sort(enMasks(:)'));
    end

    function t = setTok(t, idx, v)
        if idx <= numel(t), t{idx} = sprintf('%g', v); end
    end

    function loadFile(p)
        try
            txt = fileread(p);
        catch
            uialert(fig, ['Could not read: ' p], 'Error'); return;
        end
        L = strsplit(txt, newline);
        for i = 1:numel(L), L{i} = strrep(L{i}, sprintf('\r'), ''); end
        rawLines = L(:)';
        loadedPath = p;
        fig.Name = ['AWR2944 .cfg editor - ' p];
        parseLines();
        refresh();
    end

    function onLoad(~,~)
        h = fileparts(mfilename('fullpath'));
        [f,p] = uigetfile({'*.cfg','mmWave .cfg profile'}, 'Load .cfg', h);
        if isequal(f,0), return; end
        loadFile(fullfile(p,f));
    end

    function onDefault(~,~)
        h = fileparts(mfilename('fullpath'));
        d = fullfile(h,'DCA_RX1111_TX1110_TDM.cfg');
        if isfile(d), loadFile(d);
        else, uialert(fig,'DCA_RX1111_TX1110_TDM.cfg not found in the toolbox folder.','Error'); end
    end

    function parseLines()
        % defaults
        D.startFreq=77; D.idleTime=100; D.adcStartTime=6; D.rampEndTime=60;
        D.freqSlope=70; D.numAdc=256; D.sampleRate=10000; D.rxGain=30;
        D.chirpStart=0; D.chirpEnd=2; D.numLoops=16; D.numFrames=20;
        D.framePeriod=100;
        D.rxMask=15; D.txMask=7; D.adcBits=16; D.adcWasReal=true;
        D.lvdsFound=false; D.chirpCount=0; D.lvdsOn=true;
        D.chirpMasks=[]; D.isTdm=false;

        for i = 1:numel(rawLines)
            Ls = strtrim(rawLines{i});
            if isempty(Ls) || Ls(1)=='%' || Ls(1)=='#', continue; end
            t = strsplit(Ls, ' ');
            v = str2double(t(2:end)); v(isnan(v)) = 0;
            switch lower(t{1})
                case 'channelcfg'
                    if numel(v)>=2, D.rxMask=v(1); D.txMask=v(2); end
                case 'adccfg'
                    if numel(v)>=2
                        bm=[12 16 14]; ix=round(v(1));
                        if ix>=1 && ix<=3, D.adcBits=bm(ix); end
                        D.adcWasReal = (v(1)==2 && v(2)==0);
                    end
                case 'profilecfg'
                    if numel(v)>=14
                        D.startFreq=v(2); D.idleTime=v(3); D.adcStartTime=v(4);
                        D.rampEndTime=v(5); D.freqSlope=v(8); D.numAdc=v(10);
                        D.sampleRate=v(11); D.rxGain=v(14);
                    end
                case 'framecfg'
                    if numel(v)>=4
                        D.chirpStart=v(1); D.chirpEnd=v(2);
                        D.numLoops=v(3); D.numFrames=v(4);
                    end
                    if numel(v)>=6, D.framePeriod=v(6); end   % 6th value = period [ms]
                case 'chirpcfg'
                    D.chirpCount = D.chirpCount + 1;
                    if numel(v)>=8, D.chirpMasks(end+1) = v(8); end %#ok<AGROW>
                case 'lvdsstreamcfg'
                    D.lvdsFound = true;
            end
        end

        % TDM = each chirpCfg has exactly one TX mask with a single bit
        D.isTdm = D.chirpCount>0 && ~isempty(D.chirpMasks) && ...
                  all(arrayfun(@(m) popc(m)==1, D.chirpMasks));

        % to the UI (programmatic setting does not trigger ValueChangedFcn)
        H.startFreq.Value=D.startFreq;     H.idleTime.Value=D.idleTime;
        H.adcStartTime.Value=D.adcStartTime; H.rampEndTime.Value=D.rampEndTime;
        H.freqSlope.Value=D.freqSlope;     H.numAdc.Value=D.numAdc;
        H.sampleRate.Value=D.sampleRate;   H.rxGain.Value=D.rxGain;
        H.chirpStart.Value=D.chirpStart;   H.chirpEnd.Value=D.chirpEnd;
        H.numLoops.Value=D.numLoops;       H.numFrames.Value=D.numFrames;
        H.framePeriod.Value=D.framePeriod;
        H.rxBin.Value=mask2bin(D.rxMask);  H.txBin.Value=mask2bin(D.txMask);
        H.lvds.Value = true;
    end

    function refresh()
        % read UI -> D
        D.startFreq=H.startFreq.Value;     D.idleTime=H.idleTime.Value;
        D.adcStartTime=H.adcStartTime.Value; D.rampEndTime=H.rampEndTime.Value;
        D.freqSlope=H.freqSlope.Value;     D.numAdc=round(H.numAdc.Value);
        D.sampleRate=H.sampleRate.Value;   D.rxGain=H.rxGain.Value;
        D.chirpStart=round(H.chirpStart.Value); D.chirpEnd=round(H.chirpEnd.Value);
        D.numLoops=round(H.numLoops.Value); D.numFrames=round(H.numFrames.Value);
        D.framePeriod=H.framePeriod.Value;
        D.rxMask=bin2mask(H.rxBin.Value);  D.txMask=bin2mask(H.txBin.Value);
        D.lvdsOn = H.lvds.Value;

        nrx = popc(D.rxMask); ntx = popc(D.txMask);

        % plan for chirpCfg + effective order to be written
        [regenChirp, enMasks] = chirpPlan();
        if D.isTdm
            if regenChirp, effMasks = enMasks; else, effMasks = D.chirpMasks; end
            nChirp = numel(effMasks);
            % in TDM the chirp indices are derived: 0 .. (number of TX - 1)
            D.chirpStart = 0; D.chirpEnd = max(nChirp-1, 0);
            H.chirpStart.Value = D.chirpStart; H.chirpEnd.Value = D.chirpEnd;
        else
            effMasks = D.chirpMasks;
            nChirp = (D.chirpEnd - D.chirpStart + 1);
        end
        cpf = nChirp * D.numLoops;

        % --- frame-rate guard: chirp time (Demo Visualizer style) + practical limit 20 fps ---
        tChirp_us  = D.idleTime + D.rampEndTime;
        tActive_ms = cpf * tChirp_us / 1000;
        if tActive_ms > 0, maxFpsTime = 900 / tActive_ms; else, maxFpsTime = Inf; end  % 1000*0.9/tActive
        maxFps = min(20, maxFpsTime);
        if D.framePeriod > 0, fpsNow = 1000 / D.framePeriod; else, fpsNow = Inf; end

        % same formulas as everywhere else -> from RADAR_CFG (single source of truth)
        Pm = radar_cfg(struct('numAdc',D.numAdc, 'fs_ksps',D.sampleRate, ...
                 'slope_MHzus',D.freqSlope, 'startFreq_GHz',D.startFreq, ...
                 'idle_us',D.idleTime, 'rampEnd_us',D.rampEndTime, ...
                 'numTx',ntx, 'numRx',nrx, 'numLoops',D.numLoops, ...
                 'chirpStart',D.chirpStart, 'chirpEnd',D.chirpEnd, 'numFrames',D.numFrames));
        rangeRes   = Pm.rangeRes_m;
        maxR       = Pm.Rmax_m;
        rampBW_MHz = Pm.rampBW_MHz;
        fEnd_GHz   = Pm.fEnd_GHz;

        if D.numFrames > 0
            binMB = D.numAdc*cpf*nrx*2*D.numFrames/1e6;
            cubeStr = sprintf('[%d x %d x %d x %d]', D.numAdc, nrx, cpf, D.numFrames);
            binStr = sprintf('%.2f MB', binMB);
        else
            cubeStr = sprintf('[%d x %d x %d x inf]', D.numAdc, nrx, cpf);
            binStr = 'inf (numFrames=0)';
        end

        compTxt = sprintf([ ...
            'RX channels:          %s\n' ...
            'TX channels:          %s\n' ...
            'chirp order (TX):     %s\n' ...
            'RX / TX count:        %d / %d\n' ...
            'chirps / frame:       %d   (= %d x %d loops)\n' ...
            'data cube:            %s\n' ...
            'range resolution:     %.1f cm\n' ...
            'max. range:           %.1f m\n' ...
            'total bandwidth:      %.0f MHz\n' ...
            'end frequency:        %.2f GHz\n' ...
            'frame period/fps:     %g ms (%.1f fps) | t_active %.1f ms | max %.1f fps\n' ...
            '.bin size:            %s'], ...
            chList(D.rxMask,'RX'), chList(D.txMask,'TX'), orderStr(effMasks), ...
            nrx, ntx, cpf, nChirp, D.numLoops, ...
            cubeStr, rangeRes*100, maxR, rampBW_MHz, fEnd_GHz, ...
            D.framePeriod, fpsNow, tActive_ms, maxFps, binStr);
        H.comp.Text = strsplit(compTxt, newline);

        % warnings
        w = {};
        if fEnd_GHz > 81
            w{end+1} = sprintf('- WARNING: end frequency %.2f GHz exceeds 81 GHz (outside the AWR2944 band)!', fEnd_GHz);
        end
        if D.startFreq < 76
            w{end+1} = sprintf('- WARNING: start frequency %.2f GHz is below 76 GHz (outside the AWR2944 band).', D.startFreq);
        end
        if ~D.adcWasReal
            w{end+1} = '- adcCfg was not 2 0 -> forced to 16-bit real.';
        end
        % consistency channelCfg <-> chirpCfg
        if D.chirpCount > 0
            if D.isTdm
                if regenChirp
                    w{end+1} = sprintf('- TX mask changed -> chirpCfg will be regenerated as: %s (TDM, TX1 last), frameCfg adjusted.', orderStr(enMasks));
                end
            else
                cu = 0; for mm = D.chirpMasks, cu = bitor(cu, round(mm)); end
                if cu ~= round(D.txMask)
                    w{end+1} = sprintf('- NON-TDM profile: union of chirpCfg masks (%d) != TX mask (%d). The editor does not change chirpCfg - edit manually.', cu, round(D.txMask));
                end
            end
        end
        if ~D.isTdm && D.chirpCount > 0 && D.chirpCount ~= (D.chirpEnd - D.chirpStart + 1)
            w{end+1} = sprintf('- number of chirpCfg (%d) != chirpEnd-chirpStart+1 (%d) - check TDM.', ...
                               D.chirpCount, (D.chirpEnd - D.chirpStart + 1));
        end
        if D.numFrames == 0
            w{end+1} = '- numFrames=0 = infinite; for capture() enter a finite number (e.g. 20).';
        end
        if D.framePeriod <= 0
            w{end+1} = '- frame period must be > 0 ms.';
        elseif D.framePeriod < tActive_ms/0.9
            w{end+1} = sprintf('- WARNING: frame period %g ms < active chirp time (t_active=%.1f ms at 90%%) -> max ~%.1f fps (chirp time). The radar will reject the period.', D.framePeriod, tActive_ms, maxFpsTime);
        elseif fpsNow > 20 + 1e-9
            w{end+1} = sprintf('- frame rate %.1f fps exceeds the practical limit of 20 fps -> set the frame period >= 50 ms.', fpsNow);
        end
        if ~D.lvdsOn
            w{end+1} = '- WARNING: lvdsStreamCfg disabled -> the DCA receives no data!';
        end
        if ~D.lvdsFound && D.lvdsOn
            w{end+1} = '- lvdsStreamCfg was missing in the loaded profile -> the editor adds it on export.';
        end
        if isempty(w), H.warn.Text = ''; else, H.warn.Text = strjoin(w, newline); end

        % preview
        H.preview.Value = strsplit(generateCfg(), newline);
    end

    function txt = generateCfg()
        out = {};
        hasLvds = false; hasAnalog = false;
        [regenChirp, enMasks] = chirpPlan();
        chirpEmitted = false;
        for i = 1:numel(rawLines)
            Ls = strtrim(rawLines{i});
            if isempty(Ls), out{end+1} = ''; continue; end
            if Ls(1)=='%' || Ls(1)=='#', out{end+1} = Ls; continue; end
            t = strsplit(Ls, ' ');
            switch lower(t{1})
                case 'channelcfg'
                    t = setTok(t,2,D.rxMask); t = setTok(t,3,D.txMask);
                    out{end+1} = strjoin(t,' ');
                case 'adccfg'
                    out{end+1} = 'adcCfg 2 0';            % invariant
                case 'profilecfg'
                    t = setTok(t,3,D.startFreq);   t = setTok(t,4,D.idleTime);
                    t = setTok(t,5,D.adcStartTime); t = setTok(t,6,D.rampEndTime);
                    t = setTok(t,9,D.freqSlope);   t = setTok(t,11,D.numAdc);
                    t = setTok(t,12,D.sampleRate); t = setTok(t,15,D.rxGain);
                    out{end+1} = strjoin(t,' ');
                case 'chirpcfg'
                    if regenChirp
                        % regenerate the whole block at the first occurrence, skip the rest
                        if ~chirpEmitted
                            for kk = 1:numel(enMasks)
                                out{end+1} = sprintf('chirpCfg %d %d 0 0 0 0 0 %d', kk-1, kk-1, enMasks(kk));
                            end
                            chirpEmitted = true;
                        end
                    else
                        out{end+1} = Ls;   % keep the original (order from Demo Visualizer)
                    end
                case 'framecfg'
                    t = setTok(t,2,D.chirpStart); t = setTok(t,3,D.chirpEnd);
                    t = setTok(t,4,D.numLoops);   t = setTok(t,5,D.numFrames);
                    t = setTok(t,7,D.framePeriod);   % 6th value = period [ms] (token 7)
                    out{end+1} = strjoin(t,' ');
                case 'analogmonitor'
                    hasAnalog = true; out{end+1} = Ls;
                case 'lvdsstreamcfg'
                    hasLvds = true;
                    if D.lvdsOn, out{end+1} = 'lvdsStreamCfg -1 0 1 0';
                    else,        out{end+1} = Ls; end
                case 'sensorstart'
                    if ~hasAnalog, out{end+1} = 'analogMonitor 0 0'; hasAnalog = true; end
                    if ~hasLvds && D.lvdsOn, out{end+1} = 'lvdsStreamCfg -1 0 1 0'; hasLvds = true; end
                    out{end+1} = Ls;
                otherwise
                    out{end+1} = Ls;
            end
        end
        if ~hasLvds && D.lvdsOn
            if ~hasAnalog, out{end+1} = 'analogMonitor 0 0'; end
            out{end+1} = 'lvdsStreamCfg -1 0 1 0';
        end
        txt = strjoin(out, newline);
    end

    function nm = conventionName()
        % build the name by our convention from the profile CONTENT:
        %   <DCA|DV>_RX<mask>_TX<mask>[_TDM].cfg
        % prefix by LVDS (DCA = has lvdsStreamCfg / raw capture, DV = none / TLV),
        % binary masks (left = antenna 0), _TDM if the profile is time-multiplexed.
        if D.lvdsOn, pfx = 'DCA'; else, pfx = 'DV'; end
        nm = sprintf('%s_RX%s_TX%s', pfx, mask2bin(D.rxMask), mask2bin(D.txMask));
        if D.isTdm, nm = [nm '_TDM']; end
        nm = [nm '.cfg'];
    end

    function onSave(~,~)
        % suggested name: if it already follows our convention, keep it (it carries
        % everything incl. LVDS in the prefix); for a foreign export (Demo Visualizer/
        % mmWave Studio), build the full conventional name from the content.
        if ~isempty(loadedPath)
            [~,n,e] = fileparts(loadedPath);
            if startsWith(n,'DCA_') || startsWith(n,'DV_')
                sug = [n e];
            else
                sug = conventionName();
            end
        else
            sug = conventionName();
        end
        [f,p] = uiputfile({'*.cfg','mmWave .cfg'}, 'Save .cfg', sug);
        if isequal(f,0), return; end
        full = fullfile(p,f);
        fid = fopen(full,'w');
        if fid < 0, uialert(fig,'Could not write the file.','Error'); return; end
        lines = strsplit(generateCfg(), newline);
        for i = 1:numel(lines), fprintf(fid, '%s\n', lines{i}); end
        fclose(fid);
        uialert(fig, sprintf('Saved:\n%s', full), 'Done', 'Icon','success');
    end
end

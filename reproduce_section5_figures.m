%% REPRODUCE_SECTION5_FIGURES - application figures of the article (Section V)
% One data cube -> two products: a range-Doppler map of one frame (static
% background suppressed) and a micro-Doppler spectrogram across frames.
% Input:  sample_data\capture_raw_micro\adc_data_Raw_0.bin (shipped)
% Output: figures_out\fig_rd_51_mti.png, figures_out\fig_md_52.png
% Run the whole file (F5). No hardware required.

HERE = fileparts(mfilename('fullpath'));
SRC  = fullfile(HERE, 'sample_data', 'capture_raw_micro', 'adc_data_Raw_0.bin');
OUT  = fullfile(HERE, 'figures_out');
if ~exist(OUT, 'dir'), mkdir(OUT); end
c0 = 299792458;

% profile DCA_RX1111_TX1011_micro (non-TDM, 3 TX simultaneously)
nS = 560; nRX = 4; nCh = 48; fs = 11.396e6; S = 70e12;
Tc  = (267 + 57.14)*1e-6;          % chirp period (idle + ramp)
Tf  = 0.100;                        % frame period
lam = c0/79.2e9;                    % operating wavelength (band center)

fid = fopen(SRC); x = fread(fid, inf, 'int16=>double'); fclose(fid);
spf = nS*nRX*nCh; nF = floor(numel(x)/spf);
cube = reshape(x(1:spf*nF), [nS nRX nCh nF]);
fprintf('cube: [%d %d %d %d]  (%.1f s of recording)\n', size(cube), nF*Tf);

% range FFT (Hann window, per-chirp DC removal), noncoherent sum of 4 RX
w = hann(nS);
D = cube - mean(cube, 1);
R = fft(D .* w, nS, 1); R = R(1:nS/2, :, :, :);         % [280 4 48 nF]
rax = (0:nS/2-1)' * c0*fs/(2*S*nS);                      % range axis
A = squeeze(sum(abs(R), 2));                             % [280 48 nF]

% ---- range-bin selection for micro-Doppler: max slow-time variance ----
sel = rax >= 0.5 & rax <= 2.5;
va = var(reshape(A, size(A,1), []), 0, 2); va(~sel) = 0;
[~, kbin] = max(va);
fprintf('micro-Doppler range bin: %d (%.2f m)\n', kbin, rax(kbin));

% ---- micro-Doppler spectrogram: per-frame Doppler FFT at kbin ----
nfftD = 128; wD = hann(nCh).';
sd = squeeze(R(kbin,1,:,:) + R(kbin,2,:,:) + R(kbin,3,:,:) + R(kbin,4,:,:));
MD = fftshift(fft(sd .* wD.', nfftD, 1), 1);             % [128 nF]
MDdb = 20*log10(abs(MD)); MDdb = MDdb - max(MDdb(:));
vax = ((-nfftD/2:nfftD/2-1)/nfftD) * lam/(2*Tc);         % velocity axis
tax = (0:nF-1)*Tf;

f = figure('Position',[80 80 760 400]);
imagesc(tax, vax, MDdb, [-40 0]); axis xy; ylim([-2.5 2.5])
xlabel('time (s)'); ylabel('velocity (m/s)');
cb = colorbar; ylabel(cb, 'magnitude (dB)');
title(sprintf('micro-Doppler @ %.2f m', rax(kbin)));
print(f, fullfile(OUT, 'fig_md_52.png'), '-dpng', '-r110'); close(f)

% ---- range-Doppler map: frame with max energy outside |v| < 0.5 m/s,
%      static background suppressed by subtracting the chirp mean ----
Rm  = R - mean(R, 3);                                    % per-frame MTI
RDm = fftshift(fft(permute(Rm, [1 3 2 4]) .* reshape(wD,1,[]), nfftD, 2), 2);
RDmS = squeeze(sum(abs(RDm), 3));                        % [280 128 nF]
vmask = abs(((-nfftD/2:nfftD/2-1)/nfftD)*lam/(2*Tc)) > 0.5;
[~, kfr] = max(squeeze(sum(sum(RDmS(sel, vmask, :), 1), 2)));
fprintf('range-Doppler frame: %d (t = %.1f s)\n', kfr, (kfr-1)*Tf);
RDmdb = 20*log10(RDmS(:,:,kfr)); RDmdb = RDmdb - max(RDmdb(:));

f = figure('Position',[80 80 560 420]);
imagesc(vax, rax, RDmdb, [-35 0]); axis xy; ylim([0 3.5])
xlabel('velocity (m/s)'); ylabel('range (m)');
cb = colorbar; ylabel(cb, 'magnitude (dB)');
title(sprintf('range-Doppler (static suppressed), frame %d', kfr));
print(f, fullfile(OUT, 'fig_rd_51_mti.png'), '-dpng', '-r110'); close(f)

fprintf('DONE. Output: %s\n', OUT);

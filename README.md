# awr2944_dca — Raw Data Acquisition for the TI AWR2944EVM + DCA1000EVM in MATLAB

The `awr2944_dca` class is a native MATLAB path to raw ADC data of the
Texas Instruments AWR2944 radar module with the DCA1000EVM capture card.
A single call configures both the sensor and the capture card and returns
the complete four-dimensional data cube
(samples x RX channels x chirps x frames).

## Contents

| Item                                   | Description                                            |
|----------------------------------------|--------------------------------------------------------|
| `src/awr2944_dca.m`                        | The acquisition class (v1.7)                           |
| `src/awr_*.m`, `src/dca_*.m` | Helper functions: sensor CLI over UART, DCA1000EVM control and UDP capture, logging |
| `src/DCA_RX1111_TX1110_TDM.cfg`   | Class default profile (TDM, 3 TX, elevation TX1)       |
| `src/cast4_mmws_match.cfg`        | Verification profile (single TX0)  |
| `sample_data/capture_raw/`             | Sample recording: static corner-reflector scene        |
| `sample_data/capture_raw_micro/`       | Sample recording: rotating wire whisk (micro-Doppler)  |
| `reproduce_section5_figures.m`         | Reproduces the range-Doppler map and micro-Doppler spectrogram      |
| `LICENSE.txt`                              | MIT                                                    |

Each sample-data folder holds the raw recording (`adc_data_Raw_0.bin`), its
companion `adc_data_LogFile.txt`, and a copy of the configuration profile used:

- **capture_raw** — trihedral corner reflector on the boresight at 3.0 m, apex at
  antenna height, recorded with the default TDM profile (3 TX, 20 frames).
- **capture_raw_micro** — a single wire whisk on the planetary attachment of a
  food processor at 1.0–1.2 m, recorded with a non-TDM profile in which three
  azimuth transmitters transmit simultaneously (98 frames, 9.8 s).

## Requirements

- MATLAB (developed and tested on R2024b/R2025a, Windows) with Instrument Control Toolbox (required for acquisition: UDP interface of the DCA1000EVM)
- For live measurements: AWR2944EVM flashed with the TI mmw demo firmware
  (mmWave MCUPLUS SDK), DCA1000EVM, Ethernet connection
- No hardware is needed to read the sample data or reproduce the figures

## Quick start — no hardware

```matlab
addpath('src');
src  = awr2944_dca('ConfigFile', 'sample_data/capture_raw/DCA_RX1111_TX1110_TDM.cfg');
cube = src.readBin('sample_data/capture_raw/adc_data_Raw_0.bin');
size(cube)          % 560 x 4 x 48 x 19  [samples x RX x chirps x frames]
```

Reproduce the range-Doppler map and micro-Doppler spectrogram from the sample recording:

```matlab
reproduce_section5_figures
```

## Quick start — with hardware

```matlab
addpath('src');
src  = awr2944_dca;      % interactive profile and COM-port prompts
cube = src.capture();    % one batch measurement; writes .bin + LogFile
```

Continuous operation:

```matlab
src.startLive();
for k = 1:100
    frm = src.readFrame();          % complete frame sequence
end                                  % readFrameLatest() = bounded latency
src.stopLive(); src.release();
```

## Citation

A citation will be provided here once the accompanying article is published.

## Acknowledgment

This work was supported by the Cultural and Educational Grant Agency of the
Ministry of Education, Research, Development and Youth of the Slovak Republic
under Grant KEGA 073TUKE-4/2024.

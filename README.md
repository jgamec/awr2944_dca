# awr2944_dca — Raw Data Acquisition for the TI AWR2944EVM + DCA1000EVM in MATLAB

Companion package for the article:

> J. Gamec and M. Gamcova, "Raw Data Acquisition for 4D mmWave Radar:
> An Open MATLAB Interface to the AWR2944EVM and DCA1000EVM,"
> 2026, submitted for publication.
> [journal, volume, year, DOI — to be added upon acceptance]

The article is currently under review. This package is released together with
the article; the citation above and the DOI of this deposit will be completed
once the article is accepted.

The `awr2944_dca` class is a native MATLAB path to raw ADC data of the
Texas Instruments AWR2944 radar module with the DCA1000EVM capture card.
A single call configures both the sensor and the capture card and returns
the complete four-dimensional data cube
(samples x RX channels x chirps x frames).

## Contents

| Item                                   | Description                                            |
|----------------------------------------|--------------------------------------------------------|
| `src/awr2944_dca.m`                        | The acquisition class (v1.7)                           |
| `profiles/DCA_RX1111_TX1110_TDM.cfg`   | Class default profile (TDM, 3 TX, elevation TX1)       |
| `profiles/cast4_mmws_match.cfg`        | Verification profile (single TX0; used in Section IV)  |
| `sample_data/capture_raw/`             | Sample recording: static corner-reflector scene        |
| `sample_data/capture_raw_micro/`       | Sample recording: rotating wire whisk (micro-Doppler)  |
| `reproduce_section5_figures.m`         | Reproduces the application figures of the article      |
| `LICENSE.txt`                              | MIT                                                    |

Each sample-data folder holds the raw recording (`adc_data_Raw_0.bin`), its
companion `adc_data_LogFile.txt`, and a copy of the configuration profile used:

- **capture_raw** — trihedral corner reflector on the boresight at 3.0 m, apex at
  antenna height, recorded with the default TDM profile (3 TX, 20 frames).
- **capture_raw_micro** — a single wire whisk on the planetary attachment of a
  food processor at 1.0–1.2 m, recorded with a non-TDM profile in which three
  azimuth transmitters transmit simultaneously (98 frames, 9.8 s). This is the
  recording behind the application figures of Section V.

## Requirements

- MATLAB (developed and tested on R2024b/R2025a, Windows; the class relies
  only on the standard serial-port and UDP interfaces)
- For live measurements: AWR2944EVM flashed with the TI mmw demo firmware
  (mmWave MCUPLUS SDK), DCA1000EVM, Ethernet connection
- No hardware is needed to read the sample data or reproduce the figures

## Quick start — no hardware

```matlab
addpath('src');
src  = awr2944_dca('ConfigFile', 'profiles/cast4_mmws_match.cfg');
cube = src.readBin('sample_data/capture_raw/adc_data_Raw_0.bin');
size(cube)          % [samples x RX x chirps x frames]
```

Reproduce the article figures (range-Doppler map and micro-Doppler
spectrogram, Section V):

```matlab
reproduce_section5_figures
```

## Quick start — with hardware

```matlab
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

If you use this package, please cite the article above (DOI to be added upon
acceptance). Until then, please cite this deposit by its Zenodo DOI.

## Acknowledgment

This work was supported by the Cultural and Educational Grant Agency of the
Ministry of Education, Research, Development and Youth of the Slovak Republic
under Grant KEGA 073TUKE-4/2024.

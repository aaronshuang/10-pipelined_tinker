# Pipelined Tinker

This repository contains a modular pipelined Tinker implementation with:

- 2-wide fetch and rename
- register renaming with a physical register file
- reservation stations
- reorder buffer based retirement
- separate integer ALU and floating-point execution paths
- load/store queue with store-to-load forwarding

Repository layout:

- `hdl/`: synthesizable modules
- `test/`: testbenches
- `sim/`: waveform output
- `vvp/`: compiled simulation binaries

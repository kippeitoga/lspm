# Project Overview

## Goal
Build an MVP that:
- connects an LSMP device to an iPhone via BLE
- receives and visualizes lung sound data
- records the audio locally
- uploads the recording to a server
- runs AI wheeze detection on the server
- returns and displays the result on the iPhone

## Tech Stack
- iOS app: Swift, SwiftUI, CoreBluetooth
- Server: Python, FastAPI
- AI: Python, TensorFlow/Keras
- Audio processing: librosa, numpy

## Non-Goals for MVP
- On-device AI inference
- Multi-user accounts
- App Store release readiness
- Crackle/cough classification
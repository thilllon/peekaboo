# Peekaboo

Ultra-fast image viewer for macOS (Apple Silicon) — work in progress.

Goals:
- Instant first pixel: show a low-resolution preview immediately, then re-rasterize at high quality.
- Predictive prefetch: neighbouring images in the folder are decoded before you ask for them.
- Custom GPU rendering pipeline for sharp, alias-free zoom at 120–144 Hz.
- Fully keyboard-driven and customizable (config file keymap).

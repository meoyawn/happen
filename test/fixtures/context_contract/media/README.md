# Recorded-audio fixture

`jfk-excerpt.wav` is a three-second excerpt of the recorded JFK speech in
OpenAI Whisper's `tests/jfk.flac`, converted to 8 kHz mono 16-bit PCM WAV.
It tests forwarding and duration accounting; tests never play it or synthesize
audio.

Source: <https://github.com/openai/whisper/blob/main/tests/jfk.flac>
(Whisper repository: MIT license; Kennedy speech recording: public domain.)

- Downloaded source SHA-256: `63a4b1e4c1dc655ac70961ffbf518acd249df237e5a0152faae9a4a836949715`
- Converted fixture SHA-256: `b1b8937d38995cb46bc538990a96a19987cf4e1e27b3cb25e8fe720719691dc2`
- Size: 48,078 bytes

Conversion: `ffmpeg -i jfk.flac -t 3 -ar 8000 -ac 1 -c:a pcm_s16le -map_metadata -1 jfk-excerpt.wav`.
The test uses the committed bytes and requires neither FFmpeg nor network access.

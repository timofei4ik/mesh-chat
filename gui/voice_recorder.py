import os
import struct
import tempfile
import wave
from datetime import datetime

from PyQt6.QtCore import QBuffer, QIODevice, QTimer
from PyQt6.QtMultimedia import QAudioFormat, QAudioSource, QMediaDevices


class VoiceRecorderMixin:

    def setup_voice_recorder(self):

        self.voice_audio_source = None
        self.voice_buffer = None
        self.voice_recording = False
        self.voice_record_timer = QTimer(
            self
        )
        self.voice_record_timer.setSingleShot(
            True
        )
        self.voice_record_timer.timeout.connect(
            self.stop_voice_recording
        )

    def toggle_voice_recording(self):

        if self.voice_recording:

            self.stop_voice_recording()

        else:

            self.start_voice_recording()

    def start_voice_recording(self):

        audio_input = QMediaDevices.defaultAudioInput()

        if audio_input.isNull():

            self.show_voice_error(
                "Микрофон не найден"
            )

            return

        audio_format = QAudioFormat()
        audio_format.setSampleRate(
            16000
        )
        audio_format.setChannelCount(
            1
        )
        audio_format.setSampleFormat(
            QAudioFormat.SampleFormat.Int16
        )

        if not audio_input.isFormatSupported(
            audio_format
        ):

            audio_format = audio_input.preferredFormat()

        self.voice_buffer = QBuffer(
            self
        )
        self.voice_buffer.open(
            QIODevice.OpenModeFlag.WriteOnly
        )

        self.voice_audio_source = QAudioSource(
            audio_input,
            audio_format,
            self
        )
        self.voice_audio_source.start(
            self.voice_buffer
        )

        self.voice_recording = True
        self.voice_format = audio_format
        self.voice_button.setText(
            "■"
        )
        self.voice_button.setToolTip(
            "Остановить запись"
        )
        self.voice_record_timer.start(
            60000
        )

    def stop_voice_recording(self):

        if not self.voice_recording:
            return

        self.voice_recording = False
        self.voice_record_timer.stop()

        if self.voice_audio_source:

            self.voice_audio_source.stop()

        if not self.voice_buffer:
            return

        data = bytes(
            self.voice_buffer.data()
        )

        self.voice_buffer.close()
        self.voice_buffer = None
        self.voice_audio_source = None

        self.voice_button.setText(
            "🎙"
        )
        self.voice_button.setToolTip(
            "Голосовое сообщение"
        )

        if len(data) < 1024:

            self.show_voice_error(
                "Запись слишком короткая"
            )

            return

        path = self.write_voice_wav(
            data
        )

        if path:

            self.send_file_path(
                path
            )

    def write_voice_wav(
        self,
        data
    ):

        filename = (
            "voice_"
            + datetime.now().strftime(
                "%Y%m%d_%H%M%S"
            )
            + ".wav"
        )

        path = os.path.join(
            tempfile.gettempdir(),
            filename
        )

        pcm_data = self.convert_voice_data_to_pcm16(
            data
        )

        with wave.open(
            path,
            "wb"
        ) as wav_file:

            wav_file.setnchannels(
                self.voice_format.channelCount()
                or 1
            )
            wav_file.setsampwidth(
                2
            )
            wav_file.setframerate(
                self.voice_format.sampleRate()
                or 16000
            )
            wav_file.writeframes(
                pcm_data
            )

        return path

    def convert_voice_data_to_pcm16(
        self,
        data
    ):

        sample_format = self.voice_format.sampleFormat()

        if sample_format == QAudioFormat.SampleFormat.Int16:
            return data

        converted = bytearray()

        if sample_format == QAudioFormat.SampleFormat.Float:

            for offset in range(
                0,
                len(data) - 3,
                4
            ):

                value = struct.unpack(
                    "<f",
                    data[offset:offset + 4]
                )[0]
                value = max(
                    -1.0,
                    min(
                        1.0,
                        value
                    )
                )
                converted.extend(
                    int(
                        value * 32767
                    ).to_bytes(
                        2,
                        "little",
                        signed=True
                    )
                )

            return bytes(
                converted
            )

        if sample_format == QAudioFormat.SampleFormat.UInt8:

            for value in data:

                converted.extend(
                    int(
                        (value - 128) * 256
                    ).to_bytes(
                        2,
                        "little",
                        signed=True
                    )
                )

            return bytes(
                converted
            )

        int32_format = getattr(
            QAudioFormat.SampleFormat,
            "Int32",
            None
        )

        if (
            int32_format is not None
            and sample_format == int32_format
        ):

            for offset in range(
                0,
                len(data) - 3,
                4
            ):

                value = int.from_bytes(
                    data[offset:offset + 4],
                    "little",
                    signed=True
                )
                converted.extend(
                    int(
                        value / 65536
                    ).to_bytes(
                        2,
                        "little",
                        signed=True
                    )
                )

            return bytes(
                converted
            )

        return data

    def show_voice_error(
        self,
        message
    ):

        if hasattr(
            self,
            "add_my_message"
        ):

            self.add_my_message(
                f"[Система] {message}"
            )

        elif hasattr(
            self,
            "add_message"
        ):

            self.add_message(
                "Система",
                message,
                False
            )

import wave

from PyQt6.QtCore import Qt, QUrl, pyqtSignal
from PyQt6.QtGui import QColor, QPainter
from PyQt6.QtMultimedia import QAudioOutput, QMediaPlayer
from PyQt6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QPushButton,
    QVBoxLayout,
    QWidget,
)


def format_millis(ms):

    seconds = max(
        0,
        int(ms / 1000)
    )
    minutes = seconds // 60
    seconds = seconds % 60

    return f"{minutes}:{seconds:02d}"


class WaveformWidget(QWidget):

    seek_requested = pyqtSignal(float)

    def __init__(
        self,
        parent=None
    ):

        super().__init__(
            parent
        )

        self.samples = [
            0.35, 0.55, 0.42, 0.68, 0.50, 0.80,
            0.48, 0.62, 0.38, 0.73, 0.58, 0.46,
            0.66, 0.52, 0.76, 0.44, 0.60, 0.35,
            0.70, 0.50, 0.64, 0.40, 0.78, 0.56,
            0.45, 0.68, 0.52, 0.74, 0.42, 0.60,
            0.36, 0.70, 0.50, 0.62, 0.44, 0.58,
        ]
        self.progress = 0.0
        self.setFixedHeight(
            34
        )
        self.setMinimumWidth(
            150
        )
        self.setCursor(
            Qt.CursorShape.PointingHandCursor
        )

    def set_samples(
        self,
        samples
    ):

        if samples:

            self.samples = samples

        self.update()

    def set_progress(
        self,
        progress
    ):

        self.progress = max(
            0.0,
            min(
                1.0,
                progress
            )
        )
        self.update()

    def paintEvent(
        self,
        event
    ):

        painter = QPainter(
            self
        )
        painter.setRenderHint(
            QPainter.RenderHint.Antialiasing
        )

        width = self.width()
        height = self.height()
        count = len(
            self.samples
        )

        if count <= 0:
            return

        gap = 3
        bar_width = max(
            3,
            int(
                (width - gap * (count - 1)) / count
            )
        )
        active_limit = width * self.progress
        center = height / 2

        for index, sample in enumerate(
            self.samples
        ):

            x = index * (
                bar_width + gap
            )

            if x > width:
                break

            bar_height = max(
                6,
                int(
                    sample * (height - 6)
                )
            )
            y = int(
                center - bar_height / 2
            )

            painter.setBrush(
                QColor(
                    "#8fb8ff"
                    if x <= active_limit
                    else "#596170"
                )
            )
            painter.setPen(
                Qt.PenStyle.NoPen
            )
            painter.drawRoundedRect(
                x,
                y,
                bar_width,
                bar_height,
                2,
                2
            )

    def mousePressEvent(
        self,
        event
    ):

        self.emit_seek(
            event.position().x()
        )

    def mouseMoveEvent(
        self,
        event
    ):

        if event.buttons() & Qt.MouseButton.LeftButton:

            self.emit_seek(
                event.position().x()
            )

    def emit_seek(
        self,
        x
    ):

        width = max(
            1,
            self.width()
        )

        self.seek_requested.emit(
            max(
                0.0,
                min(
                    1.0,
                    x / width
                )
            )
        )


class AudioMessageWidget(QWidget):

    def __init__(
        self,
        filename,
        resolve_path,
        parent=None
    ):

        super().__init__(
            parent
        )

        self.filename = filename
        self.resolve_path = resolve_path
        self.loaded_path = ""
        self.duration_ms = 0
        self.player = None
        self.audio_output = None

        self.setObjectName(
            "file_preview"
        )
        self.setFixedWidth(
            260
        )
        self.setFixedHeight(
            78
        )
        self.setStyleSheet(
            """
            QWidget#file_preview {
                background:#20242b;
                border:1px solid #4a505c;
                border-radius:8px;
            }
            QLabel {
                color:white;
            }
            QPushButton {
                background:#2f80ed;
                color:white;
                border:none;
                border-radius:16px;
                font-size:14px;
                min-width:32px;
                max-width:32px;
                min-height:32px;
                max-height:32px;
            }
            QPushButton:hover {
                background:#3d8cff;
            }
            """
        )

        layout = QHBoxLayout(
            self
        )
        layout.setContentsMargins(
            10, 8, 10, 8
        )
        layout.setSpacing(
            10
        )

        self.play_button = QPushButton(
            "▶"
        )
        self.play_button.clicked.connect(
            self.toggle_playback
        )

        text_column = QVBoxLayout()
        text_column.setContentsMargins(
            0, 0, 0, 0
        )
        text_column.setSpacing(
            4
        )

        self.title_label = QLabel(
            "Голосовое сообщение"
            if filename.lower().endswith(".wav")
            else filename
        )
        self.title_label.setStyleSheet(
            "font-size:12px;font-weight:600;"
        )

        self.waveform = WaveformWidget()
        self.waveform.seek_requested.connect(
            self.seek_to_ratio
        )

        self.time_label = QLabel(
            self.read_wave_duration()
        )
        self.time_label.setStyleSheet(
            "color:#cfd3da;font-size:11px;"
        )
        self.time_label.setAlignment(
            Qt.AlignmentFlag.AlignRight
        )

        text_column.addWidget(
            self.title_label
        )
        text_column.addWidget(
            self.waveform
        )
        text_column.addWidget(
            self.time_label
        )

        layout.addWidget(
            self.play_button
        )
        layout.addLayout(
            text_column,
            1
        )

        self.load_waveform()

    def ensure_player(self):

        if self.player:
            return

        self.player = QMediaPlayer(
            self
        )
        self.audio_output = QAudioOutput(
            self
        )
        self.player.setAudioOutput(
            self.audio_output
        )
        self.audio_output.setVolume(
            1.0
        )
        self.player.positionChanged.connect(
            self.on_position_changed
        )
        self.player.durationChanged.connect(
            self.on_duration_changed
        )
        self.player.playbackStateChanged.connect(
            self.on_state_changed
        )

    def resolve_audio_path(self):

        return self.resolve_path(
            self.filename
        )

    def read_wave_duration(self):

        path = self.resolve_audio_path()

        if not path:
            return "0:00"

        try:

            with wave.open(
                path,
                "rb"
            ) as wav_file:

                frames = wav_file.getnframes()
                rate = wav_file.getframerate() or 1

            self.duration_ms = int(
                frames * 1000 / rate
            )

            return format_millis(
                self.duration_ms
            )

        except Exception:

            return "0:00"

    def load_waveform(self):

        path = self.resolve_audio_path()

        if path:

            self.waveform.set_samples(
                self.read_waveform_samples(
                    path
                )
            )

    def read_waveform_samples(
        self,
        path,
        count=36
    ):

        try:

            with wave.open(
                path,
                "rb"
            ) as wav_file:

                sample_width = wav_file.getsampwidth()
                channels = max(
                    1,
                    wav_file.getnchannels()
                )
                frames = wav_file.readframes(
                    wav_file.getnframes()
                )

            if sample_width not in (
                1,
                2,
                3,
                4
            ) or not frames:
                return []

            frame_size = sample_width * channels
            total_frames = len(frames) // frame_size
            bucket = max(
                1,
                total_frames // count
            )
            raw_samples = []

            for index in range(
                count
            ):

                start = index * bucket * frame_size
                end = min(
                    len(frames),
                    start + bucket * frame_size
                )
                chunk = frames[
                    start:end
                ]

                if not chunk:
                    raw_samples.append(
                        0.0
                    )
                    continue

                total = 0
                seen = 0

                for offset in range(
                    0,
                    len(chunk) - sample_width + 1,
                    frame_size
                ):

                    sample = int.from_bytes(
                        chunk[offset:offset + sample_width],
                        byteorder="little",
                        signed=True
                    )
                    total += sample * sample
                    seen += 1

                rms = (
                    (total / seen) ** 0.5
                    if seen
                    else 0
                )

                raw_samples.append(
                    float(
                        rms
                    )
                )

            max_sample = max(
                raw_samples
                or [
                    1.0
                ]
            )

            if max_sample <= 0:
                return []

            samples = []

            for value in raw_samples:

                normalized = value / max_sample

                samples.append(
                    max(
                        0.12,
                        min(
                            1.0,
                            0.18 + normalized * 0.82
                        )
                    )
                )


            return samples

        except Exception:

            return []

    def ensure_source(self):

        path = self.resolve_audio_path()

        if not path:
            return False

        self.ensure_player()

        if path != self.loaded_path:

            self.loaded_path = path
            self.player.setSource(
                QUrl.fromLocalFile(
                    path
                )
            )
            self.load_waveform()

        return True

    def toggle_playback(self):

        if not self.ensure_source():
            return

        if (
            self.player
            and self.player.playbackState()
            == QMediaPlayer.PlaybackState.PlayingState
        ):

            self.player.pause()

        else:

            self.player.play()

    def seek_to_ratio(
        self,
        ratio
    ):

        duration = (
            self.duration_ms
            or (
                self.player.duration()
                if self.player
                else 0
            )
        )

        if duration <= 0:
            return

        if self.ensure_source():

            self.player.setPosition(
                int(
                    duration * ratio
                )
            )

    def on_position_changed(
        self,
        position
    ):

        duration = (
            self.duration_ms
            or (
                self.player.duration()
                if self.player
                else 0
            )
        )

        if duration > 0:

            self.waveform.set_progress(
                position / duration
            )

        tail = format_millis(
            duration
        )

        self.time_label.setText(
            f"{format_millis(position)} / {tail}"
        )

    def on_duration_changed(
        self,
        duration
    ):

        self.duration_ms = duration

        if duration > 0:

            self.time_label.setText(
                f"0:00 / {format_millis(duration)}"
            )

    def on_state_changed(
        self,
        state
    ):

        if state == QMediaPlayer.PlaybackState.PlayingState:

            self.play_button.setText(
                "⏸"
            )

        else:

            self.play_button.setText(
                "▶"
            )

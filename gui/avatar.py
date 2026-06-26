import hashlib
from pathlib import Path

from PyQt6.QtCore import Qt, QRectF
from PyQt6.QtGui import QColor, QIcon, QPainter, QPainterPath, QPixmap


def _colors(seed):
    digest = hashlib.sha256(seed.encode("utf-8")).digest()
    hue = digest[0]
    return (
        QColor.fromHsv(hue, 105, 190),
        QColor.fromHsv((hue + 32) % 255, 130, 140)
    )


def _initials(name):
    parts = [
        part
        for part in (name or "").strip().split()
        if part
    ]

    if not parts:
        return "?"

    if len(parts) == 1:
        return parts[0][:2].upper()

    return (parts[0][:1] + parts[1][:1]).upper()


def round_pixmap(path, size, fallback_name="", fallback_seed=""):
    source = QPixmap()

    if path and Path(path).exists():
        source.load(path)

    target = QPixmap(size, size)
    target.fill(Qt.GlobalColor.transparent)

    painter = QPainter(target)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)

    circle = QPainterPath()
    circle.addEllipse(QRectF(0, 0, size, size))
    painter.setClipPath(circle)

    if not source.isNull():
        scaled = source.scaled(
            size,
            size,
            Qt.AspectRatioMode.KeepAspectRatioByExpanding,
            Qt.TransformationMode.SmoothTransformation
        )
        x = (size - scaled.width()) // 2
        y = (size - scaled.height()) // 2
        painter.drawPixmap(x, y, scaled)
    else:
        color_a, color_b = _colors(fallback_seed or fallback_name or "?")
        painter.fillRect(0, 0, size, size, color_a)
        painter.setBrush(color_b)
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawEllipse(
            int(size * 0.38),
            int(size * 0.18),
            int(size * 0.78),
            int(size * 0.78)
        )
        painter.setPen(QColor("#ffffff"))
        font = painter.font()
        font.setBold(True)
        font.setPointSize(max(9, size // 3))
        painter.setFont(font)
        painter.drawText(
            QRectF(0, 0, size, size),
            Qt.AlignmentFlag.AlignCenter,
            _initials(fallback_name)
        )

    painter.end()
    return target


def avatar_icon(path, name, seed, size=36):
    return QIcon(
        round_pixmap(path, size, name, seed)
    )

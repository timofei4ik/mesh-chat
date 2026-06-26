from pathlib import Path

from PyQt6.QtCore import QByteArray, QBuffer, QIODevice, Qt
from PyQt6.QtGui import QImageReader


IMAGE_EXTENSIONS = (
    ".png",
    ".jpg",
    ".jpeg",
    ".bmp",
    ".webp"
)


def is_compressible_image(path):

    return Path(path).suffix.lower() in IMAGE_EXTENSIONS


def prepare_image_for_send(
    file_path,
    compress=True,
    max_side=1600,
    quality=82
):

    path = Path(
        file_path
    )

    original_bytes = path.read_bytes()
    filename = path.name

    if (
        not compress
        or not is_compressible_image(path)
    ):

        return filename, original_bytes

    reader = QImageReader(
        str(path)
    )
    reader.setAutoTransform(
        True
    )
    image = reader.read()

    if image.isNull():
        return filename, original_bytes

    if (
        image.width() > max_side
        or image.height() > max_side
    ):

        image = image.scaled(
            max_side,
            max_side,
            Qt.AspectRatioMode.KeepAspectRatio,
            Qt.TransformationMode.SmoothTransformation
        )

    data = QByteArray()
    buffer = QBuffer(
        data
    )
    buffer.open(
        QIODevice.OpenModeFlag.WriteOnly
    )

    image.save(
        buffer,
        "JPG",
        quality
    )

    compressed = bytes(
        data
    )

    if (
        not compressed
        or len(compressed) >= len(original_bytes)
    ):

        return filename, original_bytes

    output_name = path.with_suffix(
        ".jpg"
    ).name

    return output_name, compressed

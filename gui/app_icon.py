import sys
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtGui import QIcon, QPixmap


def resource_path(*parts):

    if getattr(
        sys,
        "frozen",
        False
    ):

        base = Path(
            getattr(
                sys,
                "_MEIPASS",
                Path(sys.executable).parent
            )
        )

    else:

        base = Path(__file__).resolve().parents[1]

    return str(
        base.joinpath(
            *parts
        )
    )


def app_icon():

    return QIcon(
        resource_path(
            "assets",
            "app_icon.png"
        )
    )


def app_logo(size=48):

    pixmap = QPixmap(
        resource_path(
            "assets",
            "app_icon.png"
        )
    )

    if pixmap.isNull():
        return pixmap

    return pixmap.scaled(
        size,
        size,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation
    )

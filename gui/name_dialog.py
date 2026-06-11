from PyQt6.QtWidgets import QInputDialog


def ask_username():

    name, ok = QInputDialog.getText(
        None,
        "MeshChat",
        "Введите имя пользователя:"
    )

    if ok:

        name = name.strip()

        if name:
            return name

    return None
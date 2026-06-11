from PyQt6.QtWidgets import(
    QMessageBox
)


class ChatRequestDialog:

    @staticmethod
    def show(parent, username):

        msg = QMessageBox(parent)

        msg.setWindowTitle(
            "Новый запрос"
        )

        msg.setText(
            f"{username} хочет начать чат"
        )

        accept = msg.addButton(
            "Принять",
            QMessageBox.ButtonRole.AcceptRole
        )

        decline = msg.addButton(
            "Отклонить",
            QMessageBox.ButtonRole.RejectRole
        )

        msg.exec()

        if msg.clickedButton() == accept:
            return True
        
        return False
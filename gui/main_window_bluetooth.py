import threading

from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QInputDialog,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
)

from network.bluetooth_discovery import get_paired_bluetooth_devices
from network.bluetooth_transport import send_bluetooth_packet
from network.message_id import generate_message_id


class BluetoothMixin:
    def set_bluetooth_channel(
        self,
        channel
    ):

        self.bluetooth_channel = channel
        self.update_bluetooth_status()

        print(
            "MeshChat Bluetooth channel:",
            channel
        )

    def update_bluetooth_status(self):

        if self.bluetooth_channel is None:

            status = "Bluetooth сервер не запущен"

        else:

            address = self.bluetooth_address or "не найден"

            status = (
                f"MAC: {address} | "
                f"channel: {self.bluetooth_channel}"
            )

        self.bluetooth_status_label.setText(
            status
        )

        self.settings_bluetooth_label.setText(
            status
        )

    def scan_bluetooth_contacts(self):

        if self.bluetooth_channel is None:

            QMessageBox.warning(
                self,
                "Bluetooth",
                "Запустите приложение с --bluetooth-channel 0."
            )

            return

        if not self.bluetooth_address:

            QMessageBox.warning(
                self,
                "Bluetooth",
                "Не удалось определить Bluetooth MAC этого компьютера."
            )

            return

        devices = get_paired_bluetooth_devices()

        devices = [
            device
            for device in devices
            if device["address"] != self.bluetooth_address
        ]

        if not devices:

            QMessageBox.information(
                self,
                "Bluetooth",
                "Спаренные Bluetooth-устройства не найдены."
            )

            return

        labels = [
            (
                f"{device['name']} "
                f"({device['address']}, {device.get('status') or 'unknown'})"
            )
            for device in devices
        ]

        selected_label, ok = QInputDialog.getItem(
            self,
            "Bluetooth",
            "Выберите устройство для проверки MeshChat:",
            labels,
            0,
            False
        )

        if not ok:
            return

        selected_index = labels.index(
            selected_label
        )

        selected_device = devices[
            selected_index
        ]

        self.bluetooth_scan_button.setEnabled(
            False
        )

        threading.Thread(
            target=self.run_bluetooth_scan,
            args=(selected_device,),
            daemon=True
        ).start()

    def run_bluetooth_scan(
        self,
        device
    ):

        attempts = 0

        print(
            "Bluetooth selected device:",
            device
        )

        address = device["address"]

        packet = {

            "packet_id":
            generate_message_id(),

            "type":
            "bluetooth_hello",

            "source_node":
            self.node_id,

            "sender":
            self.username,

            "source_bluetooth_address":
            self.bluetooth_address,

            "source_bluetooth_channel":
            self.bluetooth_channel or 0
        }

        for channel in range(
            1,
            31
        ):

            if send_bluetooth_packet(
                address,
                channel,
                packet
            ):

                attempts += 1

        self.bluetooth_scan_done.emit(
            attempts
        )

    def show_bluetooth_scan_result(
        self,
        attempts
    ):

        self.bluetooth_scan_button.setEnabled(
            True
        )

        QMessageBox.information(
            self,
            "Bluetooth",
            f"Проверка завершена. Успешных подключений: {attempts}"
        )

    def handle_bluetooth_hello(
        self,
        packet
    ):

        peer_node_id = packet.get(
            "source_node"
        )

        peer_name = packet.get(
            "sender"
        ) or "Bluetooth"

        peer_address = (
            packet.get("remote_bluetooth_address")
            or packet.get("source_bluetooth_address")
        )

        peer_channel = packet.get(
            "source_bluetooth_channel",
            0
        )

        if not peer_node_id or not peer_address:
            return

        self.save_bluetooth_contact(
            peer_node_id,
            peer_name,
            peer_address,
            peer_channel
        )

        if self.bluetooth_address:

            response = {

                "packet_id":
                generate_message_id(),

                "type":
                "bluetooth_hello_response",

                "source_node":
                self.node_id,

                "destination_node":
                peer_node_id,

                "sender":
                self.username,

                "source_bluetooth_address":
                self.bluetooth_address,

                "source_bluetooth_channel":
                self.bluetooth_channel or 0
            }

            send_bluetooth_packet(
                peer_address,
                peer_channel,
                response
            )

        self.notify(
            "Bluetooth",
            f"Найден {peer_name}"
        )

        self.refresh_chats()

    def handle_bluetooth_hello_response(
        self,
        packet
    ):

        peer_node_id = packet.get(
            "source_node"
        )

        peer_name = packet.get(
            "sender"
        ) or "Bluetooth"

        peer_address = (
            packet.get("remote_bluetooth_address")
            or packet.get("source_bluetooth_address")
        )

        peer_channel = packet.get(
            "source_bluetooth_channel",
            0
        )

        if not peer_node_id or not peer_address:
            return

        self.save_bluetooth_contact(
            peer_node_id,
            peer_name,
            peer_address,
            peer_channel
        )

        self.notify(
            "Bluetooth",
            f"Добавлен {peer_name}"
        )

        self.refresh_chats()

    def save_bluetooth_contact(
        self,
        peer_node_id,
        peer_name,
        bluetooth_address,
        bluetooth_channel
    ):

        self.db.update_user(
            peer_node_id,
            peer_name,
            f"BT:{bluetooth_address}",
            bluetooth_channel
        )

    def open_bluetooth_chat_dialog(self):

        peer_name, ok = QInputDialog.getText(
            self,
            "Bluetooth чат",
            "Имя контакта:"
        )

        if not ok:
            return

        peer_name = peer_name.strip()

        if not peer_name:
            return

        peer_node_id, ok = QInputDialog.getText(
            self,
            "Bluetooth чат",
            "Node ID второго компьютера:"
        )

        if not ok:
            return

        peer_node_id = peer_node_id.strip()

        if not peer_node_id:
            return

        if peer_node_id == self.node_id:

            QMessageBox.warning(
                self,
                "Bluetooth чат",
                "Это ваш Node ID. Введите Node ID второго компьютера."
            )

            return

        bluetooth_address, ok = QInputDialog.getText(
            self,
            "Bluetooth чат",
            "Bluetooth MAC второго компьютера:"
        )

        if not ok:
            return

        bluetooth_address = bluetooth_address.strip()

        if not bluetooth_address:
            return

        bluetooth_channel, ok = QInputDialog.getInt(
            self,
            "Bluetooth чат",
            "Bluetooth channel второго компьютера:",
            0,
            0,
            30
        )

        if not ok:
            return

        peer_ip = f"BT:{bluetooth_address}"

        self.save_bluetooth_contact(
            peer_node_id,
            peer_name,
            bluetooth_address,
            bluetooth_channel
        )

        self.open_chat(
            peer_name,
            peer_node_id,
            peer_ip,
            bluetooth_channel,
            "bluetooth",
            bluetooth_address,
            bluetooth_channel
        )

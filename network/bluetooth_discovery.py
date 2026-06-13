import json
import re
import subprocess


DEVICE_ID_RE = re.compile(
    r"DEV_([0-9A-Fa-f]{12})"
)


def normalize_bluetooth_address(address):

    if not address:
        return None

    value = re.sub(
        r"[^0-9A-Fa-f]",
        "",
        address
    ).upper()

    if len(value) != 12:
        return None

    return ":".join(
        value[i:i + 2]
        for i in range(
            0,
            12,
            2
        )
    )


def run_powershell_json(command):

    completed = subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-Command",
            command
        ],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20
    )

    if completed.returncode != 0:
        return []

    output = completed.stdout.strip()

    if not output:
        return []

    data = json.loads(
        output
    )

    if isinstance(
        data,
        dict
    ):

        return [
            data
        ]

    return data


def get_local_bluetooth_address():

    adapters = run_powershell_json(
        "Get-CimInstance Win32_NetworkAdapter "
        "| Where-Object { $_.Name -match 'Bluetooth' -and $_.MACAddress } "
        "| Select-Object -First 1 Name,MACAddress "
        "| ConvertTo-Json"
    )

    if not adapters:
        return None

    return normalize_bluetooth_address(
        adapters[0].get(
            "MACAddress"
        )
    )


def get_paired_bluetooth_devices():

    devices = run_powershell_json(
        "Get-PnpDevice -Class Bluetooth "
        "| Select-Object FriendlyName,InstanceId,Status "
        "| ConvertTo-Json"
    )

    result = []
    seen = set()

    for device in devices:

        instance_id = device.get(
            "InstanceId",
            ""
        )

        match = DEVICE_ID_RE.search(
            instance_id
        )

        if not match:
            continue

        address = normalize_bluetooth_address(
            match.group(1)
        )

        if not address:
            continue

        if address in seen:
            continue

        seen.add(
            address
        )

        result.append(
            {
                "name": device.get(
                    "FriendlyName"
                ) or address,

                "address": address,

                "status": device.get(
                    "Status"
                )
            }
        )

    return result

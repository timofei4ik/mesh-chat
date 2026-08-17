import base64
import getpass
import hashlib
import secrets


password = getpass.getpass("Moderation admin password: ")
confirmation = getpass.getpass("Repeat password: ")
if len(password) < 12:
    raise SystemExit("Password must contain at least 12 characters")
if password != confirmation:
    raise SystemExit("Passwords do not match")
salt = secrets.token_bytes(16)
digest = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
print(
    "scrypt$"
    + base64.urlsafe_b64encode(salt).decode()
    + "$"
    + base64.urlsafe_b64encode(digest).decode()
)

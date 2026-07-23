from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Protocol
import shutil


@dataclass(frozen=True)
class AccountDataPolicy:
    owner: str
    table: str
    action: str = "delete"


@dataclass
class AccountDeletionContext:
    login: str
    nodes: list[str] = field(default_factory=list)
    owned_group_ids: list[str] = field(default_factory=list)
    stored_paths: list[str] = field(default_factory=list)
    transfer_ids: list[str] = field(default_factory=list)


class AccountDeletionContextLoader(Protocol):
    def load(self, login: str) -> AccountDeletionContext:
        ...


class AccountDataOwner(Protocol):
    name: str
    policies: tuple[AccountDataPolicy, ...]

    def delete_account(self, context: AccountDeletionContext) -> None:
        ...


class AccountDeletionOrchestrator:
    def __init__(
        self,
        context_loader: AccountDeletionContextLoader,
        owners: list[AccountDataOwner],
        transaction_factory: Callable,
        pending_path_factory=None,
    ):
        self._context_loader = context_loader
        self._owners = tuple(owners)
        self._transaction_factory = transaction_factory
        self._pending_path_factory = pending_path_factory
        names = [owner.name for owner in self._owners]
        if len(names) != len(set(names)):
            raise ValueError("account deletion owner names must be unique")

    @property
    def policies(self):
        return tuple(
            policy
            for owner in self._owners
            for policy in owner.policies
        )

    def delete(self, login: str) -> AccountDeletionContext:
        normalized_login = str(login or "").strip().lower()
        if not normalized_login:
            raise ValueError("account login is required")

        with self._transaction_factory():
            context = self._context_loader.load(normalized_login)
            for owner in self._owners:
                owner.delete_account(context)

        self._cleanup_files(context)
        return context

    def _cleanup_files(self, context):
        for value in context.stored_paths:
            try:
                Path(value).unlink(missing_ok=True)
            except OSError:
                pass

        if not callable(self._pending_path_factory):
            return
        for transfer_id in context.transfer_ids:
            try:
                shutil.rmtree(
                    self._pending_path_factory(context.login, transfer_id),
                    ignore_errors=True,
                )
            except OSError:
                pass

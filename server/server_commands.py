"""Compatibility facade for the domain command modules.

The relay imports this module as its composition root. Packet handlers live in
domain-focused modules so transport dispatch no longer grows as one file.
"""

try:
    from server.server_command_bus import (
        ConnectionContext,
        PacketCommandRegistry,
        StopConnectionHandler,
    )
    from server.server_commands_ai import register_ai_commands
    from server.server_commands_automation import (
        register_automation_commands,
    )
    from server.server_commands_identity import (
        register_identity_commands,
        register_identity_control_commands,
    )
    from server.server_commands_push import register_push_commands
    from server.server_commands_subscriptions import (
        register_subscription_commands,
    )
    from server.server_commands_sync import register_sync_control_commands
    from server.server_calls import register_call_commands
except ModuleNotFoundError:
    from server_command_bus import (
        ConnectionContext,
        PacketCommandRegistry,
        StopConnectionHandler,
    )
    from server_commands_ai import register_ai_commands
    from server_commands_automation import register_automation_commands
    from server_commands_identity import (
        register_identity_commands,
        register_identity_control_commands,
    )
    from server_commands_push import register_push_commands
    from server_commands_subscriptions import (
        register_subscription_commands,
    )
    from server_commands_sync import register_sync_control_commands
    from server_calls import register_call_commands


def build_command_registry():
    registry = PacketCommandRegistry()
    register_subscription_commands(registry)
    register_push_commands(registry)
    register_identity_commands(registry)
    register_automation_commands(registry)
    register_ai_commands(registry)
    register_call_commands(registry)
    return registry


def build_control_command_registry():
    registry = PacketCommandRegistry()
    register_identity_control_commands(registry)
    register_sync_control_commands(registry)
    return registry


__all__ = [
    "ConnectionContext",
    "PacketCommandRegistry",
    "StopConnectionHandler",
    "build_command_registry",
    "build_control_command_registry",
]
